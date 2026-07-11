package dev.audaro.runemobile

import android.view.Surface
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future

/**
 * Thin Kotlin facade over the native JNI Invocation-API bootstrap + render/input host.
 *
 * The app process is hosted by ART, but the game runs on a *second*, in-process HotSpot VM that the
 * native layer brings up with JNI_CreateJavaVM (dlopen of the embedded JRE's libjvm.so). This mirrors
 * the proven iOS CPU/headless bootstrap (JVMLauncher.m) minus every iOS-JIT workaround — Android grants JIT
 * for free. (Mirrors the iOS CPU path; the iOS Route-C GPU host has no Android counterpart yet —
 * see android/BLUEPRINT.md Track G.)
 *
 * The HotSpot VM lives for the whole process: [startJvm] creates it on a dedicated, never-exiting native
 * thread and returns once it is up (it does NOT block on the game). Frames are pulled from the
 * net.runelite.client.headless.JavaBridge facade by a native render thread and blitted to the SurfaceView
 * window set via [setSurface]; touches are enqueued via [click]/[touch]/[camera] and drained by that same
 * render thread (so the ART UI thread never attaches to HotSpot).
 */
object JvmLauncher {
    init {
        System.loadLibrary("runemobile")
    }

    /**
     * Bring up the embedded HotSpot VM and start running [mainClass].main(args) on its own thread. Returns
     * once the VM is created (0 == JNI_OK) — the game keeps running after this returns.
     *
     * @param javaHome    filesDir path of the unpacked JRE (contains lib/server/libjvm.so).
     * @param libjvmPath  absolute path to libjvm.so (javaHome/lib/server/libjvm.so).
     * @param libraryPath ':'-joined java.library.path (dirs holding the JRE .so libs).
     * @param classpath   ':'-joined jar list on the embedded VM's classpath.
     * @param mainClass   binary name of the entrypoint class to invoke.
     * @param extraOpts   additional -X / -D / --add-* VM options.
     */
    external fun startJvm(
        javaHome: String,
        libjvmPath: String,
        libraryPath: String,
        classpath: String,
        mainClass: String,
        extraOpts: Array<String>,
    ): Int

    /**
     * Set a process environment variable. MUST be called before [startJvm] — HotSpot snapshots the
     * environment at VM startup, and the OSRS gamepack reads the JX_* launcher handoff from it.
     */
    external fun nativeSetEnv(
        key: String,
        value: String,
    )

    /** A8: enable/disable piping the embedded VM's stdout/err to logcat. Call BEFORE [startJvm] with
     *  BuildConfig.DEBUG so a release build never leaks the engine's output (incl. account/network chatter). */
    external fun nativeSetStdioRedirect(enabled: Boolean)

    /** Hand the SurfaceView's surface (or null to clear) to the native render thread for blitting. */
    external fun nativeSetSurface(surface: Surface?)

    // PERF-BATTERY-NETWORK-01: visibility gate. Paused (backgrounded) -> the render thread idles at 4 Hz.
    external fun nativeSetPaused(paused: Boolean)

    /** A discrete tap at game-canvas (x,y); button 1 = left (walk/interact), 3 = long-press menu. */
    external fun nativeClick(
        x: Int,
        y: Int,
        button: Int,
    )

    /** One phase of a drag stream (type 0=down/1=move/2=up) at game-canvas (x,y) — no synthesized click. */
    external fun nativeTouch(
        type: Int,
        x: Int,
        y: Int,
        button: Int,
    )

    /** Rotate the camera by a raw pixel delta (two-finger / one-finger pan). */
    external fun nativeCamera(
        dx: Int,
        dy: Int,
    )

    /** Make the engine pointer "absent" (call when a camera/pan gesture begins). */
    external fun nativeClearHover()

    /** FIX-3 idle keepalive: bump the engine idle-logout timer on a native-UI touch (queued; UI-thread-safe). */
    external fun nativeKeepAlive()

    // AP-2a sticky-Shift (Finding 12): hold/release a synthetic VK_SHIFT via JavaBridge.setShiftHeld. Queued
    // through the input path so it's ORDERED ahead of the menu-open right-click (engine must read shift held
    // before it builds the menu, or Mark/Configure entries aren't injected). UI-thread-safe (enqueue only).
    external fun nativeSetShiftHeld(held: Boolean)

    /** Sticky Ctrl/Alt latch (mirror of setShiftHeld) + a discrete middle-button (BUTTON2) click. */
    external fun nativeSetCtrlHeld(held: Boolean)

    external fun nativeSetAltHeld(held: Boolean)

    external fun nativeMiddleClick(
        x: Int,
        y: Int,
    )

    // ---- A1 input parity ----------------------------------------------------------------------------

    /** Mouse-wheel notch at game-canvas (x,y); rotation <0 = up/zoom-in, >0 = down/zoom-out (pinch). */
    external fun nativeWheel(
        x: Int,
        y: Int,
        rotation: Int,
    )

    /** Precise tap at game-canvas (x,y) with NO world snap — for UI/widget hits and chrome proxying. */
    external fun nativeClickPrecise(
        x: Int,
        y: Int,
        button: Int,
    )

    /** Move the engine pointer to game-canvas (x,y) without a click (hover / menu-track). */
    external fun nativeMove(
        x: Int,
        y: Int,
    )

    /** Commit a string of text to the focused engine field (soft-keyboard input). */
    external fun nativeText(s: String)

    /** A special key by AWT virtual-key code (backspace, enter, arrows, …). */
    external fun nativeKeyStroke(vk: Int)

    /** Fire a plugin Keybind chord via JavaBridge.onKeybind: an AWT key-code + extended-modifier mask. */
    external fun nativeKeybind(
        vk: Int,
        modifiers: Int,
    )

    // User-defined hotkey buttons: list every bound plugin keybind ([{group,key,label,keyCode,mods,bind}]) for the
    // native Hotkeys screen, and fire one by (group,key) off its live binding when its HUD button is tapped.
    external fun nativeBoundKeybindsJson(): String

    external fun nativeFireHotkey(
        group: String,
        key: String,
    )

    /** Does the engine currently have a text field focused? Poll to auto-raise/dismiss the soft keyboard. */
    external fun nativeIsTextInputOpen(): Boolean

    /** Monotonic counter the engine bumps on each committed interact-tap — advance => fire a haptic. */
    external fun nativeInteractTapSeq(): Int

    /** Tap-KIND truth: [nativeTapKindSeq] bumps once per resolved left tap; [nativeLastTapKind] is its kind
     *  (TAP_KIND_*); [nativeLastWidgetBounds] packs the WIDGET-kind bounds (canvas px, x<<48|y<<32|w<<16|h). */
    external fun nativeTapKindSeq(): Int

    external fun nativeLastTapKind(): Int

    external fun nativeLastWidgetBounds(): Long

    // ---- A2 press-and-peek menu ---------------------------------------------------------------------

    /** Commit a menu choice by clicking the engine row centre (game-canvas x,y) — honours plugin onClick. */
    external fun nativeSelectMenuPoint(
        x: Int,
        y: Int,
    )

    /** FIX-10b: commit a tap-menu row / submenu child by index (child<0 = the parent entry itself). */
    external fun nativeInvokeMenuEntry(
        parent: Int,
        child: Int,
    )

    /** Latest MenuPeekBridge snapshot JSON (escaped), published by the render thread. */
    external fun nativeMenuSnapshot(): String

    /** Monotonic publish counter for the menu snapshot (freshness check). */
    external fun nativeMenuPublishSeq(): Long

    /** One-shot tab/stone/chat sprite set from the live cache (HudVeneerBridge.tabSprites), JSON of raw ARGB
     *  pixels. "" until captured (first logged-in tick). Lets the native chrome composite the real OSRS art with
     *  nothing bundled. */
    external fun nativeTabSprites(): String

    /** Latest composited frame dimensions (game-canvas pixels), or 0 before the first frame. */
    external fun nativeFrameWidth(): Int

    external fun nativeFrameHeight(): Int

    /** Phase 3 (auto-GPU watchdog): frames the GPU/117HD renderer has actually presented. 0 == renderer not armed or
     *  never activated (failed/black/crashed); a climbing value == it activated and is presenting. */
    external fun nativeGpuFramesPresented(): Long

    // AP-2b Finding 5 (screenshot): the latest composited CPU frame as 0x00RRGGBB ints (alpha unset; the consumer
    // ORs 0xFF for an opaque PNG). null before the first frame / bridge off. Pull OFF the UI thread (via [onBridge])
    // — it attaches the caller to HotSpot. Size against [nativeFrameWidth]; guard len % width == 0.
    external fun nativeFramePixels(): IntArray?

    // ---- A4 plugin control plane (MobileUiBridge; gated by -Drunelite.mobileui) ----------------------
    // CALL THESE OFF THE UI THREAD ONLY (via [onBridge]) — they daemon-attach the calling thread to the
    // embedded HotSpot VM and may block (config writes dispatch to the client thread). ART<->HotSpot strings
    // are marshalled as UTF-8 in the native layer.
    external fun nativeListPlugins(): String

    external fun nativeMobileUiSeq(): Long

    external fun nativePollMobileUiEvents(sinceSeq: Long): String

    external fun nativeSetPluginEnabled(
        className: String,
        enabled: Boolean,
    ): String

    external fun nativeSetPinned(pluginName: String, pinned: Boolean): String // Finding 6: star by display name

    external fun nativeGetPluginConfig(group: String): String

    external fun nativeSetConfig(
        group: String,
        key: String,
        value: String,
    ): String

    external fun nativeProcessedWriteId(): Long

    // A8: persist pending plugin-config writes (call when the app backgrounds). Off the UI thread (onBridge).
    external fun nativeFlushConfig(): String

    // SC-2/CFG-10: reset an entire plugin/config group to defaults (returns {"ok":..,"writeId":n}). Off the UI thread.
    external fun nativeResetPluginConfig(group: String): String

    // SC-1/NOTIF-2: the serialized default Notification seed for the per-item editor. Off the UI thread.
    external fun nativeNotificationDefaults(): String

    // AP-2a bridge-amortized drain surfaces (off the UI thread via [onBridge]); "" = nothing pending / unresolved.
    external fun nativeNextNotification(): String // Finding 9:  "titlebody" or ""

    external fun nativeNextLink(): String // Finding 25: a URL or ""

    external fun nativeNextScreenshot(): String // PARITY-ANDROID-SHOT: absolute PNG path or ""

    external fun nativeHubState(): String // Finding 17: {"refreshing":bool,"seq":int}

    external fun nativeHubManifest(): String // Finding 17: {"status":loading|ok,...,plugins:[...]}

    external fun nativeHubInstall(internalName: String): String // Finding 17: {"ok":true,"writeId":n}

    external fun nativeHubUninstall(internalName: String): String // Finding 17: {"ok":true,"writeId":n}

    external fun nativePublishNotification(title: String, body: String) // host-origin alert into the shared queue

    external fun nativePublishLink(url: String) // host-origin link into the shared queue

    // A5 Tier-1 plugin panels: a plugin's Swing side-panel rendered off-screen to an ARGB int[] (like the
    // game blit), pulled here and shown in a zoom/pan view; taps map back via panelClick. Off the UI thread.
    external fun nativeListPanels(): String

    external fun nativeOpenPanel(index: Int): String

    external fun nativeClosePanel(): String

    external fun nativePanelWidth(): Int

    external fun nativePanelHeight(): Int

    external fun nativePanelFrameSeq(): Int

    external fun nativePanelPixels(): IntArray?

    external fun nativePanelClick(
        x: Int,
        y: Int,
    ): String

    // SC-4 panel-text input (best-effort; no-op if the staged jar predates them).
    external fun nativeIsPanelTextActive(): Boolean // a tap focused an editable field -> raise keyboard

    external fun nativeGetPanelText(): String // current text of the focused field (pre-fill)

    external fun nativePanelText(text: String): String // mirror whole text into the focused field (live filter)

    external fun nativePanelKey(vk: Int): String // a single key (VK_ENTER submit / VK_BACK_SPACE)

    external fun nativePanelLongPress(x: Int, y: Int): String // BUTTON3 into the panel

    external fun nativePanelWheel(x: Int, y: Int, rotation: Int): String // inner scroll

    external fun nativePanelMove(x: Int, y: Int): String // hover -> tooltips/highlights

    // A5 Tier-2 native reflow: curated native screens for Quest Helper + World Switcher (QuestHelperBridge /
    // WorldSwitcherBridge). isAvailable() gates native-vs-Tier-1: Quest is false unless the hub plugin is
    // installed (→ fall back to the rendered panel); World Switcher is built-in. Off the UI thread (onBridge).
    external fun nativeQuestAvailable(): Boolean

    external fun nativeQuestSetUiOpen(open: Boolean)

    external fun nativeQuestListJson(): String

    external fun nativeQuestActiveJson(): String

    external fun nativeQuestStart(questName: String)

    external fun nativeQuestStop()

    external fun nativeWorldAvailable(): Boolean

    external fun nativeWorldSetUiOpen(open: Boolean)

    external fun nativeWorldListJson(): String

    external fun nativeWorldHop(worldId: Int)

    // SC-5 World Switcher favourites + quick-hop (best-effort; no-op if the staged jar predates them).
    external fun nativeWorldSetFavourite(
        worldId: Int,
        favourite: Boolean,
    )

    external fun nativeWorldHopDirection(previous: Boolean)

    // Finding 14 — XP Tracker native reflow (read-only data panel; same facade shape as Quest/World).
    // setUiOpen brackets the screen so the bridge only rebuilds the snapshot while it's shown. Off the UI thread.
    external fun nativeXpAvailable(): Boolean

    external fun nativeXpSetUiOpen(open: Boolean)

    external fun nativeXpJson(): String

    external fun nativeLootAvailable(): Boolean

    external fun nativeLootSetUiOpen(open: Boolean)

    external fun nativeLootJson(): String

    // "Reset All": clears the loot log + deletes the persisted drops_* config. Returns the bridge JSON ack.
    // Inert if the staged jar lacks resetAll().
    external fun nativeLootResetAll(): String

    external fun nativeGeAvailable(): Boolean

    external fun nativeGeSetUiOpen(open: Boolean)

    external fun nativeGeJson(): String

    // Time Tracking native reflow (TimeTrackingBridge; same facade shape). getTimeTrackingJson = farming patches,
    // farming contract, bird houses, timers + stopwatches — all with second-resolution countdowns.
    external fun nativeTimeTrackingAvailable(): Boolean

    external fun nativeTimeTrackingSetUiOpen(open: Boolean)

    external fun nativeTimeTrackingJson(): String

    // Finding 15 — overlay edit (OverlayBridge): list movable overlays, snap one to a corner, reset to default.
    // snap/reset return the bridge JSON ack; positionName is an OverlayPosition (TOP_LEFT/.../BOTTOM_RIGHT).
    external fun nativeOverlayAvailable(): Boolean

    external fun nativeOverlaySetUiOpen(open: Boolean)

    external fun nativeOverlaysJson(): String

    external fun nativeOverlaySnap(
        name: String,
        positionName: String,
    ): String

    external fun nativeOverlayReset(name: String): String

    // Free pixel-drag: move an overlay to an explicit canvas-px location (clears its snap corner). Returns the
    // bridge JSON ack. Inert if the staged jar lacks setOverlayPreferredLocation.
    external fun nativeOverlaySetLocation(
        name: String,
        x: Int,
        y: Int,
    ): String

    // RuneLite-account login (config sync) — distinct from the Jagex game login.
    external fun nativeAccountAvailable(): Boolean

    external fun nativeAccountLogin()

    external fun nativeAccountLogout()

    external fun nativeAccountSession(): String

    // Config profiles (ConfigProfileBridge): list profiles + switch the active one. switchProfile returns the
    // bridge JSON ack; the switch itself completes asynchronously off the engine thread.
    external fun nativeProfilesAvailable(): Boolean

    external fun nativeProfilesJson(): String

    external fun nativeSwitchProfile(id: Long): String

    // Finding 22 — infobox menu (InfoBoxBridge): list infoboxes + their menu options, invoke one by index.
    external fun nativeInfoBoxAvailable(): Boolean

    external fun nativeInfoBoxSetUiOpen(open: Boolean)

    external fun nativeInfoBoxesJson(): String

    external fun nativeInfoBoxInvoke(
        index: Int,
        option: String,
    ): String

    // Native Notes panel (MobileUiBridge): a single editable note string (config group "notes"). set returns
    // the bridge JSON ack; the write persists on the client-thread config lane.
    external fun nativeNotesAvailable(): Boolean

    external fun nativeNotesGet(): String

    external fun nativeNotesSet(text: String): String

    // A6 chrome: the per-frame MobileChromeBridge read-only snapshot (escaped JSON: tab/panel/minimap/orb/chat/
    // viewport canvas bounds the native edge-rails read). Gated by -Drunelite.mobilechrome. Off the UI thread.
    external fun nativeChromeSnapshot(): String

    // A6 overlay: the render-thread-PUBLISHED chrome snapshot — lock-free, no HotSpot attach, safe to read each
    // frame from the Choreographer tick (UI thread). Drives the native 2-col tab-grid overlay.
    external fun nativeChromeSnapshotPub(): String

    // A6 chrome write surface (HudVeneerBridge; gated -Drunelite.hudveneer): hide the 14 engine tab stones (the
    // native 2-col grid replaces them), open a tab by replaying its stone op-script (works while hidden), and
    // relocate the engine side panel flush-left of the grid. Off the UI thread ONLY (via [onBridge]) — they
    // daemon-attach the calling thread to HotSpot. Cheap fire-and-forget setters re-applied by the engine tick.
    external fun nativeSetStonesHidden(hidden: Boolean)

    external fun nativeOpenTab(tabIndex: Int)

    external fun nativeOpenWorldMap() // FIX-5: open the world map via ORB_WORLDMAP op-replay

    external fun nativeRelocateSidePanel(
        x: Int,
        y: Int,
    )

    // A6 chat-at-top: move the engine's own chatbox to (x,y) canvas px and flip it to OSRS transparent-chat mode
    // (the tabs / scrollback / colours / input all stay live — it IS the real chat). x<0 stops relocating. Off
    // the UI thread (via [onBridge]); re-applied by the engine tick.
    external fun nativeRelocateChat(
        x: Int,
        y: Int,
        transparent: Boolean,
    )

    /** Phase-3: safe-area insets in CANVAS px — the shared OverlayRenderer insets every overlay snap corner. */
    external fun nativeSetOverlayInsets(
        l: Int,
        t: Int,
        r: Int,
        b: Int,
    )

    /** Phase-4 chat pill: collapse the chat (shared shove-off-canvas) / switch channel (op-script replay). */
    external fun nativeSetChatCollapsed(collapsed: Boolean)

    external fun nativeSwitchChatTab(index: Int)

    /** Phase-5 world map: pan by finger deltas (canvas px; shared tick converts to tiles) + the published
     *  snapshot {open, map:[x,y,w,h], close, search, zoomIn, zoomOut} (render-thread copy — UI-safe). */
    external fun nativePanWorldMap(
        dx: Int,
        dy: Int,
    )

    external fun nativeScrollMapPanel(dy: Int)

    external fun nativeMapSnapshotPub(): String

    // A7 edge-to-edge: pull the engine minimap+orbs cluster (MAP_CONTAINER) into the top-right safe area. It
    // stays the live engine HUD (minimap click-to-walk + orb clicks keep working). x<0 stops. Off the UI thread.
    external fun nativeRelocateMinimap(
        x: Int,
        y: Int,
    )

    // A3 enlarged native chat-tab veneer. The per-frame chat-tab geometry/state snapshot (escaped JSON: each of
    // the 7 tabs' canvas bounds + selected/new/filter state) is PUBLISHED by the render thread — read lock-free
    // from the Choreographer tick (no HotSpot attach). The two setters (off the UI thread) tell the engine to
    // push the message area below the taller native row (rowH canvas px) / keep its natural width (0).
    external fun nativeChatSnapshotPub(): String

    external fun nativeDialogueJson(): String // UI-4: the engine NPC-dialogue snapshot (opaque-parchment source)

    external fun nativeOrbSnapshotPub(): String // minimap-orb veneer: per-orb canvas bounds (read on tap, no attach)

    external fun nativeSetChatTabRowHeight(canvasPx: Int)

    external fun nativeSetChatAreaWidth(canvasPx: Int)

    // AP-0 chat scroll-by-drag: scroll the chat by deltaCanvasPx (positive = toward newer/bottom) via the
    // chatbox's OWN scroll layer — not a mouse wheel, which would zoom the camera under the transparent chat.
    // Off the UI thread (via [onBridge]); accumulated and applied by the engine tick.
    external fun nativeScrollChat(deltaCanvasPx: Int)

    // Kotlin-friendly aliases.
    fun setEnv(
        key: String,
        value: String,
    ) = nativeSetEnv(key, value)

    fun setStdioRedirect(enabled: Boolean) = nativeSetStdioRedirect(enabled)

    fun setSurface(surface: Surface?) = nativeSetSurface(surface)

    fun setPaused(paused: Boolean) = nativeSetPaused(paused)

    fun click(
        x: Int,
        y: Int,
        button: Int,
    ) = nativeClick(x, y, button)

    fun touch(
        type: Int,
        x: Int,
        y: Int,
        button: Int,
    ) = nativeTouch(type, x, y, button)

    fun camera(
        dx: Int,
        dy: Int,
    ) = nativeCamera(dx, dy)

    fun clearHover() = nativeClearHover()

    fun keepAlive() = nativeKeepAlive()

    fun setShiftHeld(held: Boolean) = nativeSetShiftHeld(held)

    fun setCtrlHeld(held: Boolean) = nativeSetCtrlHeld(held)

    fun setAltHeld(held: Boolean) = nativeSetAltHeld(held)

    fun middleClick(
        x: Int,
        y: Int,
    ) = nativeMiddleClick(x, y)

    fun wheel(
        x: Int,
        y: Int,
        rotation: Int,
    ) = nativeWheel(x, y, rotation)

    fun clickPrecise(
        x: Int,
        y: Int,
        button: Int,
    ) = nativeClickPrecise(x, y, button)

    fun move(
        x: Int,
        y: Int,
    ) = nativeMove(x, y)

    fun text(s: String) = nativeText(s)

    fun keyStroke(vk: Int) = nativeKeyStroke(vk)

    fun keybind(
        vk: Int,
        modifiers: Int,
    ) = nativeKeybind(vk, modifiers)

    fun boundKeybindsJson() = nativeBoundKeybindsJson()

    fun fireHotkey(
        group: String,
        key: String,
    ) = nativeFireHotkey(group, key)

    fun isTextInputOpen() = nativeIsTextInputOpen()

    fun interactTapSeq() = nativeInteractTapSeq()

    fun tapKindSeq() = nativeTapKindSeq()

    fun lastTapKind() = nativeLastTapKind()

    fun lastWidgetBounds() = nativeLastWidgetBounds()

    fun selectMenuPoint(
        x: Int,
        y: Int,
    ) = nativeSelectMenuPoint(x, y)

    fun invokeMenuEntry(
        parent: Int,
        child: Int,
    ) = nativeInvokeMenuEntry(parent, child)

    fun menuSnapshot() = nativeMenuSnapshot()

    fun menuPublishSeq() = nativeMenuPublishSeq()

    fun tabSprites() = nativeTabSprites()

    fun frameWidth() = nativeFrameWidth()

    fun frameHeight() = nativeFrameHeight()

    fun framePixels(): IntArray? = nativeFramePixels()

    // ---- A3.5 bridge request/response thread --------------------------------------------------------
    // A single dedicated background thread the UI posts plugin-plane requests to, so the ART UI thread NEVER
    // attaches to HotSpot (ANR risk) and HotSpot only ever sees one caller from the ART side. The thread
    // daemon-attaches to HotSpot on its first bridge call (native layer) and stays attached for the process.
    private val bridgeExec: ExecutorService =
        Executors.newSingleThreadExecutor { r -> Thread(r, "rl-bridge").apply { isDaemon = true } }

    /** Run [block] on the rl-bridge thread; returns a Future (do NOT .get() it on the UI thread). */
    fun <T> onBridge(block: () -> T): Future<T> = bridgeExec.submit(block)

    /**
     * FIX-3: like [onBridge], but ALSO bumps the engine idle-logout timer ([keepAlive]) because this call is a
     * genuine native-UI *touch* (a write the user initiated), not a passive data refresh. Use this ONLY at real
     * touch handlers — NOT on the per-second json-refresh polls (those run while a screen is merely open; poking
     * keepAlive there would suppress real AFK-logout when the user walks away). keepAlive only enqueues (it's
     * UI-thread-safe and never attaches to HotSpot), so calling it before submitting the work is fine.
     */
    fun <T> onBridgeTouch(block: () -> T): Future<T> {
        nativeKeepAlive()
        return bridgeExec.submit(block)
    }

    fun listPlugins() = nativeListPlugins()

    fun mobileUiSeq() = nativeMobileUiSeq()

    fun pollMobileUiEvents(sinceSeq: Long) = nativePollMobileUiEvents(sinceSeq)

    fun setPluginEnabled(
        className: String,
        enabled: Boolean,
    ) = nativeSetPluginEnabled(className, enabled)

    fun setPinned(
        pluginName: String,
        pinned: Boolean,
    ) = nativeSetPinned(pluginName, pinned)

    fun getPluginConfig(group: String) = nativeGetPluginConfig(group)

    fun setConfig(
        group: String,
        key: String,
        value: String,
    ) = nativeSetConfig(group, key, value)

    fun processedWriteId() = nativeProcessedWriteId()

    fun flushConfig() = nativeFlushConfig()

    fun resetPluginConfig(group: String) = nativeResetPluginConfig(group)

    fun notificationDefaults() = nativeNotificationDefaults()

    fun nextNotification() = nativeNextNotification()

    fun nextLink() = nativeNextLink()

    fun nextScreenshot() = nativeNextScreenshot()

    fun hubState() = nativeHubState()

    fun hubManifest() = nativeHubManifest()

    fun hubInstall(internalName: String) = nativeHubInstall(internalName)

    fun hubUninstall(internalName: String) = nativeHubUninstall(internalName)

    fun publishNotification(
        title: String,
        body: String,
    ) = nativePublishNotification(title, body)

    fun publishLink(url: String) = nativePublishLink(url)

    fun listPanels() = nativeListPanels()

    fun openPanel(index: Int) = nativeOpenPanel(index)

    fun closePanel() = nativeClosePanel()

    fun panelWidth() = nativePanelWidth()

    fun panelHeight() = nativePanelHeight()

    fun panelFrameSeq() = nativePanelFrameSeq()

    fun panelPixels(): IntArray? = nativePanelPixels()

    fun panelClick(
        x: Int,
        y: Int,
    ) = nativePanelClick(x, y)

    fun isPanelTextActive() = nativeIsPanelTextActive()

    fun getPanelText() = nativeGetPanelText()

    fun panelText(text: String) = nativePanelText(text)

    fun panelKey(vk: Int) = nativePanelKey(vk)

    fun panelLongPress(
        x: Int,
        y: Int,
    ) = nativePanelLongPress(x, y)

    fun panelWheel(
        x: Int,
        y: Int,
        rotation: Int,
    ) = nativePanelWheel(x, y, rotation)

    fun panelMove(
        x: Int,
        y: Int,
    ) = nativePanelMove(x, y)

    fun questAvailable() = nativeQuestAvailable()

    fun questSetUiOpen(open: Boolean) = nativeQuestSetUiOpen(open)

    fun questListJson() = nativeQuestListJson()

    fun questActiveJson() = nativeQuestActiveJson()

    fun questStart(questName: String) = nativeQuestStart(questName)

    fun questStop() = nativeQuestStop()

    fun worldAvailable() = nativeWorldAvailable()

    fun worldSetUiOpen(open: Boolean) = nativeWorldSetUiOpen(open)

    fun worldListJson() = nativeWorldListJson()

    fun worldHop(worldId: Int) = nativeWorldHop(worldId)

    fun worldSetFavourite(
        worldId: Int,
        favourite: Boolean,
    ) = nativeWorldSetFavourite(worldId, favourite)

    fun worldHopDirection(previous: Boolean) = nativeWorldHopDirection(previous)

    fun xpAvailable() = nativeXpAvailable()

    fun xpSetUiOpen(open: Boolean) = nativeXpSetUiOpen(open)

    fun xpJson() = nativeXpJson()

    fun lootAvailable() = nativeLootAvailable()

    fun lootSetUiOpen(open: Boolean) = nativeLootSetUiOpen(open)

    fun lootJson() = nativeLootJson()

    fun lootResetAll() = nativeLootResetAll()

    fun geAvailable() = nativeGeAvailable()

    fun geSetUiOpen(open: Boolean) = nativeGeSetUiOpen(open)

    fun geJson() = nativeGeJson()

    fun timeTrackingAvailable() = nativeTimeTrackingAvailable()

    fun timeTrackingSetUiOpen(open: Boolean) = nativeTimeTrackingSetUiOpen(open)

    fun timeTrackingJson() = nativeTimeTrackingJson()

    fun overlayAvailable() = nativeOverlayAvailable()

    fun overlaySetUiOpen(open: Boolean) = nativeOverlaySetUiOpen(open)

    fun overlaysJson() = nativeOverlaysJson()

    fun overlaySnap(
        name: String,
        positionName: String,
    ) = nativeOverlaySnap(name, positionName)

    fun overlayReset(name: String) = nativeOverlayReset(name)

    fun overlaySetLocation(
        name: String,
        x: Int,
        y: Int,
    ) = nativeOverlaySetLocation(name, x, y)

    fun accountAvailable() = nativeAccountAvailable()

    fun accountLogin() = nativeAccountLogin()

    fun accountLogout() = nativeAccountLogout()

    fun accountSessionJson() = nativeAccountSession()

    fun profilesAvailable() = nativeProfilesAvailable()

    fun profilesJson() = nativeProfilesJson()

    fun switchProfile(id: Long) = nativeSwitchProfile(id)

    fun infoBoxAvailable() = nativeInfoBoxAvailable()

    fun infoBoxSetUiOpen(open: Boolean) = nativeInfoBoxSetUiOpen(open)

    fun infoBoxesJson() = nativeInfoBoxesJson()

    fun infoBoxInvoke(
        index: Int,
        option: String,
    ) = nativeInfoBoxInvoke(index, option)

    fun notesAvailable() = nativeNotesAvailable()

    fun notesGet() = nativeNotesGet()

    fun notesSet(text: String) = nativeNotesSet(text)

    fun chromeSnapshot() = nativeChromeSnapshot()

    fun chromeSnapshotPub() = nativeChromeSnapshotPub()

    fun setStonesHidden(hidden: Boolean) = nativeSetStonesHidden(hidden)

    fun openTab(tabIndex: Int) = nativeOpenTab(tabIndex)

    fun openWorldMap() = nativeOpenWorldMap()

    fun relocateSidePanel(
        x: Int,
        y: Int,
    ) = nativeRelocateSidePanel(x, y)

    fun relocateChat(
        x: Int,
        y: Int,
        transparent: Boolean,
    ) = nativeRelocateChat(x, y, transparent)

    fun setOverlayInsets(
        l: Int,
        t: Int,
        r: Int,
        b: Int,
    ) = nativeSetOverlayInsets(l, t, r, b)

    fun setChatCollapsed(collapsed: Boolean) = nativeSetChatCollapsed(collapsed)

    fun switchChatTab(index: Int) = nativeSwitchChatTab(index)

    fun panWorldMap(
        dx: Int,
        dy: Int,
    ) = nativePanWorldMap(dx, dy)

    fun scrollMapPanel(dy: Int) = nativeScrollMapPanel(dy)

    fun mapSnapshotPub() = nativeMapSnapshotPub()

    fun relocateMinimap(
        x: Int,
        y: Int,
    ) = nativeRelocateMinimap(x, y)

    fun chatSnapshotPub() = nativeChatSnapshotPub()

    fun dialogueJsonPub() = nativeDialogueJson()

    fun orbSnapshotPub() = nativeOrbSnapshotPub()

    fun setChatTabRowHeight(canvasPx: Int) = nativeSetChatTabRowHeight(canvasPx)

    fun setChatAreaWidth(canvasPx: Int) = nativeSetChatAreaWidth(canvasPx)

    fun scrollChat(deltaCanvasPx: Int) = nativeScrollChat(deltaCanvasPx)
}
