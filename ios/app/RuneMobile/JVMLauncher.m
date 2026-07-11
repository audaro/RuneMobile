#import "JVMLauncher.h"
#import <dlfcn.h>
#import <signal.h>
#import <pthread.h>
#import <unistd.h>
#import <sys/mman.h>
#import <mach/mach.h>
#import <os/proc.h>            // os_proc_available_memory() — jetsam headroom (login-crash diagnostics)
#import <libkern/OSCacheControl.h>
#import <stdatomic.h>
#import <os/lock.h>            // os_unfair_lock — guards the bridge-fault rate-limiter (QA-SYS-1)
#import <time.h>              // clock_gettime_nsec_np — monotonic window for the rate-limiter
#import "jni/jni.h"
#import "routec_gl_jni.h"   // W3 GPU Route C: RouteC_registerGLNatives(env) — the JNI GL bridge registration
#import "routec_zone_jni.h" // W3 GPU Zone B0.5: RouteC_registerZoneNatives(env) — the RLHD facade-delta natives

// --- csops / CS_DEBUGGED (private; same probe Amethyst/StikDebug rely on) -----
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#ifndef CS_OPS_STATUS
#define CS_OPS_STATUS 0
#endif
#ifndef CS_DEBUGGED
#define CS_DEBUGGED 0x10000000
#endif

// We embed via the JNI Invocation API (JNI_CreateJavaVM), NOT JLI_Launch. The iOS
// JRE launcher's first-thread dance (libjli apple_main -> re-invokes our main() ->
// UIApplicationMain -> "There can only be one UIApplication instance") makes
// JLI_Launch unusable from inside an existing UIKit app; JNI_CreateJavaVM creates
// the VM in-process on this thread with no launcher threading.
typedef jint (*CreateJavaVM_t)(JavaVM **pvm, void **penv, void *args);

// ---- Phase 4 (W3) sub-goal B / Phase 5: reverse-JNI bridge state ------------------------------------
// The VM is created on the jvm-main worker thread (runProbesWithLog); the live blit + input handlers run
// on the main/UI thread, so they AttachCurrentThreadAsDaemon and cache the JavaBridge class + method ids
// once. gVM is written by the worker thread and read by the main thread, so it is published atomically
// (a plain static is a C-level data race even where it happens to work on-device).
static _Atomic(JavaVM *) gVM = NULL;  // set right after JNI_CreateJavaVM; cleared before DestroyJavaVM
static JNIEnv   *gMainEnv = NULL;     // the UI thread's attached env (main thread only)
static jclass    gBridgeClass = NULL; // global ref to net.runelite.client.headless.JavaBridge
static jmethodID gMidW = NULL, gMidH = NULL, gMidSeq = NULL, gMidPixels = NULL;
static jmethodID gMidInteractSeq = NULL;  // getInteractTapSeq()I — native haptic cue (optional; tolerate older jar)
static jmethodID gMidTouch = NULL, gMidClick = NULL, gMidClickPrecise = NULL, gMidMove = NULL;
static jmethodID gMidWheel = NULL, gMidCamera = NULL, gMidText = NULL, gMidKey = NULL;
static jmethodID gMidInputOpen = NULL, gMidClearHover = NULL;
static jmethodID gMidWarmed = NULL;   // JavaBridge.presentReady()Z — world geometry uploaded (direct-present reveal)
static jmethodID gMidMenuSelect = NULL;  // selectMenuPoint(II)V — menu row select + hover-clear (optional)
static jmethodID gMidShiftHeld = NULL;   // setShiftHeld(Z)V — sticky-Shift modifier (optional; tolerate older jar)
static jmethodID gMidCtrlHeld = NULL;    // setCtrlHeld(Z)V — sticky-Ctrl modifier (PARITY-IOS-LATCH; optional)
static jmethodID gMidAltHeld = NULL;     // setAltHeld(Z)V — sticky-Alt modifier (Ground-Items Alt-highlight; optional)
static jmethodID gMidMenuSuppress = NULL; // setMenuRenderSuppressed(Z)V — engine-menu raster gate (optional)
static jmethodID gMidInvokeMenu = NULL;  // invokeMenuEntry(II)V — commit a drilled-in submenu child (MENU-1, optional)
static jmethodID gMidKeybind = NULL;     // onKeybind(II)V — fire a plugin action-hotkey chord (KEY-1, optional)
static jmethodID gMidInvBounds = NULL;   // getInventoryBounds()[I — inventory grid bounds for item-drag (DRAG-1, optional)
static jmethodID gMidEngineScroll = NULL; // isEngineScrollableAt(II)Z — SCROLL-SPIKE pan-begin gate (optional)
static jmethodID gMidKeepAlive = NULL;   // keepAlive()V — idle-logout reset from native-UI touches (optional; tolerate older jar)

// W3 hybrid-chrome read surface — a SEPARATE facade (MobileChromeBridge) resolved lazily on the main thread.
static jclass    gChromeClass = NULL;   // global ref to net.runelite.client.headless.MobileChromeBridge
static jmethodID gMidChromeSnap = NULL; // getSnapshot()Ljava/lang/String;

// W3 touch-targeting read surface — the MenuPeekBridge facade, resolved lazily on the main thread. The native
// press-and-peek UI polls getSnapshot() (the menu the engine computed for the finger streamed via onMove).
static jclass    gMenuPeekClass = NULL; // global ref to net.runelite.client.headless.MenuPeekBridge
static jmethodID gMidMenuPeekSnap = NULL; // getSnapshot()Ljava/lang/String;

// Phase-6 plugin/config control plane — the MobileUiBridge facade, resolved lazily on the main thread.
static jclass    gMuiClass = NULL;      // global ref to net.runelite.client.headless.MobileUiBridge
static jmethodID gMuiList = NULL;       // listPlugins()Ljava/lang/String;
static jmethodID gMuiGetCfg = NULL;     // getPluginConfig(Ljava/lang/String;)Ljava/lang/String;
static jmethodID gMuiSetEnabled = NULL; // setPluginEnabled(Ljava/lang/String;Z)Ljava/lang/String;
static jmethodID gMuiSetCfg = NULL;     // setConfig(3x String)Ljava/lang/String;
static jmethodID gMuiResetCfg = NULL;   // resetConfig(2x String)Ljava/lang/String;
static jmethodID gMuiSeq = NULL;        // getMobileUiSeq()J
static jmethodID gMuiPoll = NULL;       // pollMobileUiEvents(J)Ljava/lang/String;
static jmethodID gMuiProcessed = NULL;  // getProcessedWriteId()J
static jmethodID gMuiFlush = NULL;      // flushConfigQueued()Ljava/lang/String; (async, off the iOS main thread)
static jmethodID gMuiHubManifest = NULL;  // hubManifest()Ljava/lang/String;
static jmethodID gMuiHubInstall = NULL;   // hubInstall(Ljava/lang/String;)Ljava/lang/String;
static jmethodID gMuiHubUninstall = NULL; // hubUninstall(Ljava/lang/String;)Ljava/lang/String;
static jmethodID gMuiListPanels = NULL;   // listPanels()Ljava/lang/String;
static jmethodID gMuiXpAvail = NULL;      // xpTrackerAvailable()Z  (native XP Tracker panel)
static jmethodID gMuiXpJson = NULL;       // xpTrackerJson()Ljava/lang/String;
static jmethodID gMuiNotesAvail = NULL;   // notesAvailable()Z  (native Notes panel)
static jmethodID gMuiNotesGet = NULL;     // notesGet()Ljava/lang/String;
static jmethodID gMuiNotesSet = NULL;     // notesSet(Ljava/lang/String;)Ljava/lang/String;
static jmethodID gMuiGeAvail = NULL;      // geAvailable()Z  (native Grand Exchange panel)
static jmethodID gMuiGeSetUi = NULL;      // geSetUiOpen(Z)Ljava/lang/String;
static jmethodID gMuiGeJson = NULL;       // geJson()Ljava/lang/String;
static jmethodID gMuiGeSearch = NULL;     // geSearch(Ljava/lang/String;)Ljava/lang/String;
static jmethodID gMuiOpenPanel = NULL;    // openPanel(I)Ljava/lang/String;
static jmethodID gMuiClosePanel = NULL;   // closePanel()Ljava/lang/String;
static jmethodID gMuiPanelW = NULL;       // getPanelWidth()I
static jmethodID gMuiPanelH = NULL;       // getPanelHeight()I
static jmethodID gMuiPanelSeq = NULL;     // getPanelFrameSeq()I
static jmethodID gMuiPanelPixels = NULL;  // getPanelPixels()[I
static jmethodID gMuiPanelClick = NULL;   // panelClick(II)Ljava/lang/String;
static jmethodID gMuiNextNotif = NULL;    // nextNotification()Ljava/lang/String; (optional)
static jmethodID gMuiNextShot = NULL;     // nextScreenshot()Ljava/lang/String; — SHOT-2 auto-screenshot path (optional)
static jmethodID gMuiNextLink = NULL;     // nextLink()Ljava/lang/String; (optional)
static jmethodID gMuiSetPinned = NULL;    // setPinned(Ljava/lang/String;Z)Ljava/lang/String; (optional)
static jmethodID gMuiHubState = NULL;     // hubState()Ljava/lang/String; (optional)
static jmethodID gMuiResetPlugin = NULL;  // resetPluginConfig(Ljava/lang/String;)Ljava/lang/String; (optional)
static jmethodID gMuiNotifDefaults = NULL; // notificationDefaults()Ljava/lang/String; (optional)
// Panel-input P0 (PANEL-1/2) — all optional so an older staged jar still boots.
static jmethodID gMuiPanelText = NULL;      // panelText(Ljava/lang/String;)Ljava/lang/String;
static jmethodID gMuiPanelKey = NULL;       // panelKey(I)Ljava/lang/String;
static jmethodID gMuiPanelLongPress = NULL; // panelLongPress(II)Ljava/lang/String;
static jmethodID gMuiPanelWheel = NULL;     // panelWheel(III)Ljava/lang/String;
static jmethodID gMuiPanelMove = NULL;      // panelMove(II)Ljava/lang/String;
static jmethodID gMuiPanelTextActive = NULL;// isPanelTextActive()Z
static jmethodID gMuiPanelTextGet = NULL;   // getPanelText()Ljava/lang/String;
static jmethodID gMuiHotkeyActions = NULL;  // hotkeyActionsJson()Ljava/lang/String; — KEY-1 fireable hotkeys (optional)
static jmethodID gMuiFireHotkey = NULL;     // fireHotkey(String,String)V — KEY-1 fire a plugin action-hotkey (optional)

// Native Quest Helper reflow — the QuestHelperBridge facade (reflection into the external plugin).
static jclass    gQhClass = NULL;       // global ref to net.runelite.client.headless.QuestHelperBridge
static jmethodID gQhAvailable = NULL;   // isAvailable()Z
static jmethodID gQhList = NULL;        // getQuestListJson()Ljava/lang/String;
static jmethodID gQhActive = NULL;      // getQuestActiveJson()Ljava/lang/String;
static jmethodID gQhStart = NULL;       // startQuest(Ljava/lang/String;)V
static jmethodID gQhStop = NULL;        // stopQuest()V
static jmethodID gQhSetOpen = NULL;     // setUiOpen(Z)V

// Native overlay edit-mode — the OverlayBridge facade (move / snap / reset live overlays).
static jclass    gOvlClass = NULL;      // global ref to net.runelite.client.headless.OverlayBridge
static jmethodID gOvlAvailable = NULL;  // isAvailable()Z
static jmethodID gOvlSetOpen = NULL;    // setUiOpen(Z)V
static jmethodID gOvlList = NULL;       // getOverlaysJson()Ljava/lang/String;
static jmethodID gOvlSetLoc = NULL;     // setOverlayPreferredLocation(Ljava/lang/String;II)Ljava/lang/String;
static jmethodID gOvlSetPos = NULL;     // setOverlayPreferredPosition(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
static jmethodID gOvlReset = NULL;      // resetOverlay(Ljava/lang/String;)Ljava/lang/String;
static jmethodID gOvlSnap = NULL;       // snapPositionForPoint(IIII)Ljava/lang/String;

// RuneLite-account login (config sync) — the RuneLiteAccountBridge facade (start/stop OAuth + read session).
static jclass    gAccountClass = NULL;  // global ref to net.runelite.client.headless.RuneLiteAccountBridge
static jmethodID gAccAvail = NULL;      // isAvailable()Z
static jmethodID gAccSession = NULL;    // getSessionJson()Ljava/lang/String;
// startLogin()V + logout()V are resolved on a worker thread (login blocks on a localhost server + network call).

// Native World Switcher reflow — the WorldSwitcherBridge facade (direct WorldService reads, reflected hop).
static jclass    gWsClass = NULL;       // global ref to net.runelite.client.headless.WorldSwitcherBridge
static jmethodID gWsAvailable = NULL;   // isAvailable()Z
static jmethodID gWsList = NULL;        // getWorldListJson()Ljava/lang/String;
static jmethodID gWsHop = NULL;         // hop(I)V
static jmethodID gWsSetOpen = NULL;     // setUiOpen(Z)V
static jmethodID gWsSetFav = NULL;      // setFavourite(IZ)V (optional)
static jmethodID gWsHopDir = NULL;      // hopDirection(Z)V (optional)

// Native Loot Tracker reflow — the LootTrackerBridge facade (read-only per-source loot snapshot + Reset All).
static jclass gLootClass = NULL;      // global ref to net.runelite.client.headless.LootTrackerBridge
static jmethodID gLootAvail = NULL;   // isAvailable()Z
static jmethodID gLootSetOpen = NULL; // setUiOpen(Z)V
static jmethodID gLootJson = NULL;    // getLootJson()Ljava/lang/String;
static jmethodID gLootReset = NULL;   // resetAll()Ljava/lang/String; (optional — older jars lack it)

// Native Time Tracking reflow — the TimeTrackingBridge facade (read-only farming/bird-house/timer snapshot).
static jclass gTtClass = NULL;      // global ref to net.runelite.client.headless.TimeTrackingBridge
static jmethodID gTtAvail = NULL;   // isAvailable()Z
static jmethodID gTtSetOpen = NULL; // setUiOpen(Z)V
static jmethodID gTtJson = NULL;    // getTimeTrackingJson()Ljava/lang/String;

// Native Config Profiles reflow — the ConfigProfileBridge facade (list profiles + switch the active one).
static jclass gProfClass = NULL;     // global ref to net.runelite.client.headless.ConfigProfileBridge
static jmethodID gProfAvail = NULL;  // isAvailable()Z
static jmethodID gProfJson = NULL;   // getProfilesJson()Ljava/lang/String;
static jmethodID gProfSwitch = NULL; // switchProfile(J)Ljava/lang/String;

// Native Infobox menu — the InfoBoxBridge facade (list infoboxes + their menu options, invoke one by index).
static jclass gIbClass = NULL;      // global ref to net.runelite.client.headless.InfoBoxBridge
static jmethodID gIbAvail = NULL;   // isAvailable()Z
static jmethodID gIbSetOpen = NULL; // setUiOpen(Z)V
static jmethodID gIbJson = NULL;    // getInfoBoxesJson()Ljava/lang/String;
static jmethodID gIbInvoke = NULL;  // invokeInfoBoxMenu(ILjava/lang/String;)Ljava/lang/String;

// ---- W3 plugin-config de-risk (verdict #7, NATIVE-ORIGIN leg) — STRIP AFTER DEVICE CONFIRM ----------
// Proves the half the desktop smoke can't: that the OBJC side builds the correct signed decimal of
// Color.getRGB(). The trap — an opaque color's getRGB() is a NEGATIVE int (top alpha bit set), and
// ColorUtil.fromString uses Integer.decode, which REJECTS 0xFFxxxxxx hex — so the control must send the
// signed decimal, not hex. We write the agreed opaque color 0xFF123456 to the throwaway sentinel group;
// MobileUiSmokeRunner reads it back through the typed proxy path and emits MUI_RT_NATIVE_COLOR_OK.
// Gated like the smoke flags below — flip to YES (+ re-add the 3 smoke opts) to re-run the device confirm.
// Device confirm md5-GREEN 2026-06-01 (MUI_RT_NATIVE_COLOR_OK=true): ObjC signed-decimal getRGB round-trips.
static const BOOL kMuiNativeColorProbe = NO;

static void runMuiNativeColorProbe(JVMLogSink log) {
    // 0xFF123456 == new Color(0x12,0x34,0x56,255).getRGB() — agreed with MobileUiSmokeRunner.nativeColorReadback.
    int32_t argb = (int32_t)(((uint32_t)0xFFu << 24) | ((uint32_t)0x12u << 16) | ((uint32_t)0x34u << 8) | (uint32_t)0x56u);
    NSString *decimal = [NSString stringWithFormat:@"%d", (int)argb];   // the signed decimal the control must send
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        JavaVM *vm = atomic_load(&gVM);
        if (!vm) return;
        JNIEnv *e = NULL;   // own daemon attach — the worker thread is blocked in callMain(DeviceHeadlessBoot)
        if ((*vm)->AttachCurrentThreadAsDaemon(vm, (void **)&e, NULL) != JNI_OK || !e) return;
        jclass cls = (*e)->FindClass(e, "net/runelite/client/headless/MobileUiBridge"); // on the system classpath
        if (!cls || (*e)->ExceptionCheck(e)) { (*e)->ExceptionClear(e); return; }
        jmethodID set = (*e)->GetStaticMethodID(e, cls, "setConfig",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
        if (!set) { (*e)->ExceptionClear(e); return; }
        jstring jg = (*e)->NewStringUTF(e, "mobileuismoke");
        jstring jk = (*e)->NewStringUTF(e, "nativecolor");
        jstring jv = (*e)->NewStringUTF(e, decimal.UTF8String);
        BOOL logged = NO;
        // Retry until the facade is wired (config/clientThread non-null) so the write lands; same value each
        // time, so post-landing writes are harmless no-ops. Stops at ~60s or when the VM goes away.
        for (int i = 0; i < 30 && atomic_load(&gVM); i++) {
            jobject r = (*e)->CallStaticObjectMethod(e, cls, set, jg, jk, jv);
            if ((*e)->ExceptionCheck(e)) { (*e)->ExceptionClear(e); }
            if (r) (*e)->DeleteLocalRef(e, r);
            if (!logged) { log([NSString stringWithFormat:@"[mui] NATIVE_RT_COLOR_WRITE=%@", decimal]); logged = YES; }
            usleep(2000 * 1000);   // 2s
        }
        (*e)->DeleteLocalRef(e, jg); (*e)->DeleteLocalRef(e, jk); (*e)->DeleteLocalRef(e, jv);
    });
}

// Resolve + cache the JavaBridge facade on the calling (main) thread. Returns YES once usable.
static BOOL ensureBridge(void) {
    if (gBridgeClass) return atomic_load(&gVM) != NULL;   // cached, but bail once the VM is torn down
    JavaVM *vm = atomic_load(&gVM);
    if (!vm) return NO;
    JNIEnv *env = NULL;
    jint r = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_21);
    if (r == JNI_EDETACHED) {
        // Daemon attach: the VM won't block on this (UI) thread at shutdown, so DestroyJavaVM stays clean
        // even though we never explicitly detach the main thread (it outlives the VM teardown call).
        if ((*vm)->AttachCurrentThreadAsDaemon(vm, (void **)&env, NULL) != JNI_OK || !env) return NO;
    } else if (r != JNI_OK || !env) {
        return NO;
    }
    gMainEnv = env;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/JavaBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    gMidW      = (*env)->GetStaticMethodID(env, global, "getFrameWidth", "()I");
    gMidH      = (*env)->GetStaticMethodID(env, global, "getFrameHeight", "()I");
    gMidSeq    = (*env)->GetStaticMethodID(env, global, "getFrameSeq", "()I");
    gMidPixels = (*env)->GetStaticMethodID(env, global, "getFramePixels", "()[I");
    gMidTouch  = (*env)->GetStaticMethodID(env, global, "onTouch", "(IIII)V");
    gMidClick  = (*env)->GetStaticMethodID(env, global, "onClick", "(III)V");
    gMidClickPrecise = (*env)->GetStaticMethodID(env, global, "onClickPrecise", "(III)V");
    gMidMove   = (*env)->GetStaticMethodID(env, global, "onMove", "(II)V");
    gMidWheel  = (*env)->GetStaticMethodID(env, global, "onWheel", "(III)V");
    gMidCamera = (*env)->GetStaticMethodID(env, global, "onCameraDrag", "(II)V");
    gMidText   = (*env)->GetStaticMethodID(env, global, "onText", "(Ljava/lang/String;)V");
    gMidKey    = (*env)->GetStaticMethodID(env, global, "onKeyStroke", "(I)V");
    gMidInputOpen = (*env)->GetStaticMethodID(env, global, "isTextInputOpen", "()Z");
    gMidWarmed = (*env)->GetStaticMethodID(env, global, "presentReady", "()Z");   // optional (not in the null-check below)
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); }
    gMidClearHover = (*env)->GetStaticMethodID(env, global, "clearHover", "()V");
    if (!gMidW || !gMidH || !gMidSeq || !gMidPixels || !gMidTouch || !gMidClick || !gMidClickPrecise || !gMidMove
        || !gMidWheel || !gMidCamera || !gMidText || !gMidKey || !gMidInputOpen || !gMidClearHover) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);   // don't leak the class ref on the retry path
        return NO;                              // retry next tick (the class may load just after bringup)
    }
    // Optional (not in the mandatory set above, so an older jar without it still boots the bridge).
    gMidInteractSeq = (*env)->GetStaticMethodID(env, global, "getInteractTapSeq", "()I");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidInteractSeq = NULL; }
    gMidMenuSelect = (*env)->GetStaticMethodID(env, global, "selectMenuPoint", "(II)V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidMenuSelect = NULL; }
    gMidShiftHeld = (*env)->GetStaticMethodID(env, global, "setShiftHeld", "(Z)V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidShiftHeld = NULL; }
    gMidCtrlHeld = (*env)->GetStaticMethodID(env, global, "setCtrlHeld", "(Z)V");
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        gMidCtrlHeld = NULL;
    }
    gMidAltHeld = (*env)->GetStaticMethodID(env, global, "setAltHeld", "(Z)V");
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        gMidAltHeld = NULL;
    }
    gMidMenuSuppress = (*env)->GetStaticMethodID(env, global, "setMenuRenderSuppressed", "(Z)V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidMenuSuppress = NULL; }
    gMidInvokeMenu = (*env)->GetStaticMethodID(env, global, "invokeMenuEntry", "(II)V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidInvokeMenu = NULL; }
    gMidKeybind = (*env)->GetStaticMethodID(env, global, "onKeybind", "(II)V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidKeybind = NULL; }
    gMidInvBounds = (*env)->GetStaticMethodID(env, global, "getInventoryBounds", "()[I");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidInvBounds = NULL; }
    gMidEngineScroll = (*env)->GetStaticMethodID(env, global, "isEngineScrollableAt", "(II)Z");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidEngineScroll = NULL; }
    gMidKeepAlive = (*env)->GetStaticMethodID(env, global, "keepAlive", "()V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMidKeepAlive = NULL; }
    gBridgeClass = global;   // publish only once fully resolved
    return YES;
}

// Resolve + cache the MobileChromeBridge facade on the calling (main) thread. Reuses the JavaBridge attach
// (gMainEnv), so call only after ensureBridge() has run. Returns YES once usable.
static BOOL ensureChrome(void) {
    if (gChromeClass) return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv) return NO;   // shares the main thread's attached env
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/MobileChromeBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    jmethodID snap = (*env)->GetStaticMethodID(env, global, "getSnapshot", "()Ljava/lang/String;");
    if (!snap) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    gMidChromeSnap = snap;
    gChromeClass = global;   // publish only once fully resolved
    return YES;
}

// Resolve + cache the MenuPeekBridge facade on the calling (main) thread. Shares the JavaBridge attach.
static BOOL ensureMenuPeek(void) {
    if (gMenuPeekClass) return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv) return NO;   // shares the main thread's attached env
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/MenuPeekBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    jmethodID snap = (*env)->GetStaticMethodID(env, global, "getSnapshot", "()Ljava/lang/String;");
    if (!snap) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    gMidMenuPeekSnap = snap;
    gMenuPeekClass = global;   // publish only once fully resolved
    return YES;
}

// Resolve + cache the HudDataBridge facade (W3 Feature-A native HUD data). Shares the JavaBridge attach.
static jclass    gHudClass = NULL;
static jmethodID gMidHudSnap = NULL;   // getSnapshot()Ljava/lang/String;
static jmethodID gMidHudSeq = NULL;    // getSeq()I
static BOOL ensureHud(void) {
    if (gHudClass) return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv) return NO;   // shares the main thread's attached env
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/HudDataBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    jmethodID snap = (*env)->GetStaticMethodID(env, global, "getSnapshot", "()Ljava/lang/String;");
    jmethodID sq = (*env)->GetStaticMethodID(env, global, "getSeq", "()I");
    if (!snap || !sq) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    gMidHudSnap = snap;
    gMidHudSeq = sq;
    gHudClass = global;   // publish only once fully resolved
    return YES;
}

// Resolve + cache the HudVeneerBridge facade (W3 A3 chatbox control). Shares the JavaBridge attach.
static jclass    gVeneerClass = NULL;
static jmethodID gMidSetChatHidden = NULL;   // setChatHidden(Z)V
static jmethodID gMidRelocateChat = NULL;    // relocateChat(IIZ)V
static jmethodID gMidRelocateMinimap = NULL; // relocateMinimap(II)V  (A4 — minimap+orbs cluster)
static jmethodID gMidSetMinimapScale = NULL; // setMinimapScale(I)V  (bigger minimap)
static jmethodID gMidRelocateSide = NULL;    // relocateSidePanel(II)V (A4/A6 — inventory side panel)
static jmethodID gMidOpenTab = NULL;         // openTab(I)V  (A4 — open a tab by replaying its stone op script)
static jmethodID gMidSetStonesHidden = NULL; // setStonesHidden(Z)V  (A4 — hide the engine tab stones)
static jmethodID gMidSetChatRowH = NULL;     // setChatTabRowHeight(I)V  (A3 — bigger native chat tabs)
static jmethodID gMidSetChatAreaW = NULL;    // setChatAreaWidth(I)V  (A3 — widen message area to align)
static jmethodID gMidScrollChat = NULL;      // scrollChat(I)V  (A3 — finger-scroll the chat, no wheel/zoom)
static jmethodID gMidSwitchChatTab = NULL;   // switchChatTab(I)V  (A3 — switch tab via op-replay, hidden tabs)
static jmethodID gMidSetChatCollapsed = NULL; // setChatCollapsed(Z)V  (A3 — tap active tab hides the chat box)
static jmethodID gMidGetChatSnap = NULL;     // getChatSnapshot()Ljava/lang/String;  (A3)
static jmethodID gMidGetChatLines = NULL;    // getChatLines()Ljava/lang/String;  (native top-rendered chat)
static jmethodID gMidGetDialogue = NULL;     // getDialogueJson()Ljava/lang/String;  (native-rendered dialogue)
static jmethodID gMidSetOverlayInsets = NULL; // setOverlaySafeInsets(IIII)V (snap-corner safe frame)
static jmethodID gMidPanMap = NULL;          // panWorldMap(II)V  (world map: finger pan -> map centre)
static jmethodID gMidGetMapSnap = NULL;      // getMapSnapshot()Ljava/lang/String;  (world map open + rects)
static jmethodID gMidTabSprites = NULL;      // tabSprites()Ljava/lang/String;  (cache-rendered chrome sprites)
static BOOL ensureVeneer(void) {
    if (gVeneerClass) return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv) return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/HudVeneerBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    jmethodID m = (*env)->GetStaticMethodID(env, global, "setChatHidden", "(Z)V");
    jmethodID r = (*env)->GetStaticMethodID(env, global, "relocateChat", "(IIZ)V");
    jmethodID mm = (*env)->GetStaticMethodID(env, global, "relocateMinimap", "(II)V");
    jmethodID sp = (*env)->GetStaticMethodID(env, global, "relocateSidePanel", "(II)V");
    jmethodID ot = (*env)->GetStaticMethodID(env, global, "openTab", "(I)V");
    jmethodID sh = (*env)->GetStaticMethodID(env, global, "setStonesHidden", "(Z)V");
    if (!m || !r || !mm || !sp || !ot || !sh) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    // A3 bigger-chat-tabs methods — OPTIONAL so an older bundled jar still loads the veneer (clear any pending
    // NoSuchMethod and leave the ids NULL; the wrappers below no-op when absent).
    gMidSetChatRowH = (*env)->GetStaticMethodID(env, global, "setChatTabRowHeight", "(I)V");
    gMidSetChatAreaW = (*env)->GetStaticMethodID(env, global, "setChatAreaWidth", "(I)V");
    gMidScrollChat = (*env)->GetStaticMethodID(env, global, "scrollChat", "(I)V");
    gMidGetChatSnap = (*env)->GetStaticMethodID(env, global, "getChatSnapshot", "()Ljava/lang/String;");
    gMidGetChatLines = (*env)->GetStaticMethodID(env, global, "getChatLines", "()Ljava/lang/String;");
    gMidGetDialogue = (*env)->GetStaticMethodID(env, global, "getDialogueJson", "()Ljava/lang/String;");
    gMidSetMinimapScale = (*env)->GetStaticMethodID(env, global, "setMinimapScale", "(I)V");
    gMidSwitchChatTab = (*env)->GetStaticMethodID(env, global, "switchChatTab", "(I)V");
    gMidSetChatCollapsed = (*env)->GetStaticMethodID(env, global, "setChatCollapsed", "(Z)V");
    gMidSetOverlayInsets = (*env)->GetStaticMethodID(env, global, "setOverlaySafeInsets", "(IIII)V");
    gMidPanMap = (*env)->GetStaticMethodID(env, global, "panWorldMap", "(II)V");
    gMidGetMapSnap = (*env)->GetStaticMethodID(env, global, "getMapSnapshot", "()Ljava/lang/String;");
    gMidTabSprites = (*env)->GetStaticMethodID(env, global, "tabSprites", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); }
    gMidSetChatHidden = m;
    gMidRelocateChat = r;
    gMidRelocateMinimap = mm;
    gMidRelocateSide = sp;
    gMidOpenTab = ot;
    gMidSetStonesHidden = sh;
    gVeneerClass = global;
    return YES;
}

// Resolve + cache the MobileUiBridge facade on the calling (main) thread. Shares the JavaBridge attach.
static BOOL ensureMui(void) {
    if (gMuiClass) return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv) return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/MobileUiBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    gMuiList       = (*env)->GetStaticMethodID(env, global, "listPlugins", "()Ljava/lang/String;");
    gMuiGetCfg     = (*env)->GetStaticMethodID(env, global, "getPluginConfig", "(Ljava/lang/String;)Ljava/lang/String;");
    gMuiSetEnabled = (*env)->GetStaticMethodID(env, global, "setPluginEnabled", "(Ljava/lang/String;Z)Ljava/lang/String;");
    gMuiSetCfg     = (*env)->GetStaticMethodID(env, global, "setConfig", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    gMuiResetCfg   = (*env)->GetStaticMethodID(env, global, "resetConfig", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    gMuiSeq        = (*env)->GetStaticMethodID(env, global, "getMobileUiSeq", "()J");
    gMuiPoll       = (*env)->GetStaticMethodID(env, global, "pollMobileUiEvents", "(J)Ljava/lang/String;");
    gMuiProcessed  = (*env)->GetStaticMethodID(env, global, "getProcessedWriteId", "()J");
    // QA-P1-03: bind the QUEUED variant. The iOS callers (panel/overlay/config close, app background) are all
    // fire-and-forget on the MAIN thread; flushConfigQueued enqueues sendConfig on the client thread and returns
    // immediately, so it never blocks the UI on the fsync. (The synchronous flushConfig stays for callers that
    // must persist before exiting — the Android logout path.)
    gMuiFlush      = (*env)->GetStaticMethodID(env, global, "flushConfigQueued", "()Ljava/lang/String;");
    gMuiHubManifest  = (*env)->GetStaticMethodID(env, global, "hubManifest", "()Ljava/lang/String;");
    gMuiHubInstall   = (*env)->GetStaticMethodID(env, global, "hubInstall", "(Ljava/lang/String;)Ljava/lang/String;");
    gMuiHubUninstall = (*env)->GetStaticMethodID(env, global, "hubUninstall", "(Ljava/lang/String;)Ljava/lang/String;");
    gMuiListPanels   = (*env)->GetStaticMethodID(env, global, "listPanels", "()Ljava/lang/String;");
    gMuiOpenPanel    = (*env)->GetStaticMethodID(env, global, "openPanel", "(I)Ljava/lang/String;");
    gMuiClosePanel   = (*env)->GetStaticMethodID(env, global, "closePanel", "()Ljava/lang/String;");
    gMuiPanelW       = (*env)->GetStaticMethodID(env, global, "getPanelWidth", "()I");
    gMuiPanelH       = (*env)->GetStaticMethodID(env, global, "getPanelHeight", "()I");
    gMuiPanelSeq     = (*env)->GetStaticMethodID(env, global, "getPanelFrameSeq", "()I");
    gMuiPanelPixels  = (*env)->GetStaticMethodID(env, global, "getPanelPixels", "()[I");
    gMuiPanelClick   = (*env)->GetStaticMethodID(env, global, "panelClick", "(II)Ljava/lang/String;");
    if (!gMuiList || !gMuiGetCfg || !gMuiSetEnabled || !gMuiSetCfg || !gMuiResetCfg
        || !gMuiSeq || !gMuiPoll || !gMuiProcessed || !gMuiFlush
        || !gMuiHubManifest || !gMuiHubInstall || !gMuiHubUninstall
        || !gMuiListPanels || !gMuiOpenPanel || !gMuiClosePanel || !gMuiPanelW || !gMuiPanelH
        || !gMuiPanelSeq || !gMuiPanelPixels || !gMuiPanelClick) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    // Optional (not in the mandatory set above, so an older staged jar still boots the facade). Each wrapper
    // null-guards its own id, so a missing method only disables that one feature.
    gMuiNextNotif = (*env)->GetStaticMethodID(env, global, "nextNotification", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiNextNotif = NULL; }
    gMuiNextShot = (*env)->GetStaticMethodID(env, global, "nextScreenshot", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiNextShot = NULL; }
    gMuiNextLink = (*env)->GetStaticMethodID(env, global, "nextLink", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiNextLink = NULL; }
    gMuiSetPinned = (*env)->GetStaticMethodID(env, global, "setPinned", "(Ljava/lang/String;Z)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiSetPinned = NULL; }
    gMuiHubState = (*env)->GetStaticMethodID(env, global, "hubState", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiHubState = NULL; }
    gMuiResetPlugin = (*env)->GetStaticMethodID(env, global, "resetPluginConfig", "(Ljava/lang/String;)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiResetPlugin = NULL; }
    gMuiNotifDefaults = (*env)->GetStaticMethodID(env, global, "notificationDefaults", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiNotifDefaults = NULL; }
    gMuiXpAvail = (*env)->GetStaticMethodID(env, global, "xpTrackerAvailable", "()Z");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiXpAvail = NULL; }
    gMuiXpJson = (*env)->GetStaticMethodID(env, global, "xpTrackerJson", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiXpJson = NULL; }
    gMuiNotesAvail = (*env)->GetStaticMethodID(env, global, "notesAvailable", "()Z");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiNotesAvail = NULL; }
    gMuiNotesGet = (*env)->GetStaticMethodID(env, global, "notesGet", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiNotesGet = NULL; }
    gMuiNotesSet = (*env)->GetStaticMethodID(env, global, "notesSet", "(Ljava/lang/String;)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiNotesSet = NULL; }
    gMuiGeAvail = (*env)->GetStaticMethodID(env, global, "geAvailable", "()Z");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiGeAvail = NULL; }
    gMuiGeSetUi = (*env)->GetStaticMethodID(env, global, "geSetUiOpen", "(Z)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiGeSetUi = NULL; }
    gMuiGeJson = (*env)->GetStaticMethodID(env, global, "geJson", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiGeJson = NULL; }
    gMuiGeSearch = (*env)->GetStaticMethodID(env, global, "geSearch", "(Ljava/lang/String;)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiGeSearch = NULL; }
    gMuiPanelText = (*env)->GetStaticMethodID(env, global, "panelText", "(Ljava/lang/String;)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiPanelText = NULL; }
    gMuiPanelKey = (*env)->GetStaticMethodID(env, global, "panelKey", "(I)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiPanelKey = NULL; }
    gMuiPanelLongPress = (*env)->GetStaticMethodID(env, global, "panelLongPress", "(II)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiPanelLongPress = NULL; }
    gMuiPanelWheel = (*env)->GetStaticMethodID(env, global, "panelWheel", "(III)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiPanelWheel = NULL; }
    gMuiPanelMove = (*env)->GetStaticMethodID(env, global, "panelMove", "(II)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiPanelMove = NULL; }
    gMuiPanelTextActive = (*env)->GetStaticMethodID(env, global, "isPanelTextActive", "()Z");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiPanelTextActive = NULL; }
    gMuiPanelTextGet = (*env)->GetStaticMethodID(env, global, "getPanelText", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiPanelTextGet = NULL; }
    gMuiHotkeyActions = (*env)->GetStaticMethodID(env, global, "hotkeyActionsJson", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiHotkeyActions = NULL; }
    gMuiFireHotkey = (*env)->GetStaticMethodID(env, global, "fireHotkey", "(Ljava/lang/String;Ljava/lang/String;)V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gMuiFireHotkey = NULL; }
    gMuiClass = global;   // publish only once fully resolved
    return YES;
}

static BOOL ensureQuest(void) {
    if (gQhClass) return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv) return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/QuestHelperBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    gQhAvailable = (*env)->GetStaticMethodID(env, global, "isAvailable", "()Z");
    gQhList      = (*env)->GetStaticMethodID(env, global, "getQuestListJson", "()Ljava/lang/String;");
    gQhActive    = (*env)->GetStaticMethodID(env, global, "getQuestActiveJson", "()Ljava/lang/String;");
    gQhStart     = (*env)->GetStaticMethodID(env, global, "startQuest", "(Ljava/lang/String;)V");
    gQhStop      = (*env)->GetStaticMethodID(env, global, "stopQuest", "()V");
    gQhSetOpen   = (*env)->GetStaticMethodID(env, global, "setUiOpen", "(Z)V");
    if (!gQhAvailable || !gQhList || !gQhActive || !gQhStart || !gQhStop || !gQhSetOpen) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    gQhClass = global;
    return YES;
}

static BOOL ensureOvl(void) {
    if (gOvlClass) return YES;
    if (!ensureBridge() || !gMainEnv) return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/OverlayBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    gOvlAvailable = (*env)->GetStaticMethodID(env, global, "isAvailable", "()Z");
    gOvlSetOpen   = (*env)->GetStaticMethodID(env, global, "setUiOpen", "(Z)V");
    gOvlList      = (*env)->GetStaticMethodID(env, global, "getOverlaysJson", "()Ljava/lang/String;");
    gOvlSetLoc    = (*env)->GetStaticMethodID(env, global, "setOverlayPreferredLocation", "(Ljava/lang/String;II)Ljava/lang/String;");
    gOvlSetPos    = (*env)->GetStaticMethodID(env, global, "setOverlayPreferredPosition", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    gOvlReset     = (*env)->GetStaticMethodID(env, global, "resetOverlay", "(Ljava/lang/String;)Ljava/lang/String;");
    if (!gOvlAvailable || !gOvlSetOpen || !gOvlList || !gOvlSetLoc || !gOvlSetPos || !gOvlReset) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    // Optional (the live snap-preview accessor; the snap MENU uses fixed corner names, so its absence in an older
    // jar must not disable the whole edit-mode).
    gOvlSnap = (*env)->GetStaticMethodID(env, global, "snapPositionForPoint", "(IIII)Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gOvlSnap = NULL; }
    gOvlClass = global;
    return YES;
}

// Resolve the RuneLite-account facade on the main thread for the quick reads (available / sessionJson). The
// blocking writes (startLogin / logout) attach their own worker thread instead (see +accountLogin/+accountLogout).
static BOOL ensureAccount(void) {
    if (gAccountClass) return atomic_load(&gVM) != NULL;   // cached, but bail if the VM was torn down
    if (!ensureBridge() || !gMainEnv) return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/RuneLiteAccountBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    gAccAvail   = (*env)->GetStaticMethodID(env, global, "isAvailable", "()Z");
    gAccSession = (*env)->GetStaticMethodID(env, global, "getSessionJson", "()Ljava/lang/String;");
    if (!gAccAvail || !gAccSession) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    gAccountClass = global;
    return YES;
}

static BOOL ensureWorld(void) {
    if (gWsClass) return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv) return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/WorldSwitcherBridge");
    if (!local || (*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return NO; }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global) return NO;
    gWsAvailable = (*env)->GetStaticMethodID(env, global, "isAvailable", "()Z");
    gWsList      = (*env)->GetStaticMethodID(env, global, "getWorldListJson", "()Ljava/lang/String;");
    gWsHop       = (*env)->GetStaticMethodID(env, global, "hop", "(I)V");
    gWsSetOpen   = (*env)->GetStaticMethodID(env, global, "setUiOpen", "(Z)V");
    if (!gWsAvailable || !gWsList || !gWsHop || !gWsSetOpen) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    // Optional (WH-1/WH-3) — an older staged jar without these still boots the rest of the switcher.
    gWsSetFav = (*env)->GetStaticMethodID(env, global, "setFavourite", "(IZ)V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gWsSetFav = NULL; }
    gWsHopDir = (*env)->GetStaticMethodID(env, global, "hopDirection", "(Z)V");
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); gWsHopDir = NULL; }
    gWsClass = global;
    return YES;
}

static BOOL ensureLoot(void) {
    if (gLootClass)
        return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv)
        return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/LootTrackerBridge");
    if (!local || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NO;
    }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global)
        return NO;
    gLootAvail = (*env)->GetStaticMethodID(env, global, "isAvailable", "()Z");
    gLootSetOpen = (*env)->GetStaticMethodID(env, global, "setUiOpen", "(Z)V");
    gLootJson = (*env)->GetStaticMethodID(env, global, "getLootJson", "()Ljava/lang/String;");
    if (!gLootAvail || !gLootSetOpen || !gLootJson) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    // Optional — "Reset All" write action; an older staged jar without it still serves the read-only panel.
    gLootReset = (*env)->GetStaticMethodID(env, global, "resetAll", "()Ljava/lang/String;");
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        gLootReset = NULL;
    }
    gLootClass = global;
    return YES;
}

static BOOL ensureTimeTracking(void) {
    if (gTtClass)
        return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv)
        return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/TimeTrackingBridge");
    if (!local || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NO;
    }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global)
        return NO;
    gTtAvail = (*env)->GetStaticMethodID(env, global, "isAvailable", "()Z");
    gTtSetOpen = (*env)->GetStaticMethodID(env, global, "setUiOpen", "(Z)V");
    gTtJson = (*env)->GetStaticMethodID(env, global, "getTimeTrackingJson", "()Ljava/lang/String;");
    if (!gTtAvail || !gTtSetOpen || !gTtJson) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    gTtClass = global;
    return YES;
}

static BOOL ensureProfiles(void) {
    if (gProfClass)
        return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv)
        return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/ConfigProfileBridge");
    if (!local || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NO;
    }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global)
        return NO;
    gProfAvail = (*env)->GetStaticMethodID(env, global, "isAvailable", "()Z");
    gProfJson = (*env)->GetStaticMethodID(env, global, "getProfilesJson", "()Ljava/lang/String;");
    gProfSwitch = (*env)->GetStaticMethodID(env, global, "switchProfile", "(J)Ljava/lang/String;");
    if (!gProfAvail || !gProfJson || !gProfSwitch) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    gProfClass = global;
    return YES;
}

static BOOL ensureInfoBox(void) {
    if (gIbClass)
        return atomic_load(&gVM) != NULL;
    if (!ensureBridge() || !gMainEnv)
        return NO;
    JNIEnv *env = gMainEnv;
    jclass local = (*env)->FindClass(env, "net/runelite/client/headless/InfoBoxBridge");
    if (!local || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NO;
    }
    jclass global = (*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    if (!global)
        return NO;
    gIbAvail = (*env)->GetStaticMethodID(env, global, "isAvailable", "()Z");
    gIbSetOpen = (*env)->GetStaticMethodID(env, global, "setUiOpen", "(Z)V");
    gIbJson = (*env)->GetStaticMethodID(env, global, "getInfoBoxesJson", "()Ljava/lang/String;");
    gIbInvoke = (*env)->GetStaticMethodID(env, global, "invokeInfoBoxMenu", "(ILjava/lang/String;)Ljava/lang/String;");
    if (!gIbAvail || !gIbSetOpen || !gIbJson || !gIbInvoke) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteGlobalRef(env, global);
        return NO;
    }
    gIbClass = global;
    return YES;
}

// ---- QA-SYS-1: rate-limited reverse-JNI fault sink -------------------------------------------------
// The per-frame / per-poll facade methods below clear any pending Java exception and return a nil/0/NO
// sentinel so a transient bridge fault can never escape into UIKit. That clear used to be SILENT, so a
// post-merge engine/API drift (a changed widget id, a renamed bridge method) surfaced only as a frozen
// frame, a dropped tap or a dead HUD — with zero diagnostic, the exact failure this port keeps debugging
// on-device. bridgeNoteClear() emits ONE line per call-site per 5s window (the suppressed count is reported
// on the next window) tagged "[bridge-fault]" — the SAME tag the Java-side BridgeFaults uses, so both halves
// of the bridge grep together in jvm-stdio.log — then dumps the exception (class + message + stack via
// ExceptionDescribe) and clears it. Returns YES if it cleared a pending exception, NO if none was pending,
// so it is a drop-in for a bare ExceptionClear (harmless when called with nothing pending).
static BOOL bridgeNoteClear(JNIEnv *env, const char *site) {
    if (!env || !(*env)->ExceptionCheck(env)) {
        return NO;   // nothing pending — same effect as the old no-op ExceptionClear
    }

    // Per-site 5s rate limit, mirroring BridgeFaults.WINDOW_MS. Pure-ObjC bookkeeping (no JNI), so it is safe
    // to run while the Java exception is still pending; the describe+clear happens after.
    static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *sites;   // site -> [lastLogNs, suppressed]
    static os_unfair_lock siteLock = OS_UNFAIR_LOCK_INIT;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sites = [NSMutableDictionary dictionary]; });

    const uint64_t windowNs = 5ull * NSEC_PER_SEC;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    NSString *key = @(site ? site : "?");
    BOOL shouldLog;
    unsigned long long suppressed = 0;
    os_unfair_lock_lock(&siteLock);
    NSArray<NSNumber *> *s = sites[key];
    if (s && now - s[0].unsignedLongLongValue < windowNs) {
        sites[key] = @[ s[0], @(s[1].unsignedLongLongValue + 1) ];   // within window: count, stay quiet
        shouldLog = NO;
    } else {
        suppressed = s ? s[1].unsignedLongLongValue : 0;
        sites[key] = @[ @(now), @0 ];                                // window rolled: log now, reset count
        shouldLog = YES;
    }
    os_unfair_lock_unlock(&siteLock);

    if (shouldLog) {
        if (suppressed > 0) {
            fprintf(stderr, "[bridge-fault] %s threw (%llu more suppressed in the last 5000ms)\n",
                    site ? site : "?", suppressed);
        } else {
            fprintf(stderr, "[bridge-fault] %s threw\n", site ? site : "?");
        }
        (*env)->ExceptionDescribe(env);   // class + message + stack to stderr (jvm-stdio.log); also clears
    }

    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);      // suppressed path (Describe didn't run), or belt-and-suspenders
    }
    return YES;
}

// Pull a Java String return into an NSString (and free the local ref). Returns nil on null/exception.
static NSString *jstringToNS(JNIEnv *env, jstring js) {
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.jstringToNS"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

@implementation JVMLauncher

+ (BOOL)isDebuggerAttached {
    int flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return NO; // EPERM etc. -> treat as not-yet-debugged
    }
    return (flags & CS_DEBUGGED) != 0;
}

+ (int)runRwxCanary:(JVMLogSink)log {
    size_t pg = (size_t)getpagesize();
    void *mem = mmap(NULL, pg, PROT_READ | PROT_WRITE,
                     MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);
    if (mem == MAP_FAILED) {
        // MAP_JIT may be rejected; retry without it.
        mem = mmap(NULL, pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    }
    if (mem == MAP_FAILED) { log(@"[canary] mmap RW failed"); return -1; }

    // arm64: mov w0, #42 ; ret
    uint32_t code[] = { 0x52800540u, 0xD65F03C0u };
    memcpy(mem, code, sizeof(code));

    if (mprotect(mem, pg, PROT_READ | PROT_EXEC) != 0) {
        log([NSString stringWithFormat:@"[canary] mprotect RX failed errno=%d", errno]);
        munmap(mem, pg);
        return -2;
    }
    sys_icache_invalidate(mem, sizeof(code));   // arm64: flush I-cache for the new code
    log(@"[canary] RX page ready; calling (SIGILL/EXC_BAD_ACCESS here => naive RWX blocked)");

    int (*fn)(void) = (int (*)(void))mem;
    int r = fn();                       // crashes here if RWX exec is disallowed
    log([NSString stringWithFormat:@"[canary] returned %d (expected 42) -> naive RWX WORKS", r]);
    munmap(mem, pg);
    return r;
}

+ (NSString *)javaHome {
    NSString *jh = [[NSBundle mainBundle] pathForResource:@"jre" ofType:nil];
    if (jh) return jh;
    // Folder-reference fallback: <bundle>/jre
    NSString *guess = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"jre"];
    return [[NSFileManager defaultManager] fileExistsAtPath:guess] ? guess : nil;
}

// Library/Application Support — NOT surfaced by UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace
// (those only expose Documents). Unlike Documents, the system does not create this for us, so ensure it exists.
+ (NSString *)appSupportDir {
    NSString *as = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    [[NSFileManager defaultManager] createDirectoryAtPath:as withIntermediateDirectories:YES attributes:nil error:NULL];
    return as;
}

+ (NSString *)tokensPath {
    NSString *path = [[self appSupportDir] stringByAppendingPathComponent:@"tokens.json"];
    // One-time migration: older builds wrote the session bearer into the Files/USB-exposed Documents dir.
    // Relocate any legacy copy into Application Support and purge the exposed one, so the bearer stops being
    // browsable on existing installs — whether or not an Application Support copy already exists.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *legacy = [docs stringByAppendingPathComponent:@"tokens.json"];
        if ([fm fileExistsAtPath:legacy]) {
            if (![fm fileExistsAtPath:path]) {
                [fm moveItemAtPath:legacy toPath:path error:NULL];
            } else {
                [fm removeItemAtPath:legacy error:NULL];
            }
        }
    });
    return path;
}

// Map tokens.json (Library/Application Support — see +tokensPath) -> the JX_* env the OSRS gamepack reads
// when "launched from the Jagex launcher". tokens.json is a gitignored secret (throwaway account) pushed
// into the app container at test time (devicectl) or minted on-device by the login web view, never bundled
// into the shared build. Returns YES iff a usable session was found (session_id + chosen_account_id), so
// autologin only arms when we can authenticate. Mirrors run-headless-login.sh's jq mapping. Env MUST be set
// before JNI_CreateJavaVM (HotSpot snapshots the environment at startup). Logs presence only — never values.
static BOOL loadJagexTokens(JVMLogSink log) {
    NSString *path = [JVMLauncher tokensPath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        log(@"[jx] no tokens.json — autologin DISABLED (login-screen render only)");
        return NO;
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        log([NSString stringWithFormat:@"[jx] tokens.json parse failed: %@", err.localizedDescription]);
        return NO;
    }
    NSDictionary *t = (NSDictionary *)obj;
    NSString *(^str)(NSString *) = ^NSString *(NSString *k) {
        id v = t[k];
        return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
    };
    NSString *session   = str(@"session_id");
    NSString *character = str(@"chosen_account_id");
    NSString *display   = str(@"chosen_display_name");
    NSString *access    = str(@"access_token");
    NSString *refresh   = str(@"refresh_token");
    if (session.length == 0 || character.length == 0) {
        log(@"[jx] tokens.json missing session_id/chosen_account_id — autologin DISABLED");
        return NO;
    }
    setenv("JX_SESSION_ID", session.UTF8String, 1);
    setenv("JX_CHARACTER_ID", character.UTF8String, 1);
    if (display.length)  setenv("JX_DISPLAY_NAME", display.UTF8String, 1);
    if (access.length)   setenv("JX_ACCESS_TOKEN", access.UTF8String, 1);
    if (refresh.length)  setenv("JX_REFRESH_TOKEN", refresh.UTF8String, 1);
    // Presence only — the display name and the stable character id are account PII; the session prefix is
    // kept (truncated, non-recoverable) as the "autologin armed" diagnostic.
    log([NSString stringWithFormat:@"[jx] JX_* set: displayName=%@ characterId=%@ session=%@… access=%@ refresh=%@",
        display.length ? @"set" : @"empty", character.length ? @"set" : @"empty",
        session.length >= 6 ? [session substringToIndex:6] : session,
        access.length ? @"set" : @"empty", refresh.length ? @"set" : @"empty"]);
    return YES;
}

// Reset the signals HotSpot manages to SIG_DFL so its own handlers install
// cleanly (Amethyst does this immediately before JLI_Launch).
static void resetSignalHandlers(void) {
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGPIPE, SIGTRAP };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        signal(sigs[i], SIG_DFL);
    }
}

// ───────────────────── Same-session login-crash diagnostics (Phase 6) — STRIP AFTER DIAGNOSIS ─────────────────────
// Symptom: opening the Jagex login WKWebView earlier in the SAME app session crashes the JVM natively
// right after RuneLite init; a force-quit + relaunch before Start JVM reaches the game cleanly. The two
// obvious causes are ALREADY defended (resetSignalHandlers() wipes WebKit's POSIX SIGSEGV/SIGBUS handlers;
// the §6.2 clear drops the task EXC_BAD_ACCESS Mach port), so this dumps the *actual* runtime state to the
// crash-safe stderr fd (Documents/jvm-stdio.log — dup2'd UNBUFFERED, so it survives even a silent jetsam
// kill). Run twice and diff: (A) fresh launch → Start JVM (clean baseline) vs (B) fresh launch → Log in →
// Start JVM (the crash case). What differs pins the cause:
//   • a non-null BAD_ACCESS port (task or thread) in B → WebKit's JavaScriptCore is stealing HotSpot's
//     null-check/safepoint faults (exception-port path) → the thread-level clear below should fix it;
//   • a "custom" SIGSEGV handler surviving into B → a POSIX-handler shadow we're not resetting;
//   • avail-memory collapsing toward 0 (memwatch) before B dies with no SIGSEGV → jetsam (WebKit helper
//     processes) → the web-view teardown (login VC) is the lever, not the ports.
static void dumpFaultState(const char *when) {
    exception_mask_t      masks[EXC_TYPES_COUNT];
    mach_port_t           ports[EXC_TYPES_COUNT];
    exception_behavior_t  behs[EXC_TYPES_COUNT];
    thread_state_flavor_t flav[EXC_TYPES_COUNT];
    mach_msg_type_number_t n = 0;

    kern_return_t kr = task_get_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS,
                                                masks, &n, ports, behs, flav);
    fprintf(stderr, "[faultdiag:%s] task BAD_ACCESS kr=%d n=%u", when, kr, n);
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        fprintf(stderr, " {mask=0x%x port=0x%x beh=0x%x flav=%d}", masks[i], ports[i], behs[i], flav[i]);
        if (ports[i] != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), ports[i]);
    }
    fprintf(stderr, "\n");

    // BREAKPOINT is the mask that matters for HotSpot's JIT-mirror brk #0x69 — if WebKit displaced the
    // StikDebug debugger here, the brk is never serviced. BAD_INSTRUCTION for completeness (JSC claims it).
    n = 0;
    kr = task_get_exception_ports(mach_task_self(), EXC_MASK_BREAKPOINT, masks, &n, ports, behs, flav);
    fprintf(stderr, "[faultdiag:%s] task BREAKPOINT kr=%d n=%u", when, kr, n);
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        fprintf(stderr, " {mask=0x%x port=0x%x beh=0x%x flav=%d}", masks[i], ports[i], behs[i], flav[i]);
        if (ports[i] != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), ports[i]);
    }
    fprintf(stderr, "\n");
    n = 0;
    kr = task_get_exception_ports(mach_task_self(), EXC_MASK_BAD_INSTRUCTION, masks, &n, ports, behs, flav);
    fprintf(stderr, "[faultdiag:%s] task BAD_INSTRUCTION kr=%d n=%u", when, kr, n);
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        fprintf(stderr, " {mask=0x%x port=0x%x beh=0x%x flav=%d}", masks[i], ports[i], behs[i], flav[i]);
        if (ports[i] != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), ports[i]);
    }
    fprintf(stderr, "\n");

    thread_t th = mach_thread_self();
    n = 0;
    kr = thread_get_exception_ports(th, EXC_MASK_BAD_ACCESS, masks, &n, ports, behs, flav);
    fprintf(stderr, "[faultdiag:%s] thread BAD_ACCESS kr=%d n=%u", when, kr, n);
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        fprintf(stderr, " {mask=0x%x port=0x%x beh=0x%x flav=%d}", masks[i], ports[i], behs[i], flav[i]);
        if (ports[i] != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), ports[i]);
    }
    fprintf(stderr, "\n");
    mach_port_deallocate(mach_task_self(), th);

    int sg[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP };
    const char *nm[] = { "SIGSEGV", "SIGBUS", "SIGILL", "SIGTRAP" };
    for (size_t i = 0; i < sizeof(sg) / sizeof(sg[0]); i++) {
        struct sigaction sa; memset(&sa, 0, sizeof(sa));
        if (sigaction(sg[i], NULL, &sa) != 0) continue;
        void *h = (sa.sa_flags & SA_SIGINFO) ? (void *)sa.sa_sigaction : (void *)sa.sa_handler;
        const char *tag = h == (void *)SIG_DFL ? "DFL" : h == (void *)SIG_IGN ? "IGN" : "custom";
        fprintf(stderr, "[faultdiag:%s] %s=%p(%s) flags=0x%x onstack=%d\n",
                when, nm[i], h, tag, sa.sa_flags, (sa.sa_flags & SA_ONSTACK) ? 1 : 0);
    }

    size_t avail = os_proc_available_memory();
    task_vm_info_data_t vmi; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; uint64_t fp = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &c) == KERN_SUCCESS) fp = vmi.phys_footprint;
    fprintf(stderr, "[faultdiag:%s] mem avail=%.1fMB footprint=%.1fMB\n", when, avail / 1048576.0, fp / 1048576.0);
}

// Sample jetsam headroom every 500 ms across RuneLite init (the crash window), to the crash-safe fd. If a
// post-login launch is OOM/jetsam-killed, the last line shows avail collapsing toward 0 right before death
// — the signature that separates a memory kill from a SIGSEGV (exception-port/handler) kill.
static void *memWatchdog(void *unused) {
    (void)unused;
    pthread_setname_np("mem-watchdog");
    for (int i = 0; i < 60; i++) {
        size_t avail = os_proc_available_memory();
        task_vm_info_data_t vmi; mach_msg_type_number_t c = TASK_VM_INFO_COUNT; uint64_t fp = 0;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmi, &c) == KERN_SUCCESS) fp = vmi.phys_footprint;
        fprintf(stderr, "[memwatch t=%4.1fs] avail=%.1fMB footprint=%.1fMB\n", i * 0.5, avail / 1048576.0, fp / 1048576.0);
        usleep(500000);
    }
    return NULL;
}
static void startMemWatchdog(void) {
    pthread_t t; if (pthread_create(&t, NULL, memWatchdog, NULL) == 0) pthread_detach(t);
}

// Same-session login fix: if WebKit (resident from the login web view) displaced the StikDebug debugger on
// the task EXC_BREAKPOINT port, HotSpot's JIT-mirror brk #0x69 is delivered to WebKit instead of the
// debugger → never serviced → fatal SIGTRAP in CodeCache::initialize. The debugger still holds the
// EXC_BAD_ACCESS port (it claims EXC_MASK_ALL on one handler), so copy that handler back onto
// EXC_BREAKPOINT. Call BEFORE the §6.2 BAD_ACCESS clear (which needs the debugger's port still in place).
// No-op on a clean launch — the debugger owns both already.
static void restoreBreakpointPortToDebugger(JVMLogSink log) {
    exception_mask_t      m[EXC_TYPES_COUNT];
    mach_port_t           p[EXC_TYPES_COUNT];
    exception_behavior_t  b[EXC_TYPES_COUNT];
    thread_state_flavor_t f[EXC_TYPES_COUNT];
    mach_msg_type_number_t n = 0;
    if (task_get_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, m, &n, p, b, f) != KERN_SUCCESS || n == 0) {
        log(@"[jvm] bp-restore: no BAD_ACCESS handler (debugger not attached?) — skipping");
        return;
    }
    mach_port_t dbg = p[0]; exception_behavior_t dbgBeh = b[0]; thread_state_flavor_t dbgFlav = f[0];

    mach_msg_type_number_t nb = 0;
    exception_mask_t      bm[EXC_TYPES_COUNT];
    mach_port_t           bp[EXC_TYPES_COUNT];
    exception_behavior_t  bb[EXC_TYPES_COUNT];
    thread_state_flavor_t bf[EXC_TYPES_COUNT];
    task_get_exception_ports(mach_task_self(), EXC_MASK_BREAKPOINT, bm, &nb, bp, bb, bf);
    mach_port_t cur = nb ? bp[0] : MACH_PORT_NULL;

    if (cur != dbg) {
        kern_return_t kr = task_set_exception_ports(mach_task_self(), EXC_MASK_BREAKPOINT, dbg, dbgBeh, dbgFlav);
        log([NSString stringWithFormat:@"[jvm] bp-restore: BREAKPOINT 0x%x != debugger 0x%x -> repointed kr=%d (beh=0x%x flav=%d)",
             cur, dbg, kr, dbgBeh, dbgFlav]);
    } else {
        log([NSString stringWithFormat:@"[jvm] bp-restore: BREAKPOINT already debugger's (0x%x) — no-op", dbg]);
    }
    for (mach_msg_type_number_t i = 0; i < n;  i++) if (p[i])  mach_port_deallocate(mach_task_self(), p[i]);
    for (mach_msg_type_number_t i = 0; i < nb; i++) if (bp[i]) mach_port_deallocate(mach_task_self(), bp[i]);
}

// Public wrapper (JVMLauncher.h): lets the shell re-run the repair after a MID-SESSION WebKit load (the
// session-expired re-login) — the boot-time call above only protects VM creation.
+ (void)restoreBreakpointPortNow:(JVMLogSink)log {
    restoreBreakpointPortToDebugger(log ?: ^(NSString *line) {
        (void)line;
    });
}

// Invoke <className>.main(args) on the (already-created) VM. Clears any exception
// so one probe's failure doesn't poison the next.
static void callMain(JNIEnv *env, const char *className, NSArray<NSString *> *args, JVMLogSink log) {
    jclass cls = (*env)->FindClass(env, className);
    if (!cls || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env);
        log([NSString stringWithFormat:@"[jvm] FindClass(%s) failed", className]); return;
    }
    jmethodID mid = (*env)->GetStaticMethodID(env, cls, "main", "([Ljava/lang/String;)V");
    if (!mid || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env);
        log([NSString stringWithFormat:@"[jvm] GetStaticMethodID(%s.main) failed", className]); return;
    }
    jclass strCls = (*env)->FindClass(env, "java/lang/String");
    jsize n = (jsize)args.count;
    jobjectArray jargs = (*env)->NewObjectArray(env, n, strCls, NULL);
    for (jsize i = 0; i < n; i++) {
        jstring s = (*env)->NewStringUTF(env, args[i].UTF8String);
        (*env)->SetObjectArrayElement(env, jargs, i, s);
        (*env)->DeleteLocalRef(env, s);
    }
    log([NSString stringWithFormat:@"[jvm] ===== %s.main =====", className]);
    (*env)->CallStaticVoidMethod(env, cls, mid, jargs);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env);
        log([NSString stringWithFormat:@"[jvm] %s threw", className]);
    } else {
        log([NSString stringWithFormat:@"[jvm] %s done", className]);
    }
}

- (int)runProbesWithLog:(JVMLogSink)log {
    NSString *javaHome = [JVMLauncher javaHome];
    if (!javaHome) { log(@"[jvm] FATAL: embedded jre not found in bundle"); return -10; }
    log([NSString stringWithFormat:@"[jvm] JAVA_HOME = %@", javaHome]);

    NSString *jarPath = [[NSBundle mainBundle] pathForResource:@"probes" ofType:@"jar"];
    if (!jarPath) { log(@"[jvm] FATAL: probes.jar not found in bundle"); return -11; }
    NSString *frameworks = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *glyphPng = [docs stringByAppendingPathComponent:@"glyph-smoke.png"];

    // §6.2: the shaded RuneLite client jar (all deps) + a writable RuneLite home for the gamepack
    // cache, and the headless capture dir (HeadlessCapture dumps mainBufferProvider PNGs there).
    NSString *shadedPath = [[NSBundle mainBundle] pathForResource:@"client-shaded" ofType:@"jar"];
    NSString *classpath;
    if (self.routecL1Mode) {
        // L1 kill-test: routec-l1.jar (facade-native + RouteCL1Probe) ALONE — no shaded jar, no LWJGL, so the
        // facade is provably the only provider and the probe isolates the JNI bridge.
        NSString *l1jar = [[NSBundle mainBundle] pathForResource:@"routec-l1" ofType:@"jar"];
        if (!l1jar) { log(@"[jvm] FATAL: routec-l1.jar not found in bundle"); return -11; }
        classpath = l1jar;
        log([NSString stringWithFormat:@"[jvm] ROUTEC L1 mode — classpath = %@", classpath]);
    } else {
        classpath = shadedPath ? [NSString stringWithFormat:@"%@:%@", shadedPath, jarPath] : jarPath;
        // Always append the staged 117HD (RLHD) jar so rs117.hd.* class-loads — not just in Zone mode. The
        // "renderers as plugins" model loads HdPlugin (no-start) into the panel in EVERY mode so 117HD is a
        // selectable plugin, so its classes must always be resolvable. It carries no lwjgl (the facade ships in
        // the shaded jar); RLHDStarter starts it only when 117HD is the active renderer.
        NSString *rlhdPath = [[NSBundle mainBundle] pathForResource:@"client-rlhd" ofType:@"jar"];
        if (rlhdPath) {
            classpath = [NSString stringWithFormat:@"%@:%@", classpath, rlhdPath];
            log([NSString stringWithFormat:@"[jvm] rlhd jar on classpath = %@", rlhdPath]);
        } else {
            log(@"[jvm] WARN: client-rlhd.jar not in bundle — 117HD will not load");
        }
    }
    // RuneLite home (.runelite: config + gamepack cache + RuneLite's own rolling client.log). Debug keeps it
    // in the Files/USB-exposed Documents dir for off-device retrieval; Release (QA-P1-11) relocates it to the
    // sandboxed Application Support dir so client.log + the cache are not externally browsable.
#if DEBUG
    NSString *rlHome = docs;
    NSString *captureDir = [docs stringByAppendingPathComponent:@"rl-capture"];
    // Clear stale frames from prior runs: the draw counter resets each launch, so an old run's
    // higher-numbered frame would otherwise win the W3 shell's lexical-newest pick (and disk grows).
    [[NSFileManager defaultManager] removeItemAtPath:captureDir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:captureDir withIntermediateDirectories:YES attributes:nil error:nil];
#else
    // QA-P1-10/11: the daily-driver does not write frame PNGs (HeadlessCapture stays inert with no capture.dir
    // below), and .runelite is sandboxed in App Support.
    NSString *rlHome = [JVMLauncher appSupportDir];
#endif
    (void)glyphPng;

    setenv("JAVA_HOME", javaHome.UTF8String, 1);

    // dlopen libjvm directly and use the JNI Invocation API (no launcher). Claim A
    // (re-signed ad-hoc dylibs load via plain dlopen, no dyld bypass) still holds.
    NSString *libjvm = [javaHome stringByAppendingPathComponent:@"lib/server/libjvm.dylib"];
    log([NSString stringWithFormat:@"[jvm] dlopen %@", libjvm]);
    void *h = dlopen(libjvm.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { log([NSString stringWithFormat:@"[jvm] FATAL dlopen(libjvm): %s", dlerror()]); return -12; }
    CreateJavaVM_t JNI_CreateJavaVM = (CreateJavaVM_t)dlsym(h, "JNI_CreateJavaVM");
    if (!JNI_CreateJavaVM) { log([NSString stringWithFormat:@"[jvm] FATAL dlsym(JNI_CreateJavaVM): %s", dlerror()]); return -13; }
    log(@"[jvm] JNI_CreateJavaVM resolved");

    NSMutableArray<NSString *> *opts = [@[
        @"-XX:+UnlockExperimentalVMOptions",
        @"-XX:+MirrorMappedCodeCache",            // iOS-26 code cache (Amethyst jre21 patch)
        @"-XX:+DisablePrimordialThreadGuardPages",
        @"-XX:-UseCompressedClassPointers",       // free cert: no extended-virtual-addressing
        @"-XX:ReservedCodeCacheSize=64m",         // bound the brk #0x69 RX reservation
        // NOTE (UPDATE 14): TieredStopAtLevel=1 + CICompilerCount=1 were tried and REVERTED — they did
        // NOT fix the §6.2 crash, they only MOVED it (code-cache is_unloading → GC heap corruption in
        // copy_to_survivor_space, with the crash reporter itself faulting = broad memory corruption).
        // Root cause is the debugger JIT region's physical pages aliasing the JVM heap, not tier-3
        // density. Full tiered is restored: it has the demonstrated CLEAN boots (UPDATE 9/10), and the
        // crash is probabilistic either way — retry until a boot doesn't collide.
        // W1 P3 §6.0 activation confirm: non-headless + the CACIO JPMS set (same flags the
        // desktop awtsmoke harness uses). HotSpot accepts --add-exports/--add-opens directly
        // as VM options (verified). sun.awt.image is needed by CTC's CTCVolatileSurfaceManager.
        // For the Phase-1 probe set, restore -Djava.awt.headless=true and drop the JPMS block.
        // NOTE (2026-05-31): JIT cannot be disabled on this patched libjvm — both -Xint and
        // -XX:-UseCompiler fail VM init with "Failed setting boot class path". The MirrorMappedCodeCache
        // build requires the JIT mirror active, so the §6.2 fix must repair the mirror, not bypass it.
        @"-Djava.awt.headless=false",
        @"--add-exports=java.desktop/java.awt=ALL-UNNAMED",
        @"--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED",
        @"--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED",
        @"--add-exports=java.desktop/sun.java2d=ALL-UNNAMED",
        @"--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED",
        @"--add-exports=java.desktop/sun.awt=ALL-UNNAMED",
        @"--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED",
        @"--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED",
        @"--add-exports=java.base/sun.security.action=ALL-UNNAMED",
        @"--add-opens=java.base/java.util=ALL-UNNAMED",
        @"--add-opens=java.desktop/java.awt=ALL-UNNAMED",
        @"--add-opens=java.desktop/sun.java2d=ALL-UNNAMED",
        @"--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
        // §6.2: heap for the full client + a writable RuneLite home (gamepack cache) + capture dir.
        @"-Xmx1024m",                             // 256m is ample for the CPU login screen, but 117HD's
                                                  // ZoneRenderer (scene/model staging on-heap + per-frame
                                                  // BufferedImage capture) OOMs in 256m on the first real draw
                                                  // (device round 3). 1024m fits well under the jetsam ceiling on
                                                  // this 12 GB device w/ the increased-memory-limit entitlement
                                                  // (NIO direct buffers are off-heap). Dial back if jetsam kills.
        [NSString stringWithFormat:@"-Duser.home=%@", rlHome],                     // -> <rlHome>/.runelite
#if DEBUG
        [NSString stringWithFormat:@"-Drunelite.headless.capture.dir=%@", captureDir],
#endif
        // Steady capture cadence (the §6.2 TCC fix made the process long-lived, so the old eager
        // interval=2/preLoginMax=6/exit-at-8 burst is no longer needed): grab a fresh login frame
        // ~every 10th draw so the W3 shell shows the LIVE, animated, complete login screen for the
        // whole window, and keep enough budget that it never freezes mid-run.
        @"-Drunelite.bridge=true",                   // enable the reverse-JNI live-blit + touch facade (W3 B)
        @"-Drunelite.mobileui=true",                 // Phase-6 (W3): arm the MobileUiBridge control-plane facade
                                                     // (plugin/config DTOs + chat-input tick snapshot)
        @"-Drunelite.mobilechrome=true",             // W3 hybrid-chrome: arm the read-only MobileChromeBridge
                                                     // snapshot (tab/panel/minimap/orb/chat/viewport bounds).
                                                     // NOT the .probe gate — that mutates and is desktop-only.
        @"-Drunelite.menupeek=true",                 // W3 touch-targeting: arm the read-only MenuPeekBridge
                                                     // (native right-click menu data source). NOT .probe (desktop-only).
        @"-Drunelite.menupeek.maxEntries=32",        // MENU-2: publish enough rows that crowded scenes aren't truncated (native scrolls)
        @"-Drunelite.huddata=true",                  // W3 Feature-A: arm the read-only HudDataBridge snapshot
                                                     // (chat lines / orb values / minimap positions for the veneers)
        @"-Drunelite.hudveneer=true",                // W3 Feature-A A3: arm the HudVeneerBridge (engine-HUD
                                                     // suppression; native sets which elements to hide, e.g. chat)
        // "Renderers as plugins": drop safe-mode in EVERY mode (incl. plain CPU) so the GPU + 117HD plugins load
        // + show in the panel (GpuPlugin is loadInSafeMode=false). DeviceHeadlessBoot reads this. The plugin HUB
        // works with safe-mode off; the one hazard — the PUBLIC hub 117HD whose jar has no facade (it collides
        // with our staged rs117.hd.HdPlugin) — is blocked in MobileUiBridge (HUB_BLOCKED hides it from the
        // catalog + refuses install), so OUR staged GpuPlugin/HdPlugin stay the canonical panel entries.
        @"-Drunelite.nosafemode=true",
        // The hub serves manifests for RELEASED versions only; our jar is a -SNAPSHOT (manifest 404s without
        // this). Pin to the latest released manifest (verify https://repo.runelite.net/plugins/manifest/
        // <v>_full.js answers 200 when bumping the client version).
        @"-Drunelite.pluginhub.version=1.12.28",
        @"-Drunelite.rendererpanel=true",            // arm RendererPanelStarter: load GPU + 117HD (no-start) into
                                                     // the panel so both are selectable + configurable.
        @"-Drunelite.nosplash=true",                 // no desktop Swing splash (its JFrame creation under CACIO
                                                     // aborted ExternalPluginManager.refreshPlugins).
        // NOTE: -Drunelite.mobilechrome.repos was tried and REVERTED — repositioned stones over the world are
        // occluded by the 3D viewport (only the mobile 601 toplevel draws tabs above it). Native rails it is.
        // Phase-6 STEP-0 device smoke confirmed GREEN (2026-06-01): lanes separate (config on client thread,
        // toggle on EDT), overlay registers headless (Ground Items 92->146), config persists across launches,
        // PluginManager EDT asserts live. To re-run the on-device self-test, re-add:
        //   @"-Drunelite.mobileui.smoke=true", @"-ea:net.runelite.client.plugins.PluginManager",
        // W3 plugin-config device confirms — all md5-GREEN 2026-06-01, flags stripped:
        //   typed round-trip (verdict #7) + bridge hardening (event/ack + getPluginConfig completeness +
        //   reset-default), both via the MobileUiSmokeRunner bytes. To re-run the self-test, re-add:
        //   @"-Drunelite.mobileui.smoke=true", @"-ea:net.runelite.client.plugins.PluginManager",
        //   (and -Drunelite.mobileui.nativeprobe + kMuiNativeColorProbe=YES for the native-origin color leg)
        // PLUGIN-HUB device de-risk — md5-GREEN 2026-06-02 (manifest=1700, nail-beast-sfx downloaded +
        // classloaded + JIT-ran + started under the mirror + showed in the panel, clean uninstall). Flags
        // stripped; to re-run the probe re-add:
        //   @"-Drunelite.mobileui.smoke=true", @"-ea:net.runelite.client.plugins.PluginManager",
        //   @"-Drunelite.mobileui.hubprobe=true", @"-Drunelite.hub=true", @"-Drunelite.pluginhub.version=1.12.27",
        // NOTE: -Drunelite.hub also drops safe-mode (enables external plugins) — the real hub UI will pass it.
#if DEBUG
        @"-Drunelite.headless.capture.interval=10",
        @"-Drunelite.headless.capture.preLoginMax=40",  // login-screen/EULA frames before LOGGED_IN gets its
                                                        // own (MAX_FRAMES) budget; a long LOADING can't starve it
#endif
        @"-Dheadless.runSeconds=240",               // wide window: interactive login adds EULA+Play Now clicks,
                                                    // network login, and a first-run cache download before LOGGED_IN
        @"-Dheadless.captureTargetFrames=999",      // don't early-exit; ride the window so the LOGGED_IN frame lands
        [NSString stringWithFormat:@"-Djava.home=%@", javaHome],
        [NSString stringWithFormat:@"-Djava.library.path=%@", frameworks],
        [NSString stringWithFormat:@"-Djava.class.path=%@", classpath],
    ] mutableCopy];

    // Fail fast at heap exhaustion instead of limping (bridge seams no-op, GC thrash) until an
    // untraceable jetsam kill — a clean exit lands in the normal relaunch flow and leaves an hs_err
    // trail. (Kept out of the literal above: any edit inside it makes clang-format reflow the block.)
    [opts addObject:@"-XX:+ExitOnOutOfMemoryError"];

    // BOTH renderer plugins are enabledByDefault=true, so with safe-mode off EITHER would AUTO-START in every
    // mode — and 117HD's HdPlugin (conflicts=GPU) then hijacks rendering even when CPU or base-GPU is the chosen
    // renderer (the "always boots 117HD regardless of selection" bug: rendererPref=cpu but HdPlugin auto-starts
    // from enabledByDefault). Force-disable whichever renderer plugin is NOT the selected one; the chosen
    // renderer is started by its own starter (RouteCGpuStarter / RLHDStarter). forceDisablePlugins wins over a
    // persisted enabled=true; the key is the plugin class simpleName (GpuPlugin -> "gpuplugin", HdPlugin -> "hdplugin").
    NSMutableArray<NSString *> *forceDisable = [NSMutableArray array];
    if (!self.routecGpuMode)  { [forceDisable addObject:@"gpuplugin"]; }
    if (!self.routecZoneMode) { [forceDisable addObject:@"hdplugin"]; }
    if (forceDisable.count) {
        [opts addObject:[NSString stringWithFormat:@"-Drunelite.forceDisablePlugins=%@",
                         [forceDisable componentsJoinedByString:@","]]];
    }
    // ...and force-ENABLE the chosen renderer plugin so a synced/switched RuneLite-account profile that DISABLES it
    // (a desktop profile picks a different renderer) can't STOP it mid-session and destroy its GL context — the
    // GpuPlugin.loadScene "unable to map GL buffer" → "Loading - please wait." hang. forceEnable wins over the
    // synced flag (symmetric to forceDisable above); CPU pins neither renderer plugin.
    NSString *forceEnable = self.routecGpuMode ? @"gpuplugin" : (self.routecZoneMode ? @"hdplugin" : nil);
    if (forceEnable) {
        [opts addObject:[NSString stringWithFormat:@"-Drunelite.forceEnablePlugins=%@", forceEnable]];
    }

    // Full-screen landscape: after login the headless client resizes its CTC canvas to this WxH (the
    // gamepack switches to resizable layout and fills it). Login stays at 765x503 (autologin coords).
    if (self.resizeSpec.length) {
        [opts addObject:[NSString stringWithFormat:@"-Drunelite.headless.resize=%@", self.resizeSpec]];
        log([NSString stringWithFormat:@"[jvm] full-screen render target = %@", self.resizeSpec]);
    }

    // GPU Route C scene-render diagnostic: read-only per-frame log (isGpu / registered DrawCallbacks +
    // classloader / viewport / drawScene count) -> .runelite/logs/client.log, to localise the black-3D-scene
    // blocker (zone callbacks never firing) ABOVE the GL bridge. Inert in CPU/L1 mode.
    if (self.routecGpuMode) {
        // Force-enable + start the gpu plugin once the client is in-world (canvas laid out), overriding any persisted
        // runelite.gpuplugin=false and sidestepping the startUp-runs-too-early canvas.isValid() race. Without this the
        // GPU plugin intermittently never initialises (createGLContext never runs) and the engine silently falls back
        // to the CPU renderer. See RouteCGpuStarter. (gpudiag/gpuframedump are dev-only — gpuframedump fills
        // Documents/routec-frames with a PNG per frame — and are left off for the shipping default.)
        [opts addObject:@"-Drunelite.routecgpu=true"];
        log(@"[jvm] base GPU ARMED (routecgpu=true)");
    }

    // W3 GPU Zone B0.5: arm RLHDStarter to load + start the external 117HD plugin once in-world. Same read-only
    // per-frame diagnostics + frame dump as GPU mode, but NOT routecgpu (HdPlugin conflicts=GPU and replaces the
    // base gpu plugin — force-starting base would race it). RLHDStarter forces hd.uiScalingMode=LINEAR +
    // tiledLighting=false before load (the simplest GLSL-ES paths) then loadAndStartPlugin(rs117.hd.HdPlugin).
    if (self.routecZoneMode) {
        // gpudiag/gpuframedump are dev-only (gpuframedump fills Documents/routec-frames with a PNG per frame) —
        // left off for the shipping opt-in 117HD path.
        [opts addObject:@"-Drunelite.routecrlhd=true"];
        // Tell the shared RLHDStarter this is the iOS (Route C / EAGL, full feature port) path, so it applies
        // the full iOS 117HD config (tiled/POM/seeded-tunables/safety) rather than Android's mobile config.
        [opts addObject:@"-Drunelite.gfxIos=true"];
        // (The hub's own "117hd" jar can't collide with our staged rs117.hd.HdPlugin — it's blocked in
        // MobileUiBridge.HUB_BLOCKED.)
        log(@"[jvm] GPU Zone (117HD) ARMED (routecrlhd=true)");
    }

    // Phase 4 sub-goal A — interactive login, purely in-process (no native touch bridge). Map the JX_*
    // launcher handoff from tokens.json (Application Support), then arm HeadlessLogin's two-stage click
    // machine (EULA Accept -> Play Now). Only arms when a usable token set is present, so a build with no
    // tokens.json pushed still does the proven §6.2 login-screen render.
    BOOL autologin = loadJagexTokens(log);
    if (autologin) {
        [opts addObjectsFromArray:@[
            @"-Drunelite.headless.autologin=true",
            @"-Drunelite.headless.autologin.eula=true",
            @"-Drunelite.headless.autologin.eula.point=302,312",  // EULA Accept centre (765x503 device frame)
            @"-Drunelite.headless.autologin.eula.loginIndex=12",  // observed EULA sub-state on device
            @"-Drunelite.headless.autologin.point=382,248",       // Play Now centre (desktop-proven)
            @"-Drunelite.headless.autologin.world=301",           // F2P world (throwaway account)
            @"-Drunelite.headless.autologin.worldAddress=oldschool1.runescape.com",
            // Play Now only crosses LOGIN_SCREEN -> LOGGED_IN; the gamepack then PARKS on the post-login
            // "Welcome to Gielinor / Click here to play" screen with the world NOT yet per-frame-rendered
            // (viewport 0x0, topLevelIf 165). WelcomePlayProbe clicks the real WelcomeScreen.PLAY widget bounds
            // to enter the world — WITHOUT it the engine never drives the scene render (the black-3D-scene
            // blocker; reproduced + resolved on desktop, see ios/dev-tools/gpu-routec/BLACK-SCENE-DIAGNOSIS.md).
            @"-Drunelite.headless.welcomeplay=true",
        ]];
        log(@"[jvm] autologin ARMED: EULA 302,312 (idx 12) -> Play Now 382,248 -> WelcomePlay (enter world), world 301/oldschool1");
    }

    JavaVMOption *vmopts = (JavaVMOption *)calloc(opts.count, sizeof(JavaVMOption));
    for (NSUInteger i = 0; i < opts.count; i++) {
        vmopts[i].optionString = strdup(opts[i].UTF8String);
        vmopts[i].extraInfo = NULL;
        log([NSString stringWithFormat:@"[jvm] opt[%lu] = %@", (unsigned long)i, opts[i]]);
    }
    JavaVMInitArgs vmArgs;
    vmArgs.version = JNI_VERSION_21;
    vmArgs.nOptions = (jint)opts.count;
    vmArgs.options = vmopts;
    vmArgs.ignoreUnrecognized = JNI_FALSE;

    resetSignalHandlers();
    dumpFaultState("pre-clear");   // STRIP AFTER DIAGNOSIS — state inherited from this (maybe WebKit-poisoned) session

    // W1 P3 §6.2 — Amethyst app-side JIT parity (the proven path on THIS device).
    // The Amethyst CDN jre21 is byte-identical to ours (size+last-modified match the pin),
    // i.e. Amethyst runs Minecraft's heavier JIT on this SAME libjvm with no crash — so the
    // §6.2 SIGSEGV is NOT a libjvm defect, it's our process setup. JavaLauncher.m clears the
    // task's EXC_BAD_ACCESS Mach exception port (port 0 = default) before bringing up the VM:
    // HotSpot deliberately faults SIGSEGV for implicit null checks / safepoint polls in compiled
    // code and catches them in its OWN handler. With StikDebug attached, that Mach exception is
    // instead delivered to the debugger (and our map-on-fault net can swallow it without
    // re-delivering), so HotSpot's null-check slow path never runs → execution continues with a
    // garbage register → the SEGV_ACCERR we saw in a fresh tier-3 nmethod (x0 = bogus oop).
    // Clearing the bad-access port lets those faults fall through to HotSpot's sigaction handler.
    // brk #0x69 is EXC_BREAKPOINT (a DIFFERENT mask) — left with the debugger, so the 64 MB
    // code-cache reservation is still serviced by runelite-jit.js.
    //
    // SAME-SESSION LOGIN FIX: when the login WKWebView is resident, WebKit displaces the debugger on the
    // task BREAKPOINT port → the brk #0x69 is never serviced → SIGTRAP in CodeCache::initialize. Re-point
    // BREAKPOINT back at the debugger (which still owns BAD_ACCESS) BEFORE we clear BAD_ACCESS below.
    restoreBreakpointPortToDebugger(log);

    kern_return_t kr = task_set_exception_ports(
        mach_task_self(), EXC_MASK_BAD_ACCESS, MACH_PORT_NULL,
        EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    log([NSString stringWithFormat:@"[jvm] cleared EXC_MASK_BAD_ACCESS port (Amethyst parity) kr=%d", kr]);

    // Belt-and-braces for the post-login case: a task-level clear leaves THREAD-level handlers intact, so
    // also drop any bad-access port on this jvm-main thread. No-op on a clean launch; the fix if the
    // diagnostics show WebKit's JavaScriptCore left a thread-level port. (STRIP/keep per diagnosis.)
    thread_t jvmThread = mach_thread_self();
    kern_return_t krt = thread_set_exception_ports(jvmThread, EXC_MASK_BAD_ACCESS, MACH_PORT_NULL,
                                                   EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    mach_port_deallocate(mach_task_self(), jvmThread);
    log([NSString stringWithFormat:@"[jvm] cleared thread EXC_MASK_BAD_ACCESS port krt=%d", krt]);

    dumpFaultState("post-clear");   // STRIP AFTER DIAGNOSIS — did the clears stick?
    startMemWatchdog();             // STRIP AFTER DIAGNOSIS — sample jetsam headroom across RuneLite init

    log(@"[jvm] JNI_CreateJavaVM (HotSpot generates its template interpreter now)…");

    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint rc = JNI_CreateJavaVM(&vm, (void **)&env, &vmArgs);
    if (rc != JNI_OK || !vm || !env) { log([NSString stringWithFormat:@"[jvm] FATAL JNI_CreateJavaVM rc=%d", rc]); return -14; }
    // Publish the VM so the main thread's live-blit + touch bridge can attach into it (atomic store —
    // the main thread loads it with atomic_load in ensureBridge).
    atomic_store(&gVM, vm);
    log(@"[jvm] JavaVM created — HotSpot is up. Running probes…");
    dumpFaultState("post-createvm");   // STRIP AFTER DIAGNOSIS — HotSpot's own SIGSEGV handler is installed now

    if (kMuiNativeColorProbe) { runMuiNativeColorProbe(log); }  // STRIP AFTER DEVICE CONFIRM

    // W1 P3 §6.1 device smoke: AwtSmoke activates CTC via UnsafePokeActivation (§6.0, device-GREEN),
    // then realizes a Frame+Canvas and asserts Canvas.getGraphics() non-null + CTC pixel/font readback.
    // Greppable verdicts in jvm-stdio.log:
    //   "AWT-ACTIVATION = CTC ACTIVE"  (§6.0 still holds)
    //   "AWT-SMOKE = CANVAS+CTC OK"    -> §6.1 green on device, proceed to the real-RuneLite buffer smoke
    //   "AWT-SMOKE = FAILED"           -> read the per-gate FAIL line (Canvas peer / getGraphics / fonts)
    // The PNG (args[0]) lands in Documents for an eyeball A/B (pull via devicectl).
    // Earlier probe sets: UnsafePokeActivation alone (§6.0); JitProbe/Bench/GlyphSmoke (Phase-1).
    // W1 P3 §6.2: boot the REAL RuneLite headless client under UnsafePoke CTC, capture
    // mainBufferProvider. Greppable verdicts in jvm-stdio.log:
    //   "[boot] graphicsenv = …CTCGraphicsEnvironment" + "[headless] … displayable=true"
    //   "[headless-capture] … nullGraphics=0" + "wrote frame-LOGIN_SCREEN-*.png" -> §6.2 login render OK
    // PNGs land in Documents/rl-capture/. Earlier entrypoints: AwtSmoke (§6.1), UnsafePokeActivation
    // (§6.0), JitProbe/Bench/GlyphSmoke (Phase-1).
    // Register the JNI GL bridge natives onto the facade classes (GLALL / AWTContext / GL) BEFORE the client
    // runs. "Renderers as plugins": register ALWAYS (not just when a GPU mode is pre-selected), so whichever
    // renderer the user activates from the panel — base GPU, or 117HD which adds the zone delta — has its GL
    // bridge ready. The registration is inert until a renderer plugin actually calls into it. L1 mode uses the
    // routec-l1.jar facade ALONE (no shaded/rlhd jar), so it gets only the base natives. Non-fatal: log + clear.
    {
        jint rr = RouteC_registerGLNatives(env);
        if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); }
        log([NSString stringWithFormat:@"[jvm] RouteC_registerGLNatives rc=%d (%@)", rr,
            rr == 0 ? @"OK" : @"ERR — facade classes not found"]);
        // The RLHD facade-delta natives (disjoint method sets on the same GLALL + MemoryUtil) need the rlhd jar
        // on the classpath — always present except in the L1 probe. Base 85 must register first (above).
        if (!self.routecL1Mode) {
            jint zr = RouteC_registerZoneNatives(env);
            if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); }
            log([NSString stringWithFormat:@"[jvm] RouteC_registerZoneNatives rc=%d (%@)", zr,
                zr == 0 ? @"OK" : @"ERR — GLALL/MemoryUtil facade not found"]);
        }
    }

    if (self.routecL1Mode) {
        callMain(env, "RouteCL1Probe", @[], log);   // GPU Route C L1 kill-test (verdict -> jvm-stdio.log)
    } else {
        callMain(env, "DeviceHeadlessBoot", @[], log);
    }

    // QA-P1-01: null gVM BEFORE DestroyJavaVM, not after. Every facade call snapshots gVM through its ensure*
    // gate; clearing it first means any concurrent (main-thread) facade call sees the VM as gone and bails,
    // instead of racing a JNI call into a VM that is mid-destroy. DestroyJavaVM takes the local vm pointer (not
    // gVM), so clearing gVM first is safe. (In practice this blocks forever on the engine's non-daemon threads,
    // so these lines stay effectively unreachable and the session keeps running on the live VM + warm cache; the
    // ordering only matters if a clean shutdown ever lets DestroyJavaVM return.)
    atomic_store(&gVM, NULL);
    (*vm)->DestroyJavaVM(vm);
    log(@"[jvm] DestroyJavaVM done.");
    return 0;
}

// ---- Phase 4 (W3) sub-goal B: reverse-JNI bridge (main-thread API) ---------------------------------

+ (BOOL)bridgeReady {
    return ensureBridge();
}

// Drop the warm reverse-JNI facade cache after the VM is gone (post-DestroyJavaVM). Pure C-pointer reset that
// makes NO JNI calls — the VM and all its global refs died with DestroyJavaVM, so there is nothing to (and no
// env to) DeleteGlobalRef against. Nulling the 8 facade class refs + gMainEnv is sufficient: every ensure*
// short-circuits on its own class ref, so a re-created VM re-resolves each facade (and its method ids) from
// scratch — no stale gMid* is ever read before its class ref is re-resolved. Call on the main thread.
+ (void)bridgeInvalidate {
    gMainEnv = NULL;
    gBridgeClass = NULL;
    gChromeClass = NULL;
    gMenuPeekClass = NULL;
    gHudClass = NULL;
    gVeneerClass = NULL;
    gMuiClass = NULL;
    gQhClass = NULL;
    gWsClass = NULL;
}

// Monotonic counter that advances each time an in-game left tap resolved to an interactable (hit or snap),
// not a bare walk. The shell polls this and fires a light haptic when it changes. 0 if the jar predates it.
+ (int)interactTapSeq {
    if (!ensureBridge() || !gMidInteractSeq) return 0;
    JNIEnv *env = gMainEnv;
    jint v = (*env)->CallStaticIntMethod(env, gBridgeClass, gMidInteractSeq);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.interactTapSeq"); return 0; }
    return (int)v;
}

+ (UIImage *)latestFrame {
    if (!ensureBridge()) return nil;
    JNIEnv *env = gMainEnv;

    // Skip the costly readback + CGImage rebuild when the engine hasn't composited a new frame since the
    // last tick (the display refreshes up to 120 Hz; the engine composites at ~50 fps). Return the cached
    // UIImage so the on-screen view keeps showing the current frame at no per-tick cost.
    static UIImage *cachedImage = nil;
    static jint lastSeq = -1;
    jint seq = (*env)->CallStaticIntMethod(env, gBridgeClass, gMidSeq);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.latestFrame"); return nil; }
    if (seq == lastSeq && cachedImage != nil) {
        return cachedImage;
    }

    jint w = (*env)->CallStaticIntMethod(env, gBridgeClass, gMidW);
    jint h = (*env)->CallStaticIntMethod(env, gBridgeClass, gMidH);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.latestFrame"); return nil; }
    if (w <= 0 || h <= 0) return nil;

    jintArray arr = (jintArray)(*env)->CallStaticObjectMethod(env, gBridgeClass, gMidPixels);
    if (!arr || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.latestFrame"); return nil; }
    jsize len = (*env)->GetArrayLength(env, arr);
    NSUInteger need = (NSUInteger)w * (NSUInteger)h;
    if ((NSUInteger)len < need) { (*env)->DeleteLocalRef(env, arr); return nil; }

    // PERF-1: rotating scratch ring backing the CGImage DIRECTLY — the old path copied the frame twice
    // (Java array -> scratch, scratch -> CFData). Depth 3 means a buffer isn't rewritten until two more
    // frames have been fetched, which outlives every consumer: the CA commit reads the bytes this tick,
    // and by the time a slot cycles back its image has left the screen. (A canvas resize frees the
    // too-small slot on reuse — three frames stale by then.) No CFData duplicate, one copy per frame.
    static uint32_t *bufs[3] = {NULL, NULL, NULL};
    static NSUInteger bufCounts[3] = {0, 0, 0};
    static int bufIdx = 0;
    bufIdx = (bufIdx + 1) % 3;
    if (bufCounts[bufIdx] < need) {
        free(bufs[bufIdx]);
        bufs[bufIdx] = (uint32_t *)malloc(need * sizeof(uint32_t));
        bufCounts[bufIdx] = bufs[bufIdx] ? need : 0;
    }
    uint32_t *buf = bufs[bufIdx];
    if (!buf) { (*env)->DeleteLocalRef(env, arr); return nil; }
    (*env)->GetIntArrayRegion(env, arr, 0, (jsize)need, (jint *)buf);
    (*env)->DeleteLocalRef(env, arr);

    // NULL release callback: the provider borrows the static ring slot, it never owns/frees it.
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, buf, need * sizeof(uint32_t), NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    // The engine buffer is TYPE_INT_RGB: packed 0x00RRGGBB ints. On little-endian arm64, reading each
    // 32-bit word native-endian with alpha-skip-first yields [skip],R,G,B — the correct opaque pixel.
    CGBitmapInfo info = (CGBitmapInfo)(kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef cg = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs, info,
                                  provider, NULL, false, kCGRenderingIntentDefault);
    UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    if (img) { cachedImage = img; lastSeq = seq; }   // remember for the skip-unchanged fast path above
    return img;
}

// Picture-in-Picture frame feed: the same JavaBridge frame as latestFrame, but delivered as a 32BGRA
// CVPixelBuffer (what AVSampleBufferDisplayLayer consumes). The engine's TYPE_INT_RGB ints (0x00RRGGBB)
// already lay out as B,G,R,[junk] on little-endian arm64, so the rows copy straight in and only the alpha
// byte needs stamping opaque. Seq-gated per CALLER (ioSeq), independent of latestFrame's own gate.
+ (CVPixelBufferRef)copyFramePixelBufferSinceSeq:(int32_t *)ioSeq {
    if (!ioSeq || !ensureBridge()) return NULL;
    JNIEnv *env = gMainEnv;

    jint seq = (*env)->CallStaticIntMethod(env, gBridgeClass, gMidSeq);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.copyFramePixelBuffer"); return NULL; }
    if (seq == *ioSeq) return NULL;   // nothing composited since the caller's last fetch

    jint w = (*env)->CallStaticIntMethod(env, gBridgeClass, gMidW);
    jint h = (*env)->CallStaticIntMethod(env, gBridgeClass, gMidH);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.copyFramePixelBuffer"); return NULL; }
    if (w <= 0 || h <= 0) return NULL;

    jintArray arr = (jintArray)(*env)->CallStaticObjectMethod(env, gBridgeClass, gMidPixels);
    if (!arr || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.copyFramePixelBuffer"); return NULL; }
    jsize len = (*env)->GetArrayLength(env, arr);
    NSUInteger need = (NSUInteger)w * (NSUInteger)h;
    if ((NSUInteger)len < need) { (*env)->DeleteLocalRef(env, arr); return NULL; }

    // Recycling pool (IOSurface-backed, what the video pipeline wants); rebuilt if the canvas resizes.
    static CVPixelBufferPoolRef pool = NULL;
    static jint poolW = 0, poolH = 0;
    if (!pool || poolW != w || poolH != h) {
        if (pool) { CVPixelBufferPoolRelease(pool); pool = NULL; }
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey : @(w),
            (id)kCVPixelBufferHeightKey : @(h),
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool) != kCVReturnSuccess) {
            pool = NULL;
        }
        poolW = w; poolH = h;
    }
    CVPixelBufferRef pb = NULL;
    if (pool) CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pb);
    if (!pb) { (*env)->DeleteLocalRef(env, arr); return NULL; }

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
    size_t stride = CVPixelBufferGetBytesPerRow(pb);
    // PERF-1: one fused pass — read the Java pixels via a critical (pinned, no-copy) pointer and stamp the
    // alpha byte during the row copy, instead of GetIntArrayRegion (copy 1) + a second full-buffer OR pass
    // (copy 2's cost). The critical window holds only this loop — no JNI or blocking calls inside.
    jint *src = (jint *)(*env)->GetPrimitiveArrayCritical(env, arr, NULL);
    if (!src) {
        bridgeNoteClear(env, "JVMLauncher.copyFramePixelBuffer");
        CVPixelBufferUnlockBaseAddress(pb, 0);
        CVPixelBufferRelease(pb);
        (*env)->DeleteLocalRef(env, arr);
        return NULL;
    }
    for (jint row = 0; row < h; row++) {
        const jint *srow = src + (size_t)row * w;
        uint32_t *drow = (uint32_t *)(base + (size_t)row * stride);
        for (jint i = 0; i < w; i++)
            drow[i] = ((uint32_t)srow[i]) | 0xFF000000u; // copy + opaque alpha
    }
    (*env)->ReleasePrimitiveArrayCritical(env, arr, src, JNI_ABORT);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    (*env)->DeleteLocalRef(env, arr);

    *ioSeq = seq;
    return pb;   // +1 — caller releases
}

+ (void)postTouchType:(int)type x:(int)x y:(int)y button:(int)button {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidTouch,
                                 (jint)type, (jint)x, (jint)y, (jint)button);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postTouchType"); }
}

// DRAG-1: the live inventory item-grid bounds in canvas px, or CGRectNull when the inventory isn't visible
// (so the caller leaves a one-finger drag as a camera pan). Reads JavaBridge.getInventoryBounds() ([x,y,w,h]).
+ (CGRect)inventoryCanvasBounds {
    if (!ensureBridge() || !gMidInvBounds) return CGRectNull;
    JNIEnv *env = gMainEnv;
    jintArray arr = (jintArray)(*env)->CallStaticObjectMethod(env, gBridgeClass, gMidInvBounds);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.inventoryCanvasBounds"); return CGRectNull; }
    if (!arr) return CGRectNull;
    CGRect r = CGRectNull;
    if ((*env)->GetArrayLength(env, arr) >= 4) {
        jint v[4];
        (*env)->GetIntArrayRegion(env, arr, 0, 4, v);
        if (v[2] > 0 && v[3] > 0) r = CGRectMake(v[0], v[1], v[2], v[3]);
    }
    (*env)->DeleteLocalRef(env, arr);
    return r;
}

+ (BOOL)engineScrollableAtX:(int)x y:(int)y {
    if (!ensureBridge() || !gMidEngineScroll) return NO;
    JNIEnv *env = gMainEnv;
    jboolean r = (*env)->CallStaticBooleanMethod(env, gBridgeClass, gMidEngineScroll, (jint)x, (jint)y);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.engineScrollableAt"); return NO; }
    return r ? YES : NO;
}

+ (void)postClickX:(int)x y:(int)y button:(int)button {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidClick, (jint)x, (jint)y, (jint)button);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postClick"); }
}

+ (void)postClickPreciseX:(int)x y:(int)y button:(int)button {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidClickPrecise, (jint)x, (jint)y, (jint)button);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postClickPrecise"); }
}

// Select an open-menu row at (x,y) AND clear the parked hover afterwards (avoids the "cursor stuck on the
// stairs" bug). Falls back to a plain precise click if the jar predates selectMenuPoint.
+ (void)postMenuSelectX:(int)x y:(int)y {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    if (gMidMenuSelect) {
        (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidMenuSelect, (jint)x, (jint)y);
    } else {
        (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidClickPrecise, (jint)x, (jint)y, (jint)1);
    }
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postMenuSelect"); }
}

// MENU-1: commit a drilled-in right-click submenu child by (parent display index, child index) — the native
// menu resolved these from the published snapshot; JavaBridge re-walks the live (frozen) menu tree and runs the
// child's RuneLite onClick (or menuAction). No-op on an older jar without invokeMenuEntry.
+ (void)invokeMenuEntryParent:(int)parentDisplayIndex child:(int)childIndex {
    if (!ensureBridge() || !gMidInvokeMenu) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidInvokeMenu,
                                 (jint)parentDisplayIndex, (jint)childIndex);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.invokeMenuEntry"); }
}

// KEY-1: fire a plugin's configured action-hotkey by synthesizing its key chord (AWT extended keyCode + the
// InputEvent.*_DOWN_MASK modifier bits). No-op on an older jar without onKeybind.
+ (void)onKeybindKeyCode:(int)keyCode modifiers:(int)modifiers {
    if (!ensureBridge() || !gMidKeybind) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidKeybind, (jint)keyCode, (jint)modifiers);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.onKeybind"); }
}

+ (void)postMoveX:(int)x y:(int)y {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidMove, (jint)x, (jint)y);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postMove"); }
}

+ (void)postWheelX:(int)x y:(int)y rotation:(int)rotation {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidWheel, (jint)x, (jint)y, (jint)rotation);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postWheel"); }
}

+ (void)postCameraDx:(int)dx dy:(int)dy {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidCamera, (jint)dx, (jint)dy);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postCamera"); }
}

+ (void)setEngineMenuRenderSuppressed:(BOOL)suppressed {
    if (!ensureBridge() || !gMidMenuSuppress) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidMenuSuppress,
                                 (jboolean)(suppressed ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.setEngineMenuRenderSuppressed"); }
}

+ (void)postClearHover {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidClearHover);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postClearHover"); }
}

+ (void)postKeepAlive {
    if (!ensureBridge() || !gMidKeepAlive) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidKeepAlive);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postKeepAlive"); }
}

+ (void)postText:(NSString *)text {
    if (!ensureBridge() || text.length == 0) return;
    JNIEnv *env = gMainEnv;
    jstring js = (*env)->NewStringUTF(env, text.UTF8String);
    if (js) {
        (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidText, js);
        if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postText"); }
        (*env)->DeleteLocalRef(env, js);
    }
}

+ (void)postKeyStroke:(int)awtKeyCode {
    if (!ensureBridge()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidKey, (jint)awtKeyCode);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postKeyStroke"); }
}

+ (void)postShiftHeld:(BOOL)held {
    if (!ensureBridge() || !gMidShiftHeld) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidShiftHeld, (jboolean)(held ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.postShiftHeld"); }
}

+ (void)postCtrlHeld:(BOOL)held {
    if (!ensureBridge() || !gMidCtrlHeld)
        return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidCtrlHeld, (jboolean)(held ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) {
        bridgeNoteClear(env, "JVMLauncher.postCtrlHeld");
    }
}

+ (void)postAltHeld:(BOOL)held {
    if (!ensureBridge() || !gMidAltHeld)
        return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gBridgeClass, gMidAltHeld, (jboolean)(held ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) {
        bridgeNoteClear(env, "JVMLauncher.postAltHeld");
    }
}

+ (BOOL)textInputOpen {
    if (!ensureBridge()) return NO;
    JNIEnv *env = gMainEnv;
    jboolean r = (*env)->CallStaticBooleanMethod(env, gBridgeClass, gMidInputOpen);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.textInputOpen"); return NO; }
    return r == JNI_TRUE;
}

// Direct-present reveal gate: YES once the world geometry is uploaded (JavaBridge.presentReady). Returns YES if
// the bridge/method isn't available so it can never permanently block revealing the GPU layer.
+ (BOOL)sceneWarmedUp {
    if (!gMidWarmed || !ensureBridge()) return YES;
    JNIEnv *env = gMainEnv;
    jboolean r = (*env)->CallStaticBooleanMethod(env, gBridgeClass, gMidWarmed);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.sceneWarmedUp"); return YES; }
    return r == JNI_TRUE;
}

+ (NSString *)chromeSnapshot {
    if (!ensureChrome()) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gChromeClass, gMidChromeSnap);
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.chromeSnapshot"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

+ (NSString *)menuPeekSnapshot {
    if (!ensureMenuPeek()) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gMenuPeekClass, gMidMenuPeekSnap);
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.menuPeekSnapshot"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

+ (NSString *)hudSnapshot {
    if (!ensureHud()) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gHudClass, gMidHudSnap);
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.hudSnapshot"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

+ (int)hudSeq {
    if (!ensureHud()) return 0;
    JNIEnv *env = gMainEnv;
    jint s = (*env)->CallStaticIntMethod(env, gHudClass, gMidHudSeq);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.hudSeq"); return 0; }
    return (int)s;
}

+ (void)setEngineChatHidden:(BOOL)hidden {
    if (!ensureVeneer()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidSetChatHidden, (jboolean)(hidden ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.setEngineChatHidden"); }
}

+ (void)relocateEngineChatX:(int)x y:(int)y transparent:(BOOL)transparent {
    if (!ensureVeneer()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidRelocateChat,
                                 (jint)x, (jint)y, (jboolean)(transparent ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.relocateEngineChat"); }
}

+ (void)relocateEngineMinimapX:(int)x y:(int)y {
    if (!ensureVeneer()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidRelocateMinimap, (jint)x, (jint)y);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.relocateEngineMinimap"); }
}

+ (void)setEngineMinimapScale:(int)scalePct {
    if (!ensureVeneer() || !gMidSetMinimapScale) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidSetMinimapScale, (jint)scalePct);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.setEngineMinimapScale"); }
}

+ (void)relocateEngineSidePanelX:(int)x y:(int)y {
    if (!ensureVeneer()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidRelocateSide, (jint)x, (jint)y);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.relocateEngineSidePanel"); }
}

+ (void)openEngineTab:(int)tabIndex {
    if (!ensureVeneer()) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native 2-col grid tab open posts no canvas event
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidOpenTab, (jint)tabIndex);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.openEngineTab"); }
}

+ (void)setEngineStonesHidden:(BOOL)hidden {
    if (!ensureVeneer()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidSetStonesHidden, (jboolean)(hidden ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.setEngineStonesHidden"); }
}

+ (void)setEngineChatTabRowHeight:(int)canvasPx {
    if (!ensureVeneer() || !gMidSetChatRowH) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidSetChatRowH, (jint)canvasPx);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.setEngineChatTabRowHeight"); }
}

+ (void)setEngineChatAreaWidth:(int)canvasPx {
    if (!ensureVeneer() || !gMidSetChatAreaW) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidSetChatAreaW, (jint)canvasPx);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.setEngineChatAreaWidth"); }
}

+ (void)setEngineOverlaySafeInsetsL:(int)l t:(int)t r:(int)r b:(int)b {
    if (!ensureVeneer() || !gMidSetOverlayInsets) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidSetOverlayInsets, (jint)l, (jint)t, (jint)r, (jint)b);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.setEngineOverlaySafeInsets"); }
}

+ (void)scrollEngineChat:(int)deltaCanvasPx {
    if (!ensureVeneer() || !gMidScrollChat) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidScrollChat, (jint)deltaCanvasPx);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.scrollEngineChat"); }
}

+ (void)switchEngineChatTab:(int)index {
    if (!ensureVeneer() || !gMidSwitchChatTab) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native chat-tab switch posts no canvas event
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidSwitchChatTab, (jint)index);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.switchEngineChatTab"); }
}

+ (void)setEngineChatCollapsed:(BOOL)collapsed {
    if (!ensureVeneer() || !gMidSetChatCollapsed) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native chat collapse/expand posts no canvas event
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidSetChatCollapsed, (jboolean)(collapsed ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.setEngineChatCollapsed"); }
}

+ (NSString *)chatSnapshot {
    if (!ensureVeneer() || !gMidGetChatSnap) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gVeneerClass, gMidGetChatSnap);
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.chatSnapshot"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

// The real OSRS chrome sprites (tab stones, 14 tab glyphs, chat-tab backgrounds) the engine rendered from the live
// game cache, as JSON (base64 ARGB). The shell builds its native HUD from these instead of bundling interface art.
// "" until captured (a few ticks post-login); nil on an older bundle without the method.
+ (NSString *)tabSprites {
    if (!ensureVeneer() || !gMidTabSprites) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gVeneerClass, gMidTabSprites);
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.tabSprites"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

// The engine can't raster a relocated chatbox, so chat-at-top draws the MESSAGE lines natively. This returns the
// live per-active-tab message model (escaped JSON, colour runs pre-parsed) the ViewController renders. nil if the
// veneer/method is absent (older bundle).
+ (NSString *)chatLines {
    if (!ensureVeneer() || !gMidGetChatLines) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gVeneerClass, gMidGetChatLines);
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.chatLines"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

// The open chatbox dialogue as JSON (HudVeneerBridge.getDialogueJson), or nil/"{}" when none. The shell renders
// it natively (opaque parchment, head cutout); nil on an older bundle without the method.
+ (NSString *)dialogueJson {
    if (!ensureVeneer() || !gMidGetDialogue) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gVeneerClass, gMidGetDialogue);
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.dialogueJson"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

+ (void)panEngineMapDx:(int)dx dy:(int)dy {
    if (!ensureVeneer() || !gMidPanMap) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gVeneerClass, gMidPanMap, (jint)dx, (jint)dy);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.panEngineMap"); }
}

+ (NSString *)mapSnapshot {
    if (!ensureVeneer() || !gMidGetMapSnap) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gVeneerClass, gMidGetMapSnap);
    if (!js || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mapSnapshot"); return nil; }
    const char *utf = (*env)->GetStringUTFChars(env, js, NULL);
    NSString *out = utf ? [NSString stringWithUTF8String:utf] : nil;
    if (utf) (*env)->ReleaseStringUTFChars(env, js, utf);
    (*env)->DeleteLocalRef(env, js);
    return out;
}

// ---- Phase 6 (W3): plugin-management + config panel facade wrappers --------------------------------

+ (NSString *)mobilePlugins {
    if (!ensureMui()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiList));
}

+ (NSString *)mobilePluginConfig:(NSString *)group {
    if (!ensureMui() || group == nil) return nil;
    JNIEnv *env = gMainEnv;
    jstring jg = (*env)->NewStringUTF(env, group.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiGetCfg, jg));
    (*env)->DeleteLocalRef(env, jg);
    return out;
}

+ (NSString *)mobileSetPluginEnabled:(NSString *)className enabled:(BOOL)enabled {
    if (!ensureMui() || className == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native plugin toggle posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jc = (*env)->NewStringUTF(env, className.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiSetEnabled,
                                                                             jc, (jboolean)(enabled ? JNI_TRUE : JNI_FALSE)));
    (*env)->DeleteLocalRef(env, jc);
    return out;
}

+ (NSString *)mobileSetConfigGroup:(NSString *)group key:(NSString *)key value:(NSString *)value {
    if (!ensureMui() || group == nil || key == nil || value == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native config write posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jg = (*env)->NewStringUTF(env, group.UTF8String);
    jstring jk = (*env)->NewStringUTF(env, key.UTF8String);
    jstring jv = (*env)->NewStringUTF(env, value.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiSetCfg, jg, jk, jv));
    (*env)->DeleteLocalRef(env, jg); (*env)->DeleteLocalRef(env, jk); (*env)->DeleteLocalRef(env, jv);
    return out;
}

+ (NSString *)mobileResetConfigGroup:(NSString *)group key:(NSString *)key {
    if (!ensureMui() || group == nil || key == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native config reset posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jg = (*env)->NewStringUTF(env, group.UTF8String);
    jstring jk = (*env)->NewStringUTF(env, key.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiResetCfg, jg, jk));
    (*env)->DeleteLocalRef(env, jg); (*env)->DeleteLocalRef(env, jk);
    return out;
}

// Whole-plugin reset (CFG-10): reapply group defaults + plugin.resetConfiguration().
+ (NSString *)mobileResetPluginConfig:(NSString *)group {
    if (!ensureMui() || !gMuiResetPlugin || group == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native whole-plugin config reset posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jg = (*env)->NewStringUTF(env, group.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiResetPlugin, jg));
    (*env)->DeleteLocalRef(env, jg);
    return out;
}

// Fully-seeded default Notification JSON (NOTIF-2): the base for a per-notification sub-editor.
+ (NSString *)mobileNotificationDefaults {
    if (!ensureMui() || !gMuiNotifDefaults) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiNotifDefaults));
}

// ---- Panel input P0 (PANEL-1/2): typing, key, right-click, wheel, hover into the active rendered panel -------

+ (BOOL)mobilePanelTextActive {
    if (!ensureMui() || !gMuiPanelTextActive) return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gMuiClass, gMuiPanelTextActive);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobilePanelTextActive"); return NO; }
    return v == JNI_TRUE;
}

+ (NSString *)mobilePanelText {
    if (!ensureMui() || !gMuiPanelTextGet) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPanelTextGet));
}

+ (NSString *)mobileSetPanelText:(NSString *)text {
    if (!ensureMui() || !gMuiPanelText || text == nil) return nil;
    JNIEnv *env = gMainEnv;
    jstring jt = (*env)->NewStringUTF(env, text.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPanelText, jt));
    (*env)->DeleteLocalRef(env, jt);
    return out;
}

+ (NSString *)mobilePanelKey:(int)vk {
    if (!ensureMui() || !gMuiPanelKey) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPanelKey, (jint)vk));
}

+ (NSString *)mobilePanelLongPressX:(int)x y:(int)y {
    if (!ensureMui() || !gMuiPanelLongPress) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPanelLongPress, (jint)x, (jint)y));
}

+ (NSString *)mobilePanelWheelX:(int)x y:(int)y rotation:(int)rotation {
    if (!ensureMui() || !gMuiPanelWheel) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPanelWheel, (jint)x, (jint)y, (jint)rotation));
}

+ (NSString *)mobilePanelMoveX:(int)x y:(int)y {
    if (!ensureMui() || !gMuiPanelMove) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPanelMove, (jint)x, (jint)y));
}

+ (long long)mobileUiSeq {
    if (!ensureMui()) return 0;
    JNIEnv *env = gMainEnv;
    jlong v = (*env)->CallStaticLongMethod(env, gMuiClass, gMuiSeq);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobileUiSeq"); return 0; }
    return (long long)v;
}

+ (NSString *)mobileNextNotification {
    if (!ensureMui() || !gMuiNextNotif) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiNextNotif));
}

// SHOT-2: the next auto-screenshot's sandbox PNG path, or nil. The shell reads the file and saves it to Photos.
+ (NSString *)mobileNextScreenshot {
    if (!ensureMui() || !gMuiNextShot) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiNextShot));
}

+ (NSString *)mobileNextLink {
    if (!ensureMui() || !gMuiNextLink) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiNextLink));
}

+ (NSString *)mobileSetPinned:(NSString *)pluginName pinned:(BOOL)pinned {
    if (!ensureMui() || !gMuiSetPinned || pluginName == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native plugin pin/unpin posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jn = (*env)->NewStringUTF(env, pluginName.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiSetPinned,
                                                                             jn, (jboolean)(pinned ? JNI_TRUE : JNI_FALSE)));
    (*env)->DeleteLocalRef(env, jn);
    return out;
}

+ (NSString *)mobileHubState {
    if (!ensureMui() || !gMuiHubState) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiHubState));
}

// KEY-1: the curated fireable plugin action-hotkeys + their current bindings, as JSON
// [{group,key,label,keyCode,mods,bind}]. nil on an older jar without the method.
+ (NSString *)mobileHotkeyActions {
    if (!ensureMui() || !gMuiHotkeyActions) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiHotkeyActions));
}

// KEY-1: fire a plugin action-hotkey by (config group, key) — the bridge reads the live Keybind and synthesizes
// its chord. No-op on an older jar without the method.
+ (void)mobileFireHotkeyGroup:(NSString *)group key:(NSString *)key {
    if (!ensureMui() || !gMuiFireHotkey || group == nil || key == nil) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native hotkey fire posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jg = (*env)->NewStringUTF(env, group.UTF8String);
    jstring jk = (*env)->NewStringUTF(env, key.UTF8String);
    (*env)->CallStaticVoidMethod(env, gMuiClass, gMuiFireHotkey, jg, jk);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobileFireHotkeyGroup"); }
    (*env)->DeleteLocalRef(env, jg);
    (*env)->DeleteLocalRef(env, jk);
}

+ (NSString *)mobilePollEventsSince:(long long)sinceSeq {
    if (!ensureMui()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPoll, (jlong)sinceSeq));
}

+ (long long)mobileProcessedWriteId {
    if (!ensureMui()) return 0;
    JNIEnv *env = gMainEnv;
    jlong v = (*env)->CallStaticLongMethod(env, gMuiClass, gMuiProcessed);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobileProcessedWriteId"); return 0; }
    return (long long)v;
}

// Fire-and-forget config flush for the iOS UI paths (panel/overlay/config close, app background). gMuiFlush is
// bound to Java flushConfigQueued (QA-P1-03), so this enqueues the fsync on the client thread and returns at once
// without stalling the main thread.
+ (void)mobileFlushConfig {
    if (!ensureMui()) return;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiFlush);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobileFlushConfig"); return; }
    if (js) (*env)->DeleteLocalRef(env, js);
}

+ (NSString *)mobileHubManifest {
    if (!ensureMui()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiHubManifest));
}

+ (NSString *)mobileHubInstall:(NSString *)internalName uninstall:(BOOL)uninstall {
    if (!ensureMui() || internalName == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native hub install/uninstall posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jn = (*env)->NewStringUTF(env, internalName.UTF8String);
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass,
                                                         uninstall ? gMuiHubUninstall : gMuiHubInstall, jn);
    NSString *out = jstringToNS(env, js);
    (*env)->DeleteLocalRef(env, jn);
    return out;
}

// ---- Plugin side-panels (toolbar + embedded-Swing panel surface) -----------------------------------

+ (NSString *)mobileListPanels {
    if (!ensureMui()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiListPanels));
}

// Native XP Tracker panel (§3.4): availability gate + the live per-skill session JSON. nil/NO on an older jar.
+ (BOOL)xpTrackerAvailable {
    if (!ensureMui() || !gMuiXpAvail) return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gMuiClass, gMuiXpAvail);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.xpTrackerAvailable"); return NO; }
    return v ? YES : NO;
}

+ (NSString *)xpTrackerJson {
    if (!ensureMui() || !gMuiXpJson) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiXpJson));
}

// Native Notes panel (§3.4): availability + read/write the single note string. nil/NO on an older jar.
+ (BOOL)notesAvailable {
    if (!ensureMui() || !gMuiNotesAvail) return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gMuiClass, gMuiNotesAvail);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.notesAvailable"); return NO; }
    return v ? YES : NO;
}

+ (NSString *)notesGet {
    if (!ensureMui() || !gMuiNotesGet) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiNotesGet));
}

+ (void)notesSet:(NSString *)text {
    if (!ensureMui() || !gMuiNotesSet || text == nil) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native notes write posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring js = (*env)->NewStringUTF(env, text.UTF8String ?: "");
    (void)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiNotesSet, js);
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.notesSet");
    if (js) (*env)->DeleteLocalRef(env, js);
}

// Native Grand Exchange panel (§3.4): availability + ui-open gate + offer/history JSON + live item search.
// nil/NO on an older jar (the bridge methods are looked up optionally).
+ (BOOL)geAvailable {
    if (!ensureMui() || !gMuiGeAvail) return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gMuiClass, gMuiGeAvail);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.geAvailable"); return NO; }
    return v ? YES : NO;
}

+ (void)geSetUiOpen:(BOOL)open {
    if (!ensureMui() || !gMuiGeSetUi) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: opening the native GE screen posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiGeSetUi, (jboolean)(open ? JNI_TRUE : JNI_FALSE));
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.geSetUiOpen"); return; }
    if (js) (*env)->DeleteLocalRef(env, js);
}

+ (NSString *)geJson {
    if (!ensureMui() || !gMuiGeJson) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiGeJson));
}

+ (NSString *)geSearch:(NSString *)query {
    if (!ensureMui() || !gMuiGeSearch || query == nil) return nil;
    JNIEnv *env = gMainEnv;
    jstring js = (*env)->NewStringUTF(env, query.UTF8String ?: "");
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiGeSearch, js));
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.geSearch"); out = nil; }
    if (js) (*env)->DeleteLocalRef(env, js);
    return out;
}

+ (void)mobileOpenPanel:(int)index {
    if (!ensureMui()) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native side-panel open posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiOpenPanel, (jint)index);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobileOpenPanel"); return; }
    if (js) (*env)->DeleteLocalRef(env, js);
}

+ (void)mobileClosePanel {
    if (!ensureMui()) return;
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiClosePanel);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobileClosePanel"); return; }
    if (js) (*env)->DeleteLocalRef(env, js);
}

+ (int)mobilePanelFrameSeq {
    if (!ensureMui()) return 0;
    JNIEnv *env = gMainEnv;
    jint v = (*env)->CallStaticIntMethod(env, gMuiClass, gMuiPanelSeq);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobilePanelFrameSeq"); return 0; }
    return (int)v;
}

+ (void)mobilePanelClickX:(int)x y:(int)y {
    if (!ensureMui()) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: Swing-panel dispatch posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring js = (jstring)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPanelClick, (jint)x, (jint)y);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobilePanelClick"); return; }
    if (js) (*env)->DeleteLocalRef(env, js);
}

// Pull the active panel's full ARGB image (PANEL_W x panelH). Opaque dark-theme pixels, so the same
// alpha-skip/little-endian setup as latestFrame works.
+ (UIImage *)mobilePanelImage {
    if (!ensureMui()) return nil;
    JNIEnv *env = gMainEnv;
    jint w = (*env)->CallStaticIntMethod(env, gMuiClass, gMuiPanelW);
    jint h = (*env)->CallStaticIntMethod(env, gMuiClass, gMuiPanelH);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobilePanelImage"); return nil; }
    if (w <= 0 || h <= 0) return nil;
    jintArray arr = (jintArray)(*env)->CallStaticObjectMethod(env, gMuiClass, gMuiPanelPixels);
    if (!arr || (*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.mobilePanelImage"); return nil; }
    jsize len = (*env)->GetArrayLength(env, arr);
    NSUInteger need = (NSUInteger)w * (NSUInteger)h;
    // Validate against a torn read: the EDT repaint publishes w/h then pixels (Java side), so a frame caught
    // mid-swap can have a pixel array that doesn't match w*h — skip it (the next tick is consistent).
    if ((NSUInteger)len < need) { (*env)->DeleteLocalRef(env, arr); return nil; }
    uint32_t *buf = (uint32_t *)malloc(need * sizeof(uint32_t));
    if (!buf) { (*env)->DeleteLocalRef(env, arr); return nil; }
    (*env)->GetIntArrayRegion(env, arr, 0, (jsize)need, (jint *)buf);
    (*env)->DeleteLocalRef(env, arr);
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)buf, (CFIndex)(need * sizeof(uint32_t)));
    free(buf);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo info = (CGBitmapInfo)(kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef cg = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs, info,
                                  provider, NULL, false, kCGRenderingIntentDefault);
    UIImage *img = cg ? [UIImage imageWithCGImage:cg] : nil;
    if (cg) CGImageRelease(cg);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return img;
}

// ---- Native Quest Helper reflow (QuestHelperBridge) ------------------------------------------------

+ (BOOL)questAvailable {
    if (!ensureQuest()) return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gQhClass, gQhAvailable);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.questAvailable"); return NO; }
    return v ? YES : NO;
}

+ (NSString *)questListJson {
    if (!ensureQuest()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gQhClass, gQhList));
}

+ (NSString *)questActiveJson {
    if (!ensureQuest()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gQhClass, gQhActive));
}

+ (void)questStart:(NSString *)name {
    if (!ensureQuest() || name == nil) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native quest-helper start posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring js = (*env)->NewStringUTF(env, name.UTF8String);
    (*env)->CallStaticVoidMethod(env, gQhClass, gQhStart, js);
    if (js) (*env)->DeleteLocalRef(env, js);
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.questStart");
}

+ (void)questStop {
    if (!ensureQuest()) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native quest-helper stop posts no canvas event
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gQhClass, gQhStop);
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.questStop");
}

+ (void)questSetUiOpen:(BOOL)open {
    if (!ensureQuest()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gQhClass, gQhSetOpen, (jboolean)(open ? 1 : 0));
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.questSetUiOpen");
}

// ---- Native overlay edit-mode (OverlayBridge) — move / snap / reset live overlays ------------------

+ (BOOL)overlayAvailable {
    if (!ensureOvl()) return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gOvlClass, gOvlAvailable);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.overlayAvailable"); return NO; }
    return v ? YES : NO;
}

+ (void)overlaySetUiOpen:(BOOL)open {
    if (!ensureOvl()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gOvlClass, gOvlSetOpen, (jboolean)(open ? 1 : 0));
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.overlaySetUiOpen");
}

+ (NSString *)overlaysJson {
    if (!ensureOvl()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gOvlClass, gOvlList));
}

+ (NSString *)overlaySetLocation:(NSString *)name x:(int)x y:(int)y {
    if (!ensureOvl() || name == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native overlay move posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jn = (*env)->NewStringUTF(env, name.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gOvlClass, gOvlSetLoc, jn, (jint)x, (jint)y));
    (*env)->DeleteLocalRef(env, jn);
    return out;
}

+ (NSString *)overlaySetPosition:(NSString *)name position:(NSString *)position {
    if (!ensureOvl() || name == nil || position == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native overlay snap posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jn = (*env)->NewStringUTF(env, name.UTF8String);
    jstring jp = (*env)->NewStringUTF(env, position.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gOvlClass, gOvlSetPos, jn, jp));
    (*env)->DeleteLocalRef(env, jn);
    (*env)->DeleteLocalRef(env, jp);
    return out;
}

+ (NSString *)overlayReset:(NSString *)name {
    if (!ensureOvl() || name == nil) return nil;
    [JVMLauncher postKeepAlive];   // idle keepalive: native overlay reset posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jn = (*env)->NewStringUTF(env, name.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gOvlClass, gOvlReset, jn));
    (*env)->DeleteLocalRef(env, jn);
    return out;
}

+ (NSString *)overlaySnapForX:(int)x y:(int)y canvasW:(int)canvasW canvasH:(int)canvasH {
    if (!ensureOvl()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gOvlClass, gOvlSnap,
                                                                    (jint)x, (jint)y, (jint)canvasW, (jint)canvasH));
}

// ---- RuneLite-account login (config sync, RuneLiteAccountBridge) — distinct from the Jagex game login ------

+ (BOOL)accountAvailable {
    if (!ensureAccount()) return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gAccountClass, gAccAvail);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.accountAvailable"); return NO; }
    return v ? YES : NO;
}

+ (NSString *)accountSessionJson {
    if (!ensureAccount()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gAccountClass, gAccSession));
}

// startLogin()/logout() BLOCK (login starts a localhost server + a network call to api.runelite.net before handing
// the OAuth url to LinkBrowser → the native SFSafariViewController). Run on a worker thread with its own daemon
// attach (self-contained FindClass — the main-thread gAccountClass cache may not be warm yet).
static void accountInvokeVoid(const char *method) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        JavaVM *vm = atomic_load(&gVM);
        if (!vm) return;
        JNIEnv *e = NULL;
        if ((*vm)->AttachCurrentThreadAsDaemon(vm, (void **)&e, NULL) != JNI_OK || !e) return;
        jclass cls = (*e)->FindClass(e, "net/runelite/client/headless/RuneLiteAccountBridge");
        if (!cls || (*e)->ExceptionCheck(e)) { (*e)->ExceptionClear(e); return; }
        jmethodID m = (*e)->GetStaticMethodID(e, cls, method, "()V");
        if (!m) { (*e)->ExceptionClear(e); return; }
        (*e)->CallStaticVoidMethod(e, cls, m);
        if ((*e)->ExceptionCheck(e)) (*e)->ExceptionClear(e);
        (*e)->DeleteLocalRef(e, cls);
    });
}

+ (void)accountLogin  { accountInvokeVoid("startLogin"); }
+ (void)accountLogout { accountInvokeVoid("logout"); }

// ---- Native World Switcher reflow (WorldSwitcherBridge) --------------------------------------------

+ (BOOL)worldAvailable {
    if (!ensureWorld()) return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gWsClass, gWsAvailable);
    if ((*env)->ExceptionCheck(env)) { bridgeNoteClear(env, "JVMLauncher.worldAvailable"); return NO; }
    return v ? YES : NO;
}

+ (NSString *)worldListJson {
    if (!ensureWorld()) return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gWsClass, gWsList));
}

+ (void)worldHop:(int)worldId {
    if (!ensureWorld()) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native world hop posts no canvas event
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gWsClass, gWsHop, (jint)worldId);
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.worldHop");
}

+ (void)worldSetUiOpen:(BOOL)open {
    if (!ensureWorld()) return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gWsClass, gWsSetOpen, (jboolean)(open ? 1 : 0));
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.worldSetUiOpen");
}

// WH-1: mark/unmark a world as a favourite (shared worldhopper config). No-op on an older jar.
+ (void)worldSetFavourite:(int)worldId favourite:(BOOL)favourite {
    if (!ensureWorld() || !gWsSetFav) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native world favourite toggle posts no canvas event
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gWsClass, gWsSetFav, (jint)worldId, (jboolean)(favourite ? 1 : 0));
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.worldSetFavourite");
}

// WH-3: quick-hop to the next/previous world (reflects WorldHopperPlugin.hop(boolean)). No-op on an older jar.
+ (void)worldHopDirection:(BOOL)previous {
    if (!ensureWorld() || !gWsHopDir) return;
    [JVMLauncher postKeepAlive];   // idle keepalive: native quick-hop posts no canvas event
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gWsClass, gWsHopDir, (jboolean)(previous ? 1 : 0));
    if ((*env)->ExceptionCheck(env)) bridgeNoteClear(env, "JVMLauncher.worldHopDirection");
}

// ---- Native Loot Tracker reflow (LootTrackerBridge) — read-only per-source loot + "Reset All" --------

+ (BOOL)lootAvailable {
    if (!ensureLoot())
        return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gLootClass, gLootAvail);
    if ((*env)->ExceptionCheck(env)) {
        bridgeNoteClear(env, "JVMLauncher.lootAvailable");
        return NO;
    }
    return v ? YES : NO;
}

+ (void)lootSetUiOpen:(BOOL)open {
    if (!ensureLoot())
        return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gLootClass, gLootSetOpen, (jboolean)(open ? 1 : 0));
    if ((*env)->ExceptionCheck(env))
        bridgeNoteClear(env, "JVMLauncher.lootSetUiOpen");
}

+ (NSString *)lootJson {
    if (!ensureLoot())
        return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gLootClass, gLootJson));
}

+ (NSString *)lootResetAll {
    if (!ensureLoot() || !gLootReset)
        return nil;
    [JVMLauncher postKeepAlive]; // idle keepalive: the native reset posts no canvas event
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gLootClass, gLootReset));
}

// ---- Native Time Tracking reflow (TimeTrackingBridge) — read-only farming/bird-house/timer countdowns ----

+ (BOOL)timeTrackingAvailable {
    if (!ensureTimeTracking())
        return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gTtClass, gTtAvail);
    if ((*env)->ExceptionCheck(env)) {
        bridgeNoteClear(env, "JVMLauncher.timeTrackingAvailable");
        return NO;
    }
    return v ? YES : NO;
}

+ (void)timeTrackingSetUiOpen:(BOOL)open {
    if (!ensureTimeTracking())
        return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gTtClass, gTtSetOpen, (jboolean)(open ? 1 : 0));
    if ((*env)->ExceptionCheck(env))
        bridgeNoteClear(env, "JVMLauncher.timeTrackingSetUiOpen");
}

+ (NSString *)timeTrackingJson {
    if (!ensureTimeTracking())
        return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gTtClass, gTtJson));
}

// ---- Native Config Profiles reflow (ConfigProfileBridge) — list profiles + switch the active one --------

+ (BOOL)profilesAvailable {
    if (!ensureProfiles())
        return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gProfClass, gProfAvail);
    if ((*env)->ExceptionCheck(env)) {
        bridgeNoteClear(env, "JVMLauncher.profilesAvailable");
        return NO;
    }
    return v ? YES : NO;
}

+ (NSString *)profilesJson {
    if (!ensureProfiles())
        return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gProfClass, gProfJson));
}

+ (NSString *)switchProfile:(long long)profileId {
    if (!ensureProfiles())
        return nil;
    [JVMLauncher postKeepAlive]; // idle keepalive: the native profile switch posts no canvas event
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gProfClass, gProfSwitch, (jlong)profileId));
}

// ---- Native Infobox menu reflow (InfoBoxBridge) — list infoboxes + invoke a menu option (#20) -----------

+ (BOOL)infoBoxAvailable {
    if (!ensureInfoBox())
        return NO;
    JNIEnv *env = gMainEnv;
    jboolean v = (*env)->CallStaticBooleanMethod(env, gIbClass, gIbAvail);
    if ((*env)->ExceptionCheck(env)) {
        bridgeNoteClear(env, "JVMLauncher.infoBoxAvailable");
        return NO;
    }
    return v ? YES : NO;
}

+ (void)infoBoxSetUiOpen:(BOOL)open {
    if (!ensureInfoBox())
        return;
    JNIEnv *env = gMainEnv;
    (*env)->CallStaticVoidMethod(env, gIbClass, gIbSetOpen, (jboolean)(open ? 1 : 0));
    if ((*env)->ExceptionCheck(env))
        bridgeNoteClear(env, "JVMLauncher.infoBoxSetUiOpen");
}

+ (NSString *)infoBoxesJson {
    if (!ensureInfoBox())
        return nil;
    JNIEnv *env = gMainEnv;
    return jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gIbClass, gIbJson));
}

+ (NSString *)invokeInfoBoxMenu:(int)index option:(NSString *)option {
    if (!ensureInfoBox() || option == nil)
        return nil;
    [JVMLauncher postKeepAlive]; // idle keepalive: the native infobox invoke posts no canvas event
    JNIEnv *env = gMainEnv;
    jstring jo = (*env)->NewStringUTF(env, option.UTF8String);
    NSString *out = jstringToNS(env, (jstring)(*env)->CallStaticObjectMethod(env, gIbClass, gIbInvoke, (jint)index, jo));
    if (jo)
        (*env)->DeleteLocalRef(env, jo);
    return out;
}

@end
