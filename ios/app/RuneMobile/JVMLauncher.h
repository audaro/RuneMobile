#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

@class AVSampleBufferDisplayLayer;

NS_ASSUME_NONNULL_BEGIN

/// Result/diagnostic callback. `line` is one log line (already newline-free);
/// the UI appends it to the on-screen console and it is also written to
/// Documents/hello-shell.log for retrieval off-device.
typedef void (^JVMLogSink)(NSString *line);

@interface JVMLauncher : NSObject

/// Optional "WxH" the headless client should resize its canvas to after login (full-screen landscape).
/// Set on the main thread before -runProbesWithLog: (computed from the screen aspect). Nil = 765x503.
@property (nonatomic, copy, nullable) NSString *resizeSpec;

/// W3 GPU Route C — when YES, -runProbesWithLog: boots the L1 kill-test (routec-l1.jar ALONE on the classpath,
/// RouteC_registerGLNatives after VM create, callMain RouteCL1Probe) instead of the full RuneLite boot. The
/// probe asserts GL.createCapabilities().OpenGL33 + real core GL calls work through the JNI bridge on a live
/// EAGL ES3 context — the cheapest device gate for Route C. Set on the main thread before -runProbesWithLog:.
@property (nonatomic, assign) BOOL routecL1Mode;

/// W3 GPU Route C — when YES, the FULL RuneLite boots (DeviceHeadlessBoot) with the JNI GL bridge natives
/// registered after VM create, so the unmodified gpu plugin renders the scene on the device GPU through the
/// facade (EAGL ES3 FBO) and the swapBuffers shim publishes each composited frame to JavaBridge. The bundle
/// must carry the iOS staged shaded jar (stage-ios-gpu-jar.sh). Set on the main thread before -runProbesWithLog:.
@property (nonatomic, assign) BOOL routecGpuMode;

/// W3 GPU Zone B0.5 — when YES, the FULL RuneLite boots with the staged 117HD (RLHD) jar on the classpath and the
/// zone facade-delta natives registered (RouteC_registerZoneNatives, on top of the base bridge). RLHDStarter
/// (-Drunelite.routecrlhd=true) loads + starts rs117.hd.HdPlugin (the Zone renderer) once in-world; HdPlugin
/// conflicts=GPU so it replaces the base gpu plugin. The bundle must carry client-rlhd.jar + the shaded jar
/// staged with the grown facade superset. Set on the main thread before -runProbesWithLog:.
@property (nonatomic, assign) BOOL routecZoneMode;

/// CS_DEBUGGED gate (the W1-audit Claim E): true once StikDebug has attached and the
/// kernel marks this process debugged. Poll this BEFORE warming HotSpot.
+ (BOOL)isDebuggerAttached;

/// True while a debugger is attached to this process right now (P_TRACED). Unlike CS_DEBUGGED, which stays set
/// after a detach, this tells "a StikDebug script is attached" from "StikDebug attached and let go without one".
/// YES in the simulator (no attach there) and when the state can't be read.
+ (BOOL)isDebuggerTracing;

/// The cover's check of the attached StikDebug script (startJitScriptCheck).
typedef NS_ENUM(NSInteger, RMJitScriptCheck) {
    RMJitScriptCheckNotRun = 0,  ///< nothing asked yet
    RMJitScriptCheckRunning,     ///< the request is out; the script holds the whole process while it answers
    RMJitScriptCheckServed,      ///< runelite-jit.js mapped the code cache; Tap to Play can start the JVM
    RMJitScriptCheckUnanswered,  ///< no debugger took the request (StikDebug let go without a script)
    RMJitScriptCheckWrongAnswer, ///< a debugger answered, but not with RX memory: another script
};

/// Where the check stands. Always RMJitScriptCheckServed in the simulator, which maps its own code cache.
+ (RMJitScriptCheck)jitScriptCheck;

/// Device only: asks the attached script for the JVM's code cache now, with the same `brk #0x69` request libjvm
/// makes, so a wrong script shows on the cover instead of killing the app after Tap to Play. runelite-jit.js
/// answers it with RX memory and detaches; the JVM is handed that memory at start-up (JNI_CreateJavaVM) with no
/// debugger needed. Call it only while a debugger is attached (isDebuggerTracing). No-op while a check is running
/// or after one was served. `done` runs on the main queue with the result and a log line.
+ (void)startJitScriptCheck:(void (^)(RMJitScriptCheck result, NSString *line))done;

/// YES once if the previous launch died inside JNI_CreateJavaVM or the cover's script check, where the code-cache
/// request is answered: the attached StikDebug script was not (a current) runelite-jit.js. Clears the record as it
/// reads it.
+ (BOOL)takeJitStartupFailure;

/// Optional RWX canary (the W1-audit Claim E "tiny TXM preflight"). Maps a page,
/// writes `mov w0,#42; ret`, flips it to RX and calls it. Returns 42 on
/// success. NOTE: a plain mprotect RW->RX canary may FALSE-NEGATIVE under the
/// MirrorMappedCodeCache path HotSpot actually uses — treat a crash here as
/// "naive RWX is blocked", not "HotSpot will fail". Diagnostic only.
+ (int)runRwxCanary:(JVMLogSink)log;

/// Resolve the embedded JRE home inside the .app bundle (".../jre").
+ (nullable NSString *)javaHome;

/// Re-point the task EXC_BREAKPOINT port back at the StikDebug debugger (the same-session-login fix the
/// boot path runs before creating the VM). Call after loading WebKit MID-SESSION (e.g. the session-expired
/// re-login) — WebKit can displace the debugger's handler, after which a JIT-mirror brk is never serviced
/// and the JVM dies with SIGTRAP. No-op when the debugger already owns the port.
+ (void)restoreBreakpointPortNow:(JVMLogSink)log;

/// Absolute path to the session bearer, tokens.json, in Library/Application Support — NOT the Files.app /
/// USB-exposed Documents dir. The single source of truth for the path: the native login writer, the
/// login-state readers, logout, and the JVM autologin reader all go through here. First call lazily migrates
/// any legacy Documents/tokens.json into Application Support (and purges the exposed copy). Any thread.
+ (NSString *)tokensPath;

/// Where this build keeps its logs: Documents in Debug (Files/USB-exposed, for off-device pulls), the sandboxed
/// Application Support dir in Release. hello-shell.log, crash.log and the VM's hs_err_pid*.log land here.
+ (NSString *)appLogDir;

/// YES once JNI_CreateJavaVM has returned a VM. Any thread (unlike bridgeReady, which caches the caller's env).
+ (BOOL)vmStarted;

/// "Share logs": DiagnosticsBridge.engineReport(), the JSON {"names":[...],"text":"..."} of the engine's report
/// section. Runs on a thread of its own and waits at most `seconds`, so a frozen engine can't hang the caller;
/// `timedOut` says why it came back nil then. nil before the VM is up or on a jar without the method. Call it
/// off the main thread.
+ (nullable NSString *)engineDiagnosticsJSONWaiting:(NSTimeInterval)seconds timedOut:(BOOL *_Nullable)timedOut;

/// Phase 4 perf probe: YES when a `perfprobe` file is in Documents (tools/perfprobe.sh ios on) and does not say
/// "off" (devicectl can't delete it, so `off` overwrites it), in either build configuration. Armed, the VM gets -Drunelite.fpsprobe (headless.FrameStats' frame-pacing lines) plus GC and
/// safepoint logging, the present paths log [presentprobe] (the GL direct present and the PiP frame feed), and a Release build keeps those timing lines,
/// and only those, in Documents/perf-probe.log (Debug already has them in jvm-stdio.log). A marker rather than
/// DEBUG because Debug is the daily driver and jvm-stdio.log grows for the whole session. Read once; any thread.
+ (BOOL)perfProbeArmed;

/// Milliseconds since this process started, for the cold-start stamps; -1 if the kernel won't say. Any thread.
+ (long)msSinceProcessStart;

/// dlopen(libjvm) -> JNI_CreateJavaVM -> run JitProbe, Bench, GlyphSmoke in one VM,
/// then DestroyJavaVM. Blocks until done. MUST be called on a dedicated thread with
/// JIT already live (CS_DEBUGGED + the StikDebug brk #0x69 script). Returns 0 on a
/// clean VM lifecycle, negative on a fatal setup error.
- (int)runProbesWithLog:(JVMLogSink)log;

// ---- Phase 4 (W3) sub-goal B: reverse-JNI bridge (called from the main/UI thread) ------------------

/// True once the VM is up and the JavaBridge class has been resolved — i.e. live blit + touch are usable.
+ (BOOL)bridgeReady;

/// Drop the cached reverse-JNI facade refs after the VM has been destroyed (post-DestroyJavaVM). Makes NO JNI
/// calls — pure pointer reset so a re-created VM re-resolves cleanly. Call on the main thread, after the VM is gone.
+ (void)bridgeInvalidate;

/// Monotonic counter that advances when an in-game left tap resolved to an interactable (not a bare walk).
/// The shell polls this and fires a light haptic on change. Returns 0 if the bundled jar predates it.
+ (int)interactTapSeq;

/// The last resolved tap kind (JavaBridge.getLastTapKind): TAP_KIND_NONE=0 / WALK=1 / SCENE=2 / WIDGET=3. Read
/// it right after interactTapSeq bumps (that seq is published last, as a release barrier, so the kind is then
/// committed). The shell suppresses its red click-ring on WIDGET (the engine draws its own outline). 0 on an
/// older jar.
+ (int)lastTapKind;

/// The engine's monotonic rendered-frame counter (JavaBridge.getFrameSeq). Advances once per composited
/// SOFTWARE frame, so a delta over time yields a true engine FPS. The GPU direct-present path (117HD) does
/// not bump it (it presents off-thread), so a frozen value there is "not measured", not a stall. -1 before
/// the bridge is up. Main thread only.
+ (int)renderedFrameSeq;

/// The width of the latest engine frame (JavaBridge.getFrameWidth) — a cheap "has anything painted yet"
/// probe: > 0 once the engine has composited at least one frame, 0 before then, -1 before the bridge is up.
/// Used by the boot-progress overlay to dismiss itself the tick real content first appears. Main thread only.
+ (int)renderedFrameWidth;

/// The base-GPU present counter (JavaBridge.getGpuFrameSeq) — > 0 once the GPU readback seam has actually
/// published a frame. Unlike renderedFrameSeq (CPU login frames bump it too) this is true GPU provenance, so
/// the boot crash-cookie clears only after the GPU renderer has really presented. -1 before the bridge is up
/// or on an older jar. Main thread only.
+ (int)gpuFrameSeq;

/// JVM heap usage as "usedMB/maxMB" (JavaBridge.heapStats) — the Java-heap pressure the GC manages, distinct
/// from the OS resident memory. nil before the bridge is up / on an older jar. Main thread only.
+ (nullable NSString *)heapStats;

/// Developer test hook: force the "Reconnecting…" overlay on for `seconds` (bridge-clamped 1..10) WITHOUT a
/// real socket drop — exercises the overlay + snapshot path only. No-op before the bridge is up. Main thread.
+ (void)devSimulateReconnect:(int)seconds;

/// The camera zoom the game draws with, or -1 while logged out (or on an older jar). Main thread only.
+ (int)cameraZoom;
/// Ask for a camera zoom; the game applies it, clamped to its zoom limits, once logged in. Main thread only.
+ (void)setCameraZoom:(int)zoom;

/// Developer test hook: publish a host-origin notification ("RuneLite" / "Notification delivery test") through
/// the shared bridge, exercising the full delivery path (queue -> drain -> OS notification) without an in-game
/// trigger. Mirrors Android's DEBUG Shift long-press. No-op before the bridge is up / on an older jar. Main thread.
+ (void)devPublishTestNotification;

/// Pull the engine's latest composited frame as a UIImage (reverse JNI -> JavaBridge.getFramePixels).
/// Returns nil before the first draw / if the VM isn't up yet. Call on the main thread.
+ (nullable UIImage *)latestFrame;

/// Ask the game for a `w` x `h` canvas mid-session (the phone turned). It resizes on its next draw; before login it takes
/// the size as the one to resize to at login. Only the newest request counts. NO before the bridge is up. Main thread only.
+ (BOOL)requestResizeWidth:(int)w height:(int)h;
/// The canvas the game draws now, hidden strip included; 0 before the client is up. Main thread only.
+ (int)canvasWidth;
+ (int)canvasHeight;

/// The canvas rows shown on screen: the frame and the Picture-in-Picture feed keep only the top `rows` rows, so the
/// hidden strip below them (HudVeneerBridge.setHudStrip) never reaches the screen. 0 shows the whole canvas.
+ (void)setShownRows:(int)rows;

/// The Picture-in-Picture frame feed's target layer (nil turns the feed off). Each new engine frame is copied into a
/// 32BGRA CVPixelBuffer and enqueued on its sampleBufferRenderer, display-immediately. Never waits on the feed
/// thread: a frame in flight re-checks the layer just before its enqueue and is dropped if the layer changed, so only
/// a frame already past that check can still land. Main thread.
+ (void)pipFeedSetLayer:(nullable AVSampleBufferDisplayLayer *)layer;

/// As +pipFeedSetLayer:, then runs `drained` on the main thread once no feed pass can still enqueue onto the old
/// layer: at once if none is in flight, otherwise when that pass ends (a few ms). Hand the layer to another producer
/// from `drained`, so its first frame can't be followed by a late one from this feed. Main thread.
+ (void)pipFeedSetLayer:(nullable AVSampleBufferDisplayLayer *)layer drained:(nullable dispatch_block_t)drained;

/// Ask the feed for the newest frame: a no-op unless the engine composited one since the last frame fed. Cheap; the
/// copy and enqueue run on the feed's own JVM-attached thread (or inline, if Documents/pipfeed says "main"). Main thread.
+ (void)pipFeedKick;

/// The JavaBridge frame seq last enqueued by the feed, -1 before the first. For logs. Any thread.
+ (int)pipFeedSeq;

/// Game audio stops behind other apps. Remembered if the VM isn't up yet. Main thread.
+ (void)setGameAudioForeground:(BOOL)foreground;

/// The player's Game sound switch, live. The boot passes it as -Drunelite.audio.muted. Main thread.
+ (void)setGameAudioMuted:(BOOL)muted;

/// Gate the engine's right-click-menu RASTER (its logic/geometry stay live for click-through). Suppressed
/// by default on device — the native big-row overlay is the only menu UI; the engine's tiny box only ever
/// showed as 1-frame flash artifacts. The shell flips it OFF for the native-menu build-timeout fallback
/// (so drag-select isn't blind) and back ON at menu teardown. No-op on a jar without the method.
+ (void)setEngineMenuRenderSuppressed:(BOOL)suppressed;

/// Post a DRAG phase into the gamepack via JavaBridge.onTouch. `type`: 0=down, 1=move, 2=up;
/// `x`,`y` are gamepack-canvas (765x503) pixels; `button` is 1 (left) or 3 (right). A release does NOT
/// synthesize a click (use postClick for a tap). Call on the main thread. Used by the camera/scroll drag.
+ (void)postTouchType:(int)type x:(int)x y:(int)y button:(int)button;

/// DRAG-1: the live inventory item-grid bounds in gamepack-canvas px, or CGRectNull when the inventory isn't
/// visible. The shell uses it to divert a drag that starts over the inventory into an item rearrange. Main thread.
+ (CGRect)inventoryCanvasBounds;

/// DRAG-1b: the visible reorder-pane bounds (Prayer/Spellbook/Bank) in gamepack-canvas px as NSValue-wrapped
/// CGRects (0-3 panes), or @[] when none. Backed by JavaBridge.getReorderPaneBounds(); diverts a drag that
/// starts over a reorder pane into an engine WidgetDrag rather than a camera rotate. Main thread.
+ (NSArray<NSValue *> *)reorderPaneCanvasBounds;

/// SCROLL-SPIKE: YES if a scrollable engine interface (bank / GE / quest list / settings / collection log …) is
/// under the canvas point (x,y). The shell calls this at pan-begin to divert a one-finger drag into an interface
/// scroll (wheel notches) instead of a camera rotate. NO when the jar predates it. Main thread.
+ (BOOL)engineScrollableAtX:(int)x y:(int)y;

/// Post a discrete TAP into the gamepack via JavaBridge.onClick (the full press+release+click at one
/// point). `x`,`y` are gamepack-canvas (765x503) pixels; `button` is 1 (left tap / menu-entry select) or
/// 3 (long-press: open the right-click menu). Call on the main thread.
+ (void)postClickX:(int)x y:(int)y button:(int)button;

/// Post a PRECISE tap (JavaBridge.onClickPrecise) at exactly (x,y) with NO snap-to-entity resolution — for
/// deliberate UI proxies (native chrome tapping a tab stone / widget) where touch-forgiveness must not pull
/// the click onto a nearby world entity. Call on the main thread.
+ (void)postClickPreciseX:(int)x y:(int)y button:(int)button;

/// Select an open right-click menu row at (x,y), then clear the parked hover so the engine doesn't leave the
/// cursor stuck on the selected target (the "stays on the stairs" bug). Use for the native menu commit/cancel.
+ (void)postMenuSelectX:(int)x y:(int)y;

/// MENU-1: commit a drilled-in right-click submenu child by (parent display index, child index) into the live
/// frozen menu tree — runs the child's RuneLite onClick / menuAction. No-op on a jar without invokeMenuEntry.
+ (void)invokeMenuEntryParent:(int)parentDisplayIndex child:(int)childIndex;

/// KEY-1: fire a plugin's configured action-hotkey by synthesizing its key chord (AWT extended keyCode + the
/// InputEvent.*_DOWN_MASK modifier bits) via JavaBridge.onKeybind. No-op on a jar without onKeybind.
+ (void)onKeybindKeyCode:(int)keyCode modifiers:(int)modifiers;

/// Move the pointer (no button held) into the gamepack via JavaBridge.onMove — a plain MOUSE_MOVED.
/// Used to highlight the entry under the finger while drag-selecting an open right-click menu.
/// `x`,`y` are gamepack-canvas (765x503) pixels. Call on the main thread.
+ (void)postMoveX:(int)x y:(int)y;

/// Stream one real move sample of the finger that armed a tap (JavaBridge.onTapMove). Called for every
/// sample of a one-finger scene touch; the bridge replays it as a drag of the press it is holding and drops
/// it when there is no such press, so the shell does not have to know what the gesture became. Main thread.
+ (void)postTapMoveX:(int)x y:(int)y;

/// Tell the bridge a finger has LANDED at the game-canvas point it will click if it lifts as a tap, so the
/// engine-resolved gate a left tap must pass (cursor move + wait for the engine to resolve the point) runs
/// during the finger-down time instead of after the lift. Clicks nothing by itself; a touch that turns into
/// a drag or a hold must call postCancelArmedTap. Main thread. No-ops into a plain move on an older jar.
+ (void)postArmTapX:(int)x y:(int)y;

/// The armed touch became a camera drag, a long-press menu or a pinch: drop the arm. Main thread.
+ (void)postCancelArmedTap;

/// Scroll the wheel via JavaBridge.onWheel (a MouseWheelEvent). `x`,`y` are gamepack-canvas pixels (the
/// pinch centroid); `rotation` notches: negative = zoom in. Used by pinch-to-zoom. Call on the main thread.
+ (void)postWheelX:(int)x y:(int)y rotation:(int)rotation;

/// Hold the camera turning at a pixel RATE per second, in the same sign convention as a drag; `0, 0`
/// releases. Per second rather than per frame so the turn does not track the frame rate.
+ (void)setCameraHoldDxPerSec:(int)dxPerSec dyPerSec:(int)dyPerSec;

/// Rotate the camera via JavaBridge.onCameraDrag — raw two-finger-pan pixel deltas applied to the camera
/// yaw/pitch targets directly (no middle-mouse). Call on the main thread.
+ (void)postCameraDx:(int)dx dy:(int)dy;

/// Make the engine pointer "absent" (JavaBridge.clearHover -> MOUSE_EXITED) so nothing stays highlighted.
/// Call when a camera/pinch gesture begins: a camera drag moves the world, not the cursor, so a frozen
/// cursor would otherwise light up (and let you mis-click) whatever scenery rotates under it. Main thread.
+ (void)postClearHover;

/// Type committed text via JavaBridge.onText (KEY_PRESSED+KEY_TYPED+KEY_RELEASED per char). From the
/// hidden UITextField's change callback. Call on the main thread.
+ (void)postText:(NSString *)text;

/// Press+release one non-text key via JavaBridge.onKeyStroke, by AWT virtual keycode (8=backspace,
/// 10=enter, 27=escape, 9=tab, 37/38/39/40=arrows). Call on the main thread.
+ (void)postKeyStroke:(int)awtKeyCode;

/// Sticky-Shift: hold (held=YES) or release (held=NO) the SHIFT modifier via JavaBridge.setShiftHeld so the
/// engine's isKeyPressed(KC_SHIFT) path reads true on touch (shift-click swaps / Shift+right-click marking /
/// overlay "Configure"). Transition-gated on the Java side. Call on the main thread.
+ (void)postShiftHeld:(BOOL)held;

/// PARITY-IOS-LATCH: sticky-Ctrl / sticky-Alt, mirroring postShiftHeld. Alt is what makes Ground Items'
/// Alt-gated highlight reachable on touch (no hardware key). Transition-gated on the Java side; main thread.
+ (void)postCtrlHeld:(BOOL)held;
+ (void)postAltHeld:(BOOL)held;

/// True when the gamepack has a text field open and awaiting input (search / PM / enter-amount dialog).
/// Polled by the shell to auto-raise/dismiss the soft keyboard. Call on the main thread.
+ (BOOL)textInputOpen;

/// What the open game field takes: 0 none, 1 text, 2 a number (amount prompts, Grand Exchange quantity/price).
/// Non-zero exactly when textInputOpen is YES. Call on the main thread.
+ (int)textInputKind;

/// Direct-present reveal gate: YES once the world geometry is uploaded (the GPU layer can be revealed over the
/// CPU loading-screen blit without a sky flash). YES if the bridge isn't available.
+ (BOOL)sceneWarmedUp;

/// Read the W3 hybrid-chrome read-only snapshot (reverse JNI -> MobileChromeBridge.getSnapshot) as a JSON
/// string: active-tab varc + tab-stone / side-panel / minimap / orbs / chat / viewport bounds in
/// gamepack-canvas pixels. Returns nil before the VM/bridge is up or if the chrome facade is off
/// (-Drunelite.mobilechrome). The native chrome reads this each display tick to position+highlight its
/// rails and to find a tab stone's centre to proxy a tap into. Call on the main thread.
+ (nullable NSString *)chromeSnapshot;

/// Read the W3 touch-targeting menu-peek snapshot (reverse JNI -> MenuPeekBridge.getSnapshot) as a JSON
/// string: {active,loggedIn,seq,mouseX,mouseY,menuOpen,menuScrollable,menuX/Y/W/H,count,entries:[{opt,tgt,
/// type,id,p0,p1,item,wv,deprio,force}]} in display order (entries[0] = top = left-click action). The native
/// press-and-peek UI polls this while streaming the finger via postMoveX:y: to drive the offset reticle/chip
/// and to release-revalidate the top action before committing. nil before the VM/bridge is up or if the
/// facade is off (-Drunelite.menupeek). Read-only — it never invokes; commit via postClickPrecise. Main thread.
+ (nullable NSString *)menuPeekSnapshot;

/// Read the W3 Feature-A HUD-data snapshot (reverse JNI -> HudDataBridge.getSnapshot) as a JSON string:
/// {enabled,loggedIn,seq,orbs:{hp,hpMax,pray,prayMax,energy,spec,run,specEnabled,poison,stamina},
/// minimap:{plane,px,py,mapAngle,players,npcs,dots:[[type,dx,dy]...]},chat:[{type,name,value,ts}...]}. The
/// native HUD veneers (chat-at-top / minimap / orbs) read this each display tick. nil before the VM/bridge is
/// up or if the facade is off (-Drunelite.huddata). Read-only. Call on the main thread.
+ (nullable NSString *)hudSnapshot;
/// Monotonic publish counter for the HUD snapshot (HudDataBridge.getSeq) — skip re-parse when unchanged.
+ (int)hudSeq;

/// W3 A3: ask the engine to hide (YES) or show (NO) its chatbox, so the native chat-at-top veneer replaces it
/// without a duplicate. Re-applied each frame by HudVeneerBridge (the engine rebuilds the toplevel). Main thread.
+ (void)setEngineChatHidden:(BOOL)hidden;

/// W3 A3: relocate the engine's OWN chatbox to the top-left (x,y) and optionally flip it to OSRS transparent-chat
/// mode — the chat-at-top is then the engine's pixel-perfect chat (tabs/scrollback/input stay live), re-applied
/// each frame by HudVeneerBridge. Main thread.
+ (void)relocateEngineChatX:(int)x y:(int)y transparent:(BOOL)transparent;

/// W3 A4: relocate the engine minimap+orbs cluster (MAP_CONTAINER) to canvas (x,y) — for edge-to-edge it moves
/// into the safe area while the scene fills the screen. The cluster stays the live engine HUD, so minimap clicks
/// still walk and orb clicks still fire. x < 0 stops. Re-applied each frame by HudVeneerBridge. Main thread.
+ (void)relocateEngineMinimapX:(int)x y:(int)y;

/// Make the top-right minimap BIGGER: enlarge the engine minimap globe to scalePct% of its natural size and
/// reposition its chrome (compass / orbs / world-map / wiki / store) to keep hugging it. 0/100 = natural. The
/// cluster stays the live engine HUD, so click-to-walk + orb clicks keep working. No-op on an older jar. Main thread.
+ (void)setEngineMinimapScale:(int)scalePct;

/// W3 A4/A6: relocate the engine side panel (SIDE_CONTAINER — inventory/equipment/etc.) to canvas (x,y) so it
/// doesn't clip under the notch at full-bleed. No-op until a tab is open. x < 0 stops. Main thread.
+ (void)relocateEngineSidePanelX:(int)x y:(int)y;

/// W3 A4: open the side-panel tab with the given index (0..13) by replaying that stone's op script — works even
/// while the stones are hidden, so the native 2-col grid drives tabs with no cover patch. Main thread.
+ (void)openEngineTab:(int)tabIndex;

/// Advance the open chat dialogue through the engine's own continue handler.
+ (void)continueEngineDialogue;

/// Bumped only when the published dialogue CHANGES, so it identifies which dialogue the shell is looking at.
+ (long long)dialogueSeq;

/// Pick an option row in the open options dialogue, by its published digit. `seq` is the dialogue sequence the
/// tapped targets were built from, so a dialogue that changed since the tap is not answered by mistake.
+ (void)selectEngineDialogueOption:(int)digit seq:(long long)seq;

/// Press whatever the open dialogue has at this canvas point. For a box with no modelled continue or option row
/// (a quest's own Yes/No, an item box) the buttons are the box's own components, so the bridge matches the point
/// against them on the client thread and fires that widget's engine op. A point with nothing pressable under it
/// is consumed -- a click there would be resolved against the scene behind the chatbox and walk the player.
+ (void)tapEngineDialogueAtX:(int)x y:(int)y;

/// World map (touch): open the world map via HudVeneerBridge.openWorldMap — a discoverable path decoupled from
/// the tiny in-scene orb. No-op on an older jar without openWorldMap. Main thread.
+ (void)openEngineWorldMap;

/// Whether the bundled jar has HudVeneerBridge.switchToModernLayout (an older jar does not). Main thread.
+ (BOOL)canSwitchEngineLayout;

/// Switch the account's game client layout to Resizable - Modern via HudVeneerBridge.switchToModernLayout,
/// which presses it in the game's own Settings > Display dropdown. The setting is server-side and account-wide.
/// One-shot; the outcome shows up as the toplevel changing to 164. No-op on an older jar. Main thread.
+ (void)switchEngineToModernLayout;

/// W3 A4: hide (YES) or show (NO) all 14 engine tab stones, so the native 2-col grid replaces them with no gray
/// cover patch. Re-applied each frame by HudVeneerBridge. Main thread.
+ (void)setEngineStonesHidden:(BOOL)hidden;

/// W3 A3 (bigger chat tabs): the canvas-px height the enlarged native chat-tab row occupies, so the engine pushes
/// the message area (CHATAREA) down past the taller native buttons. 0 restores the default 23px row. Main thread.
+ (void)setEngineChatTabRowHeight:(int)canvasPx;

/// W3 A3 (bigger chat tabs): the canvas-px width the enlarged native row spans, so the engine widens the message
/// area to ALIGN with the bigger buttons. 0 restores the engine's default 519 width. Main thread.
+ (void)setEngineChatAreaWidth:(int)canvasPx;

/// World map (touch): pan the open world map by a finger delta in CANVAS px — the engine converts px to map
/// tiles via the live zoom and moves the map centre ("grab the map", 1:1 with the finger). Main thread.
+ (void)panEngineMapDx:(int)dx dy:(int)dy;

/// World map (touch): {open, map/close/search/zoomIn/zoomOut rects in canvas px} JSON, or {"open":false}.
/// Native polls this to gate gestures on the open map, raise the keyboard on a search tap, and proxy close.
+ (NSString *)mapSnapshot;

/// Minimap-orb touch veneer: the live per-orb canvas bounds JSON from HudVeneerBridge.getOrbSnapshot
/// (hp/prayer/run/spec/store/worldmap/wiki), read each tap so a touch can snap to the nearest orb's enlarged
/// hit-box. nil until the veneer/method is unavailable (older bundle) or logged out.
+ (nullable NSString *)orbSnapshot;

/// Overlay snap-corner safe frame: the screen safe-area insets in CANVAS px. The engine insets the overlay snap
/// corners by these (and drops the top-left corner below the relocated chat) so plugin overlays snapped to a
/// corner (e.g. Quest Helper's top-left guidance panel) clear the curved bezel + the chat. Main thread.
+ (void)setEngineOverlaySafeInsetsL:(int)l t:(int)t r:(int)r b:(int)b;

/// The shell's own controls over the game, as `count` ints {x, y, w, h, ...} in canvas px
/// (HudVeneerBridge.setOverlayKeepOut): plugin overlay boxes keep off them. Replaces the last list. Main thread.
+ (void)setEngineOverlayKeepOut:(const int *)rects count:(int)count;

/// Large portrait (HudVeneerBridge.setHudStrip): the canvas rows on screen, with the chat and minimap drawn full size in
/// the hidden rows below and copied back scaled; the game's windows open between `top` and `bottom` (canvas px).
/// visibleRows <= 0 turns it off. Main thread.
+ (void)setEngineHudStripRows:(int)visibleRows windowTop:(int)top bottom:(int)bottom;

/// W3 A3 (finger-scroll): scroll the chat by deltaCanvasPx (positive = toward newer/bottom) via the chatbox's own
/// scroll layer — NOT a mouse wheel (a wheel over the transparent chat also zooms the camera). Main thread.
+ (void)scrollEngineChat:(int)deltaCanvasPx;

/// World map (touch): scroll the open map's Key/maplist by deltaCanvasPx via the engine's own UPDATE_SCROLLBAR
/// script — NOT a mouse wheel (a wheel over the map zooms it, per onPinch). No-op on an older jar. Main thread.
+ (void)scrollEngineMapPanel:(int)deltaCanvasPx;

/// W3 A3: switch the chat to tab `index` by replaying its op-script (works while the engine tab sprite is hidden,
/// so the native tab row can fully replace the engine's). No-op on an older jar. Main thread.
+ (void)switchEngineChatTab:(int)index;

/// W3 A3: collapse (hide) or expand the engine chat box — tapping the active native tab collapses it (OSRS-mobile
/// behaviour), tapping any tab reopens it. The native tab row stays visible either way. Main thread.
+ (void)setEngineChatCollapsed:(BOOL)collapsed;

/// Put the whole engine chat away, filter stones included, or bring it back: the speech-bubble stone by the door
/// (the official app's "Toggle Chatbox"). A collapse leaves the stones up. Main thread.
+ (void)setEngineChatPutAway:(BOOL)putAway;

/// W3 A3 (bigger chat tabs): live per-tab chat geometry/state (escaped JSON) the native enlarged tab veneer reads
/// each tick — per-tab canvas bounds, selected/new-message flags, and the filter sub-label text + colour. Returns
/// nil until the chat is relocated + logged in. Main thread.
+ (nullable NSString *)chatSnapshot;

/// The real OSRS tab/stone/chat-button sprites captured from the LIVE game cache (HudVeneerBridge.tabSprites) as
/// JSON — {complete, stoneInactive/stoneActive/chatbtn{,Selected,New}:{w,h,px}, icons:[14×{w,h,px}]}, px = base64
/// big-endian ARGB. The shell renders the native chrome from these instead of bundling interface art (exactly how
/// desktop RuneLite draws its UI). Empty "" until the engine has them (a few ticks post-login). Main thread.
+ (nullable NSString *)tabSprites;

/// W3: the live chat MESSAGE lines for the active tab (escaped JSON, colour runs pre-parsed) for the native
/// top-rendered chatbox — the engine can't raster a relocated chatbox, so its messages are drawn natively.
/// Lines are oldest-first. Returns nil until logged in. Main thread.
+ (nullable NSString *)chatLines;

/// The open chatbox dialogue (NPC/player/message/options/level-up) as JSON for the native opaque-parchment
/// renderer, or nil/"{}" when none — the dialogue draws natively with a cutout for the engine's real head.
+ (nullable NSString *)dialogueJson;

// ---- Phase 6 (W3): native plugin-management + config panel (reverse JNI -> MobileUiBridge) -----------
// All call the Java-owned control-plane facade (gated -Drunelite.mobileui). Reads return JSON snapshots
// to parse once per panel open; writes are fire-and-forget onto the correct Java thread (EDT for plugin
// lifecycle, client thread for config) and return an ack JSON. Call on the main thread.

/// Plugin list snapshot (MobileUiBridge.listPlugins): array of {className,name,description,enabled,active,
/// hasConfig,developer,configGroup}. nil before the VM/facade is up.
+ (nullable NSString *)mobilePlugins;

/// Config descriptor for one group (MobileUiBridge.getPluginConfig): {group,items:[{key,name,type,value,
/// secret,…}]} with hidden items omitted and secret values masked. nil if unavailable.
+ (nullable NSString *)mobilePluginConfig:(NSString *)group;

/// Enable/disable a plugin by class name (MobileUiBridge.setPluginEnabled — EDT lane). Returns the ack JSON.
+ (nullable NSString *)mobileSetPluginEnabled:(NSString *)className enabled:(BOOL)enabled;

/// Write one already-serialized config value (MobileUiBridge.setConfig — client-thread lane). Ack JSON
/// carries {ok,writeId}; poll +mobileProcessedWriteId for completion.
+ (nullable NSString *)mobileSetConfigGroup:(NSString *)group key:(NSString *)key value:(NSString *)value;

/// Reset one config item to its default (MobileUiBridge.resetConfig — client-thread lane). Ack JSON.
+ (nullable NSString *)mobileResetConfigGroup:(NSString *)group key:(NSString *)key;

/// Reset an ENTIRE plugin's config to defaults + plugin.resetConfiguration (MobileUiBridge.resetPluginConfig). Ack JSON.
+ (nullable NSString *)mobileResetPluginConfig:(NSString *)group;

/// The frame-rate cap and idle logout time for the native Game settings screen (MobileUiBridge.gameSettings):
/// {"fpsCap":N,"idleLogoutMinutes":M}, fpsCap 0 = no cap. nil before the facade is up or on an older jar.
+ (nullable NSString *)gameSettings;
/// Cap the frame rate through the FPS Control plugin (0 removes the cap). Ack JSON, nil if unavailable.
+ (nullable NSString *)setFpsCap:(int)fps;
/// Holds the game to `fps` while the phone is hot, on top of any cap the player set; 0 lifts it (MobileUiBridge
/// setHeatFpsCap). In memory only, so it saves nothing to the player's profile. NO until the bridge is up: try again.
+ (BOOL)setHeatFpsCap:(int)fps;
/// Set the idle logout time through the Logout Timer plugin, in minutes. Ack JSON, nil if unavailable.
+ (nullable NSString *)setIdleLogoutMinutes:(int)minutes;

/// Fully-seeded default Notification JSON (MobileUiBridge.notificationDefaults) — base for the notification sub-editor.
+ (nullable NSString *)mobileNotificationDefaults;

/// Panel input P0 (PANEL-1/2). After a mobilePanelClick, poll mobilePanelTextActive to decide whether to raise the
/// soft keyboard; mobilePanelText returns the focused field's current text (pre-fill); mobileSetPanelText mirrors the
/// hidden field on each change; mobilePanelKey dispatches Enter/Backspace; long-press = BUTTON3; wheel = inner scroll;
/// move = a parked hover so Swing tooltips fire.
+ (BOOL)mobilePanelTextActive;
+ (nullable NSString *)mobilePanelText;
+ (nullable NSString *)mobileSetPanelText:(NSString *)text;
+ (nullable NSString *)mobilePanelKey:(int)vk;
+ (nullable NSString *)mobilePanelLongPressX:(int)x y:(int)y;
+ (nullable NSString *)mobilePanelWheelX:(int)x y:(int)y rotation:(int)rotation;
+ (nullable NSString *)mobilePanelMoveX:(int)x y:(int)y;

/// Latest event sequence (MobileUiBridge.getMobileUiSeq) — the panel stores this and polls for a bump to
/// know when to re-read (config/plugin changed, including changes it didn't make).
+ (long long)mobileUiSeq;

/// Drain the oldest pending OS notification ("titlebody"), or nil if none (MobileUiBridge.nextNotification).
/// The shell polls this and raises a UNUserNotificationCenter notification. Main thread.
+ (nullable NSString *)mobileNextNotification;

/// SHOT-2: drain the next auto-screenshot's sandbox PNG path, or nil (MobileUiBridge.nextScreenshot). The shell
/// reads the file and, when auto-save is on, copies it into Photos. Main thread.
+ (nullable NSString *)mobileNextScreenshot;

/// Drain the oldest pending outbound URL, or nil if none (MobileUiBridge.nextLink). The shell polls this and
/// opens it in an SFSafariViewController. Main thread.
+ (nullable NSString *)mobileNextLink;

/// Pin/unpin a plugin by display name (MobileUiBridge.setPinned) — persisted as the shared pinnedPlugins CSV.
/// Returns the ack JSON. Main thread.
+ (nullable NSString *)mobileSetPinned:(NSString *)pluginName pinned:(BOOL)pinned;

/// Hub install/remove progress ({refreshing,seq}) (MobileUiBridge.hubState). The hub screen polls this to show
/// a spinner and re-fetch the manifest when seq bumps. Main thread.
+ (nullable NSString *)mobileHubState;

/// KEY-1: curated fireable plugin action-hotkeys + current bindings, JSON [{group,key,label,keyCode,mods,bind}].
+ (nullable NSString *)mobileHotkeyActions;

/// KEY-1b: every currently-bound plugin keybind (MobileUiBridge.boundKeybindsJson), same JSON shape as
/// mobileHotkeyActions. Drives the dynamic hotkey picker so it lists all bound actions, not a curated few.
+ (nullable NSString *)mobileBoundKeybinds;

/// KEY-1: fire a plugin action-hotkey by (config group, key) — the bridge reads the live Keybind + synthesizes it.
+ (void)mobileFireHotkeyGroup:(NSString *)group key:(NSString *)key;

/// Events since `sinceSeq` as JSON (MobileUiBridge.pollMobileUiEvents): {seq, events:[{seq,kind,group,key}]}.
+ (nullable NSString *)mobilePollEventsSince:(long long)sinceSeq;

/// Highest processed write id (MobileUiBridge.getProcessedWriteId) — the fire-and-forget write ack.
+ (long long)mobileProcessedWriteId;
/// YES once every config write this shell has queued has reached the client thread and run, so the live config says
/// what it's going to. Main thread.
+ (BOOL)mobileConfigWritesLanded;

/// Flush pending config to disk (MobileUiBridge.flushConfigQueued, behind the writes already queued). iOS closes
/// the app without running RuneLite's shutdown/periodic flush, so the shell calls this on config/panel close + app
/// background so plugin toggles and config edits survive a relaunch. Returns the flush's write id (0 when it
/// couldn't be queued): once +mobileProcessedWriteId reaches it, the file is written.
+ (long long)mobileFlushConfig;

/// Plugin-hub catalog JSON (MobileUiBridge.hubManifest). First call returns {"status":"loading"} while the
/// signed manifest downloads on a background thread; poll until status is "ok" (plugins[]) or "error:*".
+ (nullable NSString *)mobileHubManifest;

/// Install (uninstall=NO) or uninstall (uninstall=YES) a hub plugin by internal name
/// (MobileUiBridge.hubInstall/hubUninstall — client-thread + flush). Returns the ack JSON.
+ (nullable NSString *)mobileHubInstall:(NSString *)internalName uninstall:(BOOL)uninstall;

// ---- Plugin side-panels (MobileUiBridge: toolbar + embedded-Swing panel surface) -------------------

/// Toolbar list JSON (MobileUiBridge.listPanels): [{index,tooltip}] for plugins that provide a side panel.
+ (nullable NSString *)mobileListPanels;

/// Open/realize + activate the panel at toolbar `index` (starts its repaint loop); close the active panel.
+ (void)mobileOpenPanel:(int)index;
+ (void)mobileClosePanel;

/// Frame sequence of the active panel's rendered buffer — poll to know when to re-pull the image.
+ (int)mobilePanelFrameSeq;

/// The active panel's full rendered image (natural width PluginPanel.PANEL_WIDTH; native scales + scrolls).
+ (nullable UIImage *)mobilePanelImage;

/// Dispatch a click at panel-space (x,y) into the active panel's Swing tree (buttons/checkboxes/etc.).
+ (void)mobilePanelClickX:(int)x y:(int)y;

// ---- Native Quest Helper reflow (QuestHelperBridge: reflection into the external quest-helper plugin) ----

/// Whether the native Quest Helper screen can be offered (plugin installed + reflectable). When NO, the dock
/// falls back to the generic rendered-image panel.
+ (BOOL)questAvailable;

/// Native XP Tracker panel (§3.4, XpTrackerBridge): whether the XP Tracker plugin is loaded + reflectable.
+ (BOOL)xpTrackerAvailable;
/// Tell the bridge the native XP Tracker screen is open/closed (gates the client-thread snapshot refresh).
+ (void)xpTrackerSetUiOpen:(BOOL)open;
/// The per-skill session JSON, snapshotted on the client thread about once a second while open:
/// {available, skills:[{skill,xpGained,xpHr,xpLeft,actions,actionsLeft,actionsHr,timeToLevelSec,startLevel,
/// endLevel,progress (0..1)}], overall:{the same fields}}. Only skills with XP gained this session are listed.
+ (nullable NSString *)xpTrackerJson;
/// A skill's small icon (skill = the JSON's enum name, e.g. "ATTACK") as a base64 PNG; nil if none.
+ (nullable NSString *)xpTrackerSkillIcon:(NSString *)skill;

/// Native Notes panel (§3.4): whether the Notes plugin is loaded, plus read/write of the single note string
/// (config group "notes"/"notesData"). notesSet persists on the client-thread config lane.
+ (BOOL)notesAvailable;
+ (nullable NSString *)notesGet;
+ (void)notesSet:(NSString *)text;

/// Native Grand Exchange panel (§3.4): whether the GE plugin is loaded; a ui-open gate that drives the
/// client-thread offer/history refresh; the cached offers+history JSON; and live tradeable-item name search
/// ({results:[{id,name,price}]}) for the Search tab (the desktop plugin's box doesn't live-filter).
+ (BOOL)geAvailable;
+ (void)geSetUiOpen:(BOOL)open;
+ (nullable NSString *)geJson;
+ (nullable NSString *)geSearch:(NSString *)query;

/// Tell the bridge the native Quest Helper screen is open/closed (gates its client-thread snapshot refresh).
+ (void)questSetUiOpen:(BOOL)open;

/// Quest catalog JSON: {available, quests:[{name,difficulty,type,state}]}. Snapshotted on the client thread.
+ (nullable NSString *)questListJson;

/// Active quest JSON: {available, active, name, steps:[..], items:[..], general:[..]} or {active:false}.
+ (nullable NSString *)questActiveJson;

/// Start / stop a quest helper by quest name (queued onto the client thread).
+ (void)questStart:(NSString *)name;
+ (void)questStop;

// ---- Native overlay edit-mode (OverlayBridge) — move / snap / reset live overlays (OVL-2/3/5) ------

/// Whether overlay edit-mode is available (the OverlayManager has resolved).
+ (BOOL)overlayAvailable;
/// Tell the bridge the edit screen is open/closed (gates its client-thread snapshot refresh).
+ (void)overlaySetUiOpen:(BOOL)open;
/// Movable overlays JSON: {available, overlays:[{name,bounds:[x,y,w,h],position,movable,snappable,resizable,dynamic}]}.
+ (nullable NSString *)overlaysJson;
/// Move an overlay to a free pixel location (canvas px) + persist (clears its snap position). Ack JSON.
+ (nullable NSString *)overlaySetLocation:(NSString *)name x:(int)x y:(int)y;
/// Snap an overlay to a corner by OverlayPosition name (TOP_LEFT…) + persist (clears its free location). Ack JSON.
+ (nullable NSString *)overlaySetPosition:(NSString *)name position:(NSString *)position;
/// Reset an overlay to its default position/size. Ack JSON.
+ (nullable NSString *)overlayReset:(NSString *)name;
/// Nearest snap-corner OverlayPosition name for a dropped point (canvas px), for a live snap preview.
+ (nullable NSString *)overlaySnapForX:(int)x y:(int)y canvasW:(int)canvasW canvasH:(int)canvasH;

// ---- RuneLite-account login (config sync) — distinct from the Jagex game login --------------------

/// Whether the RuneLite-account bridge is wired (offer the login row only when YES).
+ (BOOL)accountAvailable;
/// {"available":bool,"loggedIn":bool,"username":".."} — the current RuneLite-account session (quick read).
+ (nullable NSString *)accountSessionJson;
/// Begin the runelite.net OAuth login (opens the OAuth url in SFSafariViewController; completes async via the
/// localhost loopback redirect, after which ConfigManager syncs the user's profiles + installed hub plugins).
+ (void)accountLogin;
/// Sign out of the RuneLite account (closes + deletes the saved session).
+ (void)accountLogout;

// ---- Native World Switcher reflow (WorldSwitcherBridge) --------------------------------------------

/// Whether the native World Switcher screen can be offered (WorldService has a world list).
+ (BOOL)worldAvailable;
/// Tell the bridge the native World Switcher screen is open/closed (gates the client-thread snapshot refresh).
+ (void)worldSetUiOpen:(BOOL)open;
/// World list JSON: {available, current, worlds:[{id,players,location,favourite,members,pvp,highRisk,activity,types}]}.
+ (nullable NSString *)worldListJson;
/// Hop to a world by number (queued onto the client thread; requires being logged in).
+ (void)worldHop:(int)worldId;
/// WH-1: mark/unmark a world as a favourite (shared worldhopper config; favourites float to the top).
+ (void)worldSetFavourite:(int)worldId favourite:(BOOL)favourite;
/// WH-3: quick-hop to the next/previous world in the configured filter (the plugin's signature keybind action).
+ (void)worldHopDirection:(BOOL)previous;

// ---- Native Loot Tracker reflow (LootTrackerBridge) — read-only per-source loot, "Reset All" write -----

/// Whether the native Loot Tracker screen can be offered (the Loot Tracker plugin is loaded + reflectable).
+ (BOOL)lootAvailable;
/// Tell the bridge the native Loot Tracker screen is open/closed (gates the client-thread snapshot refresh).
+ (void)lootSetUiOpen:(BOOL)open;
/// Loot JSON: {available, sources:[{name,subTitle,type,kills,totalValue,items:[{id,name,qty,ge,ha}]}]}.
/// Snapshotted on the client thread, aggregated per source (kill) with duplicate item ids merged.
+ (nullable NSString *)lootJson;
/// Clear the entire loot log (the desktop "Reset All"): empties the records + deletes the persisted drops.
/// Ack JSON. No-op on an older staged jar that predates the bridge's resetAll().
+ (nullable NSString *)lootResetAll;

// ---- Native Time Tracking reflow (TimeTrackingBridge) — read-only farming/bird-house/timer countdowns ----

/// Whether the native Time Tracking screen can be offered (the Time Tracking plugin is loaded + resolvable).
+ (BOOL)timeTrackingAvailable;
/// Tell the bridge the native Time Tracking screen is open/closed (gates the client-thread snapshot refresh).
+ (void)timeTrackingSetUiOpen:(BOOL)open;
/// Time Tracking JSON: {available, farming:[…], contract:{…}, birdhouses:[…], timers:[…], stopwatches:[…]}.
/// Each farming/contract/bird-house entry carries an absolute readyTime (epoch-s) + a derived remainingSec.
+ (nullable NSString *)timeTrackingJson;

// ---- Native Config Profiles (ConfigProfileBridge) — list profiles + switch the active one --------------

/// Whether the native Config Profiles screen can be offered (ConfigManager + ProfileManager wired).
+ (BOOL)profilesAvailable;
/// Profiles JSON: {available, profiles:[{id,name,active,sync,internal}]}. `id` is a long; `active` marks the
/// currently-loaded profile; `internal` flags the engine's own profiles (e.g. $rsprofile).
+ (nullable NSString *)profilesJson;
/// Switch the active config profile by id (a write: reloads config asynchronously on a background executor).
/// Ack JSON; the native side re-reads profilesJson to pick up the new active flag.
+ (nullable NSString *)switchProfile:(long long)profileId;

// ---- Native Infobox menu (InfoBoxBridge) — the touch equivalent of right-clicking an infobox (#20) -------

/// Whether the native infobox menu can be offered (the InfoBoxManager is resolvable).
+ (BOOL)infoBoxAvailable;
/// Tell the bridge the native infobox menu is open/closed (gates the client-thread snapshot refresh).
+ (void)infoBoxSetUiOpen:(BOOL)open;
/// Infoboxes JSON: {available, infoboxes:[{index,name,text,tooltip,menu:["Detach",…]}]}, ordered as the engine.
+ (nullable NSString *)infoBoxesJson;
/// Fire the chosen infobox menu option (index into the live list + option text). Ack JSON. Runs on the client
/// thread, posting InfoBoxMenuClicked exactly like the desktop right-click.
+ (nullable NSString *)invokeInfoBoxMenu:(int)index option:(NSString *)option;

@end

NS_ASSUME_NONNULL_END
