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

    /** A8 + Phase 4: with the redirect off, still forward the perf-probe lines (frame/GC/present timing) and
     *  nothing else, so a release build can be measured. Call BEFORE [startJvm]. */
    external fun nativeSetStdioProbeLines(enabled: Boolean)

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

    // AP-2a sticky-Shift (Finding 12): hold/release a synthetic VK_SHIFT via JavaBridge.setShiftHeld. Queued
    // through the input path so it's ORDERED ahead of the menu-open right-click (engine must read shift held
    // before it builds the menu, or Mark/Configure entries aren't injected). UI-thread-safe (enqueue only).
    external fun nativeSetShiftHeld(held: Boolean)

    /** Sticky Ctrl/Alt latch (mirror of setShiftHeld) + a discrete middle-button (BUTTON2) click. */
    external fun nativeSetCtrlHeld(held: Boolean)

    external fun nativeSetAltHeld(held: Boolean)

    /** Menu-degrade fallback: lift/restore the engine's own "Choose Option" raster suppression. */
    external fun nativeSetMenuRenderSuppressed(suppressed: Boolean)

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

    /**
     * Stream one real move sample of the finger that armed a tap (JavaBridge.onTapMove). Queued and
     * coalesced to the latest position per drain, like the other position streams: the render thread makes
     * the call, so one sample per frame with a real timestamp beats a frame's worth posted back to back.
     */
    external fun nativeTapMove(
        x: Int,
        y: Int,
    )

    /**
     * The finger LANDED at game-canvas (x,y): start resolving that point now, click nothing. A left tap is
     * never re-hit-tested, so the bridge has to move the synthetic cursor there and wait until the engine has
     * demonstrably resolved it before it can press — frames that used to be spent AFTER the lift, which is
     * most of what "taps feel delayed" was. Arming spends them while the finger is still on the glass, so the
     * lift's [nativeClick] posts the click on the spot. Presses nothing on its own.
     */
    external fun nativeArmTap(
        x: Int,
        y: Int,
    )

    /** The armed touch turned into a drag, a hold or a pinch, so no click is coming for it: drop the arm. */
    external fun nativeCancelArmedTap()

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

    /** What the focused field takes: 0 none, 1 text, 2 a number (amount prompts, Grand Exchange quantity/price). */
    external fun nativeTextInputKind(): Int

    /** Monotonic counter the engine bumps on each committed interact-tap — advance => fire a haptic. */
    external fun nativeInteractTapSeq(): Int

    /** Tap-KIND truth: [nativeTapKindSeq] bumps once per resolved left tap; [nativeLastTapKind] is its kind
     *  (TAP_KIND_*). */
    external fun nativeTapKindSeq(): Int

    external fun nativeLastTapKind(): Int

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

    /** The height counts only the rows the screen shows ([nativeSetShownRows]). */
    external fun nativeFrameHeight(): Int

    /** The last frame's full canvas height, rows hidden under the screen included; 0 before the first frame. */
    external fun nativeCanvasHeight(): Int

    /** Large portrait UI: show only the canvas's top [rows] rows (0 = all); the strip below holds the full-size chat
     *  and minimap. Any thread. */
    external fun nativeSetShownRows(rows: Int)

    /** Large portrait UI: tell the bridge the shown rows and the band (canvas px) windows are pinned into
     *  (HudVeneerBridge.setHudStrip); 0 rows turns the strip off. Off the UI thread (via [onBridge]). */
    external fun nativeSetHudStrip(
        visibleRows: Int,
        top: Int,
        bottom: Int,
    )

    /** Phase 3 (auto-GPU watchdog): frames the GPU/117HD renderer has actually presented. 0 == renderer not armed or
     *  never activated (failed/black/crashed); a climbing value == it activated and is presenting. */
    external fun nativeGpuFramesPresented(): Long

    /** P2-1 dev perf chip: a unified monotonic present count across all renderers (GPU direct-present when armed,
     *  else the CPU blit path). Diff two samples a second apart for fps. */
    external fun nativeFramesPresented(): Long

    /** P2-1 dev panel: JVM heap usage as "usedMB/maxMB" (JavaBridge.heapStats). "" before the bridge is up. */
    external fun nativeHeapStats(): String

    /** "Share logs": DiagnosticsBridge.engineReport() as {"names":[...],"text":"..."}; "" before the VM is up or on
     *  an older jar. Blocking: call it on a thread of its own (DiagnosticsReport.kt does, with a time limit). */
    external fun nativeEngineDiagnostics(): String

    /** P2-1 dev panel: exercise the auto-reconnect path for [seconds] so the Reconnecting overlay can be verified
     *  without a real network drop. No-op on an older jar. Call OFF the UI thread (via [onBridge]). */
    external fun nativeSimulateReconnect(seconds: Int)

    /** FOLD-3: resize the game canvas to [w]x[h] mid-session (the window changed shape). False on an older jar or
     *  before the bridge is up. Call OFF the UI thread (via [onBridge]). */
    external fun nativeRequestResize(
        w: Int,
        h: Int,
    ): Boolean

    /** FOLD-4: the camera zoom the game is drawing with; -1 while logged out, before the bridge is up, or on an older
     *  jar. Call OFF the UI thread (via [onBridge]). */
    external fun nativeCameraZoom(): Int

    /** FOLD-4: set the camera zoom (clamped to the game's limits, applied once logged in). No-op on an older jar.
     *  Call OFF the UI thread (via [onBridge]). */
    external fun nativeSetCameraZoom(zoom: Int)

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

    // P2-4: reset a single config key to its plugin default (returns {"ok":..,"writeId":n}). Off the UI thread.
    external fun nativeResetConfig(
        group: String,
        key: String,
    ): String

    // SC-1/NOTIF-2: the serialized default Notification seed for the per-item editor. Off the UI thread.
    external fun nativeNotificationDefaults(): String

    // Game settings: {"fpsCap":N,"idleLogoutMinutes":M} (fpsCap 0 = no cap), or "" if unavailable. Off the UI thread.
    external fun nativeGameSettings(): String

    // Cap the frame rate through the FPS Control plugin; 0 removes the cap. Off the UI thread.
    external fun nativeSetFpsCap(fps: Int): String

    // Set the idle logout time through the Logout Timer plugin, in minutes. Off the UI thread.
    external fun nativeSetIdleLogoutMinutes(minutes: Int): String

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

    // GE item/price-check search (GrandExchangeBridge.search) -> {"results":[{id,name,price}]}.
    external fun nativeGeSearch(query: String): String

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

    // Advances whenever the published chrome, chat or dialogue string changes: updateChrome's per-vsync skip test.
    external fun nativeChromeInputsGen(): Long

    // A6 chrome write surface (HudVeneerBridge; gated -Drunelite.hudveneer): hide the 14 engine tab stones (the
    // native 2-col grid replaces them), open a tab by replaying its stone op-script (works while hidden), and
    // relocate the engine side panel flush-left of the grid. Off the UI thread ONLY (via [onBridge]) — they
    // daemon-attach the calling thread to HotSpot. Cheap fire-and-forget setters re-applied by the engine tick.
    external fun nativeSetStonesHidden(hidden: Boolean)

    external fun nativeOpenTab(tabIndex: Int)

    external fun nativeOpenWorldMap() // FIX-5: open the world map via ORB_WORLDMAP op-replay

    external fun nativeSwitchToModernLayout() // press Resizable - Modern in the game's own layout dropdown

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

    /** The shell's own controls over the game, flat {x, y, w, h, ...} in CANVAS px: plugin overlay boxes keep off them. */
    external fun nativeSetOverlayKeepOut(rects: IntArray)

    /** Phase-4 chat pill: collapse the chat (shared shove-off-canvas) / switch channel (op-script replay). */
    external fun nativeSetChatCollapsed(collapsed: Boolean)

    /** The speech bubbles: put the whole chat away, filter stones included (HudVeneerBridge.setChatPutAway). */
    external fun nativeSetChatPutAway(putAway: Boolean)

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

    // The json AND its publish seq as "<seq>\n<json>", from one critical section. Deliberately no seq-only
    // accessor: two reads can pair new json with an older seq, and the shell re-tags its rows only when the
    // json TEXT changes, so such a seq latches and every option tap is refused until the text changes.
    external fun nativeDialoguePublish(): String

    // UI-4 dialogue actions: the engine's own WIDGET_CONTINUE handler. Clicking the CONTINUE widget walks
    // the player (it reads hidden, so the click lands on the scene behind the chatbox) and a synthesized
    // key is consumed without advancing anything -- both were tried on device.
    external fun nativeContinueDialogue()

    external fun nativeSelectDialogueOption(
        digit: Int,
        seq: Long,
    )

    // The same reasoning for a box no named kind models: the point is resolved against the box's own widgets
    // on the client thread and delivered as that widget's op.
    external fun nativeTapDialogue(
        x: Int,
        y: Int,
    )

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

    fun setStdioProbeLines(enabled: Boolean) = nativeSetStdioProbeLines(enabled)

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

    fun tapMove(
        x: Int,
        y: Int,
    ) = nativeTapMove(x, y)

    fun clearHover() = nativeClearHover()

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

    fun armTap(
        x: Int,
        y: Int,
    ) = nativeArmTap(x, y)

    fun cancelArmedTap() = nativeCancelArmedTap()

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

    fun textInputKind() = nativeTextInputKind()

    fun interactTapSeq() = nativeInteractTapSeq()

    fun tapKindSeq() = nativeTapKindSeq()

    fun lastTapKind() = nativeLastTapKind()

    fun selectMenuPoint(
        x: Int,
        y: Int,
    ) = nativeSelectMenuPoint(x, y)

    // Name matches iOS's +[JVMLauncher setEngineMenuRenderSuppressed:] for cross-platform greppability.
    fun setEngineMenuRenderSuppressed(suppressed: Boolean) = nativeSetMenuRenderSuppressed(suppressed)

    fun invokeMenuEntry(
        parent: Int,
        child: Int,
    ) = nativeInvokeMenuEntry(parent, child)

    fun menuSnapshot() = nativeMenuSnapshot()

    fun menuPublishSeq() = nativeMenuPublishSeq()

    fun tabSprites() = nativeTabSprites()

    fun frameWidth() = nativeFrameWidth()

    fun frameHeight() = nativeFrameHeight()

    fun canvasHeight() = nativeCanvasHeight()

    fun setShownRows(rows: Int) = nativeSetShownRows(rows)

    fun setHudStrip(
        visibleRows: Int,
        top: Int,
        bottom: Int,
    ) = nativeSetHudStrip(visibleRows, top, bottom)

    fun framePixels(): IntArray? = nativeFramePixels()

    // P2-1 dev perf chip / panel.

    /** The renderer this process actually BOOTED with (cpu|gpu|117hd); empty until the boot path sets it.
     *  Not the same thing as the saved preference: a pick made mid-session only applies at the next launch, and
     *  a dev/CI-forced boot (gpu.mode marker, intent extra, TV) runs a renderer the pref never asked for. The
     *  plugins panel reports THIS, so a row cannot claim to be running something that isn't. */
    @Volatile
    var sessionRenderer: String = ""

    /** Whether a PERSISTENT boot override will ask for 117HD / GPU at the next launch: the `rlhd.mode` and
     *  `gpu.mode` marker files, plus a TV/leanback device without `cpu.mode` (which boots 117HD by design).
     *  Only overrides that survive a relaunch count, so an intent extra, a Game Loop launch and the one-shot
     *  `rlhd.once` marker are excluded. Set in the boot path and constant thereafter. */
    @Volatile
    var rlhdForcedNextBoot = false

    @Volatile
    var gpuForcedNextBoot = false

    /** The renderer the next launch will actually run, from the saved [pref] and the overrides above, in the
     *  boot path's own precedence (117HD wins over GPU, GPU over CPU).
     *
     *  An override does NOT simply win: a 117HD pref satisfies the same condition the `rlhd.mode` marker and
     *  the TV default do, so it outranks a `gpu.mode` override, and switching the pick to 117HD takes effect
     *  even with that marker present. Anything that reports on the next boot has to apply the whole
     *  expression, pref included -- a lone "which renderer is pinned" answer tells the panel that a pick is
     *  being ignored when it is about to be honoured. */
    fun nextBootRenderer(pref: String): String =
        when {
            rlhdForcedNextBoot || pref == "117hd" -> "117hd"
            gpuForcedNextBoot || pref == "gpu" -> "gpu"
            else -> "cpu"
        }

    fun framesPresented() = nativeFramesPresented()

    fun heapStats() = nativeHeapStats()

    fun simulateReconnect(seconds: Int) = nativeSimulateReconnect(seconds)

    fun requestResize(
        w: Int,
        h: Int,
    ) = nativeRequestResize(w, h)

    fun cameraZoom() = nativeCameraZoom()

    fun setCameraZoom(zoom: Int) = nativeSetCameraZoom(zoom)

    // ---- A3.5 bridge request/response thread --------------------------------------------------------
    // A single dedicated background thread the UI posts plugin-plane requests to, so the ART UI thread NEVER
    // attaches to HotSpot (ANR risk) and HotSpot only ever sees one caller from the ART side. The thread
    // daemon-attaches to HotSpot on its first bridge call (native layer) and stays attached for the process.
    private val bridgeExec: ExecutorService =
        Executors.newSingleThreadExecutor { r -> Thread(r, "rl-bridge").apply { isDaemon = true } }

    /** Run [block] on the rl-bridge thread; returns a Future (do NOT .get() it on the UI thread). */
    fun <T> onBridge(block: () -> T): Future<T> = bridgeExec.submit(block)

    /**
     * [onBridge] for a call that is a genuine native-UI *touch* (a write the user initiated) rather than a
     * passive data refresh. It used to also bump the engine's idle-logout timer, which is gone: the engine AFK-
     * logs us out on real inactivity now, exactly as it does a desktop client whose user is only clicking around
     * RuneLite's own panels. Kept as its own name because the distinction it marks at ~50 call sites is real and
     * is what anything keyed on user activity would need again.
     */
    fun <T> onBridgeTouch(block: () -> T): Future<T> = bridgeExec.submit(block)

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

    fun resetConfig(
        group: String,
        key: String,
    ) = nativeResetConfig(group, key)

    fun notificationDefaults() = nativeNotificationDefaults()

    fun gameSettings() = nativeGameSettings()

    fun setFpsCap(fps: Int) = nativeSetFpsCap(fps)

    fun setIdleLogoutMinutes(minutes: Int) = nativeSetIdleLogoutMinutes(minutes)

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

    fun geSearch(query: String) = nativeGeSearch(query)

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

    fun chromeInputsGen() = nativeChromeInputsGen()

    fun setStonesHidden(hidden: Boolean) = nativeSetStonesHidden(hidden)

    fun openTab(tabIndex: Int) = nativeOpenTab(tabIndex)

    fun openWorldMap() = nativeOpenWorldMap()

    /** Switch the account's game client layout to Resizable - Modern (server-side, account-wide). One-shot; the
     *  chrome snapshot's rootKind turns PRE_EOC once the server has applied it. */
    fun switchToModernLayout() = nativeSwitchToModernLayout()

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

    fun setOverlayKeepOut(rects: IntArray) = nativeSetOverlayKeepOut(rects)

    fun setChatCollapsed(collapsed: Boolean) = nativeSetChatCollapsed(collapsed)

    fun setChatPutAway(putAway: Boolean) = nativeSetChatPutAway(putAway)

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

    fun dialoguePublishRaw() = nativeDialoguePublish()

    fun continueDialogue() = nativeContinueDialogue()

    fun tapDialogue(
        x: Int,
        y: Int,
    ) = nativeTapDialogue(x, y)

    fun selectDialogueOption(
        digit: Int,
        seq: Long,
    ) = nativeSelectDialogueOption(digit, seq)

    fun orbSnapshotPub() = nativeOrbSnapshotPub()

    fun setChatTabRowHeight(canvasPx: Int) = nativeSetChatTabRowHeight(canvasPx)

    fun setChatAreaWidth(canvasPx: Int) = nativeSetChatAreaWidth(canvasPx)

    fun scrollChat(deltaCanvasPx: Int) = nativeScrollChat(deltaCanvasPx)
}
