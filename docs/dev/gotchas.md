# Gotchas

These are the traps that have cost real time in this codebase: the ones where the symptom points somewhere
other than the cause. Each entry gives the rule first, then what it looks like, why it happens, what to do, and
where it lives in the code. Skim the area you're about to work in before you start; most of these were learned
twice before they were written down.

Where a gotcha belongs mostly to one port, the entry says so. [ios.md](ios.md) and [android.md](android.md)
cover each port in depth, and [testing-qa.md](testing-qa.md) covers the checks that catch several of these.

## Input and touch

### Headless AWT drops posted key events

**Deliver keys by calling the canvas's own key listeners on the EDT, never by posting a `KeyEvent`.**

- **Symptom:** synthesized keys never reach the game, while synthesized taps always do.
- **Cause:** AWT doesn't hand a `KeyEvent` to its source component. It gives it to the `KeyboardFocusManager`,
  which routes it to the focus owner. Headless there is no focused window, so there is no focus owner and the
  event is discarded. Posting `FOCUS_GAINED` first doesn't help; it is dropped the same way. A `MouseEvent`
  goes to its source, which is why taps work.
- **What to do:** call the listeners from `canvas.getKeyListeners()` on the EDT. Keys go through one
  single-threaded pacer so they arrive in the order they were made.
- **In code:** `JavaBridge.dispatchKey`, `JavaBridge.keyPacer`.

### Android's gesture detector cancels a tap, and the long-press with it, at about 8 dp

**Own the tap/drag boundary yourself: withhold moves from `GestureDetector` until the finger leaves your
radius, and don't apply the first scroll.** Android only; iOS has the same radius (`kSceneDragSlop`).

- **Symptom:** an ordinary finger roll during a tap turns the camera a few pixels instead of clicking, and a
  press-and-hold with the same roll never opens the menu. Two symptoms that look unrelated.
- **Cause:** `ViewConfiguration.scaledTouchSlop` is about 8 dp. Once a move crosses it, the detector drops the
  tap (`onSingleTapUp` never fires) and removes its pending long-press.
- **What to do:** keep one slop radius (18 dp) that the tap, the hold and the drag all read, withhold
  `ACTION_MOVE` from the detector until the finger leaves it, and time the long-press yourself (the detector's
  long-press is off). Then the trap behind the fix: the withheld travel arrives as the **first** `onScroll`'s
  distance, because the detector measures from the down event. Use that first call to classify the gesture and
  return without applying it, or every drag jumps by the whole slop on its first frame. iOS zeroes the pan's
  translation at `Began` for the same reason.
- **In code:** `MainActivity.kt` (`sceneDragSlopPx`, `holdRunnable`, the gesture listener's `onScroll`);
  `ViewController.m` (`kSceneDragSlop`).

### A per-tap answer published through one slot and one counter is a queue

**Match tap answers to taps first-in, first-out, and queue every tap that produces an answer.**

- **Symptom:** tap two spots quickly and the newer tap marker is recoloured, or withdrawn, by a result that
  belongs to the older tap, while the older marker stays the colour it was drawn in.
- **Cause:** the bridge publishes what a tap hit as `lastTapKind` plus one `tapKindSeq` bump per resolved tap,
  in click order. A single pending slot works only while nothing is drawn before the answer arrives. Once the
  marker is drawn optimistically on lift, a second tap inside the resolve window takes the first tap's answer.
- **What to do:** keep a FIFO of pending markers; each bump belongs to the oldest one still waiting. Two rules
  keep it honest. Only the newest bump's kind is readable (the slot holds one value), so when several bumps
  arrive in one frame the overtaken entries keep the look they were drawn with. And every tap that produces a
  bump must be in the queue, including taps that draw nothing (queue a placeholder), or its answer is fed to
  the next real marker.
- **In code:** `JavaBridge.publishTapKind`, `getTapKindSeq`, `getLastTapKind`; Android `MainActivity.kt`
  (`pendingRings`, `resolvePendingRings`).

### On the open world map, touch coordinates are not overlay coordinates

**Convert a surface point into the overlay's space before you place or hit-test anything drawn over the
game.**

- **Symptom:** a long-press menu on the world map opens away from the finger, and its rows answer to the
  wrong place.
- **Cause:** while the map is open, both ports stretch the game surface with a view transform: a non-uniform
  scale and translate on Android, a uniform scale on iOS. Touch points arrive in the surface's untransformed
  space. That is right for game coordinates and wrong for any sibling view drawn over the surface.
- **What to do:** map the point through the transform. Android: `surfaceToOverlay` (the view matrix plus the
  views' offsets). iOS: `engineMenuRectInView` (`convertRect:toView:`).
- **In code:** `MainActivity.kt` (`applyMapFullscreen`, `surfaceToOverlay`); `ViewController.m`
  (`applyMapZoom:windowCanvas:`, `engineMenuRectInView`).

### Camera angles are 14-bit units

**Feed pixel deltas to the existing camera path; don't write new camera math.**

- **Symptom:** a new camera control turns eight times too slowly, or its pitch clamp pins the camera.
- **Cause:** game revision 239 widened camera angles from 11 bits (0-2047) to 14 bits (0-16383), an 8x larger
  unit space. Constants copied from older code are off by that factor.
- **What to do:** call `JavaBridge.onCameraDrag(dx, dy)` with raw pixels, or `setCameraHold(dxPerSec,
  dyPerSec)` for a held turn (set it once on press; `0, 0` releases). The bridge accumulates sub-pixel
  remainders, writes the yaw and pitch *targets* on the client thread, wraps yaw at 16384 and clamps pitch.
  A held turn is a rate: the bridge feeds each frame's elapsed share of it, so the frame rate doesn't set the
  speed.
- **In code:** `JavaBridge` (`onCameraDrag`, `setCameraHold`, `applyCameraDrag`, `PITCH_MIN`, `PITCH_MAX`).

## Chatbox, dialogues and widgets

### Nothing in the chatbox region can be driven by a synthetic click

**Answer the chatbox with a menu action, resolved on the client thread: `WIDGET_CONTINUE` for a continue or an
option row, `CC_OP` for a button.**

- **Symptom:** tapping "Click here to continue" or a dialogue option walks the player, and walking away closes
  the dialogue. A quest's own Yes/No box can't be answered at all.
- **Cause:** the chatbox is force-positioned to the top of the screen, and the engine resolves a click there
  against the scene behind it. Relocated orbs and the side panel do take clicks; this is specific to the
  chatbox.
- **What to do:** fire `client.menuAction(...)` with `param0 = -1` for a static component and the child index
  for a dynamic one (an index for a static component misroutes the dispatch; -1 for a dynamic child names no
  row). Resolve the target when the action runs, never from a stored id, and drop a tap aimed at a dialogue
  that has since changed (`dialogueSeq`, or the tapped group). A chatbox dialogue component also reads
  `isHidden() == true` while it is plainly on screen, because `isHidden()` walks the chatbox's ancestry. Never
  filter candidates by it; judge visibility by the flags inside the box.
- **In code:** `HudVeneerBridge` (the continue and option dispatch, `tapDialogueNow`);
  `GameLayoutSwitch.press` uses the same `param0` rule. Background:
  [docs/handoffs/input-dialogue-camera.md](../handoffs/input-dialogue-camera.md).

### A chatbox dialogue is not a list of interface groups

**Ask the engine what is opened onto the chatbox; don't keep a list of dialogue groups.**

- **Symptom:** a box the code doesn't know (a quest's confirm prompt, a destroy-item confirm) keeps the native
  chat veneer over it, and every tap on it goes to the chat instead.
- **Cause:** a chatbox dialogue is whatever the engine has opened onto a component of the chatbox group. A
  list of named groups misses every box that content opens for itself.
- **What to do:** walk `client.getComponentTable()` and look for an entry whose parent component belongs to
  the chatbox group (`InterfaceID.CHATBOX`).
- **In code:** `HudVeneerBridge.chatboxSubInterface`.

### The chatbox has two writers every frame, and the pre-raster one wins

**Change chatbox state at both seams in the same edit.**

- **Symptom:** a condition you added "never takes effect", as if the state were never set. Or the chatbox is
  rebuilt twice a frame.
- **Cause:** `HudVeneerBridge.tick()` runs in the post-render draw callback, and `preRender()` runs from
  `Hooks.frame()` (the `BeforeRender` seam) before anything rasterizes. Most chatbox state is written at both. A
  change made in `tick` and not mirrored in `preRender` is reverted before it can be drawn. If the two seams
  write opposite transparency values, each change re-runs the chatbox build, twice a frame. Also note the
  pairing: the chatbox transparency setting picks *which* box the engine paints, and `CHAT_BACKGROUND` is the
  widget that paints it. Setting one without the other buys nothing.
- **What to do:** grep for every write of the state you're changing and update both seams together.
- **In code:** `HudVeneerBridge.preRender`, `HudVeneerBridge.tick`, `setChatboxTransparency`, the
  `CHAT_BACKGROUND` hides. Background: [docs/handoffs/ge-item-search.md](../handoffs/ge-item-search.md).

### A fix in the shared bridge is half a fix

**When a shared flag changes meaning, find every consumer of it in both shells.**

- **Symptom:** the bridge makes a dialogue tappable, and one port still can't tap its top edge.
- **Cause:** both ports read the same `dialogueActive` flag, but each shell has to act on it. iOS hid its chat
  tab row on it; Android's tab row ignored it and stayed as an opaque strip across the top of the chatbox. That
  strip is a view, and it consumed the touch before the surface's gesture handling (and its dialogue gate)
  ever saw it.
- **What to do:** grep both shells for the flag and for every native view over the region. A view that merely
  draws over an area also takes its taps.
- **In code:** Android `MainActivity.applyChatTabs`; iOS `ViewController.m` (`hideChatTabs`).

### `revalidate()` skips children

**After resizing a HUD container, re-lay the subtree that must follow it with `revalidateScroll()`.**

- **Symptom:** you resize a container and its children keep the old layout. In the chat, the input line ended
  up below the chat's bottom edge, where the container clipped it away.
- **Cause:** `Widget.revalidate()` re-lays only that widget.
- **What to do:** call `revalidateScroll()` on the subtree that sizes from the container, and only that
  subtree: other children (the prompt layer, for example) are laid out by the game when it opens them.
- **In code:** `HudVeneerBridge` (the chat area and display pins).

### A forced position of -1 means "none"

**To place a widget at x = -1, set its own position, not a forced one.**

- **Symptom:** `setForcedPosition(-1, y)` leaves the widget exactly where it was.
- **Cause:** -1 is the "no forced position" value.
- **What to do:** `setXPositionMode(WidgetPositionMode.ABSOLUTE_LEFT)`, `setOriginalX(-1)`, then
  `revalidate()`.
- **In code:** `HudVeneerBridge` (`OFFICIAL_SCROLLBAR_X`, the chat scrollbar).

### Restore only the hidden flags you set, and read them with `isSelfHidden()`

**Record what you hid, per widget, and restore exactly that.**

- **Symptom:** when your feature turns off, a layer the engine had hidden on its own is shown.
- **Cause:** `Widget.isHidden()` also counts a hidden parent. A helper that guards on it skips a layer that was
  already hidden on the way in, then force-shows it on the way out. The mouse-over layer is the live case: the
  engine owns that flag frame to frame.
- **What to do:** read and write each widget's own flag (`isSelfHidden()`), and keep a record of the widgets
  you hid.
- **In code:** `HudVeneerBridge.setMapHudHidden`, the stone-row hides. Background:
  [docs/handoffs/worldmap-hud-overlap.md](../handoffs/worldmap-hud-overlap.md).

### The hover label is not a widget

**Turn the mouse-over text off through the client; no widget hide will reach it.**

- **Symptom:** after every HUD layer over the world map is hidden, a "Walk here" label still draws on it.
- **Cause:** the engine draws the mouse-over text itself.
- **What to do:** `client.setMouseoverTextEnabled(false)` while it must not show, and turn it back on after.
- **In code:** `HudVeneerBridge` (the world-map hides).

### A game setting is a button the server answers

**Change a server-side setting by pressing the game's own control with the engine's menu action, then read it
back.**

- **Symptom:** writing the varbit, or replaying the option's script, changes nothing.
- **Cause:** the game client layout (Classic or Modern) is `RESIZABLE_STONE_ARRANGEMENT`, a server-side varbit
  that follows the account. The option's own "Select" script only closes the list; the change is the server
  answering the press.
- **What to do:** build the game's dropdown with its own click handler, then fire the option's op as a `CC_OP`
  menu action, which is what sends the press. Check every id derived from the game cache before using it, so a
  game update that moves the setting fails in the log instead of pressing whatever now sits there. Confirm by
  reading the varbit back.
- **In code:** `GameLayoutSwitch`.

## HUD and layout

### Hide a container; don't move it

**To clear part of the HUD, hide its container for as long as needed. Moving it doesn't take everything with
it.**

- **Symptom:** you move the minimap container off-screen for the world map. The globe goes, but the orbs stay
  painted over the map.
- **Cause:** the orbs are hard-pinned on their own layer and carry their own laid-out positions, so they don't
  read the container's position.
- **What to do:** hide the ancestor container. Drawing stops at a hidden container, so nothing under it can
  paint, wherever it is pinned. Assert the hide from `preRender` (the pre-raster seam), and restore only your
  own hides (see above).
- **In code:** `HudVeneerBridge.setMapHudHidden`.

### Decide the layout from the layout setting, not the toplevel id

**The native HUD needs Resizable - Modern. Read that from "resizable" plus the layout varbit, never from the
toplevel interface id.**

- **Symptom:** during a background/foreground transition the HUD briefly decides the player is in the wrong
  layout, or a drag target claims the top-left corner of the screen.
- **Cause:** in live play the toplevel is 164 (`TOPLEVEL_PRE_EOC`, which is RuneLite's name for Resizable -
  Modern; 161 is Classic). During some transitions it reads 165 for a moment, and widgets can be parked
  off-canvas at negative coordinates.
- **What to do:** use the chrome snapshot's `rootKind`, which comes from `isResized()` and
  `RESIZABLE_STONE_ARRANGEMENT`. Publish only on-screen rectangles.
- **In code:** `MobileChromeBridge.resolveRoot`; the item-grid bounds in `JavaBridge`; iOS `updateLayoutSwitch`.

### Jagex's client guidelines limit what the HUD may do to game panels

**Never resize the game's panels, and never move or resize click zones inside combat options, the inventory,
worn equipment or the spellbook, or resize them in the prayer book.**

- **Symptom:** none you will see in testing. This is about the account, not the build.
- **Cause:** Jagex's third-party client guidelines prohibit those changes. Moving a whole panel at its normal
  size is something upstream RuneLite already lets every desktop player do: the side panel is a movable
  overlay.
- **What to do:** move whole panels only, at their normal size, and never rearrange their contents. Treat this
  as a reading of the guidelines, not a ruling, and keep the risk framing in the [README](../../README.md): a
  self-built client is not on the approved-client list, so use a throwaway account.
- **In code:** upstream `WidgetOverlay` (the movable inventory parent); the panel moves in `HudVeneerBridge`.

### A plugin settings screen must show something

**Offer a plugin settings screen only when at least one item on it is shown.**

- **Symptom:** the Notes plugin got a settings screen holding nothing but "Reset all settings", and pressing it
  wiped the notes.
- **Cause:** reset restores defaults for hidden config items too, and some plugins keep user data in a hidden
  item (Notes keeps the notes text there).
- **What to do:** decide `hasConfig` with the same filter the config editor uses to show items. The simulator
  plugin sweep is what found this.
- **In code:** `MobileUiBridge.hasShownItems`, `isShownItem`.

## Rendering and GL

### The Android GL bridge lags the iOS one

**For an Android-only GPU bug, diff the Android bridge against the iOS bridges first.** Android mostly.

- **Symptom:** Android-only artifacts on the GPU renderer: translucent screen-wide wedges, wall pieces dropping
  out for one frame.
- **Cause:** `android/app/src/main/cpp/librlawt.cpp` is a port of the iOS GL bridge and has missed later iOS
  fixes. In this case it sized NIO buffer arguments by `capacity()` instead of `remaining()` from `position()`,
  so reused draw-range buffers replayed stale ranges every frame.
- **What to do:** compare against `ios/dev-tools/gpu-routec/jni/` and `ios/dev-tools/gpu-zone/jni/`. LWJGL
  takes a buffer argument as `remaining()` elements from `position()`. For one-frame artifacts, record the
  screen and score it frame by frame; screenshots miss them.
- **In code:** `librlawt.cpp` (`rc_buf_remaining`, `rc_buf_position`).

### GL ES pairs each depth format with specific types

**Remap desktop depth-texture types to the GL ES pairing.**

- **Symptom:** on 117 HD the whole scene is darker than on desktop, with no sun shadows.
- **Cause:** RLHD allocates its shadow maps as `DEPTH_COMPONENT24` (or `16`) with type `GL_FLOAT`. Desktop GL
  allows that; GL ES 3 pairs `DEPTH_COMPONENT16` with `UNSIGNED_SHORT` or `UNSIGNED_INT`, `DEPTH_COMPONENT24`
  with `UNSIGNED_INT`, and only `DEPTH_COMPONENT32F` with `FLOAT`. A strict driver refuses the call, the shadow
  FBO stays incomplete, and every shadow lookup reads depth 0, so everything counts as shadowed.
- **What to do:** both bridges rewrite the type when no data is uploaded. Keep the two in step; Android logs
  each remap as a `[shadowmap]` line.
- **In code:** `librlawt.cpp` (`rc_glTexImage2D`); `ios/dev-tools/gpu-routec/jni/routec_gl_jni.m`.

### A launch that never draws demotes the next one to CPU

**On Android, GPU and 117 HD are trusted only after they present frames; anything that stops a launch drawing
counts as a renderer failure.** Android only. See [renderers.md](renderers.md).

- **Symptom:** you launched on GPU or 117 HD, and the next launch comes up on CPU without being asked.
- **Cause:** before a GPU or 117 HD boot the app writes an `auto-gpu-armed` cookie, and a watchdog clears it
  once a few frames present. If none present within 240 s (a crash, a black screen, or a launch that just never
  drew for some other reason), the cookie stays, and the next start reverts to CPU: permanently for an
  automatic choice, once for a choice the player made.
- **What to do:** if a test launch didn't draw for a reason unrelated to the renderer, clear the cookie before
  the next launch. Picking the renderer again in Settings clears it; on a debug build you can also run
  `adb shell run-as dev.audaro.runemobile rm -f files/auto-gpu-armed`.
- **In code:** `MainActivity.kt` (`startAutoGpuWatchdog`, `setRendererPref`, the startup cookie check).

### Live 117 HD config flips persist only on the periodic save

**Settings changed through the debug broadcast reach disk only when RuneLite next saves its config.** Android
debug builds.

- **Symptom:** a `SET_HD_CONFIG` flip works live, then reverts after a force-stop.
- **Cause:** the broadcast receiver sets the values without flushing. RuneLite's `ConfigManager` saves on a
  schedule: first after 30 s plus up to five minutes, then every five minutes. The native settings screens
  flush explicitly; the broadcast doesn't.
- **What to do:** check the saved profile on disk before you rely on a flip surviving a restart, or change the
  setting through the native screen. The day/night cycle is forced off on every launch, so it never sticks.
- **In code:** `MainActivity.kt` (the `SET_HD_CONFIG` receiver); `ConfigManager` (the scheduled
  `sendConfig`); `MobileUiBridge.flushConfig`; `RLHDStarter` (`daylightCycle`).

## JVM and boot

### Read the threading rules before you touch threads

**Each thread attaches itself; only the client thread touches the engine; values cross as copies.**

- **Symptom:** crashes or corrupted state that move around between runs, typically after someone "hardened"
  the plumbing with a lock or a cached `JNIEnv`.
- **Cause:** the bridge looks under-synchronized on purpose. It is sound only because of a discipline no single
  call site shows.
- **What to do:** never cache or share a `JNIEnv` across threads (cache only global class and method refs);
  never call an engine or bridge method that reads client state from the native UI thread (enqueue an intent);
  publish snapshots as immutable `volatile` references; keep `GetPrimitiveArrayCritical` windows tight.
- **In code:** `runelite-client/src/main/java/net/runelite/client/headless/package-info.java:32-66`.
  [architecture.md](architecture.md) covers the design.

### The code after the boot main returns runs mid-session

**Never tear the VM down after `DeviceHeadlessBoot.main` returns; park the thread.** iOS.

- **Symptom:** about four minutes into every session, all input dies (tap, long-press, pan, pinch) while the
  world keeps rendering.
- **Cause:** `DeviceHeadlessBoot.main` returns when its `headless.runSeconds` window ends (the iOS launcher
  passes 240), while the engine's non-daemon threads keep the session alive. The "unreachable" teardown after
  it cleared the VM pointer, which turned the bridge off. Calling `DestroyJavaVM` instead blocks until the
  engine's threads exit, then unloads the VM under callers that still think it is live.
- **What to do:** the launch thread parks for the life of the process. A future in-app "quit session" must
  quiesce every JNI caller, clear the VM pointer, and only then destroy the VM, in that order.
- **In code:** `JVMLauncher.m` (`gVM`, the end of the JVM main thread).

### HotSpot returns NULL for every JNI lookup made while an exception is pending

**Clear the exception after every lookup that can fail.**

- **Symptom:** one missing optional method makes every lookup after it fail too.
- **Cause:** a failed `FindClass` or `GetMethodID` leaves an exception pending, and HotSpot answers any further
  lookup with NULL until it is cleared.
- **What to do:** check and clear after each lookup, especially optional ones, and log what it was.
- **In code:** `JVMLauncher.m` (the bridge census, `simCensusTakeException`; the facade's exception clearing).

### Gate flags are read once, when the class loads

**Set a `-Drunelite.*` flag before the class that reads it is touched.**

- **Symptom:** a flag set at runtime does nothing; a test passes alone and fails in the full suite.
- **Cause:** the bridges read their flags into `static final` fields (`ENABLED = Boolean.getBoolean(...)`).
  In tests, the JVM and its static state are shared, so whichever test loads a class first decides.
- **What to do:** on device, pass the flag as a JVM option. In tests, set it in a static initialiser before the
  class under test loads, and don't depend on test order.
- **In code:** `JavaBridge.ENABLED` and the same pattern across the bridge classes.

### iOS needs one restart after an in-app login

**After signing in on the phone, the app quits; reopen it.** iOS. This is a platform wall, not a bug.

- **Symptom:** after an on-device login, the app asks to restart before you can play.
- **Cause:** the login web view leaves WebKit resident in the process, and StikDebug can then no longer
  service HotSpot's code-cache breakpoint, so the JVM would crash at code-cache init. A fresh process has never
  loaded WebKit.
- **What to do:** reopen from the Home Screen. The saved tokens take the next launch straight to play.
- **In code:** `ViewController.m` (`promptRestartToPlay`).

### Android's login goes through Chrome and the clipboard

**Don't move the Android login back into a web view, and don't change the redirect.** Android. A platform
wall, not a bug.

- **Symptom:** the sign-in ends on a "localhost refused to connect" page, and you copy the link back into the
  app.
- **Cause:** an embedded web view is blocked by the bot check at the Jagex sign-in step, and the OAuth client
  accepts only a bare `http://localhost` redirect, so the result can't be routed back into the app
  automatically.
- **What to do:** that is the flow: a Chrome Custom Tab, then the app reads the copied link from the
  clipboard. The OAuth values are pinned across all three login implementations by the auth contract.
- **In code:** `LoginActivity.kt`, `JagexLogin.kt`, `tools/shared-contract/auth-contract.json`.

## Build, staging and upstream

### A cross-port contract change is invisible to both compilers

**Treat a renamed or re-signatured public static in `headless/`, or a changed snapshot JSON key, as a breaking
change for the other port.**

- **Symptom:** one port works; the other gets a NULL lookup at runtime, or a panel that silently shows
  nothing.
- **Cause:** both ports resolve the bridge by name over JNI. No compiler sees the other side. The contract
  check covers signatures, not JSON keys.
- **What to do:** run `tools/shared-contract/check-contract.sh`, both bridge censuses and the bridge unit
  tests; see [bridge-api.md](bridge-api.md) and [testing-qa.md](testing-qa.md#3-contract-checks).
- **In code:** `tools/shared-contract/`.

### Stage iOS jars with the iOS stagers

**On iOS, stage with `stage-ios-gpu-jar.sh` and `stage-ios-zone-jar.sh`. The generic runtime stager without
`--android-only` puts the wrong jar in place.** iOS.

- **Symptom:** the app builds, boots, logs in and draws on CPU, but the GPU renderer is dead: the GL bridge
  fails to register and the stock GPU plugin tries to load the macOS library. Or the Xcode build stops at the
  staged-jar check.
- **Cause:** the bundled `client-shaded.jar` must be the GL-facade variant. The pristine desktop jar is a drop-in by
  name and size, and `tools/stage-mobile-runtime.sh` copies it when it stages iOS.
- **What to do:**

  ```sh
  ios/dev-tools/gpu-routec/stage-ios-gpu-jar.sh
  ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh
  ```

  The build phase `ios/app/scripts/check-staged-jar.sh` refuses the pristine jar.
- **In code:** `ios/app/scripts/check-staged-jar.sh`; the header of `tools/stage-mobile-runtime.sh`.

### A jar missing `runelite/index` boots to a black screen

**After editing `runelite.properties`, rebuild the shaded jar again before staging.**

- **Symptom:** the jar builds, stages and installs cleanly; the client never draws a frame.
- **Cause:** editing `runelite.properties` makes `processResources` re-run, and Gradle deletes the generated
  resources in its output (the overlay index, the assembled scripts) as stale, while the tasks that produce
  them stay up to date. The client then dies in `OverlayIndex.<clinit>` with no hint why.
- **What to do:** run `./gradlew :client:shadowJar` again (the missing file makes the producing task out of
  date), then restage. The iOS build checks for the index; on Android, check the jar yourself.
- **In code:** `ios/app/scripts/check-staged-jar.sh` (the `runelite/index` check).

### Android's self-staging skips when a jar of the current version exists

**After a bridge change or a merge that keeps the version, restage Android by hand.** Android.

- **Symptom:** a shared Java change is not in the Android build.
- **Cause:** each Gradle staging task runs only when its output for the current version is absent. A change
  that doesn't bump `project.build.version` is skipped.
- **What to do:** rerun the stagers in the order in [android/README.md](../../android/README.md) (the GPU and
  RLHD stagers, then `tools/stage-mobile-runtime.sh --no-build --android-only`, which rewrites `runtime.tag`),
  or delete the staged jars and `runtime.tag` so the tasks run again.
- **In code:** `android/app/build.gradle.kts` (`jvmMissingVersioned` and the staging tasks).

### iOS bundle jar names are version-agnostic; keep them that way

**Never hard-code a versioned jar name on iOS.** iOS.

- **Symptom:** an upstream version bump breaks the iOS bundle.
- **Cause:** `project.yml` and `JVMLauncher.m` refer to fixed names (`client-shaded.jar`, `client-rlhd.jar`,
  `routec-l1.jar`, `probes.jar`); the stagers read the versioned source jars and rename them. Android keeps
  versioned names and globs for them.
- **What to do:** reference the fixed names. A `client-<version>-shaded.jar` in iOS code is a break waiting for
  the next merge.
- **In code:** `ios/app/project.yml`; `ios/app/RuneMobile/JVMLauncher.m`.

### The 117 HD Java overrides are full-file copies

**After an upstream merge, expect to refresh a 117 HD override.**

- **Symptom:** the RLHD stager stops with "RLHD recompile FAILED" (exit 2) after a merge.
- **Cause:** each override replaces the same-path RLHD source wholesale, with a small patch on top. When
  upstream RuneLite changes an interface those sources use (a new `Model` method, for example), the copy no
  longer compiles.
- **What to do:** refresh the file from the pinned RLHD source and re-apply the patch. The pin is `RLHD_REV` in
  each port's RLHD stager; read it there.
- **In code:** `ios/dev-tools/gpu-zone/java-overrides/`, `android/dev-tools/gpu/java-overlay/` (see its
  [README](../../android/dev-tools/gpu/java-overlay/README.md)); `stage-ios-zone-jar.sh`, `stage-rlhd-zone-jar.sh`.

### The RLHD recompile needs the project's Lombok

**Let the stagers use the Lombok version pinned in `libs.versions.toml`.**

- **Symptom:** the RLHD stager's `javac` crashes with `NoSuchFieldError JCTree$JCImport.qualid`.
- **Cause:** an old cached Lombok doesn't work with JDK 21's `javac`.
- **What to do:** run `./gradlew :client:shadowJar` first, which pulls the pinned Lombok into the Gradle cache;
  the stagers find it there (or set `LOMBOK` to a jar). Their fallback is the newest cached 1.18.x, never an
  arbitrary one.
- **In code:** `stage-ios-zone-jar.sh`, `stage-rlhd-zone-jar.sh`.

### `js5connect_outofdate` means merge upstream

**A black screen after an OSRS weekly update is a stale game revision, not a bug in the app.**

- **Symptom:** a black screen or `error_game_js5connect_outofdate` at boot, on both ports at once.
- **Cause:** the game updated and the build's client revision no longer matches.
- **What to do:** merge upstream RuneLite, rebuild, and restage both ports; see
  [upstream-release.md](upstream-release.md).
- **In code:** the README's Troubleshooting section describes it for players.

### A merge never moves the plugin-hub pin

**Review the hub pin as its own step after every merge that advances the version.**

- **Symptom:** `check-hub-pin.sh` fails the release gate after a merge.
- **Cause:** the plugin hub serves manifests for released versions only, so `runelite.pluginhub.version` is
  pinned to a release while the client is a `-SNAPSHOT`. `git merge` never rewrites that pin, so a stale one
  would ride every merge forward unnoticed. The check fails once the project version passes the last reviewed
  one.
- **What to do:** follow the header of `tools/shared-contract/hub-pin.ack`: three values move together, and
  the ledger gets a dated entry.
- **In code:** `tools/shared-contract/check-hub-pin.sh`, `hub-pin.ack`.

### Never run `git clean -X` in this repo

**Reclaim disk with `tools/clean-local.sh`.**

- **Symptom:** after a clean, local-only files are gone: tokens, working notes, and the patched iOS JRE, which
  can't be downloaded again.
- **Cause:** the ignore rules cover irreplaceable local files as well as build output, and `-X` deletes
  everything ignored.
- **What to do:** `tools/clean-local.sh` (dry run by default; `--apply` deletes; `--only gradle` is opt-in).
  Also: the "Internal working notes" block in the root `.gitignore` duplicates rules that also live in a local
  exclude file, on purpose. A fresh clone has no exclude file, so the tracked copy is what keeps working notes
  out of a stray `git add -A`. Don't delete it as redundant.
- **In code:** `tools/clean-local.sh`; `.gitignore`.

## Testing and the simulator

### The harness scripts build the jar only when it's missing

**Rebuild the shaded jar after every bridge edit; restage with `--jars` for the simulator.**

- **Symptom:** a bridge change "has no effect" in the desktop harness or the simulator.
- **Cause:** the harness scripts reuse whatever shaded jar exists, and the simulator runs the staged jars.
- **What to do:** `./gradlew :client:shadowJar` before a harness run; `--jars` on `run-sim.sh`,
  `run-census-sim.sh` and `sim-gate.sh`.
- **In code:** `ios/dev-tools/headless/run-*.sh`; `ios/dev-tools/run-sim.sh`.

### Exit code 0 doesn't mean the run worked

**Gate a desktop capture on its markers, not on the script's exit code.**

- **Symptom:** a harness run "passes" with no frames, or after Java died.
- **Cause:** the run scripts exit 0 even when the JVM dies early, and the harness server's `headless_render`
  reports that exit code as `ok`.
- **What to do:** check frames were captured, no null `Graphics`, no exception or `ERROR` lines, and the game
  state you expected. Verdict scripts compute their verdict in bash from markers, never from a success line the
  JVM prints; keep new ones that way.
- **In code:** `tools/mcp/harness_server.py` (`headless_render`); `ios/dev-tools/headless/*-verdict.sh`.

### The harness writes to your real RuneLite profile

**Run the desktop harness with a scratch `user.home`.**

- **Symptom:** your desktop RuneLite's settings change after a harness run, or overlay positions you saved on
  desktop show up in captures.
- **Cause:** the harness runs the real client, which uses `~/.runelite`; some probes change config (the HUD
  veneer releases overlays it owned, for example).
- **What to do:** point `user.home` at a scratch directory with a symlink to the game cache; the steps are in
  [testing-qa.md](testing-qa.md#keep-your-real-runelite-profile-out-of-it).
- **In code:** `RuneLite.RUNELITE_DIR`; `OverlayBridge.releaseHudOwned`.

### `grep -q` under `pipefail` can fail a matching pipeline

**In a pipeline under `set -o pipefail`, use `grep ... >/dev/null`, not `grep -q`.**

- **Symptom:** a flaky RED: the census reported the app as gone while it was running.
- **Cause:** `grep -q` exits at the first match, the writer upstream gets `SIGPIPE`, and `pipefail` reports
  the pipeline as failed even though it matched.
- **What to do:** let `grep` read all its input and discard the output.
- **In code:** `ios/dev-tools/bridge-census/run-census-sim.sh` (the app-alive check).

### The simulator is not a phone

**Use the simulator for native UI and logic; use the phone for anything about speed, the JIT, the GPU driver
or touch.** iOS.

- **Symptom:** something passes in the simulator and fails on the phone, or the simulator shows a stall the
  phone doesn't.
- **Cause:** the simulator draws GPU modes with Apple's software renderer, services the JIT breakpoint itself,
  and has no real multi-touch or backgrounding. On 117 HD, the first entry into the world freezes for a minute
  or more while shaders compile, and the connection drops and logs back in once. A fresh install also
  downloads the game cache before its first frame.
- **What to do:** treat a renderer reaching the login screen as proof that it started, not that its scene
  shaders draw: use the [shader matrix](../../tools/shader-matrix/README.md) and the phone for that.
- **In code:** [ios/README.md](../../ios/README.md#run-in-the-ios-simulator-no-phone); `ios/dev-tools/sim-gate/`.

### Simulator goldens are per window facing

**If every screen fails by about the same share of pixels, check which way the Simulator window faces.** iOS.

- **Symptom:** all screens fail together, each by a similar small percentage.
- **Cause:** Simulator.app can bring a window back facing the other landscape way, and the Dynamic Island moves
  with it. Goldens are kept per facing (`LandscapeLeft`, `LandscapeRight`).
- **What to do:** turn the window back, or record goldens for the new facing after checking the shots by eye.
  A window still in portrait stops the run before the first shot.
- **In code:** `ios/dev-tools/sim-screens/screendriver.py`, `sim-screens.py`.

### Tokens don't set where the character stands, and one account holds one session

**Log the throwaway account out where you want to test, and don't share it across two clients at once.**

- **Symptom:** an in-game probe runs somewhere unexpected; or one client keeps disconnecting.
- **Cause:** the character's position comes from the server, from where it last logged out. A second login on
  the same account kicks the first session.
- **What to do:** position the character before logging out; keep the desktop harness, the simulator and each
  phone on separate sessions in time. Token stores are covered in
  [testing-qa.md](testing-qa.md#15-accounts).
- **In code:** `ios/dev-tools/headless/run-headless-login*.sh`; `run-sim.sh --desktop-login`.

## Devices

### Read the device; don't trust a doc for versions

**Measure the OS and tool versions on the device before reasoning from them.**

- **Symptom:** a diagnosis built on an OS version the device no longer runs.
- **Cause:** versions written into docs go stale with every update.
- **What to do:** read them off the device (`adb shell getprop ro.build.version.release`, or the iPhone's
  details through `xcrun devicectl`). For what has been tested, see the platform status section of the
  [README](../../README.md#platform-status--supported-devices).
- **In code:** n/a.

### iOS: JIT is a per-launch attach

**Every launch on iOS needs LocalDevVPN connected and a StikDebug attach.** iOS.

- **Symptom:** the app waits at launch forever; or StikDebug's "Starting JIT" spinner never resolves.
- **Cause:** iOS grants no JIT to a sideloaded app; StikDebug attaches as a debugger each launch and services
  HotSpot's code-cache breakpoint. Waiting without the attach is by design. A spinner that never resolves is
  StikDebug's Developer Disk Image mount, which happens before RuneMobile's script runs.
- **What to do:** for the spinner, check in order: StikDebug is current for the iOS version, LocalDevVPN is
  connected (not just open), the pairing file is fresh, and no Mac is holding the device's debug tunnel. iOS runs
  one VPN at a time, so SideStore's VPN (for installing and refreshing) must be off while you attach.
- **In code:** `ios/app/stikdebug/runelite-jit.js`; [ios/app/stikdebug/README.md](../../ios/app/stikdebug/README.md).

### iOS: an install can't go over a VPN

**Install from a Mac on the phone's own network, or over loopback as SideStore does.** iOS.

- **Symptom:** an install over a VPN interface connects, then is reset.
- **Cause:** iOS gates its developer services by interface: `lockdownd` answers on the local network and over
  loopback, and refuses requests arriving through a VPN.
- **What to do:** install from the same network, or build an IPA and install it on the phone through SideStore;
  see [ios.md](ios.md).
- **In code:** n/a.

### A silent game is usually not a broken output

**Read the audio line before suspecting the output.**

- **Symptom:** no sound, and nothing in the log.
- **Cause:** the engine obeys its own volumes, which live in `jagexcache/oldschool/LIVE/preferences.dat` and
  `preferences2.dat`, not in `jagex_cl_oldschool_LIVE.dat`, which only points at the cache folder. Logging in also
  brings the account's volumes, so an account muted on desktop is muted here. A fresh install adds about 40 s of
  silence while the music downloads.
- **What to do:** the bug report's `Audio:` line tells these apart, as does `runelite.audio.stats`. `playing` with a
  peak of 0 is the game choosing silence; a peak above 0 with `no output` is the output. To test with default volumes
  on desktop, keep the shared cache but not those two files: make `LIVE` a real folder of per-file symlinks.

### A bridge call at launch does nothing

**Check the ack of a bridge call that can run before the JVM is up, and retry it.**

- **Symptom:** a setting that the log says was restored is unchanged. Android's thermal governor logged `recovered a
  leaked throttle` for every kill mid-throttle, and the player's scale stayed low for good.
- **Cause:** `onBridge` queues on a thread that's up long before HotSpot, and the native calls return `""` until
  `MobileUiBridge` publishes. On an emulator HotSpot alone started 10 s after `onCreate`.
- **What to do:** treat anything but `{"ok":true` as not done. A written config value isn't safe yet either: it waits
  on the client thread, then in memory until a save, and `flushConfig` saves without waiting for that queue.
- **In code:** `ThermalScaleKeeper.kt`, `JvmLauncher.configWritesLanded`.

### Phone frame rate is mostly heat

**Compare frame rates only under the same thermal state.**

- **Symptom:** the same build measures several times slower than it did earlier.
- **Cause:** phones throttle when hot or charging. On 117 HD both ports also lower the scene resolution scale
  under thermal pressure, on purpose, and iOS limits the frame rate on every renderer when the phone is warm or in
  Low Power Mode, so a 30 or 40 fps reading may be the app's own limit. The Heat section of Share logs says.
- **What to do:** check the thermal state before calling a regression (on Android,
  `adb shell dumpsys thermalservice`). `fps-measure.sh` records thermal lines alongside the frame data; the
  harness server's `android_fps` flags a capture where the governor moved the scale mid-run.
- **In code:** Android `ThermalGovernor`; iOS `RMHeat.m` and `heatTick` in `ViewController.m`;
  `android/dev-tools/gpu/fps-measure.sh`.

## See also

- [testing-qa.md](testing-qa.md): the checks that catch many of these
- [debugging.md](debugging.md): logs and what to read when something breaks
- [architecture.md](architecture.md) and [bridge-api.md](bridge-api.md): the design behind the bridge rules
- [renderers.md](renderers.md): GPU and 117 HD in depth
- [ios.md](ios.md), [android.md](android.md): each port's own details
