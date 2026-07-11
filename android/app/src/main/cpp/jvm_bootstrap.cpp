// Native JNI Invocation-API bootstrap + render/input host for the embedded HotSpot VM.
//
// The app process is ART's. Here we dlopen the embedded JRE's libjvm.so and call JNI_CreateJavaVM to
// stand up a SECOND, in-process HotSpot VM (the one that runs RuneLite). This mirrors the iOS bootstrap
// (ios/app/RuneMobile/JVMLauncher.m) but drops every iOS-JIT workaround: Android grants JIT for free, so
// there is no MirrorMappedCodeCache, no brk #0x69 debugger mirror, no exception-port juggling.
//
// Milestone B host model:
//   * The VM is created on a dedicated, never-exiting native thread (the HotSpot "main" thread). It then
//     runs DeviceHeadlessBoot.main, which boots headless RuneLite under CACIO CTC and keeps the engine
//     running on its own threads. We do NOT DestroyJavaVM — the process owns teardown.
//   * The net.runelite.client.headless.JavaBridge facade (cached as HotSpot global refs at boot) is the
//     one Java seam. A render thread pulls JavaBridge.getFramePixels() each refresh and blits to the
//     SurfaceView's ANativeWindow; UI touches are enqueued (no ART->HotSpot attach) and drained by the
//     render thread, which is the only thread that calls into the bridge.

#include <jni.h>
#include <dlfcn.h>
#include <dirent.h>
#include <stdlib.h>
#include <string>
#include <vector>
#include <deque>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <algorithm>
#include <unistd.h>
#include <pthread.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#ifndef JNI_VERSION_21
#define JNI_VERSION_21 0x00150000
#endif

#define LOG_TAG "jvm-boot"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

typedef jint (*CreateJavaVM_t)(JavaVM **, void **, void *);

// ---- Process-global VM + bridge state ----------------------------------------------------------------
// g_vm is the single in-process HotSpot VM, published once JNI_CreateJavaVM succeeds. ATOMIC: the worker
// thread stores it while the ART UI thread reads it (the startJvm re-entry guard) and the render thread reads
// it to attach — a plain global would be a data race (mirrors the iOS atomic VM pointer). A JNIEnv* is NEVER
// shared across threads; every thread that needs one daemon-attaches itself (see bridgeEnvAttach).
static std::atomic<JavaVM *> g_vm{nullptr};

// JavaBridge facade, cached as HotSpot global refs at boot (never FindClass on the hot path).
static jclass    g_bridgeCls = nullptr;
static jmethodID g_midSeq = nullptr, g_midW = nullptr, g_midH = nullptr, g_midPixels = nullptr;
static jmethodID g_midTouch = nullptr, g_midClick = nullptr, g_midCamera = nullptr, g_midClearHover = nullptr;
// A1 input-parity methods: pinch-wheel, precise (no-snap) click, hover-move, text + special keys.
static jmethodID g_midWheel = nullptr, g_midClickPrecise = nullptr, g_midMove = nullptr;
static jmethodID g_midText = nullptr, g_midKeyStroke = nullptr;
// A1 polled read-surface: keyboard auto-raise, interact-tap haptic seq, finger snap radius.
static jmethodID g_midTextInputOpen = nullptr, g_midInteractTapSeq = nullptr;
// Tap-KIND truth (optional jar surface; older jars omit it -> the shell keeps the legacy ring).
static jmethodID g_midTapKindSeq = nullptr, g_midLastTapKind = nullptr, g_midLastWidgetBounds = nullptr;
// A2 press-and-peek: JavaBridge.selectMenuPoint commit + the separate MenuPeekBridge read-surface.
static jmethodID g_midSelectMenuPoint = nullptr;
// AP-2a sticky-Shift: JavaBridge.setShiftHeld(boolean) — synthetic held VK_SHIFT (shared, iOS-device-proven).
static jmethodID g_midSetShiftHeld = nullptr;
// Hotkey chord: JavaBridge.onKeybind(keyCode, modifiers) — posts a matched KEY_PRESSED+KEY_RELEASED so a
// native per-plugin hotkey button fires the plugin's Keybind. Optional resolve (older jars lack it).
static jmethodID g_midKeybind = nullptr;
// Sticky Ctrl/Alt latch (mirror of setShiftHeld) + a discrete middle-button click. Optional resolve.
static jmethodID g_midSetCtrlHeld = nullptr, g_midSetAltHeld = nullptr, g_midMiddleClick = nullptr;
// FIX-10b: JavaBridge.invokeMenuEntry(int parentDisplayIndex, int childIndex) — commit a native tap-menu row /
// submenu child directly (child<0 = the parent entry itself). Optional resolve (older jars lack it).
static jmethodID g_midInvokeMenuEntry = nullptr;
// FIX-3 idle keepalive: JavaBridge.keepAlive() — bump the idle-logout timer on a native-UI touch (optional;
// best-effort so an older staged jar without the method still boots).
static jmethodID g_midKeepAlive = nullptr;
static jclass    g_menuPeekCls = nullptr;
static jmethodID g_midMenuSnapshot = nullptr, g_midMenuPublishSeq = nullptr;

// A4 plugin control plane (MobileUiBridge) — resolved best-effort; inert unless -Drunelite.mobileui=true.
// Called from a dedicated ART background thread (the Kotlin "rl-bridge" executor), which daemon-attaches to
// HotSpot via bridgeEnvAttach() — never the ART UI thread (ANR risk). Strings cross the VM boundary as UTF-8.
static jclass    g_mobileUiCls = nullptr;
static jmethodID g_midListPlugins = nullptr, g_midMobileUiSeq = nullptr, g_midPollEvents = nullptr, g_midSetPluginEnabled = nullptr;
static jmethodID g_midGetPluginConfig = nullptr, g_midSetConfig = nullptr, g_midProcessedWriteId = nullptr;
// User-defined hotkey buttons: boundKeybindsJson() lists every bound plugin keybind; fireHotkey(group,key) fires
// one by reading its live binding. Optional (older jars lack them) — the native Hotkeys screen no-ops without.
static jmethodID g_midBoundKeybinds = nullptr, g_midFireHotkey = nullptr;
static jmethodID g_midFlushConfig = nullptr;   // A8: persist pending config writes when the app backgrounds
static jmethodID g_midResetPluginConfig = nullptr;     // SC-2/CFG-10: whole-group reset to defaults
static jmethodID g_midNotificationDefaults = nullptr;  // SC-1/NOTIF-2: default Notification seed JSON
// AP-2a bridge-amortized read surface (best-effort; a null only disables that one feature):
//   nextNotification() -> "titlebody" or null  (Finding 9: NotificationManager delivery)
//   nextLink()         -> URL or null                (Finding 25: Chrome Custom Tab)
//   hubState()         -> {"refreshing":b,"seq":i}    (Finding 17: hub install progress)
static jmethodID g_midNextNotification = nullptr, g_midNextLink = nullptr, g_midHubState = nullptr;
static jmethodID g_midNextScreenshot = nullptr; // PARITY-ANDROID-SHOT: next auto-screenshot path or null
static jmethodID g_midHubManifest = nullptr, g_midHubInstall = nullptr, g_midHubUninstall = nullptr;
// Native-origin publish into the SAME shared queues (host-raised alerts/links; also deterministic path tests).
static jmethodID g_midPublishNotification = nullptr, g_midPublishLink = nullptr;
// AP-2b Finding 6: pin/star a plugin by display name (shared pinnedPlugins CSV; sorts the list pinned-first).
static jmethodID g_midSetPinned = nullptr;
// A5 Tier-1 plugin panels (rendered off-screen under CACIO; the ARGB int[] image is marshalled cross-VM).
static jmethodID g_midListPanels = nullptr, g_midOpenPanel = nullptr, g_midClosePanel = nullptr,
                 g_midPanelW = nullptr, g_midPanelH = nullptr, g_midPanelSeq = nullptr,
                 g_midPanelPixels = nullptr, g_midPanelClick = nullptr;
// SC-4 panel-text input (best-effort; a null disables only that interaction, not the whole panel surface).
static jmethodID g_midIsPanelTextActive = nullptr, g_midGetPanelText = nullptr, g_midPanelText = nullptr,
                 g_midPanelKey = nullptr, g_midPanelLongPress = nullptr, g_midPanelWheel = nullptr,
                 g_midPanelMove = nullptr;
// Native Notes panel: a single editable note string (config group "notes"/key "notesData") on MobileUiBridge —
// notesGet/Set instead of the rendered Swing screenshot. Best-effort (a null disables only the Notes tile).
static jmethodID g_midNotesAvailable = nullptr, g_midNotesGet = nullptr, g_midNotesSet = nullptr;
// Publication latches for the MobileUiBridge facade. The method-id globals above are plain (non-atomic),
// written once on the VM boot thread (publishBridge); the A4/A5 externs run on the SEPARATE rl-bridge thread
// and a UI tap can submit a bridge call before startJvm even returns. These release/acquire flags give the
// happens-before so an extern NEVER reads a half-published facade. g_panelReady is ALL-OR-NOTHING: true only
// if EVERY panel method the viewer uses resolved (incl. closePanel — without it, viewer dispose would
// silently leak the open engine-side panel).
static std::atomic<bool> g_mobileUiReady{false};
static std::atomic<bool> g_panelReady{false};

// A5 Tier-2 native reflow facades — QuestHelperBridge / WorldSwitcherBridge. Separate classes (like
// MenuPeekBridge), already init()'d + tick()'d by MobileUiBridge, so live whenever -Drunelite.mobileui=true.
// Read on the rl-bridge thread, so each gets a release/acquire publication latch like MobileUiBridge (all-or-
// nothing). NOTE: Quest's isAvailable() is false unless the Quest Helper hub plugin is installed (the native
// screen then falls back to the Tier-1 rendered panel); the seam still resolves either way.
static jclass    g_questCls = nullptr;
static jmethodID g_midQuestAvail = nullptr, g_midQuestSetUiOpen = nullptr, g_midQuestList = nullptr,
                 g_midQuestActive = nullptr, g_midQuestStart = nullptr, g_midQuestStop = nullptr;
static jclass    g_worldCls = nullptr;
static jmethodID g_midWorldAvail = nullptr, g_midWorldSetUiOpen = nullptr, g_midWorldList = nullptr, g_midWorldHop = nullptr;
static jmethodID g_midWorldSetFav = nullptr, g_midWorldHopDir = nullptr;   // SC-5 favourites + quick-hop (best-effort)
// Finding 15 — overlay edit (OverlayBridge): list movable overlays, snap one to a corner, reset to default.
static jclass    g_overlayCls = nullptr;
static jmethodID g_midOverlayAvail = nullptr, g_midOverlaySetUiOpen = nullptr, g_midOverlaysJson = nullptr,
                 g_midOverlaySnap = nullptr, g_midOverlayReset = nullptr, g_midOverlaySetLoc = nullptr;
// Finding 22 — infobox menu (InfoBoxBridge): list infoboxes + their menu options, invoke one (Detach/Flip/Delete).
static jclass    g_infoboxCls = nullptr;
static jmethodID g_midInfoBoxAvail = nullptr, g_midInfoBoxSetUiOpen = nullptr, g_midInfoBoxesJson = nullptr,
                 g_midInfoBoxInvoke = nullptr;
// RuneLite-account login (config sync): start/stop the runelite.net OAuth + read the session state.
static jclass    g_accountCls = nullptr;
static jmethodID g_midAccountAvail = nullptr, g_midAccountLogin = nullptr, g_midAccountLogout = nullptr,
                 g_midAccountSession = nullptr;
static std::atomic<bool> g_questReady{false};
static std::atomic<bool> g_worldReady{false};
static std::atomic<bool> g_overlayReady{false};
static std::atomic<bool> g_infoboxReady{false};
static std::atomic<bool> g_accountReady{false};
// Config profiles (ConfigProfileBridge): list profiles + switch the active one (mirrors the desktop ProfilePanel).
static jclass    g_profileCls = nullptr;
static jmethodID g_midProfileAvail = nullptr, g_midProfilesJson = nullptr, g_midProfileSwitch = nullptr;
static std::atomic<bool> g_profileReady{false};

// Finding 14 — read-only data-panel facades (XP Tracker, Loot Tracker, GE, Time Tracking). All share the same
// shape: isAvailable()Z / setUiOpen(Z)V / <jsonGetter>()String. One struct + one generic registrar covers them.
struct DataPanel { jclass cls = nullptr; jmethodID avail = nullptr, setUiOpen = nullptr, json = nullptr;
                   std::atomic<bool> ready{false}; };
static DataPanel g_xpPanel;
static DataPanel g_lootPanel;
static jmethodID g_midLootReset = nullptr;   // LootTrackerBridge.resetAll() — "Reset All" write action (optional)
static DataPanel g_gePanel;
static DataPanel g_timePanel;   // TimeTrackingBridge — farming/contract/bird-house/timer/stopwatch countdowns
// A6 chrome: MobileChromeBridge read-only snapshot facade (tab/panel/minimap/orb/chat/viewport canvas bounds
// the native edge-rails cover-and-proxy reads each display tick). Separate facade; rl-bridge-thread read
// behind a release/acquire latch. Single method (getSnapshot) — populated only under -Drunelite.mobilechrome.
static jclass    g_chromeCls = nullptr;
static jmethodID g_midChromeSnap = nullptr;
static jmethodID g_midChromeSnapSeq = nullptr;   // Phase 3 (optional): content-diff publish seq for the gate below
static std::atomic<bool> g_chromeReady{false};
// A6 chrome write surface: HudVeneerBridge — hides the 14 engine tab stones (the native 2-col grid replaces
// them), opens a tab by replaying its stone op-script (works while hidden), and relocates the engine side panel
// flush-left of the grid. Separate facade; rl-bridge-thread write behind a release/acquire latch. Inert in the
// engine unless -Drunelite.hudveneer=true. ALL-OR-NOTHING: published only if every method id resolves.
static jclass    g_hudCls = nullptr;
static jmethodID g_midSetStonesHidden = nullptr, g_midOpenTab = nullptr, g_midRelocateSidePanel = nullptr;
static jmethodID g_midRelocateChat = nullptr, g_midRelocateMinimap = nullptr;
// Phase-3 overlay safe-insets (optional — absent on pre-world-map jars; facadeVoid* null-checks the id).
static jmethodID g_midSetOverlayInsets = nullptr;
// Phase-4 chat pill (optional, same rule): collapse toggle + channel switch by op-script replay.
static jmethodID g_midSetChatCollapsed = nullptr, g_midSwitchChatTab = nullptr;
// Phase-5 world map (optional): pan by finger deltas + the open-state/control-rect snapshot.
static jmethodID g_midPanWorldMap = nullptr, g_midMapSnapshot = nullptr;
// Phase 3 (Task B): content-diff publish seqs for the chat/orb/dialogue/map snapshots — gate the per-frame
// republish copy on a seq change (the menu-peek pattern). All OPTIONAL — a jar predating them just always copies.
static jmethodID g_midChatSnapshotSeq = nullptr, g_midOrbSnapshotSeq = nullptr;
static jmethodID g_midDialogueSeq = nullptr, g_midMapSnapshotSeq = nullptr;
static jmethodID g_midScrollMapPanel = nullptr;   // world-map KEY/MAPLIST swipe-scroll (optional)
// FIX-5 native open-map control (optional, same rule): open the world map by ORB_WORLDMAP op-script replay.
static jmethodID g_midOpenWorldMap = nullptr;
static std::mutex g_mapLock;
static std::string g_mapSnapshotPub = "{\"open\":false}";
static std::atomic<long long> g_mapSnapSeq{-1};   // Phase 3 (Task B): last world-map seq we copied at
// A3 enlarged native chat-tab veneer: getChatSnapshot (per-frame tab geometry/state the bigger native buttons
// read) + setChatTabRowHeight / setChatAreaWidth (tell the engine to push the message area below the taller row).
static jmethodID g_midChatSnapshot = nullptr, g_midSetChatRowH = nullptr, g_midSetChatAreaW = nullptr;
// AP-0 chat scroll-by-drag: scrollChat(deltaCanvasPx) drives the chatbox's OWN scroll layer (not a mouse
// wheel — a wheel over the transparent chat would also zoom the camera).
static jmethodID g_midScrollChat = nullptr;
// Native minimap-orb touch veneer: getOrbSnapshot (per-frame orb canvas bounds the native shell enlarges +
// proxy-clicks). OPTIONAL (never in the hud all-or-nothing gate) — an older staged jar simply loses the veneer.
static jmethodID g_midOrbSnapshot = nullptr;
// Runtime tab/stone/chat sprite set from the live cache (HudVeneerBridge.tabSprites) — one-shot, read on demand
// by the native shell so the 2-col grid composites the real OSRS art with nothing bundled. OPTIONAL (never in the
// hud all-or-nothing gate) — an older staged jar simply has no runtime sprites and the shell keeps its fallback.
static jmethodID g_midTabSprites = nullptr;
static std::atomic<bool> g_hudReady{false};

// ---- Surface / render --------------------------------------------------------------------------------
static std::mutex      g_winLock;
static ANativeWindow  *g_window = nullptr;     // SurfaceView's window (acquired); guarded by g_winLock
// Bumped every time the window pointer changes (surface destroy/recreate). The render thread re-applies
// ANativeWindow_setBuffersGeometry on a generation change — without this, a recreated surface with the SAME
// frame dims keeps the render loop's cached geomW/geomH, so the new window never gets its format/geometry set.
static std::atomic<uint64_t> g_surfaceGen{0};
// GPU direct-present (routecgpu/routecrlhd): when true the GPU draw thread presents straight to the SurfaceView
// via an EGL window surface (eglSwapBuffers), so the CPU present thread below must NOT also drive the Surface —
// a BufferQueue allows ONE producer, and an EGL window surface can't attach to a Surface the CPU path connected.
static std::atomic<bool> g_directPresent{false};
// PERF-BATTERY-NETWORK-01: set from the ART UI thread (onStop/onStart via nativeSetPaused) when the app is
// backgrounded. While true the render thread drops its per-tick JNI snapshot-republish batch to a 4 Hz
// drainInput-only idle (the UI thread isn't drawing the native overlays, so the republishes are wasted), and
// the GPU draw thread's swapBuffers paces itself (librlawt, keyed off the absent Surface). Stops a pinned CPU
// core / Mali GPU while screen-locked. Foreground (paused=false) is unchanged.
static std::atomic<bool> g_paused{false};

// Present seam handed to librlawt.cpp (it links EGL/GLES but not libandroid). librlawt owns the EGL window
// surface; these let it borrow the SurfaceView window + watch for surface recreate, with libandroid kept here.
static void* rcPresentAcquireWindow(uint64_t* outGen) {
    std::lock_guard<std::mutex> lk(g_winLock);
    if (outGen) *outGen = g_surfaceGen.load(std::memory_order_acquire);
    if (g_window) ANativeWindow_acquire(g_window);
    return g_window;   // ANativeWindow* as void*; caller releases via rcPresentReleaseWindow
}
static uint64_t rcPresentSurfaceGen() { return g_surfaceGen.load(std::memory_order_acquire); }
static void rcPresentReleaseWindow(void* win) { if (win) ANativeWindow_release((ANativeWindow*)win); }

static pthread_t       g_renderThread;
static bool            g_renderStarted = false;
static volatile bool   g_renderRun = false;
// Last frame dims the render thread saw — read by the UI thread to map touch coords to game space.
// std::atomic (not plain volatile): cross-thread publication needs real atomics under the C++ memory
// model. Two separate atomics suffice — the login canvas dims are fixed, so a torn {w,h} pair (which
// would only matter mid-resize) can't arise in this scope.
static std::atomic<int> g_lastFrameW{0};
static std::atomic<int> g_lastFrameH{0};
// Phase 3 (auto-GPU watchdog): resolved from librlawt via dlsym when direct present is armed; returns the count of
// frames presented by the GPU/117HD renderer (0 if not armed / renderer never activated). Polled by Kotlin.
static uint64_t (*g_routecFramesPresented)() = nullptr;
// Present seam (cont.): in direct-present mode the CPU present thread no longer runs (it's where g_lastFrameW/H
// were set), so librlawt publishes the live canvas dims here each frame — touch->game coordinate mapping
// (JvmLauncher.frameWidth/Height) depends on them, else clicks map off-canvas.
static void rcPresentSetFrameDims(int w, int h) {
    if (w > 0 && h > 0) { g_lastFrameW.store(w, std::memory_order_relaxed); g_lastFrameH.store(h, std::memory_order_relaxed); }
}

// A1 read-surface published by the render thread (the only HotSpot-attached caller) for the UI thread to read
// without ever attaching to HotSpot — same pattern as the frame dims above.
static std::atomic<int> g_textInputOpen{0};   // isTextInputOpen() -> raise/dismiss the soft keyboard
static std::atomic<int> g_interactTapSeq{0};  // getInteractTapSeq() -> fire a haptic when it advances
// Tap-KIND truth (optional jar surface): the resolved left tap's kind + the last widget bounds, so the UI
// thread rings only for a real scene tap and borders a widget op. Published by the render thread each tick.
static std::atomic<int>     g_tapKindSeq{0};
static std::atomic<int>     g_lastTapKind{0};
static std::atomic<int64_t> g_lastWidgetBounds{0};

// A2 menu-peek snapshot, published by the render thread (only on seq change) for the UI thread to read.
static std::mutex            g_menuLock;
static std::string           g_menuSnapshot = "{\"active\":false}";
static std::atomic<long long> g_menuPublishSeq{-1};

// A6 chrome snapshot, republished by the render thread (the only HotSpot-attached caller) for the UI thread's
// cover-and-proxy tab-rail overlay to read lock-free without ever attaching to HotSpot — same pattern as the A2
// menu snapshot. Phase 3 (Task B): the copy is now seq-gated (getSnapshotSeq) so an unchanged frame is skipped.
static std::mutex            g_chromeLock;
static std::string           g_chromeSnapshotPub = "{\"enabled\":false}";
static std::atomic<long long> g_chromeSnapSeq{-1};   // last chrome seq we copied at (-1 = none yet)

// A3 chat-tab veneer snapshot, republished by the render thread (HudVeneerBridge.getChatSnapshot) for the UI
// thread's enlarged native chat-tab overlay to read lock-free without attaching to HotSpot. Seq-gated (Task B).
static std::mutex            g_chatLock;
static std::string           g_chatSnapshotPub = "{\"loggedIn\":false}";
static std::atomic<long long> g_chatSnapSeq{-1};
// Minimap-orb veneer snapshot, republished by the render thread (HudVeneerBridge.getOrbSnapshot). Seq-gated (Task B).
static std::mutex            g_orbLock;
static std::string           g_orbSnapshotPub = "{\"loggedIn\":false}";
// One-shot runtime tab/stone/chat sprite payload (HudVeneerBridge.tabSprites). Fetched on the HotSpot render thread
// (the only thread that may call HotSpot) into this string; the UI thread reads it lock-free via nativeTabSprites
// WITHOUT attaching — same producer/consumer split as the snapshots above. g_tabSpritesDone latches it once captured.
static std::mutex            g_tabSpritesLock;
static std::string           g_tabSprites;
static std::atomic<bool>     g_tabSpritesDone{false};
static std::atomic<long long> g_orbSnapSeq{-1};
// UI-4 NPC dialogue: getDialogueJson (optional, like getMapSnapshot) — the engine dialogue is forced transparent
// while the chat is relocated, so the native shell draws an opaque parchment over it from this snapshot. Seq-gated.
static jmethodID             g_midDialogueJson = nullptr;
static std::mutex            g_dlgLock;
static std::string           g_dialogueJsonPub = "{}";
static std::atomic<long long> g_dlgSnapSeq{-1};

// ---- Input queue (UI thread enqueues; render thread drains and dispatches into the bridge) -----------
enum InputKind {
    IN_CLICK = 0, IN_TOUCH = 1, IN_CAMERA = 2, IN_CLEARHOVER = 3,
    IN_WHEEL = 4, IN_CLICKPRECISE = 5, IN_MOVE = 6, IN_KEYSTROKE = 7, IN_TEXT = 8,
    IN_SELECTMENU = 9,
    // AP-2a sticky-Shift: hold/release a synthetic VK_SHIFT (a=1 hold, a=0 release). Queued (not a direct
    // facade call) so it's ORDERED with the menu-open click — the engine must see shift held BEFORE the
    // right-click that builds the menu, or the shift-gated entries (Mark/Configure) won't be injected.
    IN_SHIFT = 10,
    // FIX-3 idle keepalive: a native-UI touch that posts no canvas event. Queued so the already-attached
    // render thread makes the JavaBridge.keepAlive() call (the ART UI thread never attaches to HotSpot).
    IN_KEEPALIVE = 11,
    // FIX-10b submenu commit: JavaBridge.invokeMenuEntry(parentDisplayIndex=a, childIndex=b). Drives a native
    // tap-menu's submenu children (Menu Entry Swapper swap lists) — they aren't in the engine menu geometry,
    // so a geometry click (selectMenuPoint) can't reach them; this calls the entry's onClick directly.
    IN_INVOKEMENUENTRY = 12,
    // Hotkey chord: JavaBridge.onKeybind(keyCode=a, modifiers=b). Queued (not a direct facade call) so the
    // already-attached render thread makes the call and it stays ordered with any paired shift-hold.
    IN_KEYBIND = 13,
    // Sticky Ctrl/Alt latch (a=1 hold, a=0 release) — same ordering rationale as IN_SHIFT (the modifier must
    // be held before the menu-open click that reads it). IN_MIDDLECLICK is a BUTTON2 click at (a=x, b=y).
    IN_CTRL = 14, IN_ALT = 15, IN_MIDDLECLICK = 16
};
// s carries the IN_TEXT payload; empty for the int-only kinds (aggregate-inits to "").
struct InputEvent { int kind, a, b, c, d; std::string s; };
static std::mutex             g_inLock;
static std::deque<InputEvent> g_inQueue;

// ---- VM bringup latch (startJvm waits until the worker has created the VM + published the bridge) -----
static std::mutex              g_bootLock;
static std::condition_variable g_bootCv;
static bool                    g_bootDone = false;
static jint                    g_bootRc = -100;

// Heap-owned args passed to the worker thread (the ART JNIEnv can't be used off the calling thread).
struct BootArgs {
    std::string javaHome, libjvmPath, libraryPath, classpath, mainClass;
    std::vector<std::string> extraOpts;
};

// The embedded VM writes System.out/err to fd 1/2, which Android drops. Pipe both into logcat so RuneLite
// (and the Milestone-A Hello) output is visible. Robust against partial setup: closes the spare write fd
// after dup2 and bails cleanly (no reader-less pipe that could block writers) if anything fails.
// A8: gated to DEBUG builds (set from Kotlin before startJvm) — a release build must NOT leak the engine's
// stdout/err (incl. any account/network chatter) to logcat. Defaults true so a missed set keeps dev visibility.
static std::atomic<bool> g_stdioRedirect{true};
static int g_stdioReadFd = -1;
static void *pumpStdio(void *) {
    char buf[1024];
    ssize_t n;
    while (true) {
        n = read(g_stdioReadFd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = '\0';
            __android_log_print(ANDROID_LOG_INFO, "jvm-stdout", "%s", buf);
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close(g_stdioReadFd);
    g_stdioReadFd = -1;
    return nullptr;
}
static void redirectStdioToLogcat() {
    static bool done = false;
    if (done) return;
    int pipefd[2];
    if (pipe(pipefd) != 0) { LOGE("stdio: pipe failed errno=%d", errno); return; }
    // Save the originals so fd 1/2 can be restored if setup fails partway: a reader-less pipe left on
    // stdout/err would raise SIGPIPE on the next write and can take the process down.
    int oldOut = dup(STDOUT_FILENO);
    int oldErr = dup(STDERR_FILENO);
    auto restoreStdio = [&] {
        if (oldOut >= 0) { dup2(oldOut, STDOUT_FILENO); close(oldOut); oldOut = -1; }
        if (oldErr >= 0) { dup2(oldErr, STDERR_FILENO); close(oldErr); oldErr = -1; }
    };
    if (dup2(pipefd[1], STDOUT_FILENO) < 0 || dup2(pipefd[1], STDERR_FILENO) < 0) {
        LOGE("stdio: dup2 failed errno=%d", errno);
        restoreStdio();
        close(pipefd[0]); close(pipefd[1]);
        return;
    }
    close(pipefd[1]);                 // the dup'd copies on fd 1/2 are the only writers now
    g_stdioReadFd = pipefd[0];
    setvbuf(stdout, nullptr, _IONBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    pthread_t t;
    if (pthread_create(&t, nullptr, pumpStdio, nullptr) != 0) {
        LOGE("stdio: pthread_create failed errno=%d", errno);
        restoreStdio();               // point fd 1/2 back at the originals so writes don't hit a dead pipe
        close(g_stdioReadFd); g_stdioReadFd = -1;
        return;
    }
    pthread_detach(t);
    if (oldOut >= 0) close(oldOut);   // success: the saved originals are no longer needed
    if (oldErr >= 0) close(oldErr);
    done = true;
}

// HotSpot dlopens lib/*.so by absolute path, but the linker resolves each .so's DT_NEEDED siblings
// (libnio.so NEEDs libnet.so, libawt NEEDs libfontmanager, etc.) via the namespace's search paths — which
// DON'T include the JRE lib dir. Preload every lib/*.so with RTLD_GLOBAL up front so those transitive
// NEEDED libs resolve by soname. Multi-pass (loop until no progress) to absorb intra-dir ordering.
static void preloadOneDir(const std::string &libDir) {
    std::vector<std::string> pending;
    DIR *d = opendir(libDir.c_str());
    if (!d) { LOGE("preload: opendir %s failed", libDir.c_str()); return; }
    struct dirent *e;
    while ((e = readdir(d)) != nullptr) {
        std::string name = e->d_name;
        if (name.size() < 4 || name.compare(name.size() - 3, 3, ".so") != 0) continue;
        if (name == "libjvm.so") continue;   // dlopen'd explicitly by absolute path
        pending.push_back(libDir + "/" + name);
    }
    closedir(d);

    while (!pending.empty()) {
        std::vector<std::string> still;
        for (const std::string &path : pending) {
            if (dlopen(path.c_str(), RTLD_NOW | RTLD_GLOBAL)) continue;
            still.push_back(path);
        }
        if (still.size() == pending.size()) {  // no progress this pass -> unresolvable, report and stop
            for (const std::string &path : still) LOGI("preload: deferred %s (%s)", path.c_str(), dlerror());
            break;
        }
        pending.swap(still);
    }
}
// java.library.path may be a ':'-joined list; preload every directory in it.
static void preloadJreLibs(const std::string &libraryPath) {
    size_t start = 0;
    while (start <= libraryPath.size()) {
        size_t end = libraryPath.find(':', start);
        std::string dir = libraryPath.substr(start, end == std::string::npos ? std::string::npos : end - start);
        if (!dir.empty()) preloadOneDir(dir);
        if (end == std::string::npos) break;
        start = end + 1;
    }
}

static std::string jstr(JNIEnv *env, jstring s) {
    if (s == nullptr) return {};
    const char *c = env->GetStringUTFChars(s, nullptr);
    if (c == nullptr) {                            // OOM: GetStringUTFChars leaves a pending exception
        if (env->ExceptionCheck()) env->ExceptionClear();   // clear so it can't trip the next JNI call
        return {};
    }
    std::string out = c;
    env->ReleaseStringUTFChars(s, c);
    return out;
}
static std::string toInternal(std::string name) {
    for (char &ch : name) if (ch == '.') ch = '/';
    return name;
}

// GetEnv-or-daemon-attach for the calling thread. Daemon attach means we never need to detach (the VM
// won't block on these threads at shutdown, and the process owns teardown). Returns nullptr on failure.
static JNIEnv *bridgeEnvAttach() {
    JavaVM *vm = g_vm.load(std::memory_order_acquire);
    if (!vm) return nullptr;
    JNIEnv *env = nullptr;
    jint r = vm->GetEnv((void **)&env, JNI_VERSION_21);
    if (r == JNI_OK && env) return env;
    if (r == JNI_EDETACHED && vm->AttachCurrentThreadAsDaemon(&env, nullptr) == JNI_OK) return env;
    return nullptr;
}

// Acquire-load the MobileUiBridge publication latches (see g_mobileUiReady/g_panelReady). An extern that
// sees these true is guaranteed (happens-before) to read fully-resolved method-id globals; false => the
// facade isn't published yet (or that sub-surface is incomplete) and the extern returns its empty sentinel.
static inline bool mobileUiReady() { return g_mobileUiReady.load(std::memory_order_acquire); }
static inline bool panelReady()    { return g_panelReady.load(std::memory_order_acquire); }
static inline bool questReady()    { return g_questReady.load(std::memory_order_acquire); }
static inline bool worldReady()    { return g_worldReady.load(std::memory_order_acquire); }
static inline bool overlayReady()  { return g_overlayReady.load(std::memory_order_acquire); }
static inline bool accountReady()  { return g_accountReady.load(std::memory_order_acquire); }
static inline bool infoboxReady()  { return g_infoboxReady.load(std::memory_order_acquire); }
static inline bool profileReady()  { return g_profileReady.load(std::memory_order_acquire); }
static inline bool chromeReady()    { return g_chromeReady.load(std::memory_order_acquire); }
static inline bool hudReady()       { return g_hudReady.load(std::memory_order_acquire); }

// Resolve an OPTIONAL static method id, clearing the NoSuchMethodError a miss leaves pending — so a failed
// lookup can't trip the NEXT JNI call on this thread (the Review-2 MenuPeekBridge pending-exception bug class).
static jmethodID midOpt(JNIEnv *env, jclass c, const char *name, const char *sig) {
    jmethodID m = env->GetStaticMethodID(c, name, sig);
    if (!m && env->ExceptionCheck()) env->ExceptionClear();
    return m;
}

// Phase 3 (Task B): return true iff a content-diff'd snapshot should be re-copied this frame. The Java side bumps
// its publish seq ONLY when the snapshot JSON actually changes, so an unchanged seq means byte-identical JSON and
// the per-frame String copy can be skipped (the menu-peek gate). Because the gate is derived from the bytes, it can
// never skip a real change — no stale HUD. If the optional seq getter is absent (older jar), always copy (the
// pre-Task-B behavior). On any JNI hiccup, also copy (fail safe toward freshness). Updates `cache` on advance.
// Memory ordering: the seq->json happens-before that matters here is carried by the JAVA volatile fields (the Java
// producer stores json before seq; CallStaticLongMethod/CallStaticObjectMethod read those volatiles through JNI, so
// a native reader that sees the new seq also sees the new json). `cache` is render-loop-local state (single
// producer / single consumer = this render thread), NOT the cross-thread channel, so relaxed is correct.
static bool snapSeqAdvanced(JNIEnv *env, jclass cls, jmethodID seqMid, std::atomic<long long> &cache) {
    if (!seqMid) return true;
    long long sq = env->CallStaticLongMethod(cls, seqMid);
    if (env->ExceptionCheck()) { env->ExceptionClear(); return true; }
    if (sq == cache.load(std::memory_order_relaxed)) return false;
    cache.store(sq, std::memory_order_relaxed);
    return true;
}

// Finding 14: register a read-only data-panel facade (all-or-nothing, release-latched like Quest/World). The
// json getter name differs per panel (getXpJson / getLootJson / …); avail+setUiOpen are uniform.
static bool registerDataPanel(JNIEnv *env, const char *clsName, const char *jsonGetter, DataPanel &p) {
    jclass c = env->FindClass(clsName);
    if (!c || env->ExceptionCheck()) { env->ExceptionClear(); LOGE("bridge: FindClass %s failed", clsName); return false; }
    jclass g = (jclass) env->NewGlobalRef(c);
    env->DeleteLocalRef(c);
    if (!g) { LOGE("bridge: %s NewGlobalRef failed", clsName); return false; }
    jmethodID a = midOpt(env, g, "isAvailable", "()Z");
    jmethodID s = midOpt(env, g, "setUiOpen", "(Z)V");
    jmethodID j = midOpt(env, g, jsonGetter, "()Ljava/lang/String;");
    if (a && s && j) {
        p.cls = g; p.avail = a; p.setUiOpen = s; p.json = j;
        p.ready.store(true, std::memory_order_release);
        LOGI("bridge: %s facade published", clsName);
        return true;
    }
    env->DeleteGlobalRef(g);
    LOGE("bridge: %s method id failed (panel reflow disabled)", clsName);
    return false;
}

// Resolve + cache the JavaBridge facade as HotSpot global refs. Called once, on the VM's main thread, at
// boot. Returns true once every method id resolved.
static bool publishBridge(JNIEnv *env) {
    jclass local = env->FindClass("net/runelite/client/headless/JavaBridge");
    if (!local || env->ExceptionCheck()) { env->ExceptionClear(); LOGE("bridge: FindClass JavaBridge failed"); return false; }
    jclass global = (jclass) env->NewGlobalRef(local);
    env->DeleteLocalRef(local);
    if (!global) return false;
    g_midSeq        = midOpt(env, global, "getFrameSeq", "()I");
    g_midW          = midOpt(env, global, "getFrameWidth", "()I");
    g_midH          = midOpt(env, global, "getFrameHeight", "()I");
    g_midPixels     = midOpt(env, global, "getFramePixels", "()[I");
    g_midTouch      = midOpt(env, global, "onTouch", "(IIII)V");
    g_midClick      = midOpt(env, global, "onClick", "(III)V");
    g_midCamera     = midOpt(env, global, "onCameraDrag", "(II)V");
    g_midClearHover = midOpt(env, global, "clearHover", "()V");
    // A1 input-parity surface (all confirmed present by the A-1 bridge census).
    g_midWheel          = midOpt(env, global, "onWheel", "(III)V");
    g_midClickPrecise   = midOpt(env, global, "onClickPrecise", "(III)V");
    g_midMove           = midOpt(env, global, "onMove", "(II)V");
    g_midText           = midOpt(env, global, "onText", "(Ljava/lang/String;)V");
    g_midKeyStroke      = midOpt(env, global, "onKeyStroke", "(I)V");
    g_midTextInputOpen  = midOpt(env, global, "isTextInputOpen", "()Z");
    g_midInteractTapSeq = midOpt(env, global, "getInteractTapSeq", "()I");
    g_midTapKindSeq     = midOpt(env, global, "getTapKindSeq", "()I");          // optional (older jar omits)
    g_midLastTapKind    = midOpt(env, global, "getLastTapKind", "()I");
    g_midLastWidgetBounds = midOpt(env, global, "getLastWidgetBounds", "()J");
    g_midSelectMenuPoint = midOpt(env, global, "selectMenuPoint", "(II)V");   // A2 commit
    if (!g_midSeq || !g_midW || !g_midH || !g_midPixels || !g_midTouch || !g_midClick
        || !g_midCamera || !g_midClearHover
        || !g_midWheel || !g_midClickPrecise || !g_midMove || !g_midText || !g_midKeyStroke
        || !g_midTextInputOpen || !g_midInteractTapSeq || !g_midSelectMenuPoint) {
        env->DeleteGlobalRef(global);   // midOpt already cleared any pending NoSuchMethodError
        LOGE("bridge: a JavaBridge method id failed to resolve");
        return false;
    }
    // AP-2a sticky-Shift: best-effort (a missing one only disables the ⇧ button, never the render path).
    g_midSetShiftHeld = midOpt(env, global, "setShiftHeld", "(Z)V");
    g_midKeybind      = midOpt(env, global, "onKeybind", "(II)V");
    g_midSetCtrlHeld  = midOpt(env, global, "setCtrlHeld", "(Z)V");
    g_midSetAltHeld   = midOpt(env, global, "setAltHeld", "(Z)V");
    g_midMiddleClick  = midOpt(env, global, "onMiddleClick", "(II)V");
    g_midInvokeMenuEntry = midOpt(env, global, "invokeMenuEntry", "(II)V");   // FIX-10b submenu commit (optional)
    // FIX-3 idle keepalive: best-effort (a missing one only disables the idle-reset, never the render path) so
    // an older staged jar lacking keepAlive still boots.
    g_midKeepAlive = midOpt(env, global, "keepAlive", "()V");
    g_bridgeCls = global;   // publish only once fully resolved
    LOGI("bridge: JavaBridge facade published (shiftHeld=%s keepAlive=%s)",
         g_midSetShiftHeld ? "on" : "off", g_midKeepAlive ? "on" : "off");

    // A2: MenuPeekBridge is a SEPARATE facade — resolve best-effort so a missing/old one only disables menu-peek
    // (never blocks the render path). It is inert unless -Drunelite.menupeek=true, but the class is always present.
    jclass mp = env->FindClass("net/runelite/client/headless/MenuPeekBridge");
    if (mp && !env->ExceptionCheck()) {
        jclass mpg = (jclass) env->NewGlobalRef(mp);
        env->DeleteLocalRef(mp);
        if (!mpg) {                       // OOM creating the global ref — never resolve methods against null
            LOGE("bridge: MenuPeekBridge NewGlobalRef failed (menu-peek disabled)");
        } else {
            jmethodID snap = midOpt(env, mpg, "getSnapshot", "()Ljava/lang/String;");
            jmethodID pseq = midOpt(env, mpg, "getPublishSeq", "()J");
            if (snap && pseq) {
                g_menuPeekCls = mpg; g_midMenuSnapshot = snap; g_midMenuPublishSeq = pseq;
                LOGI("bridge: MenuPeekBridge facade published");
            } else {
                env->DeleteGlobalRef(mpg);   // midOpt already cleared any pending NoSuchMethodError
                LOGE("bridge: MenuPeekBridge method id failed to resolve (menu-peek disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass MenuPeekBridge failed (menu-peek disabled)");
    }

    // A4: MobileUiBridge is the plugin control plane — resolve best-effort (inert unless -Drunelite.mobileui=true).
    jclass mu = env->FindClass("net/runelite/client/headless/MobileUiBridge");
    if (mu && !env->ExceptionCheck()) {
        jclass mug = (jclass) env->NewGlobalRef(mu);
        env->DeleteLocalRef(mu);
        if (!mug) {                       // OOM creating the global ref — never resolve methods against null
            LOGE("bridge: MobileUiBridge NewGlobalRef failed (plugin control disabled)");
            return true;
        }
        jmethodID lp = midOpt(env, mug, "listPlugins", "()Ljava/lang/String;");
        jmethodID sq = midOpt(env, mug, "getMobileUiSeq", "()J");
        jmethodID pe = midOpt(env, mug, "pollMobileUiEvents", "(J)Ljava/lang/String;");
        jmethodID se = midOpt(env, mug, "setPluginEnabled", "(Ljava/lang/String;Z)Ljava/lang/String;");
        if (lp && sq && pe && se) {
            g_mobileUiCls = mug; g_midListPlugins = lp; g_midMobileUiSeq = sq; g_midPollEvents = pe; g_midSetPluginEnabled = se;
            // Config surface (best-effort; a null here disables config read/write only — NOT list/toggle).
            g_midGetPluginConfig  = midOpt(env, mug, "getPluginConfig", "(Ljava/lang/String;)Ljava/lang/String;");
            g_midSetConfig        = midOpt(env, mug, "setConfig", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
            g_midProcessedWriteId = midOpt(env, mug, "getProcessedWriteId", "()J");
            g_midFlushConfig      = midOpt(env, mug, "flushConfig", "()Ljava/lang/String;");   // A8 background flush
            g_midResetPluginConfig   = midOpt(env, mug, "resetPluginConfig", "(Ljava/lang/String;)Ljava/lang/String;");   // SC-2 reset
            g_midNotificationDefaults = midOpt(env, mug, "notificationDefaults", "()Ljava/lang/String;");                  // SC-1 defaults
            g_midBoundKeybinds        = midOpt(env, mug, "boundKeybindsJson", "()Ljava/lang/String;");                    // user-defined hotkeys (optional)
            g_midFireHotkey           = midOpt(env, mug, "fireHotkey", "(Ljava/lang/String;Ljava/lang/String;)V");        // fire one (optional)
            if (!g_midGetPluginConfig || !g_midSetConfig || !g_midProcessedWriteId)
                LOGE("bridge: MobileUiBridge config methods partial (plugin config read/write disabled)");
            // AP-2a: drain surfaces for native notification / link-out / hub-progress (each best-effort).
            g_midNextNotification = midOpt(env, mug, "nextNotification", "()Ljava/lang/String;");
            g_midNextLink         = midOpt(env, mug, "nextLink", "()Ljava/lang/String;");
            g_midNextScreenshot = midOpt(env, mug, "nextScreenshot", "()Ljava/lang/String;");
            g_midHubState         = midOpt(env, mug, "hubState", "()Ljava/lang/String;");
            // Finding 17 plugin-hub browse/install (best-effort; null disables the hub screen only).
            g_midHubManifest      = midOpt(env, mug, "hubManifest", "()Ljava/lang/String;");
            g_midHubInstall       = midOpt(env, mug, "hubInstall", "(Ljava/lang/String;)Ljava/lang/String;");
            g_midHubUninstall     = midOpt(env, mug, "hubUninstall", "(Ljava/lang/String;)Ljava/lang/String;");
            g_midPublishNotification = midOpt(env, mug, "publishNotification", "(Ljava/lang/String;Ljava/lang/String;)V");
            g_midPublishLink         = midOpt(env, mug, "publishLink", "(Ljava/lang/String;)V");
            g_midSetPinned           = midOpt(env, mug, "setPinned", "(Ljava/lang/String;Z)Ljava/lang/String;");
            // A5 Tier-1 panel surface (best-effort, ALL-OR-NOTHING: every method the viewer uses must resolve.
            // closePanel in particular — without it, PanelView dispose can't close the open engine-side panel,
            // so a partial set disables panels entirely rather than opening one it can never close.)
            g_midListPanels  = midOpt(env, mug, "listPanels", "()Ljava/lang/String;");
            g_midOpenPanel   = midOpt(env, mug, "openPanel", "(I)Ljava/lang/String;");
            g_midClosePanel  = midOpt(env, mug, "closePanel", "()Ljava/lang/String;");
            g_midPanelW      = midOpt(env, mug, "getPanelWidth", "()I");
            g_midPanelH      = midOpt(env, mug, "getPanelHeight", "()I");
            g_midPanelSeq    = midOpt(env, mug, "getPanelFrameSeq", "()I");
            g_midPanelPixels = midOpt(env, mug, "getPanelPixels", "()[I");
            g_midPanelClick  = midOpt(env, mug, "panelClick", "(II)Ljava/lang/String;");
            // SC-4 panel-text input (best-effort — NOT in the panelOk all-or-nothing gate; a stale jar just
            // disables typing/scroll/long-press inside panels, the panel still opens + tap-clicks work).
            g_midIsPanelTextActive = midOpt(env, mug, "isPanelTextActive", "()Z");
            g_midGetPanelText      = midOpt(env, mug, "getPanelText", "()Ljava/lang/String;");
            g_midPanelText         = midOpt(env, mug, "panelText", "(Ljava/lang/String;)Ljava/lang/String;");
            g_midPanelKey          = midOpt(env, mug, "panelKey", "(I)Ljava/lang/String;");
            g_midPanelLongPress    = midOpt(env, mug, "panelLongPress", "(II)Ljava/lang/String;");
            g_midPanelWheel        = midOpt(env, mug, "panelWheel", "(III)Ljava/lang/String;");
            g_midPanelMove         = midOpt(env, mug, "panelMove", "(II)Ljava/lang/String;");
            // Native Notes panel (best-effort; null disables only the Notes tile).
            g_midNotesAvailable = midOpt(env, mug, "notesAvailable", "()Z");
            g_midNotesGet = midOpt(env, mug, "notesGet", "()Ljava/lang/String;");
            g_midNotesSet = midOpt(env, mug, "notesSet", "(Ljava/lang/String;)Ljava/lang/String;");
            bool panelOk = g_midListPanels && g_midOpenPanel && g_midClosePanel && g_midPanelW
                        && g_midPanelH && g_midPanelSeq && g_midPanelPixels && g_midPanelClick;
            if (!panelOk) LOGE("bridge: MobileUiBridge panel methods incomplete (Tier-1 panels disabled)");
            // Publish via release-store so the rl-bridge thread's acquire-load sees a fully-resolved facade
            // (panels first, then the umbrella latch — both happen-after every method-id write above).
            g_panelReady.store(panelOk, std::memory_order_release);
            g_mobileUiReady.store(true, std::memory_order_release);
            LOGI("bridge: MobileUiBridge facade published (panels=%s)", panelOk ? "on" : "off");
        } else {
            env->DeleteGlobalRef(mug);   // midOpt already cleared any pending NoSuchMethodError
            LOGE("bridge: MobileUiBridge method id failed (plugin control disabled)");
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass MobileUiBridge failed (plugin control disabled)");
    }

    // A5 Tier-2: QuestHelperBridge — separate facade, all-or-nothing, rl-bridge-thread read (release latch).
    jclass qh = env->FindClass("net/runelite/client/headless/QuestHelperBridge");
    if (qh && !env->ExceptionCheck()) {
        jclass qhg = (jclass) env->NewGlobalRef(qh);
        env->DeleteLocalRef(qh);
        if (!qhg) {
            LOGE("bridge: QuestHelperBridge NewGlobalRef failed (Quest Helper reflow disabled)");
        } else {
            g_midQuestAvail     = midOpt(env, qhg, "isAvailable", "()Z");
            g_midQuestSetUiOpen = midOpt(env, qhg, "setUiOpen", "(Z)V");
            g_midQuestList      = midOpt(env, qhg, "getQuestListJson", "()Ljava/lang/String;");
            g_midQuestActive    = midOpt(env, qhg, "getQuestActiveJson", "()Ljava/lang/String;");
            g_midQuestStart     = midOpt(env, qhg, "startQuest", "(Ljava/lang/String;)V");
            g_midQuestStop      = midOpt(env, qhg, "stopQuest", "()V");
            bool questOk = g_midQuestAvail && g_midQuestSetUiOpen && g_midQuestList
                        && g_midQuestActive && g_midQuestStart && g_midQuestStop;
            if (questOk) {
                g_questCls = qhg;                                       // before the release-store below
                g_questReady.store(true, std::memory_order_release);
                LOGI("bridge: QuestHelperBridge facade published");
            } else {
                env->DeleteGlobalRef(qhg);
                LOGE("bridge: QuestHelperBridge method id failed (Quest Helper reflow disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass QuestHelperBridge failed (Quest Helper reflow disabled)");
    }

    // A5 Tier-2: WorldSwitcherBridge — separate facade, all-or-nothing, rl-bridge-thread read (release latch).
    jclass wsb = env->FindClass("net/runelite/client/headless/WorldSwitcherBridge");
    if (wsb && !env->ExceptionCheck()) {
        jclass wsg = (jclass) env->NewGlobalRef(wsb);
        env->DeleteLocalRef(wsb);
        if (!wsg) {
            LOGE("bridge: WorldSwitcherBridge NewGlobalRef failed (World Switcher reflow disabled)");
        } else {
            g_midWorldAvail     = midOpt(env, wsg, "isAvailable", "()Z");
            g_midWorldSetUiOpen = midOpt(env, wsg, "setUiOpen", "(Z)V");
            g_midWorldList      = midOpt(env, wsg, "getWorldListJson", "()Ljava/lang/String;");
            g_midWorldHop       = midOpt(env, wsg, "hop", "(I)V");
            // SC-5 favourites + quick-hop: best-effort (a null only disables that one control, not the whole reflow).
            g_midWorldSetFav    = midOpt(env, wsg, "setFavourite", "(IZ)V");
            g_midWorldHopDir    = midOpt(env, wsg, "hopDirection", "(Z)V");
            bool worldOk = g_midWorldAvail && g_midWorldSetUiOpen && g_midWorldList && g_midWorldHop;
            if (worldOk) {
                g_worldCls = wsg;
                g_worldReady.store(true, std::memory_order_release);
                LOGI("bridge: WorldSwitcherBridge facade published");
            } else {
                env->DeleteGlobalRef(wsg);
                LOGE("bridge: WorldSwitcherBridge method id failed (World Switcher reflow disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass WorldSwitcherBridge failed (World Switcher reflow disabled)");
    }

    // Finding 14 — read-only data-panel reflows (XP / Loot / GE; same facade shape as Quest/World).
    registerDataPanel(env, "net/runelite/client/headless/XpTrackerBridge", "getXpJson", g_xpPanel);
    registerDataPanel(env, "net/runelite/client/headless/LootTrackerBridge", "getLootJson", g_lootPanel);
    // Loot Tracker also has a write action (resetAll) on the same facade class — resolve it optionally so an
    // older staged jar without it still gets the read-only reflow.
    if (g_lootPanel.ready.load(std::memory_order_acquire)) {
        g_midLootReset = midOpt(env, g_lootPanel.cls, "resetAll", "()Ljava/lang/String;");
    }
    registerDataPanel(env, "net/runelite/client/headless/GrandExchangeBridge", "getGeJson", g_gePanel);
    registerDataPanel(env, "net/runelite/client/headless/TimeTrackingBridge", "getTimeTrackingJson", g_timePanel);

    // Finding 15 — OverlayBridge: overlay edit (list + snap-to-corner + reset). Dedicated facade (action methods
    // take args), all-or-nothing, release-latched like Quest/World.
    jclass ob = env->FindClass("net/runelite/client/headless/OverlayBridge");
    if (ob && !env->ExceptionCheck()) {
        jclass obg = (jclass) env->NewGlobalRef(ob);
        env->DeleteLocalRef(ob);
        if (!obg) {
            LOGE("bridge: OverlayBridge NewGlobalRef failed (overlay edit disabled)");
        } else {
            g_midOverlayAvail     = midOpt(env, obg, "isAvailable", "()Z");
            g_midOverlaySetUiOpen = midOpt(env, obg, "setUiOpen", "(Z)V");
            g_midOverlaysJson     = midOpt(env, obg, "getOverlaysJson", "()Ljava/lang/String;");
            g_midOverlaySnap      = midOpt(env, obg, "setOverlayPreferredPosition", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
            g_midOverlayReset     = midOpt(env, obg, "resetOverlay", "(Ljava/lang/String;)Ljava/lang/String;");
            // Free pixel-drag (optional, not gated): older jars without it still get list/snap/reset.
            g_midOverlaySetLoc    = midOpt(env, obg, "setOverlayPreferredLocation", "(Ljava/lang/String;II)Ljava/lang/String;");
            bool overlayOk = g_midOverlayAvail && g_midOverlaySetUiOpen && g_midOverlaysJson
                          && g_midOverlaySnap && g_midOverlayReset;
            if (overlayOk) {
                g_overlayCls = obg;
                g_overlayReady.store(true, std::memory_order_release);
                LOGI("bridge: OverlayBridge facade published");
            } else {
                env->DeleteGlobalRef(obg);
                LOGE("bridge: OverlayBridge method id failed (overlay edit disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass OverlayBridge failed (overlay edit disabled)");
    }

    // RuneLite-account login (config sync): start/stop OAuth + read session. Dedicated facade, release-latched.
    jclass ac = env->FindClass("net/runelite/client/headless/RuneLiteAccountBridge");
    if (ac && !env->ExceptionCheck()) {
        jclass acg = (jclass) env->NewGlobalRef(ac);
        env->DeleteLocalRef(ac);
        if (!acg) {
            LOGE("bridge: RuneLiteAccountBridge NewGlobalRef failed (account login disabled)");
        } else {
            g_midAccountAvail   = midOpt(env, acg, "isAvailable", "()Z");
            g_midAccountLogin   = midOpt(env, acg, "startLogin", "()V");
            g_midAccountLogout  = midOpt(env, acg, "logout", "()V");
            g_midAccountSession = midOpt(env, acg, "getSessionJson", "()Ljava/lang/String;");
            if (g_midAccountAvail && g_midAccountLogin && g_midAccountLogout && g_midAccountSession) {
                g_accountCls = acg;
                g_accountReady.store(true, std::memory_order_release);
                LOGI("bridge: RuneLiteAccountBridge facade published");
            } else {
                env->DeleteGlobalRef(acg);
                LOGE("bridge: RuneLiteAccountBridge method id failed (account login disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass RuneLiteAccountBridge failed (account login disabled)");
    }

    // Finding 22 — InfoBoxBridge: infobox list + per-infobox menu actions (Detach/Flip/Delete). Dedicated facade.
    jclass ib = env->FindClass("net/runelite/client/headless/InfoBoxBridge");
    if (ib && !env->ExceptionCheck()) {
        jclass ibg = (jclass) env->NewGlobalRef(ib);
        env->DeleteLocalRef(ib);
        if (!ibg) {
            LOGE("bridge: InfoBoxBridge NewGlobalRef failed (infobox menu disabled)");
        } else {
            g_midInfoBoxAvail     = midOpt(env, ibg, "isAvailable", "()Z");
            g_midInfoBoxSetUiOpen = midOpt(env, ibg, "setUiOpen", "(Z)V");
            g_midInfoBoxesJson    = midOpt(env, ibg, "getInfoBoxesJson", "()Ljava/lang/String;");
            g_midInfoBoxInvoke    = midOpt(env, ibg, "invokeInfoBoxMenu", "(ILjava/lang/String;)Ljava/lang/String;");
            bool ibOk = g_midInfoBoxAvail && g_midInfoBoxSetUiOpen && g_midInfoBoxesJson && g_midInfoBoxInvoke;
            if (ibOk) {
                g_infoboxCls = ibg;
                g_infoboxReady.store(true, std::memory_order_release);
                LOGI("bridge: InfoBoxBridge facade published");
            } else {
                env->DeleteGlobalRef(ibg);
                LOGE("bridge: InfoBoxBridge method id failed (infobox menu disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass InfoBoxBridge failed (infobox menu disabled)");
    }

    // Config profiles: ConfigProfileBridge — list (getProfilesJson) + switch (switchProfile(J)). Dedicated
    // facade, all-or-nothing, release-latched like Overlay/InfoBox.
    jclass cp = env->FindClass("net/runelite/client/headless/ConfigProfileBridge");
    if (cp && !env->ExceptionCheck()) {
        jclass cpg = (jclass) env->NewGlobalRef(cp);
        env->DeleteLocalRef(cp);
        if (!cpg) {
            LOGE("bridge: ConfigProfileBridge NewGlobalRef failed (profiles disabled)");
        } else {
            g_midProfileAvail  = midOpt(env, cpg, "isAvailable", "()Z");
            g_midProfilesJson  = midOpt(env, cpg, "getProfilesJson", "()Ljava/lang/String;");
            g_midProfileSwitch = midOpt(env, cpg, "switchProfile", "(J)Ljava/lang/String;");
            if (g_midProfileAvail && g_midProfilesJson && g_midProfileSwitch) {
                g_profileCls = cpg;
                g_profileReady.store(true, std::memory_order_release);
                LOGI("bridge: ConfigProfileBridge facade published");
            } else {
                env->DeleteGlobalRef(cpg);
                LOGE("bridge: ConfigProfileBridge method id failed (profiles disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass ConfigProfileBridge failed (profiles disabled)");
    }

    // A6 chrome: MobileChromeBridge — read-only snapshot facade, single method, rl-bridge-thread read.
    jclass mc = env->FindClass("net/runelite/client/headless/MobileChromeBridge");
    if (mc && !env->ExceptionCheck()) {
        jclass mcg = (jclass) env->NewGlobalRef(mc);
        env->DeleteLocalRef(mc);
        if (!mcg) {
            LOGE("bridge: MobileChromeBridge NewGlobalRef failed (chrome read surface disabled)");
        } else {
            g_midChromeSnap = midOpt(env, mcg, "getSnapshot", "()Ljava/lang/String;");
            g_midChromeSnapSeq = midOpt(env, mcg, "getSnapshotSeq", "()J");   // optional (older jar omits -> always copy)
            if (g_midChromeSnap) {
                g_chromeCls = mcg;                                      // before the release-store below
                g_chromeReady.store(true, std::memory_order_release);
                LOGI("bridge: MobileChromeBridge facade published");
            } else {
                env->DeleteGlobalRef(mcg);
                LOGE("bridge: MobileChromeBridge method id failed (chrome read surface disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass MobileChromeBridge failed (chrome read surface disabled)");
    }

    // A6 chrome write surface: HudVeneerBridge — hide engine stones / open tab / relocate side panel for the
    // native 2-col tab grid. Separate facade, all-or-nothing, rl-bridge-thread write (release latch).
    jclass hv = env->FindClass("net/runelite/client/headless/HudVeneerBridge");
    if (hv && !env->ExceptionCheck()) {
        jclass hvg = (jclass) env->NewGlobalRef(hv);
        env->DeleteLocalRef(hv);
        if (!hvg) {
            LOGE("bridge: HudVeneerBridge NewGlobalRef failed (native chrome write surface disabled)");
        } else {
            g_midSetStonesHidden   = midOpt(env, hvg, "setStonesHidden", "(Z)V");
            g_midOpenTab           = midOpt(env, hvg, "openTab", "(I)V");
            g_midRelocateSidePanel = midOpt(env, hvg, "relocateSidePanel", "(II)V");
            g_midRelocateChat      = midOpt(env, hvg, "relocateChat", "(IIZ)V");
            g_midRelocateMinimap   = midOpt(env, hvg, "relocateMinimap", "(II)V");
            g_midChatSnapshot      = midOpt(env, hvg, "getChatSnapshot", "()Ljava/lang/String;");
            g_midSetChatRowH       = midOpt(env, hvg, "setChatTabRowHeight", "(I)V");
            g_midSetChatAreaW      = midOpt(env, hvg, "setChatAreaWidth", "(I)V");
            g_midScrollChat        = midOpt(env, hvg, "scrollChat", "(I)V");
            // OPTIONAL (never in the all-or-nothing check — the snapRadius lesson): a jar predating the
            // world-map/insets surface simply loses overlay inset-avoidance, not the whole veneer.
            g_midSetOverlayInsets  = midOpt(env, hvg, "setOverlaySafeInsets", "(IIII)V");
            g_midSetChatCollapsed  = midOpt(env, hvg, "setChatCollapsed", "(Z)V");
            g_midSwitchChatTab     = midOpt(env, hvg, "switchChatTab", "(I)V");
            g_midPanWorldMap       = midOpt(env, hvg, "panWorldMap", "(II)V");
            g_midScrollMapPanel    = midOpt(env, hvg, "scrollMapPanel", "(I)V");   // optional (older jar omits it)
            g_midMapSnapshot       = midOpt(env, hvg, "getMapSnapshot", "()Ljava/lang/String;");
            g_midOpenWorldMap      = midOpt(env, hvg, "openWorldMap", "()V");   // FIX-5 (optional; older jar omits it)
            g_midDialogueJson      = midOpt(env, hvg, "getDialogueJson", "()Ljava/lang/String;");   // UI-4 (optional)
            g_midOrbSnapshot       = midOpt(env, hvg, "getOrbSnapshot", "()Ljava/lang/String;");    // orb veneer (optional)
            g_midTabSprites        = midOpt(env, hvg, "tabSprites", "()Ljava/lang/String;");        // runtime cache sprites (optional)
            // Phase 3 (Task B): content-diff publish seqs (all optional — a jar predating them just always copies).
            g_midChatSnapshotSeq   = midOpt(env, hvg, "getChatSnapshotSeq", "()J");
            g_midOrbSnapshotSeq    = midOpt(env, hvg, "getOrbSnapshotSeq", "()J");
            g_midDialogueSeq       = midOpt(env, hvg, "getDialogueSeq", "()J");
            g_midMapSnapshotSeq    = midOpt(env, hvg, "getMapSnapshotSeq", "()J");
            bool hudOk = g_midSetStonesHidden && g_midOpenTab && g_midRelocateSidePanel && g_midRelocateChat
                      && g_midRelocateMinimap && g_midChatSnapshot && g_midSetChatRowH && g_midSetChatAreaW
                      && g_midScrollChat;
            if (hudOk) {
                g_hudCls = hvg;                                         // before the release-store below
                g_hudReady.store(true, std::memory_order_release);
                LOGI("bridge: HudVeneerBridge facade published");
            } else {
                env->DeleteGlobalRef(hvg);
                LOGE("bridge: HudVeneerBridge method id failed (native chrome write surface disabled)");
            }
        }
    } else {
        env->ExceptionClear();
        LOGE("bridge: FindClass HudVeneerBridge failed (native chrome write surface disabled)");
    }
    return true;
}

// Call a no-arg static void method by (FindClass) name. Used to install CACIO CTC before any AWT touch.
static bool callStaticVoidNoArg(JNIEnv *env, const char *cls, const char *method) {
    jclass c = env->FindClass(cls);
    if (!c || env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); LOGE("call: FindClass %s failed", cls); return false; }
    jmethodID m = env->GetStaticMethodID(c, method, "()V");
    if (!m || env->ExceptionCheck()) {
        env->ExceptionDescribe(); env->ExceptionClear(); LOGE("call: no %s.%s()V", cls, method);
        env->DeleteLocalRef(c);
        return false;
    }
    env->CallStaticVoidMethod(c, m);
    bool ok = !env->ExceptionCheck();
    if (!ok) { env->ExceptionDescribe(); env->ExceptionClear(); LOGE("call: %s.%s threw", cls, method); }
    env->DeleteLocalRef(c);
    return ok;
}

// Drain the input queue and dispatch each event into the bridge (called from the render thread, which is
// HotSpot-attached). The UI thread only ever pushes onto the queue, so it never attaches to HotSpot.
static void drainInput(JNIEnv *env) {
    std::deque<InputEvent> batch;
    {
        std::lock_guard<std::mutex> lk(g_inLock);
        batch.swap(g_inQueue);
    }
    for (const InputEvent &ev : batch) {
        switch (ev.kind) {
            case IN_CLICK:        env->CallStaticVoidMethod(g_bridgeCls, g_midClick, ev.a, ev.b, ev.c); break;
            case IN_TOUCH:        env->CallStaticVoidMethod(g_bridgeCls, g_midTouch, ev.a, ev.b, ev.c, ev.d); break;
            case IN_CAMERA:       env->CallStaticVoidMethod(g_bridgeCls, g_midCamera, ev.a, ev.b); break;
            case IN_CLEARHOVER:   env->CallStaticVoidMethod(g_bridgeCls, g_midClearHover); break;
            case IN_WHEEL:        env->CallStaticVoidMethod(g_bridgeCls, g_midWheel, ev.a, ev.b, ev.c); break;
            case IN_CLICKPRECISE: env->CallStaticVoidMethod(g_bridgeCls, g_midClickPrecise, ev.a, ev.b, ev.c); break;
            case IN_MOVE:         env->CallStaticVoidMethod(g_bridgeCls, g_midMove, ev.a, ev.b); break;
            case IN_KEYSTROKE:    env->CallStaticVoidMethod(g_bridgeCls, g_midKeyStroke, ev.a); break;
            case IN_KEYBIND:      if (g_midKeybind) env->CallStaticVoidMethod(g_bridgeCls, g_midKeybind, ev.a, ev.b); break;
            case IN_SELECTMENU:   env->CallStaticVoidMethod(g_bridgeCls, g_midSelectMenuPoint, ev.a, ev.b); break;
            case IN_SHIFT:        if (g_midSetShiftHeld) env->CallStaticVoidMethod(g_bridgeCls, g_midSetShiftHeld, (jboolean)(ev.a != 0)); break;
            case IN_CTRL:         if (g_midSetCtrlHeld) env->CallStaticVoidMethod(g_bridgeCls, g_midSetCtrlHeld, (jboolean)(ev.a != 0)); break;
            case IN_ALT:          if (g_midSetAltHeld) env->CallStaticVoidMethod(g_bridgeCls, g_midSetAltHeld, (jboolean)(ev.a != 0)); break;
            case IN_MIDDLECLICK:  if (g_midMiddleClick) env->CallStaticVoidMethod(g_bridgeCls, g_midMiddleClick, ev.a, ev.b); break;
            case IN_INVOKEMENUENTRY: if (g_midInvokeMenuEntry) env->CallStaticVoidMethod(g_bridgeCls, g_midInvokeMenuEntry, ev.a, ev.b); break;
            case IN_KEEPALIVE:    if (g_midKeepAlive) env->CallStaticVoidMethod(g_bridgeCls, g_midKeepAlive); break;
            case IN_TEXT: {
                jstring js = env->NewStringUTF(ev.s.c_str());
                env->CallStaticVoidMethod(g_bridgeCls, g_midText, js);
                if (js) env->DeleteLocalRef(js);
                break;
            }
            default: break;
        }
        if (env->ExceptionCheck()) {
            LOGE("drainInput: exception from bridge dispatch (kind=%d)", ev.kind);
            env->ExceptionDescribe();
            env->ExceptionClear();
        }
    }
}

// Blit the latest complete JavaBridge frame (TYPE_INT_RGB, 0x00RRGGBB ints) to the SurfaceView window,
// swapping R<->B into RGBA_8888 (the only widely-available ANativeWindow format). Skips the copy when the
// engine hasn't composited a new frame since the last tick.
static void *renderLoop(void *) {
    JavaVM *vm = g_vm.load(std::memory_order_acquire);
    JNIEnv *env = nullptr;
    if (!vm || vm->AttachCurrentThreadAsDaemon(&env, nullptr) != JNI_OK || !env) {
        LOGE("render: attach failed"); return nullptr;
    }
    int lastSeq = -1, geomW = -1, geomH = -1;
    uint64_t lastGen = 0;
    while (g_renderRun) {
        // PERF-BATTERY-NETWORK-01: app backgrounded — the UI thread isn't drawing the native overlays, so the
        // whole per-tick snapshot-republish batch + present below is wasted. Drop to ~4 Hz and only drainInput
        // (so a queued terminal touch/keepalive that arrived as we backgrounded isn't stranded). Covers both the
        // CPU blit path and the GPU direct-present idle-pace; the GPU draw thread itself is paced in librlawt.
        if (g_paused.load(std::memory_order_acquire)) {
            if (g_bridgeCls) drainInput(env);
            usleep(250000);
            continue;
        }
        // A surface destroy/recreate invalidates the cached geometry — force re-apply on the next blit.
        uint64_t gen = g_surfaceGen.load(std::memory_order_acquire);
        if (gen != lastGen) { geomW = geomH = -1; lastGen = gen; }
        if (g_bridgeCls) {
            drainInput(env);
            // Poll the A1 read-surface and publish to atomics for the UI thread (keeps it off HotSpot). Cheap
            // static calls; done every tick so keyboard/haptic state tracks even on an idle (seq-stable) frame.
            jboolean tio = env->CallStaticBooleanMethod(g_bridgeCls, g_midTextInputOpen);
            if (env->ExceptionCheck()) { env->ExceptionClear(); }
            else { g_textInputOpen.store(tio ? 1 : 0, std::memory_order_relaxed); }
            int its = env->CallStaticIntMethod(g_bridgeCls, g_midInteractTapSeq);
            if (env->ExceptionCheck()) { env->ExceptionClear(); }
            else { g_interactTapSeq.store(its, std::memory_order_relaxed); }
            // Tap-KIND truth (optional): kind + last widget bounds, for the UI thread's ring/border decision.
            if (g_midTapKindSeq) {
                int tk = env->CallStaticIntMethod(g_bridgeCls, g_midLastTapKind);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else { g_lastTapKind.store(tk, std::memory_order_relaxed); }
                int64_t wb = env->CallStaticLongMethod(g_bridgeCls, g_midLastWidgetBounds);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else { g_lastWidgetBounds.store(wb, std::memory_order_relaxed); }
                int tks = env->CallStaticIntMethod(g_bridgeCls, g_midTapKindSeq);   // seq last (gates the read)
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else { g_tapKindSeq.store(tks, std::memory_order_relaxed); }
            }

            // A2: republish the menu-peek snapshot only when its publish-seq advanced (avoids a per-frame
            // String copy on the idle path). The UI thread reads g_menuSnapshot via nativeMenuSnapshot().
            if (g_menuPeekCls) {
                long long sq = env->CallStaticLongMethod(g_menuPeekCls, g_midMenuPublishSeq);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else if (sq != g_menuPublishSeq.load(std::memory_order_relaxed)) {
                    jstring js = (jstring) env->CallStaticObjectMethod(g_menuPeekCls, g_midMenuSnapshot);
                    if (env->ExceptionCheck()) { env->ExceptionClear(); }
                    else if (js) {
                        const char *c = env->GetStringUTFChars(js, nullptr);
                        if (c) {
                            std::lock_guard<std::mutex> lk(g_menuLock);
                            g_menuSnapshot.assign(c);
                            env->ReleaseStringUTFChars(js, c);
                        } else if (env->ExceptionCheck()) {
                            env->ExceptionClear();   // OOM: don't leave it pending for the next bridge call
                        }
                        env->DeleteLocalRef(js);
                    }
                    g_menuPublishSeq.store(sq, std::memory_order_relaxed);
                }
            }

            // A6: republish the chrome snapshot each frame (the cover-and-proxy rails need fresh stone bounds;
            // it's a small JSON rebuilt each client tick, and only meaningful in-world, so a per-frame copy is
            // cheap). The UI thread reads g_chromeSnapshotPub via nativeChromeSnapshotPub() — no HotSpot attach.
            if (g_chromeReady.load(std::memory_order_acquire) && g_chromeCls
                && snapSeqAdvanced(env, g_chromeCls, g_midChromeSnapSeq, g_chromeSnapSeq)) {
                jstring js = (jstring) env->CallStaticObjectMethod(g_chromeCls, g_midChromeSnap);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else if (js) {
                    const char *c = env->GetStringUTFChars(js, nullptr);
                    if (c) {
                        std::lock_guard<std::mutex> lk(g_chromeLock);
                        g_chromeSnapshotPub.assign(c);
                        env->ReleaseStringUTFChars(js, c);
                    } else if (env->ExceptionCheck()) {
                        env->ExceptionClear();   // OOM: don't leave it pending for the next bridge call
                    }
                    env->DeleteLocalRef(js);
                }
            }

            // A3: republish the chat-tab snapshot each frame (HudVeneerBridge.getChatSnapshot) so the enlarged
            // native chat-tab overlay reads fresh tab geometry/state lock-free. Small JSON, only populated once
            // the chat is relocated; cheap per-frame copy. UI reads it via nativeChatSnapshotPub() — no attach.
            if (g_hudReady.load(std::memory_order_acquire) && g_hudCls && g_midChatSnapshot
                && snapSeqAdvanced(env, g_hudCls, g_midChatSnapshotSeq, g_chatSnapSeq)) {
                jstring js = (jstring) env->CallStaticObjectMethod(g_hudCls, g_midChatSnapshot);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else if (js) {
                    const char *c = env->GetStringUTFChars(js, nullptr);
                    if (c) {
                        std::lock_guard<std::mutex> lk(g_chatLock);
                        g_chatSnapshotPub.assign(c);
                        env->ReleaseStringUTFChars(js, c);
                    } else if (env->ExceptionCheck()) {
                        env->ExceptionClear();
                    }
                    env->DeleteLocalRef(js);
                }
            }

            // One-shot: fetch the runtime tab/stone/chat sprite payload (HudVeneerBridge.tabSprites) on THIS HotSpot
            // thread (the bridge call MUST NOT run on the UI thread — it owns no HotSpot env). Inert after capture.
            if (!g_tabSpritesDone.load(std::memory_order_acquire)
                && g_hudReady.load(std::memory_order_acquire) && g_hudCls && g_midTabSprites) {
                jstring js = (jstring) env->CallStaticObjectMethod(g_hudCls, g_midTabSprites);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else if (js) {
                    const char *c = env->GetStringUTFChars(js, nullptr);
                    if (c) {
                        if (c[0] != '\0') {
                            std::lock_guard<std::mutex> lk(g_tabSpritesLock);
                            g_tabSprites.assign(c);
                            g_tabSpritesDone.store(true, std::memory_order_release);
                            LOGI("bridge: tab sprites captured (%zu bytes)", g_tabSprites.size());
                        }
                        env->ReleaseStringUTFChars(js, c);
                    } else if (env->ExceptionCheck()) {
                        env->ExceptionClear();
                    }
                    env->DeleteLocalRef(js);
                }
            }

            // Minimap-orb veneer: republish the per-orb canvas bounds each frame (HudVeneerBridge.getOrbSnapshot)
            // so the native tap handler reads fresh orb positions lock-free, no attach. Optional method.
            if (g_hudReady.load(std::memory_order_acquire) && g_hudCls && g_midOrbSnapshot
                && snapSeqAdvanced(env, g_hudCls, g_midOrbSnapshotSeq, g_orbSnapSeq)) {
                jstring js = (jstring) env->CallStaticObjectMethod(g_hudCls, g_midOrbSnapshot);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else if (js) {
                    const char *c = env->GetStringUTFChars(js, nullptr);
                    if (c) {
                        std::lock_guard<std::mutex> lk(g_orbLock);
                        g_orbSnapshotPub.assign(c);
                        env->ReleaseStringUTFChars(js, c);
                    } else if (env->ExceptionCheck()) {
                        env->ExceptionClear();
                    }
                    env->DeleteLocalRef(js);
                }
            }

            // UI-4: republish the NPC-dialogue snapshot each frame so the native opaque parchment can read it
            // lock-free. Optional method — older jars just leave the default "{}" (no parchment drawn).
            if (g_hudReady.load(std::memory_order_acquire) && g_hudCls && g_midDialogueJson
                && snapSeqAdvanced(env, g_hudCls, g_midDialogueSeq, g_dlgSnapSeq)) {
                jstring js = (jstring) env->CallStaticObjectMethod(g_hudCls, g_midDialogueJson);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else if (js) {
                    const char *c = env->GetStringUTFChars(js, nullptr);
                    if (c) {
                        std::lock_guard<std::mutex> lk(g_dlgLock);
                        g_dialogueJsonPub.assign(c);
                        env->ReleaseStringUTFChars(js, c);
                    } else if (env->ExceptionCheck()) {
                        env->ExceptionClear();
                    }
                    env->DeleteLocalRef(js);
                }
            }

            // Phase-5: republish the world-map snapshot each frame (open-state + control rects) so the UI
            // thread can gate gestures + hide the native chrome lock-free. Optional method — older jars
            // just leave the default {"open":false}.
            if (g_hudReady.load(std::memory_order_acquire) && g_hudCls && g_midMapSnapshot
                && snapSeqAdvanced(env, g_hudCls, g_midMapSnapshotSeq, g_mapSnapSeq)) {
                jstring js = (jstring) env->CallStaticObjectMethod(g_hudCls, g_midMapSnapshot);
                if (env->ExceptionCheck()) { env->ExceptionClear(); }
                else if (js) {
                    const char *c = env->GetStringUTFChars(js, nullptr);
                    if (c) {
                        std::lock_guard<std::mutex> lk(g_mapLock);
                        g_mapSnapshotPub.assign(c);
                        env->ReleaseStringUTFChars(js, c);
                    } else if (env->ExceptionCheck()) {
                        env->ExceptionClear();
                    }
                    env->DeleteLocalRef(js);
                }
            }
        }

        // GPU direct-present mode: the draw thread owns the Surface via EGL (eglSwapBuffers). Don't also acquire
        // and post to it here — the snapshot republish above still ran for the native overlays. Just idle-pace.
        if (g_directPresent.load(std::memory_order_acquire)) { usleep(16000); continue; }

        ANativeWindow *win = nullptr;
        {
            std::lock_guard<std::mutex> lk(g_winLock);
            win = g_window;
            if (win) ANativeWindow_acquire(win);
        }
        if (!win || !g_bridgeCls) { if (win) ANativeWindow_release(win); usleep(16000); continue; }

        int seq = env->CallStaticIntMethod(g_bridgeCls, g_midSeq);
        if (env->ExceptionCheck()) { env->ExceptionClear(); seq = lastSeq; }
        if (seq != lastSeq) {
            int w = env->CallStaticIntMethod(g_bridgeCls, g_midW);
            int h = env->CallStaticIntMethod(g_bridgeCls, g_midH);
            if (env->ExceptionCheck()) { env->ExceptionClear(); w = h = 0; }
            if (w > 0 && h > 0 && w <= 16384 && h <= 16384) {
                g_lastFrameW.store(w, std::memory_order_relaxed);
                g_lastFrameH.store(h, std::memory_order_relaxed);
                jintArray arr = (jintArray) env->CallStaticObjectMethod(g_bridgeCls, g_midPixels);
                if (env->ExceptionCheck()) { env->ExceptionClear(); arr = nullptr; }
                if (arr) {
                    jsize len = env->GetArrayLength(arr);
                    const int64_t needed = (int64_t) w * h;   // w,h capped above, so this can't overflow
                    if ((int64_t) len >= needed) {
                        if (w != geomW || h != geomH) {
                            ANativeWindow_setBuffersGeometry(win, w, h, WINDOW_FORMAT_RGBA_8888);
                            geomW = w; geomH = h;
                        }
                        ANativeWindow_Buffer wb;
                        if (ANativeWindow_lock(win, &wb, nullptr) == 0) {
                            // PERF-1: GetPrimitiveArrayCritical instead of GetIntArrayElements — the latter
                            // malloc'd + copied the full frame every blit on ART. Critical gives a direct
                            // (pinned) pointer; the window is kept tight (just the swizzle loop, no JNI/IO
                            // inside) because it can block GC for its duration. librlawt's legacy path has
                            // used the same pattern for years (librlawt.cpp GetPrimitiveArrayCritical).
                            jint *px = (jint *)env->GetPrimitiveArrayCritical(arr, nullptr);
                            if (px) {
                                const int cw = std::min(w, wb.width);
                                const int ch = std::min(h, wb.height);
                                uint32_t *dst = (uint32_t *) wb.bits;
                                for (int y = 0; y < ch; y++) {
                                    uint32_t *drow = dst + (size_t) y * wb.stride;
                                    const jint *srow = px + (size_t) y * w;
                                    for (int x = 0; x < cw; x++) {
                                        uint32_t s = (uint32_t) srow[x];   // 0x00RRGGBB
                                        drow[x] = 0xFF000000u | ((s & 0xFFu) << 16) | (s & 0xFF00u) | ((s >> 16) & 0xFFu);
                                    }
                                }
                                env->ReleasePrimitiveArrayCritical(arr, px, JNI_ABORT);
                            }
                            ANativeWindow_unlockAndPost(win);
                        }
                    }
                    env->DeleteLocalRef(arr);
                }
            }
            lastSeq = seq;
        }
        ANativeWindow_release(win);
        usleep(16000);   // ~60 Hz cap; the seq check makes an idle login screen nearly free
    }
    return nullptr;
}

static void startRenderThreadOnce() {
    if (g_renderStarted) return;
    g_renderRun = true;
    if (pthread_create(&g_renderThread, nullptr, renderLoop, nullptr) == 0) {
        g_renderStarted = true;
        LOGI("render: thread started");
    } else {
        g_renderRun = false;
        LOGE("render: pthread_create failed errno=%d", errno);
    }
}

// The VM's main thread: create the VM here and NEVER exit (so HotSpot's main thread stays alive and the VM
// is not torn down). After publishing the bridge it runs DeviceHeadlessBoot.main, which boots headless
// RuneLite and keeps the engine running on its own threads.
static void *jvmThreadMain(void *argp) {
    BootArgs *a = (BootArgs *) argp;

    auto fail = [&](jint rc) {
        { std::lock_guard<std::mutex> lk(g_bootLock); g_bootDone = true; g_bootRc = rc; }
        g_bootCv.notify_all();
        delete a;
        return (void *) nullptr;
    };

    LOGI("dlopen %s", a->libjvmPath.c_str());
    void *h = dlopen(a->libjvmPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!h) { LOGE("dlopen libjvm failed: %s", dlerror()); return fail(-10); }
    auto JNI_CreateJavaVM = (CreateJavaVM_t) dlsym(h, "JNI_CreateJavaVM");
    if (!JNI_CreateJavaVM) { LOGE("dlsym JNI_CreateJavaVM failed: %s", dlerror()); return fail(-11); }

    preloadJreLibs(a->libraryPath);

    std::vector<std::string> opts;
    opts.push_back("-Djava.class.path=" + a->classpath);
    opts.push_back("-Djava.library.path=" + a->libraryPath);
    opts.push_back("-Djava.home=" + a->javaHome);
    for (const std::string &o : a->extraOpts) opts.push_back(o);

    std::vector<JavaVMOption> vmOpts(opts.size());
    for (size_t i = 0; i < opts.size(); i++) {
        vmOpts[i].optionString = const_cast<char *>(opts[i].c_str());
        vmOpts[i].extraInfo = nullptr;
        LOGI("opt[%zu] = %s", i, opts[i].c_str());
    }
    JavaVMInitArgs vmArgs{};
    vmArgs.version = JNI_VERSION_21;
    vmArgs.nOptions = (jint) vmOpts.size();
    vmArgs.options = vmOpts.data();
    vmArgs.ignoreUnrecognized = JNI_FALSE;

    JavaVM *vm = nullptr;
    JNIEnv *env = nullptr;
    LOGI("JNI_CreateJavaVM…");
    jint rc = JNI_CreateJavaVM(&vm, (void **) &env, &vmArgs);
    if (rc != JNI_OK || !vm || !env) { LOGE("JNI_CreateJavaVM rc=%d", rc); return fail(rc ? rc : -12); }
    g_vm.store(vm, std::memory_order_release);
    // Track G AG1a smoke (`-Drunelite.routec.smoke=true`): a facade-only GL-bridge boot — no engine, no AWT, no
    // CACIO, no JavaBridge/render. dlopen the librlawt EGL bridge + RegisterNatives the org.lwjgl.opengl/AWTContext
    // facade, then invoke the smoke main below. Detected from the VM opts so the normal boot path is untouched.
    bool routecSmoke = false;
    bool routecGpu = false;
    bool rlhdProbe = false;
    bool routecRlhdFull = false;
    for (const std::string &o : a->extraOpts) {
        if (o == "-Drunelite.routec.smoke=true") routecSmoke = true;
        if (o == "-Drunelite.routecgpu=true") routecGpu = true;
        if (o == "-Drunelite.rlhdprobe=true") rlhdProbe = true;
        if (o == "-Drunelite.routecrlhd=true") routecRlhdFull = true;   // AG3-b full 117HD boot
    }

    if (rlhdProbe) {
        // Track G AG2.5-b (`-Drunelite.rlhdprobe=true`): activate CACIO (RLHD class-init touches java.awt) then
        // hand off to RLHDProbe.main below — a headless 117HD class-load + loader-data test. No bridge, no render,
        // no engine, no librlawt (class-load never calls a GL native).
        LOGI("HotSpot VM up; rlhdprobe mode (CACIO + 117HD class-load probe — no bridge/render)");
        if (!callStaticVoidNoArg(env, "UnsafePokeActivation", "activate")) {
            LOGE("CACIO activation failed; aborting boot (RLHD class-init touches AWT)");
            return fail(-13);
        }
        { std::lock_guard<std::mutex> lk(g_bootLock); g_bootDone = true; g_bootRc = JNI_OK; }
        g_bootCv.notify_all();
    } else if (routecSmoke) {
        LOGI("HotSpot VM up; routec.smoke mode (facade-only GL bridge — no CACIO/engine/render)");
        void *rh = dlopen("librlawt.so", RTLD_NOW | RTLD_GLOBAL);
        if (!rh) {
            LOGE("routec: dlopen librlawt.so failed: %s", dlerror());
        } else {
            auto reg = (jint (*)(JNIEnv *)) dlsym(rh, "RouteC_registerGLNatives");
            if (!reg) LOGE("routec: dlsym RouteC_registerGLNatives failed: %s", dlerror());
            else { jint rr = reg(env); LOGI("routec: RouteC_registerGLNatives rc=%d", rr); }
        }
        { std::lock_guard<std::mutex> lk(g_bootLock); g_bootDone = true; g_bootRc = JNI_OK; }
        g_bootCv.notify_all();
    } else {
        LOGI("HotSpot VM up; activating CACIO CTC before any AWT/bridge class loads");

        // CRITICAL ordering: install CACIO's CTC toolkit BEFORE anything touches java.awt.* — otherwise
        // JavaBridge.<clinit> (it builds a java.awt.Color) drags in java.awt.Toolkit.<clinit>, which on this
        // bionic JRE tries to dlopen the default xawt backend (libawt_xawt.so, absent) and dies. iOS dodges
        // this by running activate() at the very top of DeviceHeadlessBoot.main and resolving the bridge late;
        // we mirror that here so the eager publishBridge below is safe. (DeviceHeadlessBoot.main re-activates —
        // activate() is idempotent.)
        if (!callStaticVoidNoArg(env, "UnsafePokeActivation", "activate")) {
            LOGE("CACIO activation failed; aborting boot (AWT would crash on xawt)");
            return fail(-13);
        }
        LOGI("CACIO CTC active; publishing bridge + starting render");

        if (!publishBridge(env)) {   // JavaBridge is essential for Milestone B — a null bridge is a dead render
            LOGE("bridge publish failed; aborting boot (render + input would be inert)");
            return fail(-14);
        }
        startRenderThreadOnce();

        // Track G AG2 (`-Drunelite.routecgpu=true`): FULL RuneLite boot (CACIO + engine + render) PLUS the GL
        // bridge — dlopen librlawt + RegisterNatives the org.lwjgl.opengl/AWTContext facade NOW, before the boot
        // main starts the engine, so the gpu plugin's AWTContext.createGLContext resolves to our EGL backing.
        // The facade classes live in the GPU-variant jar on this run's classpath. swapBuffers then glReadPixels-es
        // the FBO into JavaBridge's double buffer and the existing render thread blits it (no seam change).
        // AG3-b shares this path: -Drunelite.routecrlhd=true is a FULL boot that also needs the GL bridge (RLHD's
        // AWTContext.createGLContext + the Zone GL-delta forwarders resolve through librlawt); RLHDStarter then
        // loads + starts the 117HD plugin in-world.
        if (routecGpu || routecRlhdFull) {
            const char *mode = routecRlhdFull ? "routecrlhd" : "routecgpu";
            void *rh = dlopen("librlawt.so", RTLD_NOW | RTLD_GLOBAL);
            if (!rh) {
                LOGE("%s: dlopen librlawt.so failed: %s", mode, dlerror());
            } else {
                auto reg = (jint (*)(JNIEnv *)) dlsym(rh, "RouteC_registerGLNatives");
                if (!reg) LOGE("%s: dlsym RouteC_registerGLNatives failed: %s", mode, dlerror());
                else { jint rr = reg(env); LOGI("%s: RouteC_registerGLNatives rc=%d (0=OK)", mode, rr); }
                // Direct EGL present seam: hand librlawt the window-borrow callbacks, then arm direct present so
                // the CPU present thread never connects to the Surface (leaving it free for the EGL window surface).
                auto setcb = (void (*)(void* (*)(uint64_t*), uint64_t (*)(), void (*)(void*), void (*)(int, int)))
                    dlsym(rh, "RouteC_setPresentCallbacks");
                if (setcb) {
                    setcb(rcPresentAcquireWindow, rcPresentSurfaceGen, rcPresentReleaseWindow, rcPresentSetFrameDims);
                    g_directPresent.store(true, std::memory_order_release);
                    g_routecFramesPresented = (uint64_t (*)()) dlsym(rh, "RouteC_framesPresented");  // Phase 3 auto-GPU watchdog signal
                    LOGI("%s: direct EGL present armed (CPU present thread stands down)", mode);
                } else {
                    LOGE("%s: RouteC_setPresentCallbacks not found — using CPU readback present", mode);
                }
            }
        }

        // Signal startJvm that bringup is complete (VM is up). The worker now continues into the boot main.
        { std::lock_guard<std::mutex> lk(g_bootLock); g_bootDone = true; g_bootRc = JNI_OK; }
        g_bootCv.notify_all();
    }

    const std::string internal = toInternal(a->mainClass);
    jclass cls = env->FindClass(internal.c_str());
    if (!cls || env->ExceptionCheck()) {
        LOGE("FindClass %s failed", internal.c_str()); env->ExceptionDescribe(); env->ExceptionClear();
        delete a; return nullptr;   // VM stays up; bridge/render already live
    }
    jmethodID mid = env->GetStaticMethodID(cls, "main", "([Ljava/lang/String;)V");
    if (!mid || env->ExceptionCheck()) {
        LOGE("no main([String]) on %s", internal.c_str()); env->ExceptionDescribe(); env->ExceptionClear();
        delete a; return nullptr;
    }
    jclass strCls = env->FindClass("java/lang/String");
    jobjectArray args = env->NewObjectArray(0, strCls, nullptr);
    LOGI("invoking %s.main", a->mainClass.c_str());
    env->CallStaticVoidMethod(cls, mid, args);
    if (env->ExceptionCheck()) {
        LOGE("%s.main threw", a->mainClass.c_str()); env->ExceptionDescribe(); env->ExceptionClear();
    }
    LOGI("%s.main returned; VM stays alive (engine threads own the run)", a->mainClass.c_str());
    env->DeleteLocalRef(args);   // this thread parks forever below; drop its locals so they don't pin
    env->DeleteLocalRef(strCls);
    env->DeleteLocalRef(cls);
    delete a;
    // Do NOT exit cleanly in a way that detaches the VM main thread: park forever so HotSpot stays up.
    while (true) pause();
    return nullptr;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_startJvm(
        JNIEnv *artEnv, jobject /*thiz*/,
        jstring jJavaHome, jstring jLibjvmPath, jstring jLibraryPath,
        jstring jClasspath, jstring jMainClass, jobjectArray jExtraOpts) {

    if (g_vm.load(std::memory_order_acquire)) { LOGI("startJvm: VM already up (ignoring re-entry)"); return JNI_OK; }
    if (g_stdioRedirect.load(std::memory_order_acquire)) redirectStdioToLogcat();   // A8: DEBUG builds only

    auto *a = new BootArgs();
    a->javaHome    = jstr(artEnv, jJavaHome);
    a->libjvmPath  = jstr(artEnv, jLibjvmPath);
    a->libraryPath = jstr(artEnv, jLibraryPath);
    a->classpath   = jstr(artEnv, jClasspath);
    a->mainClass   = jstr(artEnv, jMainClass);
    const jsize nExtra = jExtraOpts ? artEnv->GetArrayLength(jExtraOpts) : 0;
    for (jsize i = 0; i < nExtra; i++) {
        auto s = (jstring) artEnv->GetObjectArrayElement(jExtraOpts, i);
        a->extraOpts.push_back(jstr(artEnv, s));
        artEnv->DeleteLocalRef(s);
    }

    // Reset the bringup latch so the wait below reflects THIS attempt, not a previous failed boot's
    // result (g_bootDone is process-global). startJvm is single-call by construction, but this keeps a
    // retry-after-failure honest instead of immediately returning a stale rc.
    { std::lock_guard<std::mutex> lk(g_bootLock); g_bootDone = false; g_bootRc = -100; }

    pthread_t t;
    if (pthread_create(&t, nullptr, jvmThreadMain, a) != 0) {
        LOGE("startJvm: pthread_create failed errno=%d", errno);
        delete a;
        return -1;
    }
    pthread_detach(t);

    // Block until the worker has created the VM (or failed), so the Kotlin caller gets a real rc.
    std::unique_lock<std::mutex> lk(g_bootLock);
    g_bootCv.wait(lk, [] { return g_bootDone; });
    return g_bootRc;
}

// ---- Process environment (called from the boot thread BEFORE startJvm) --------------------------------
// The OSRS gamepack reads the JX_* launcher handoff from the process environment (System.getenv), which
// HotSpot snapshots at VM startup — so these MUST be set before JNI_CreateJavaVM. setenv mutates the global
// environ; the boot thread sets them, then startJvm spawns the worker that creates the VM (a happens-before via
// pthread_create), so the worker sees them. Mirrors the iOS loadJagexTokens setenv path (JVMLauncher.m).
// A8: DEBUG-only stdout/err->logcat pipe. Set from Kotlin (BuildConfig.DEBUG) BEFORE startJvm.
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetStdioRedirect(JNIEnv *, jobject, jboolean enabled) {
    g_stdioRedirect.store(enabled == JNI_TRUE, std::memory_order_release);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetEnv(JNIEnv *env, jobject, jstring jKey, jstring jVal) {
    std::string k = jstr(env, jKey);
    std::string v = jstr(env, jVal);
    if (!k.empty()) {
        setenv(k.c_str(), v.c_str(), 1);
    }
}

// ---- Surface lifecycle (called from the ART UI thread) -----------------------------------------------

extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetSurface(JNIEnv *env, jobject, jobject surface) {
    ANativeWindow *win = surface ? ANativeWindow_fromSurface(env, surface) : nullptr;
    ANativeWindow *old = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_winLock);
        old = g_window;
        g_window = win;   // takes the fromSurface reference
    }
    if (old) ANativeWindow_release(old);
    g_surfaceGen.fetch_add(1, std::memory_order_release);   // force the render thread to re-apply geometry
    LOGI("surface %s", win ? "set" : "cleared");
}

// PERF-BATTERY-NETWORK-01: background/foreground visibility gate (called from onStop/onStart on the UI thread).
// Paused -> the render thread idles at 4 Hz (drainInput only) instead of the 60 Hz snapshot-republish batch.
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetPaused(JNIEnv *, jobject, jboolean paused) {
    g_paused.store(paused ? true : false, std::memory_order_release);
    LOGI("render %s", paused ? "paused (backgrounded)" : "resumed (foreground)");
}

// ---- Input ingress (called from the ART UI thread; pushes onto the queue, never attaches to HotSpot) --

// A position-only event safe to coalesce/drop under flood: a camera-drag delta, a hover move, or a touch-move
// (drag phase 1). Terminal/important events — taps, precise clicks, touch DOWN/UP, wheel, keys, text, menu
// commits, clear-hover — are NEVER coalesced or dropped (dropping a touch-UP would wedge the engine's drag).
static bool isCoalescible(const InputEvent &ev) {
    // IN_KEEPALIVE is idempotent (it only bumps a timestamp on the Java side), so a duplicate is safe to drop
    // under flood — a continuous native drag routed through the onBridge keepalive wrapper can't fill the queue.
    return ev.kind == IN_CAMERA || ev.kind == IN_MOVE || ev.kind == IN_KEEPALIVE || (ev.kind == IN_TOUCH && ev.a == 1);
}

static void enqueue(InputEvent ev) {
    std::lock_guard<std::mutex> lk(g_inLock);
    // 1) Coalesce a high-frequency position stream into the queue tail so a fast camera/drag/hover can't flood
    //    the queue and push terminal events past the cap. Camera deltas SUM; move/touch-move keep the LATEST
    //    position (one update per drain frame is all the engine needs). Down/up break the chain (different a).
    if (!g_inQueue.empty()) {
        InputEvent &tail = g_inQueue.back();
        if (ev.kind == IN_CAMERA && tail.kind == IN_CAMERA) { tail.a += ev.a; tail.b += ev.b; return; }
        if (ev.kind == IN_MOVE && tail.kind == IN_MOVE) { tail.a = ev.a; tail.b = ev.b; return; }
        if (ev.kind == IN_TOUCH && ev.a == 1 && tail.kind == IN_TOUCH && tail.a == 1 && tail.d == ev.d) {
            tail.b = ev.b; tail.c = ev.c; return;   // latest drag-move position (same button)
        }
        if (ev.kind == IN_KEEPALIVE && tail.kind == IN_KEEPALIVE) return;   // idempotent: one pending is enough
    }
    if (g_inQueue.size() < 512) { g_inQueue.push_back(ev); return; }
    // 2) Queue at the cap. A coalescible position event can be safely dropped; a terminal event must survive —
    //    evict the OLDEST coalescible (position) event to make room, then keep the terminal. If the whole queue
    //    is terminals (no position event to evict — not realistic at human input rates), keep it anyway: a few
    //    over 512 is far better than dropping a release/commit and wedging input.
    if (isCoalescible(ev)) return;
    for (auto it = g_inQueue.begin(); it != g_inQueue.end(); ++it) {
        if (isCoalescible(*it)) { g_inQueue.erase(it); break; }
    }
    g_inQueue.push_back(ev);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeClick(JNIEnv *, jobject, jint x, jint y, jint button) {
    enqueue({IN_CLICK, x, y, button, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeTouch(JNIEnv *, jobject, jint type, jint x, jint y, jint button) {
    enqueue({IN_TOUCH, type, x, y, button});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeCamera(JNIEnv *, jobject, jint dx, jint dy) {
    enqueue({IN_CAMERA, dx, dy, 0, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeClearHover(JNIEnv *, jobject) {
    enqueue({IN_CLEARHOVER, 0, 0, 0, 0});
}
// FIX-3 idle keepalive: queue a keepAlive() call (lock-free on the Java side). Enqueued like the others so the
// already-attached render thread makes the JNI call when it drains — the ART UI thread never attaches to HotSpot.
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeKeepAlive(JNIEnv *, jobject) {
    enqueue({IN_KEEPALIVE, 0, 0, 0, 0});
}
// AP-2a sticky-Shift: queue a hold (held=1) / release (held=0) so it's ordered ahead of the menu-open click.
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetShiftHeld(JNIEnv *, jobject, jboolean held) {
    enqueue({IN_SHIFT, held ? 1 : 0, 0, 0, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetCtrlHeld(JNIEnv *, jobject, jboolean held) {
    enqueue({IN_CTRL, held ? 1 : 0, 0, 0, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetAltHeld(JNIEnv *, jobject, jboolean held) {
    enqueue({IN_ALT, held ? 1 : 0, 0, 0, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeMiddleClick(JNIEnv *, jobject, jint x, jint y) {
    enqueue({IN_MIDDLECLICK, x, y, 0, 0});
}

// ---- A1 input ingress (UI thread enqueues; render thread drains into the bridge) ---------------------
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeWheel(JNIEnv *, jobject, jint x, jint y, jint rotation) {
    enqueue({IN_WHEEL, x, y, rotation, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeClickPrecise(JNIEnv *, jobject, jint x, jint y, jint button) {
    enqueue({IN_CLICKPRECISE, x, y, button, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeMove(JNIEnv *, jobject, jint x, jint y) {
    enqueue({IN_MOVE, x, y, 0, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeKeyStroke(JNIEnv *, jobject, jint vk) {
    enqueue({IN_KEYSTROKE, vk, 0, 0, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeKeybind(JNIEnv *, jobject, jint vk, jint modifiers) {
    enqueue({IN_KEYBIND, vk, modifiers, 0, 0});
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeText(JNIEnv *env, jobject, jstring js) {
    InputEvent ev{IN_TEXT, 0, 0, 0, 0};
    ev.s = jstr(env, js);
    enqueue(std::move(ev));
}

// ---- A2 press-and-peek menu (commit + read-surface) -------------------------------------------------
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSelectMenuPoint(JNIEnv *, jobject, jint x, jint y) {
    enqueue({IN_SELECTMENU, x, y, 0, 0});
}
// FIX-10b: commit a native tap-menu row / submenu child by index (child<0 = the parent entry itself).
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeInvokeMenuEntry(JNIEnv *, jobject, jint parent, jint child) {
    enqueue({IN_INVOKEMENUENTRY, parent, child, 0, 0});
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeMenuSnapshot(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lk(g_menuLock);
    return env->NewStringUTF(g_menuSnapshot.c_str());
}
extern "C" JNIEXPORT jlong JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeMenuPublishSeq(JNIEnv *, jobject) {
    return (jlong) g_menuPublishSeq.load(std::memory_order_relaxed);
}
// Runtime tab/stone/chat sprite payload — read lock-free by the UI thread (NewStringUTF uses the UI/ART env; the
// HotSpot fetch happens on the render thread, see the producer loop). "" until captured. NEVER call into HotSpot
// here: this thread owns no HotSpot env, so CallStaticObjectMethod would abort the process.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeTabSprites(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lk(g_tabSpritesLock);
    return env->NewStringUTF(g_tabSprites.c_str());
}

// ---- A1 read-surface (UI thread reads the render-thread-published atomics; never attaches to HotSpot) -
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeIsTextInputOpen(JNIEnv *, jobject) {
    return g_textInputOpen.load(std::memory_order_relaxed) ? JNI_TRUE : JNI_FALSE;
}
extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeInteractTapSeq(JNIEnv *, jobject) {
    return g_interactTapSeq.load(std::memory_order_relaxed);
}
// Tap-KIND truth read-surface (0 on a jar without the getters -> seq never advances -> shell keeps the ring).
extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeTapKindSeq(JNIEnv *, jobject) {
    return g_tapKindSeq.load(std::memory_order_relaxed);
}
extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeLastTapKind(JNIEnv *, jobject) {
    return g_lastTapKind.load(std::memory_order_relaxed);
}
extern "C" JNIEXPORT jlong JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeLastWidgetBounds(JNIEnv *, jobject) {
    return (jlong) g_lastWidgetBounds.load(std::memory_order_relaxed);
}
// Last frame dimensions (so the UI thread can map a screen touch to game-canvas coords). 0 before render.
extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeFrameWidth(JNIEnv *, jobject) { return g_lastFrameW.load(std::memory_order_relaxed); }
extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeFrameHeight(JNIEnv *, jobject) { return g_lastFrameH.load(std::memory_order_relaxed); }
// Phase 3 (auto-GPU watchdog): frames the GPU/117HD renderer has actually presented. 0 == not armed or renderer
// never activated (failed/black/crashed); climbing == success. The Kotlin first-boot fallback polls this.
extern "C" JNIEXPORT jlong JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeGpuFramesPresented(JNIEnv *, jobject) {
    return g_routecFramesPresented ? (jlong) g_routecFramesPresented() : 0L;
}

// ---- A4 plugin control plane (MobileUiBridge) --------------------------------------------------------
// These run on the Kotlin "rl-bridge" executor thread (NOT the ART UI thread). They daemon-attach that OS
// thread to the embedded HotSpot VM (bridgeEnvAttach) and marshal strings across the VM boundary as UTF-8:
// the ART JNIEnv* (param) makes the ART return value; the HotSpot env makes the bridge call.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeListPlugins(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady()) return artEnv->NewStringUTF("");   // acquire: facade not published yet
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midListPlugins) return artEnv->NewStringUTF("");
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, g_midListPlugins);
    if (hs->ExceptionCheck()) { hs->ExceptionClear(); if (r) hs->DeleteLocalRef(r); return artEnv->NewStringUTF(""); }
    std::string s = jstr(hs, r);            // GetStringUTFChars on the HotSpot env
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(s.c_str()); // re-create the string in the ART VM
}
extern "C" JNIEXPORT jlong JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeMobileUiSeq(JNIEnv *, jobject) {
    if (!mobileUiReady()) return -1;
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midMobileUiSeq) return -1;
    jlong v = hs->CallStaticLongMethod(g_mobileUiCls, g_midMobileUiSeq);
    if (hs->ExceptionCheck()) { hs->ExceptionClear(); return -1; }
    return v;
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePollMobileUiEvents(JNIEnv *artEnv, jobject, jlong sinceSeq) {
    if (!mobileUiReady()) return artEnv->NewStringUTF("");
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midPollEvents) return artEnv->NewStringUTF("");
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, g_midPollEvents, sinceSeq);
    if (hs->ExceptionCheck()) { hs->ExceptionClear(); if (r) hs->DeleteLocalRef(r); return artEnv->NewStringUTF(""); }
    std::string s = jstr(hs, r);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(s.c_str());
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetPluginEnabled(JNIEnv *artEnv, jobject, jstring jId, jboolean enabled) {
    if (!mobileUiReady()) return artEnv->NewStringUTF("");
    std::string id = jstr(artEnv, jId);     // ART string -> std::string
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midSetPluginEnabled) return artEnv->NewStringUTF("");
    jstring hid = hs->NewStringUTF(id.c_str());
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, g_midSetPluginEnabled, hid, enabled);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (hid) hs->DeleteLocalRef(hid);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
// AP-2b Finding 6: pin/star a plugin by DISPLAY NAME (not className). Off the UI thread (rl-bridge). Returns
// the bridge's JSON ack ({"ok":true,"writeId":n}); "" if the facade isn't published / setPinned didn't resolve.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetPinned(JNIEnv *artEnv, jobject, jstring jName, jboolean pinned) {
    if (!mobileUiReady() || !g_midSetPinned) return artEnv->NewStringUTF("");
    std::string name = jstr(artEnv, jName);
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls) return artEnv->NewStringUTF("");
    jstring hn = hs->NewStringUTF(name.c_str());
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, g_midSetPinned, hn, pinned);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (hn) hs->DeleteLocalRef(hn);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeGetPluginConfig(JNIEnv *artEnv, jobject, jstring jGroup) {
    if (!mobileUiReady()) return artEnv->NewStringUTF("");
    std::string group = jstr(artEnv, jGroup);
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midGetPluginConfig) return artEnv->NewStringUTF("");
    jstring hg = hs->NewStringUTF(group.c_str());
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, g_midGetPluginConfig, hg);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (hg) hs->DeleteLocalRef(hg);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetConfig(JNIEnv *artEnv, jobject, jstring jGroup, jstring jKey, jstring jValue) {
    if (!mobileUiReady()) return artEnv->NewStringUTF("");
    std::string group = jstr(artEnv, jGroup), key = jstr(artEnv, jKey), value = jstr(artEnv, jValue);
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midSetConfig) return artEnv->NewStringUTF("");
    jstring hg = hs->NewStringUTF(group.c_str()), hk = hs->NewStringUTF(key.c_str()), hv = hs->NewStringUTF(value.c_str());
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, g_midSetConfig, hg, hk, hv);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (hg) hs->DeleteLocalRef(hg);
    if (hk) hs->DeleteLocalRef(hk);
    if (hv) hs->DeleteLocalRef(hv);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
extern "C" JNIEXPORT jlong JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeProcessedWriteId(JNIEnv *, jobject) {
    if (!mobileUiReady()) return -1;
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midProcessedWriteId) return -1;
    jlong v = hs->CallStaticLongMethod(g_mobileUiCls, g_midProcessedWriteId);
    if (hs->ExceptionCheck()) { hs->ExceptionClear(); return -1; }
    return v;
}

// ---- A5 Tier-1 plugin panels (rendered off-screen; the ARGB int[] image is marshalled cross-VM) -------
// Small helper: call a no-arg String bridge method on g_mobileUiCls and return an ART string.
static jstring mobileUiStr(JNIEnv *artEnv, jmethodID m) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !m) return artEnv->NewStringUTF("");
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, m);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
static jint mobileUiInt(jmethodID m) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !m) return 0;
    jint v = hs->CallStaticIntMethod(g_mobileUiCls, m);
    if (hs->ExceptionCheck()) { hs->ExceptionClear(); return 0; }
    return v;
}
// panelReady() gates the whole Tier-1 surface (acquire for publication + all-or-nothing: false if ANY panel
// method, e.g. closePanel, didn't resolve — so the viewer never opens a panel it could never close).
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeListPanels(JNIEnv *artEnv, jobject) {
    if (!panelReady()) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midListPanels);
}
// A8: persist pending plugin-config writes (call when the app backgrounds, off the UI thread). Gated by the
// MobileUiBridge publication latch; a no-op if flushConfig didn't resolve. Returns the bridge's JSON ack.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeFlushConfig(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midFlushConfig) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midFlushConfig);
}
// SC-2/CFG-10: reset an entire config group to defaults. Returns the bridge JSON ack ({"ok":..,"writeId":n}).
static jstring mobileUiStrArg(JNIEnv *artEnv, jmethodID m, jstring jArg);   // defined below (Finding 17 helpers)
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeResetPluginConfig(JNIEnv *artEnv, jobject, jstring jGroup) {
    if (!mobileUiReady() || !g_midResetPluginConfig) return artEnv->NewStringUTF("");
    return mobileUiStrArg(artEnv, g_midResetPluginConfig, jGroup);
}
// SC-1/NOTIF-2: the serialized default Notification seed JSON for the per-item editor (or "" if unresolved).
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeNotificationDefaults(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midNotificationDefaults) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midNotificationDefaults);
}
// User-defined hotkey buttons: list every bound plugin keybind (JSON), and fire one by (group,key) off its live
// binding. boundKeybindsJson is read on the native Hotkeys screen; fireHotkey on a HUD button tap.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeBoundKeybindsJson(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midBoundKeybinds) return artEnv->NewStringUTF("[]");
    return mobileUiStr(artEnv, g_midBoundKeybinds);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeFireHotkey(JNIEnv *artEnv, jobject, jstring jGroup, jstring jKey) {
    if (!mobileUiReady() || !g_midFireHotkey) return;
    std::string group = jstr(artEnv, jGroup), key = jstr(artEnv, jKey);
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls) return;
    jstring hg = hs->NewStringUTF(group.c_str()), hk = hs->NewStringUTF(key.c_str());
    hs->CallStaticVoidMethod(g_mobileUiCls, g_midFireHotkey, hg, hk);
    if (hs->ExceptionCheck()) { hs->ExceptionClear(); }
    if (hg) hs->DeleteLocalRef(hg);
    if (hk) hs->DeleteLocalRef(hk);
}
// AP-2a drain surfaces: one queued item or "" (empty queue / unresolved). Off the UI thread (rl-bridge).
//   Finding 9  — nextNotification: "titlebody" (SOH-delimited), native splits + raises a notification.
//   Finding 25 — nextLink: a single URL to open in a Custom Tab.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeNextNotification(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midNextNotification) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midNextNotification);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeNextLink(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midNextLink) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midNextLink);
}
// PARITY-ANDROID-SHOT — nextScreenshot: absolute path of the next engine auto-screenshot PNG (or "").
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeNextScreenshot(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midNextScreenshot)
        return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midNextScreenshot);
}
// Finding 17 — hubState: {"refreshing":bool,"seq":int}, native drives the hub install spinner.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeHubState(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midHubState) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midHubState);
}
// Finding 17 — hubManifest: one-time async catalog download. First call returns {"status":"loading"}; the
// native screen polls until {"status":"ok",plugins:[...]} (or error:*). No args.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeHubManifest(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midHubManifest) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midHubManifest);
}
// Helper: call a (String)->String bridge method on g_mobileUiCls, marshalling the arg ART->HotSpot.
static jstring mobileUiStrArg(JNIEnv *artEnv, jmethodID m, jstring jArg) {
    if (!m) return artEnv->NewStringUTF("");
    std::string a = jstr(artEnv, jArg);
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls) return artEnv->NewStringUTF("");
    jstring ha = hs->NewStringUTF(a.c_str());
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, m, ha);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (ha) hs->DeleteLocalRef(ha);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
// Finding 17 — hubInstall/hubUninstall by internal name: register synchronously (config write + flush),
// download+load async. Returns {"ok":true,"writeId":n}; the screen then polls hubState() for the seq bump.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeHubInstall(JNIEnv *artEnv, jobject, jstring jName) {
    if (!mobileUiReady()) return artEnv->NewStringUTF("");
    return mobileUiStrArg(artEnv, g_midHubInstall, jName);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeHubUninstall(JNIEnv *artEnv, jobject, jstring jName) {
    if (!mobileUiReady()) return artEnv->NewStringUTF("");
    return mobileUiStrArg(artEnv, g_midHubUninstall, jName);
}
// Publish a host-origin notification into the shared queue (the drain delivers it like an engine one). Off
// the UI thread (rl-bridge). Lets the native shell raise its own alerts + deterministically exercise delivery.
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePublishNotification(JNIEnv *artEnv, jobject, jstring jt, jstring jb) {
    if (!mobileUiReady() || !g_midPublishNotification) return;
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls) return;
    std::string t = jstr(artEnv, jt), b = jstr(artEnv, jb);
    jstring ht = hs->NewStringUTF(t.c_str()), hb = hs->NewStringUTF(b.c_str());
    hs->CallStaticVoidMethod(g_mobileUiCls, g_midPublishNotification, ht, hb);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
    if (ht) hs->DeleteLocalRef(ht);
    if (hb) hs->DeleteLocalRef(hb);
}
// Publish a host-origin link into the shared queue (the drain opens it). Off the UI thread (rl-bridge).
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePublishLink(JNIEnv *artEnv, jobject, jstring ju) {
    if (!mobileUiReady() || !g_midPublishLink) return;
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls) return;
    std::string u = jstr(artEnv, ju);
    jstring hu = hs->NewStringUTF(u.c_str());
    hs->CallStaticVoidMethod(g_mobileUiCls, g_midPublishLink, hu);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
    if (hu) hs->DeleteLocalRef(hu);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeClosePanel(JNIEnv *artEnv, jobject) {
    if (!panelReady()) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midClosePanel);
}
extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelWidth(JNIEnv *, jobject) { return panelReady() ? mobileUiInt(g_midPanelW) : 0; }
extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelHeight(JNIEnv *, jobject) { return panelReady() ? mobileUiInt(g_midPanelH) : 0; }
extern "C" JNIEXPORT jint JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelFrameSeq(JNIEnv *, jobject) { return panelReady() ? mobileUiInt(g_midPanelSeq) : 0; }
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOpenPanel(JNIEnv *artEnv, jobject, jint index) {
    if (!panelReady()) return artEnv->NewStringUTF("");
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midOpenPanel) return artEnv->NewStringUTF("");
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, g_midOpenPanel, index);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelClick(JNIEnv *artEnv, jobject, jint x, jint y) {
    if (!panelReady()) return artEnv->NewStringUTF("");
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midPanelClick) return artEnv->NewStringUTF("");
    jstring r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, g_midPanelClick, x, y);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
// SC-4 panel-text input — all best-effort (guard on the mid; a stale jar → no-op). On the rl-bridge thread.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeIsPanelTextActive(JNIEnv *, jobject) {
    if (!panelReady() || !g_midIsPanelTextActive) return JNI_FALSE;
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls) return JNI_FALSE;
    jboolean v = hs->CallStaticBooleanMethod(g_mobileUiCls, g_midIsPanelTextActive);
    if (hs->ExceptionCheck()) { hs->ExceptionClear(); return JNI_FALSE; }
    return v;
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeGetPanelText(JNIEnv *artEnv, jobject) {
    if (!panelReady() || !g_midGetPanelText) return artEnv->NewStringUTF("");
    return mobileUiStr(artEnv, g_midGetPanelText);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelText(JNIEnv *artEnv, jobject, jstring jText) {
    if (!panelReady() || !g_midPanelText) return artEnv->NewStringUTF("");
    return mobileUiStrArg(artEnv, g_midPanelText, jText);
}
// (int|int,int|int,int,int) -> String panel-input calls, marshalled inline (no shared helper for these shapes).
static jstring panelCall(JNIEnv *artEnv, jmethodID m, jint a, jint b, jint c, int argc) {
    if (!m) return artEnv->NewStringUTF("");
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls) return artEnv->NewStringUTF("");
    jstring r;
    if (argc == 1) r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, m, a);
    else if (argc == 2) r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, m, a, b);
    else r = (jstring) hs->CallStaticObjectMethod(g_mobileUiCls, m, a, b, c);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelKey(JNIEnv *artEnv, jobject, jint vk) {
    if (!panelReady()) return artEnv->NewStringUTF("");
    return panelCall(artEnv, g_midPanelKey, vk, 0, 0, 1);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelLongPress(JNIEnv *artEnv, jobject, jint x, jint y) {
    if (!panelReady()) return artEnv->NewStringUTF("");
    return panelCall(artEnv, g_midPanelLongPress, x, y, 0, 2);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelWheel(JNIEnv *artEnv, jobject, jint x, jint y, jint rotation) {
    if (!panelReady()) return artEnv->NewStringUTF("");
    return panelCall(artEnv, g_midPanelWheel, x, y, rotation, 3);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelMove(JNIEnv *artEnv, jobject, jint x, jint y) {
    if (!panelReady()) return artEnv->NewStringUTF("");
    return panelCall(artEnv, g_midPanelMove, x, y, 0, 2);
}
extern "C" JNIEXPORT jintArray JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanelPixels(JNIEnv *artEnv, jobject) {
    if (!panelReady()) return nullptr;
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_mobileUiCls || !g_midPanelPixels) return nullptr;
    jintArray src = (jintArray) hs->CallStaticObjectMethod(g_mobileUiCls, g_midPanelPixels);
    if (hs->ExceptionCheck() || !src) { hs->ExceptionClear(); if (src) hs->DeleteLocalRef(src); return nullptr; }
    jsize n = hs->GetArrayLength(src);
    jintArray dst = artEnv->NewIntArray(n);
    if (!dst) {                              // ART OOM: clear its pending exc, drop the HotSpot ref, signal null
        if (artEnv->ExceptionCheck()) artEnv->ExceptionClear();
        hs->DeleteLocalRef(src);
        return nullptr;
    }
    if (n > 0) {
        jint *buf = hs->GetIntArrayElements(src, nullptr);
        if (buf) {
            artEnv->SetIntArrayRegion(dst, 0, n, buf);
            hs->ReleaseIntArrayElements(src, buf, JNI_ABORT);
        } else {                             // HotSpot OOM pinning the array: clear so it can't trip the next
            if (hs->ExceptionCheck()) hs->ExceptionClear();   // bridge call; return null (dst is GC'd)
            hs->DeleteLocalRef(src);
            return nullptr;
        }
    }
    hs->DeleteLocalRef(src);
    return dst;
}

// AP-2b Finding 5 (screenshot): marshal the latest composited CPU frame (JavaBridge.getFramePixels, the stable
// 0x00RRGGBB snapshot) into an ART int[] for the native PNG/MediaStore save. Same OOM-safe marshalling as the
// panel pull; gated on the live bridge. Pull off the rl-bridge thread. Width is read separately via the existing
// nativeFrameWidth() atomic (the caller guards len % w == 0 against a torn read across a resize).
extern "C" JNIEXPORT jintArray JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeFramePixels(JNIEnv *artEnv, jobject) {
    if (!g_bridgeCls || !g_midPixels) return nullptr;
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs) return nullptr;
    jintArray src = (jintArray) hs->CallStaticObjectMethod(g_bridgeCls, g_midPixels);
    if (hs->ExceptionCheck() || !src) { hs->ExceptionClear(); if (src) hs->DeleteLocalRef(src); return nullptr; }
    jsize n = hs->GetArrayLength(src);
    jintArray dst = artEnv->NewIntArray(n);
    if (!dst) {
        if (artEnv->ExceptionCheck()) artEnv->ExceptionClear();
        hs->DeleteLocalRef(src);
        return nullptr;
    }
    if (n > 0) {
        jint *buf = hs->GetIntArrayElements(src, nullptr);
        if (buf) {
            artEnv->SetIntArrayRegion(dst, 0, n, buf);
            hs->ReleaseIntArrayElements(src, buf, JNI_ABORT);
        } else {
            if (hs->ExceptionCheck()) hs->ExceptionClear();
            hs->DeleteLocalRef(src);
            return nullptr;
        }
    }
    hs->DeleteLocalRef(src);
    return dst;
}

// ---- A5 Tier-2 native reflow (QuestHelperBridge / WorldSwitcherBridge) -------------------------------
// Run on the rl-bridge thread (NOT the UI thread); each gates on its facade's acquire latch, then calls the
// cached static method on the HotSpot env and marshals the result back into the ART env. Generic by (cls, m)
// since both facades share the same no-arg String / bool / void(bool) / void(int) call shapes.
static jstring facadeStr(JNIEnv *artEnv, jclass cls, jmethodID m) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return artEnv->NewStringUTF("");
    jstring r = (jstring) hs->CallStaticObjectMethod(cls, m);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
// (String[,String])->String facade call (marshal 1 or 2 ART args ART->HotSpot). j2==nullptr → single-arg call.
static jstring facadeStrArgs(JNIEnv *artEnv, jclass cls, jmethodID m, jstring j1, jstring j2, bool two) {
    if (!cls || !m) return artEnv->NewStringUTF("");
    std::string a1 = jstr(artEnv, j1), a2 = two ? jstr(artEnv, j2) : std::string();
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs) return artEnv->NewStringUTF("");
    jstring h1 = hs->NewStringUTF(a1.c_str());
    jstring h2 = two ? hs->NewStringUTF(a2.c_str()) : nullptr;
    jstring r = (jstring) (two ? hs->CallStaticObjectMethod(cls, m, h1, h2)
                               : hs->CallStaticObjectMethod(cls, m, h1));
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (h1) hs->DeleteLocalRef(h1);
    if (h2) hs->DeleteLocalRef(h2);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
// (long)->String facade call (config profile switch: switchProfile(id) -> ack JSON).
static jstring facadeStrLong(JNIEnv *artEnv, jclass cls, jmethodID m, jlong v) {
    if (!cls || !m) return artEnv->NewStringUTF("");
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs) return artEnv->NewStringUTF("");
    jstring r = (jstring) hs->CallStaticObjectMethod(cls, m, v);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
// (String,int,int)->String facade call (overlay free pixel-drag: setOverlayPreferredLocation(name,x,y)).
static jstring facadeStrLocArgs(JNIEnv *artEnv, jclass cls, jmethodID m, jstring jName, jint x, jint y) {
    if (!cls || !m) return artEnv->NewStringUTF("");
    std::string a1 = jstr(artEnv, jName);
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs) return artEnv->NewStringUTF("");
    jstring h1 = hs->NewStringUTF(a1.c_str());
    jstring r = (jstring) hs->CallStaticObjectMethod(cls, m, h1, x, y);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (h1) hs->DeleteLocalRef(h1);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}
static jboolean facadeBool(jclass cls, jmethodID m) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return JNI_FALSE;
    jboolean v = hs->CallStaticBooleanMethod(cls, m);
    if (hs->ExceptionCheck()) { hs->ExceptionClear(); return JNI_FALSE; }
    return v;
}
static void facadeVoidBool(jclass cls, jmethodID m, jboolean b) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return;
    hs->CallStaticVoidMethod(cls, m, b);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
}
static void facadeVoid0(jclass cls, jmethodID m) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return;
    hs->CallStaticVoidMethod(cls, m);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
}
static void facadeVoidInt(jclass cls, jmethodID m, jint i) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return;
    hs->CallStaticVoidMethod(cls, m, i);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
}
static void facadeVoidIntBool(jclass cls, jmethodID m, jint i, jboolean b) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return;
    hs->CallStaticVoidMethod(cls, m, i, b);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
}
static void facadeVoidIntInt(jclass cls, jmethodID m, jint a, jint b) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return;
    hs->CallStaticVoidMethod(cls, m, a, b);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
}
static void facadeVoid4Int(jclass cls, jmethodID m, jint a, jint b, jint c, jint d) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return;
    hs->CallStaticVoidMethod(cls, m, a, b, c, d);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
}
static void facadeVoidIntIntBool(jclass cls, jmethodID m, jint a, jint b, jboolean c) {
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !cls || !m) return;
    hs->CallStaticVoidMethod(cls, m, a, b, c);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
}

// Quest Helper
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeQuestAvailable(JNIEnv *, jobject) {
    if (!questReady()) return JNI_FALSE;
    return facadeBool(g_questCls, g_midQuestAvail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeQuestSetUiOpen(JNIEnv *, jobject, jboolean open) {
    if (!questReady()) return;
    facadeVoidBool(g_questCls, g_midQuestSetUiOpen, open);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeQuestListJson(JNIEnv *artEnv, jobject) {
    if (!questReady()) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_questCls, g_midQuestList);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeQuestActiveJson(JNIEnv *artEnv, jobject) {
    if (!questReady()) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_questCls, g_midQuestActive);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeQuestStart(JNIEnv *artEnv, jobject, jstring jName) {
    if (!questReady()) return;
    std::string name = jstr(artEnv, jName);
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_questCls || !g_midQuestStart) return;
    jstring hn = hs->NewStringUTF(name.c_str());
    hs->CallStaticVoidMethod(g_questCls, g_midQuestStart, hn);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
    if (hn) hs->DeleteLocalRef(hn);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeQuestStop(JNIEnv *, jobject) {
    if (!questReady()) return;
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_questCls || !g_midQuestStop) return;
    hs->CallStaticVoidMethod(g_questCls, g_midQuestStop);
    if (hs->ExceptionCheck()) hs->ExceptionClear();
}

// World Switcher
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeWorldAvailable(JNIEnv *, jobject) {
    if (!worldReady()) return JNI_FALSE;
    return facadeBool(g_worldCls, g_midWorldAvail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeWorldSetUiOpen(JNIEnv *, jobject, jboolean open) {
    if (!worldReady()) return;
    facadeVoidBool(g_worldCls, g_midWorldSetUiOpen, open);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeWorldListJson(JNIEnv *artEnv, jobject) {
    if (!worldReady()) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_worldCls, g_midWorldList);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeWorldHop(JNIEnv *, jobject, jint worldId) {
    if (!worldReady()) return;
    facadeVoidInt(g_worldCls, g_midWorldHop, worldId);
}
// SC-5: mark/unmark a world as a favourite (best-effort; no-op if the jar predates setFavourite).
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeWorldSetFavourite(JNIEnv *, jobject, jint worldId, jboolean fav) {
    if (!worldReady() || !g_midWorldSetFav) return;
    facadeVoidIntBool(g_worldCls, g_midWorldSetFav, worldId, fav);
}
// SC-5: quick-hop to the next/previous world (best-effort; no-op if hopDirection is unresolved).
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeWorldHopDirection(JNIEnv *, jobject, jboolean previous) {
    if (!worldReady() || !g_midWorldHopDir) return;
    facadeVoidBool(g_worldCls, g_midWorldHopDir, previous);
}

// Finding 14 — XP Tracker native reflow (read-only). Same facade-call shape as Quest/World, gated on the panel's
// own release latch. getXpJson returns {available, skills:[{skill,xpGained,xpHr,...,progress}], overall:{…}}.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeXpAvailable(JNIEnv *, jobject) {
    if (!g_xpPanel.ready.load(std::memory_order_acquire)) return JNI_FALSE;
    return facadeBool(g_xpPanel.cls, g_xpPanel.avail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeXpSetUiOpen(JNIEnv *, jobject, jboolean open) {
    if (!g_xpPanel.ready.load(std::memory_order_acquire)) return;
    facadeVoidBool(g_xpPanel.cls, g_xpPanel.setUiOpen, open);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeXpJson(JNIEnv *artEnv, jobject) {
    if (!g_xpPanel.ready.load(std::memory_order_acquire)) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_xpPanel.cls, g_xpPanel.json);
}

// Finding 14 — Loot Tracker native reflow (read-only). getLootJson = {available, sources:[{name,subTitle,type,
// kills,totalValue,items:[{id,name,qty,ge,ha}]}]}.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeLootAvailable(JNIEnv *, jobject) {
    if (!g_lootPanel.ready.load(std::memory_order_acquire)) return JNI_FALSE;
    return facadeBool(g_lootPanel.cls, g_lootPanel.avail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeLootSetUiOpen(JNIEnv *, jobject, jboolean open) {
    if (!g_lootPanel.ready.load(std::memory_order_acquire)) return;
    facadeVoidBool(g_lootPanel.cls, g_lootPanel.setUiOpen, open);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeLootJson(JNIEnv *artEnv, jobject) {
    if (!g_lootPanel.ready.load(std::memory_order_acquire)) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_lootPanel.cls, g_lootPanel.json);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeLootResetAll(JNIEnv *artEnv, jobject) {
    if (!g_lootPanel.ready.load(std::memory_order_acquire) || !g_midLootReset) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_lootPanel.cls, g_midLootReset);
}

// Finding 14 — Grand Exchange native reflow (read-only). getGeJson = {available, offers:[{slot,state,itemId,
// name,qty,total,price,spent,progress}], history:[{buy,itemId,qty,price,time}]}.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeGeAvailable(JNIEnv *, jobject) {
    if (!g_gePanel.ready.load(std::memory_order_acquire)) return JNI_FALSE;
    return facadeBool(g_gePanel.cls, g_gePanel.avail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeGeSetUiOpen(JNIEnv *, jobject, jboolean open) {
    if (!g_gePanel.ready.load(std::memory_order_acquire)) return;
    facadeVoidBool(g_gePanel.cls, g_gePanel.setUiOpen, open);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeGeJson(JNIEnv *artEnv, jobject) {
    if (!g_gePanel.ready.load(std::memory_order_acquire)) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_gePanel.cls, g_gePanel.json);
}

// Finding 14 — Time Tracking native reflow (read-only). getTimeTrackingJson = {available, farming:[{tab,name,
// state,readyTime,remainingSec}], contract:{active,...}, birdhouses:[{name,state,readyTime,remainingSec}],
// timers:[{name,active,remainingSec,durationSec,loop}], stopwatches:[{name,active,elapsedSec}]}.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeTimeTrackingAvailable(JNIEnv *, jobject) {
    if (!g_timePanel.ready.load(std::memory_order_acquire)) return JNI_FALSE;
    return facadeBool(g_timePanel.cls, g_timePanel.avail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeTimeTrackingSetUiOpen(JNIEnv *, jobject, jboolean open) {
    if (!g_timePanel.ready.load(std::memory_order_acquire)) return;
    facadeVoidBool(g_timePanel.cls, g_timePanel.setUiOpen, open);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeTimeTrackingJson(JNIEnv *artEnv, jobject) {
    if (!g_timePanel.ready.load(std::memory_order_acquire)) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_timePanel.cls, g_timePanel.json);
}

// Config profiles. available + list (getProfilesJson) + switch(id) -> ack JSON (the switch runs async on the
// bridge's own daemon thread; the native side re-reads the list to pick up the new active flag).
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeProfilesAvailable(JNIEnv *, jobject) {
    if (!profileReady()) return JNI_FALSE;
    return facadeBool(g_profileCls, g_midProfileAvail);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeProfilesJson(JNIEnv *artEnv, jobject) {
    if (!profileReady()) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_profileCls, g_midProfilesJson);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSwitchProfile(JNIEnv *artEnv, jobject, jlong id) {
    if (!profileReady()) return artEnv->NewStringUTF("");
    return facadeStrLong(artEnv, g_profileCls, g_midProfileSwitch, id);
}

// Finding 15 — overlay edit. avail/setUiOpen/list like the data panels; snap(name,position) + reset(name) act.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOverlayAvailable(JNIEnv *, jobject) {
    if (!overlayReady()) return JNI_FALSE;
    return facadeBool(g_overlayCls, g_midOverlayAvail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOverlaySetUiOpen(JNIEnv *, jobject, jboolean open) {
    if (!overlayReady()) return;
    facadeVoidBool(g_overlayCls, g_midOverlaySetUiOpen, open);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOverlaysJson(JNIEnv *artEnv, jobject) {
    if (!overlayReady()) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_overlayCls, g_midOverlaysJson);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOverlaySnap(JNIEnv *artEnv, jobject, jstring jName, jstring jPos) {
    if (!overlayReady()) return artEnv->NewStringUTF("");
    return facadeStrArgs(artEnv, g_overlayCls, g_midOverlaySnap, jName, jPos, true);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOverlayReset(JNIEnv *artEnv, jobject, jstring jName) {
    if (!overlayReady()) return artEnv->NewStringUTF("");
    return facadeStrArgs(artEnv, g_overlayCls, g_midOverlayReset, jName, nullptr, false);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOverlaySetLocation(JNIEnv *artEnv, jobject, jstring jName, jint x, jint y) {
    if (!overlayReady() || !g_midOverlaySetLoc) return artEnv->NewStringUTF("");
    return facadeStrLocArgs(artEnv, g_overlayCls, g_midOverlaySetLoc, jName, x, y);
}

// RuneLite-account login (config sync): avail / startLogin / logout / session-json.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeAccountAvailable(JNIEnv *, jobject) {
    if (!accountReady()) return JNI_FALSE;
    return facadeBool(g_accountCls, g_midAccountAvail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeAccountLogin(JNIEnv *, jobject) {
    if (!accountReady()) return;
    facadeVoid0(g_accountCls, g_midAccountLogin);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeAccountLogout(JNIEnv *, jobject) {
    if (!accountReady()) return;
    facadeVoid0(g_accountCls, g_midAccountLogout);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeAccountSession(JNIEnv *artEnv, jobject) {
    if (!accountReady()) return artEnv->NewStringUTF("{\"available\":false}");
    return facadeStr(artEnv, g_accountCls, g_midAccountSession);
}

// Finding 22 — infobox menu. avail/setUiOpen/list like the others; invoke(index, option) fires the action.
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeInfoBoxAvailable(JNIEnv *, jobject) {
    if (!infoboxReady()) return JNI_FALSE;
    return facadeBool(g_infoboxCls, g_midInfoBoxAvail);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeInfoBoxSetUiOpen(JNIEnv *, jobject, jboolean open) {
    if (!infoboxReady()) return;
    facadeVoidBool(g_infoboxCls, g_midInfoBoxSetUiOpen, open);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeInfoBoxesJson(JNIEnv *artEnv, jobject) {
    if (!infoboxReady()) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_infoboxCls, g_midInfoBoxesJson);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeInfoBoxInvoke(JNIEnv *artEnv, jobject, jint index, jstring jOption) {
    if (!infoboxReady() || !g_midInfoBoxInvoke) return artEnv->NewStringUTF("");
    std::string opt = jstr(artEnv, jOption);
    JNIEnv *hs = bridgeEnvAttach();
    if (!hs || !g_infoboxCls) return artEnv->NewStringUTF("");
    jstring ho = hs->NewStringUTF(opt.c_str());
    jstring r = (jstring) hs->CallStaticObjectMethod(g_infoboxCls, g_midInfoBoxInvoke, index, ho);
    std::string out = (hs->ExceptionCheck()) ? (hs->ExceptionClear(), std::string()) : jstr(hs, r);
    if (ho) hs->DeleteLocalRef(ho);
    if (r) hs->DeleteLocalRef(r);
    return artEnv->NewStringUTF(out.c_str());
}

// Native Notes panel — a single editable note string on MobileUiBridge (config group "notes"). available()
// gates the tile; get() seeds the editor; set(text) persists on the client-thread config lane (returns an ack).
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeNotesAvailable(JNIEnv *, jobject) {
    if (!mobileUiReady() || !g_midNotesAvailable)
        return JNI_FALSE;
    return facadeBool(g_mobileUiCls, g_midNotesAvailable);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeNotesGet(JNIEnv *artEnv, jobject) {
    if (!mobileUiReady() || !g_midNotesGet)
        return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_mobileUiCls, g_midNotesGet);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeNotesSet(JNIEnv *artEnv, jobject, jstring jText) {
    if (!mobileUiReady() || !g_midNotesSet)
        return artEnv->NewStringUTF("");
    return facadeStrArgs(artEnv, g_mobileUiCls, g_midNotesSet, jText, nullptr, false);
}

// A6 chrome read surface: MobileChromeBridge.getSnapshot — the per-frame tab/panel/minimap/orb/chat/viewport
// canvas bounds the native edge-rails cover-and-proxy reads. Escaped JSON; populated under -Drunelite.mobilechrome.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeChromeSnapshot(JNIEnv *artEnv, jobject) {
    if (!chromeReady()) return artEnv->NewStringUTF("");
    return facadeStr(artEnv, g_chromeCls, g_midChromeSnap);
}
// A6 overlay read-surface: the render-thread-published chrome snapshot (UI reads lock-free, NO HotSpot attach —
// safe to call from the Choreographer tick each frame). Distinct from nativeChromeSnapshot (rl-bridge, one-shot).
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeChromeSnapshotPub(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lk(g_chromeLock);
    return env->NewStringUTF(g_chromeSnapshotPub.c_str());
}

// A6 chrome write surface (HudVeneerBridge) — hide the engine tab stones, open a tab by op-script replay, and
// relocate the engine side panel for the native 2-col grid. Run on the rl-bridge thread (NOT the UI thread):
// each gates on the facade's acquire latch, then writes the desired state (re-applied by the engine tick).
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetStonesHidden(JNIEnv *, jobject, jboolean hidden) {
    if (!hudReady()) return;
    facadeVoidBool(g_hudCls, g_midSetStonesHidden, hidden);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOpenTab(JNIEnv *, jobject, jint tabIndex) {
    if (!hudReady()) return;
    facadeVoidInt(g_hudCls, g_midOpenTab, tabIndex);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOpenWorldMap(JNIEnv *, jobject) {
    if (!hudReady()) return;
    facadeVoid0(g_hudCls, g_midOpenWorldMap);   // FIX-5: open the map via ORB_WORLDMAP op-replay (no-op on older jar)
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeRelocateSidePanel(JNIEnv *, jobject, jint x, jint y) {
    if (!hudReady()) return;
    facadeVoidIntInt(g_hudCls, g_midRelocateSidePanel, x, y);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeRelocateChat(JNIEnv *, jobject, jint x, jint y, jboolean transparent) {
    if (!hudReady()) return;
    facadeVoidIntIntBool(g_hudCls, g_midRelocateChat, x, y, transparent);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeRelocateMinimap(JNIEnv *, jobject, jint x, jint y) {
    if (!hudReady()) return;
    facadeVoidIntInt(g_hudCls, g_midRelocateMinimap, x, y);
}
// Phase-3: push the safe-area insets (CANVAS px) so the shared OverlayRenderer keeps plugin-overlay snap
// corners clear of the display cutout + the relocated chat (getOverlayChatAvoid is consumed Java-side).
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetOverlayInsets(JNIEnv *, jobject, jint l, jint t, jint r, jint b) {
    if (!hudReady()) return;
    facadeVoid4Int(g_hudCls, g_midSetOverlayInsets, l, t, r, b);
}
// Phase-4 chat pill: collapse = the shared shove-off-canvas (widget stays alive, reopen instant); switch = the
// engine tab's op-script replay (works while the button is off-canvas, unlike a proxy click).
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetChatCollapsed(JNIEnv *, jobject, jboolean collapsed) {
    if (!hudReady()) return;
    facadeVoidBool(g_hudCls, g_midSetChatCollapsed, collapsed);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSwitchChatTab(JNIEnv *, jobject, jint index) {
    if (!hudReady()) return;
    facadeVoidInt(g_hudCls, g_midSwitchChatTab, index);
}
// Phase-5 world map: pan by accumulated finger deltas (canvas px; the shared tick converts to tiles via the
// live zoom) + the render-thread-published snapshot (UI reads lock-free, no attach).
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativePanWorldMap(JNIEnv *, jobject, jint dx, jint dy) {
    if (!hudReady()) return;
    facadeVoidIntInt(g_hudCls, g_midPanWorldMap, dx, dy);
}
// Phase-5 world map: swipe-scroll the KEY (legend) list / MAPLIST dropdown by an accumulated finger delta
// (canvas px; the shared tick drives the engine UPDATE_SCROLLBAR). No-op on a jar without scrollMapPanel.
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeScrollMapPanel(JNIEnv *, jobject, jint dy) {
    if (!hudReady()) return;
    facadeVoidInt(g_hudCls, g_midScrollMapPanel, dy);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeMapSnapshotPub(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lk(g_mapLock);
    return env->NewStringUTF(g_mapSnapshotPub.c_str());
}
// A3 chat-tab veneer: the render-thread-published HudVeneerBridge.getChatSnapshot (UI reads lock-free, no attach)
// + the two row-size setters (rl-bridge thread) that push the engine message area below the taller native row.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeChatSnapshotPub(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lk(g_chatLock);
    return env->NewStringUTF(g_chatSnapshotPub.c_str());
}
// Minimap-orb veneer: the render-thread-published HudVeneerBridge.getOrbSnapshot (UI reads lock-free, no attach).
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeOrbSnapshotPub(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lk(g_orbLock);
    return env->NewStringUTF(g_orbSnapshotPub.c_str());
}
// UI-4: the render-thread-published HudVeneerBridge.getDialogueJson (UI reads lock-free, no attach) — the native
// opaque NPC-dialogue parchment that covers the engine's now-transparent dialogue.
extern "C" JNIEXPORT jstring JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeDialogueJson(JNIEnv *env, jobject) {
    std::lock_guard<std::mutex> lk(g_dlgLock);
    return env->NewStringUTF(g_dialogueJsonPub.c_str());
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetChatTabRowHeight(JNIEnv *, jobject, jint canvasPx) {
    if (!hudReady()) return;
    facadeVoidInt(g_hudCls, g_midSetChatRowH, canvasPx);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeSetChatAreaWidth(JNIEnv *, jobject, jint canvasPx) {
    if (!hudReady()) return;
    facadeVoidInt(g_hudCls, g_midSetChatAreaW, canvasPx);
}
// AP-0 chat scroll-by-drag: accumulate a finger-drag delta into the chatbox's own scroll layer (applied on
// the client thread in HudVeneerBridge.tick). Positive = toward newer/bottom. rl-bridge thread.
extern "C" JNIEXPORT void JNICALL
Java_dev_audaro_runemobile_JvmLauncher_nativeScrollChat(JNIEnv *, jobject, jint deltaCanvasPx) {
    if (!hudReady()) return;
    facadeVoidInt(g_hudCls, g_midScrollChat, deltaCanvasPx);
}
