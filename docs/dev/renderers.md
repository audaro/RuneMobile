# Renderers: CPU, GPU and 117 HD

RuneMobile can draw the game three ways: the engine's own software rasterizer (CPU), RuneLite's base GPU plugin,
and the 117 HD plugin. Both phones run the unmodified plugins on OpenGL ES, through a facade that replaces LWJGL
and a native bridge that turns desktop GL calls into ES ones. This page explains how a renderer is chosen, how
each one reaches the screen on each port, what had to change to make 117 HD run on a phone, and how to check and
measure a renderer change.

Read [architecture.md](architecture.md) first if you haven't: it covers the headless client, the AWT layer and the
JNI bridge that everything here sits on.

## At a glance

| | CPU | GPU | 117 HD |
|---|---|---|---|
| What draws | the OSRS engine's software rasterizer | RuneLite's `gpu` plugin | the 117 HD plugin (`rs117.hd`) |
| Started by | nothing extra; it is the engine's default | `RouteCGpuStarter` | `RLHDStarter` |
| JVM flag | none | `-Drunelite.routecgpu=true` | `-Drunelite.routecrlhd=true` |
| Extra jar | none | the GPU jar (facade + recompiled plugin) | the GPU jar plus the 117 HD jar |
| iOS present | int[] frame into the Picture-in-Picture sample-buffer layer | GL readback, then the same path as CPU | direct GL present (no readback) |
| Android present | int[] frame blitted to the `SurfaceView` on the render thread | direct EGL window-surface present | direct EGL window-surface present |
| Always works? | yes | needs GLES 3.0 | needs a capable GPU; see the probes below |

All three load into every session: `RendererPanelStarter` (armed by `-Drunelite.rendererpanel=true`, which both
launchers always pass) loads the GPU and 117 HD plugins into the plugin panel without starting them, so their
settings can be read and edited even when the CPU renderer is running.

## Choosing a renderer

### The saved preference

The renderer is fixed when the JVM starts. It cannot be swapped in a running session: the GPU plugins need their
jar on the class path and their GL context created before the first frame, and the CPU path needs neither.

| | iOS | Android |
|---|---|---|
| Where it is saved | `NSUserDefaults` key `rendererPref` | `SharedPreferences` file `renderer`, key `mode` |
| Values | `cpu`, `gpu`, `117hd` | `cpu`, `gpu`, `117hd` |
| Default | what the first-run probe picks, else `cpu` | the same |
| Where the user picks | the GPU or 117 HD row in the plugin panel | the same |

Toggling one of those rows saves the preference and shows "restart to apply". Tapping the row that is already
selected turns it off and saves `cpu`. Android offers **Restart** and relaunches itself. iOS cannot relaunch an
app, so it offers **Quit now**, which flushes the preference and RuneLite's config and exits; the next launch needs
a fresh StikDebug attach for the JIT, like any other launch.

The renderer a session actually booted with can differ from the saved preference: a pick made after launch applies
next time, and a failed boot (below) is reverted before the JVM starts. On iOS, `sessionRendererKey` in
`ViewController.m` reports the booted one.

### First-run promotion

On a fresh install, with no saved preference and no earlier failure, each port probes the GPU once and saves what
it picks. The choice is saved like a player's own, so a change to it reaches new installs only.

- **iOS**: `GLRecon recommendedRendererTier` (`ios/app/RuneMobile/GLRecon.m`). A device whose EAGL context can create
  an ES 3 offscreen framebuffer, render into it and read it back gets `gpu`; anything else gets `cpu`. Recent iPhones
  can all run 117 HD, but it is left for the player to choose: it works the GPU hard enough that a phone left on it
  gets hot (see [Heat](#heat)).
- **Android**: `probeGpuCaps()` in `MainActivity.kt` creates an EGL pbuffer context, trying ES 3.2, then 3.1, then
  3.0. ES 3.1 or newer with compute shaders gives `117hd`; ES 3.0 with multisampling gives `gpu`; anything else
  gives `cpu`. It also records `autoDecided` so a later failure knows the choice was automatic.

The probe never runs again once a preference exists. An explicit pick in the panel replaces whatever it chose.

### The crash cookie

A GPU renderer can kill the process before the first frame: a shader that crashes the driver, a GL call the
driver rejects badly, or a memory kill during warm-up. Without protection that becomes a crash loop, because
the same preference boots the same renderer every time. Each port guards a GPU boot with a marker file that is
written while the boot is in progress and removed once the renderer has proven itself.

**iOS** (`ViewController.m`, `hdBootCookie*`):

- The marker is `hd-boot-armed` in the app's Application Support directory.
- It is armed once a GPU boot is actually running (the first engine frame has been shown and the app is in the
  foreground), not at the Play tap, so quitting while waiting for the JIT attach does not count as a failure.
- It is cleared on the first GL present: the 117 HD bridge reporting a presented frame, or the base GPU plugin's
  frame counter moving. It is also cleared when the app goes to the background, so a session the user leaves
  before the first present is not mistaken for a crash.
- At the next Play tap, a marker still on disk means the last GPU boot died first. The launch reverts the
  preference to `cpu`, sets `autoGpuFailed` so the first-run probe never promotes again, and shows
  "GPU renderer didn't start" or "117HD renderer didn't start".

**Android** (`MainActivity.kt`):

- The marker is `files/auto-gpu-armed`; its contents name the renderer that was being tried. It is written just
  before a GPU or 117 HD boot that came from the saved preference. Boots forced by the developer triggers below
  are not protected.
- A watchdog thread (`auto-gpu-watchdog`) polls the native present counter (`nativeGpuFramesPresented()`) and
  deletes the marker once three frames have been presented, within a 240-second window. If the window runs out the
  marker stays.
- At the next start, a marker on disk reverts the preference to `cpu`, increments `gpuFailCount`, sets
  `autoGpuFailed` when the choice had been automatic, writes the details to `files/gpu-fail.txt` and shows a toast
  ("HD renderer didn't start — switched to compatibility mode. Re-enable it under Plugins.").

On both ports an explicit pick in the panel clears `autoGpuFailed` (and on Android deletes any stale marker), so a
renderer the user chose still gets its one-shot protection.

> A boot that never presents is treated as a crash even when nothing crashed. On Android the classic case is a
> launch with the screen off: no surface, no presents, the 240 s window runs out, and the next launch comes up on
> CPU. See [debugging.md](debugging.md#symptoms) for the recovery.

### Developer overrides

These force a renderer for one launch without touching the saved preference.

| Port | How | Notes |
|---|---|---|
| Android | `adb shell am start -n dev.audaro.runemobile/.MainActivity --ez routecgpu true` (or `--ez routecrlhd true`) | Intent extras; the launch is not cookie-protected. |
| Android | an empty file `gpu.mode`, `rlhd.mode` or `cpu.mode` in the app's external files dir | Debug builds only. `cpu.mode` also overrides the TV default below. |
| Android | Firebase Game Loop launch (`com.google.intent.action.TEST_LOOP`) | Boots 117 HD, for device-lab runs. |
| Android | a TV (leanback) device | Defaults to 117 HD. |
| iOS Simulator | `RENDERER=gpu ios/dev-tools/run-sim.sh` (or `117hd`, `cpu`) | For that launch only. |

The JVM flags behind them, all read in `runelite-client/src/main/java/net/runelite/client/headless/`:

| Flag | Effect |
|---|---|
| `runelite.routecgpu` | Arms `RouteCGpuStarter` (base GPU). |
| `runelite.routecrlhd` | Arms `RLHDStarter` (117 HD). |
| `runelite.gfxIos` | Tells `RLHDStarter` to apply the iOS 117 HD config branch instead of Android's. |
| `runelite.routecrlhd.startInWorld` | iOS only. `RLHDStarter` waits for the world instead of starting on the login screen, where iOS shows CPU frames and 117 HD would stop them. Android draws that screen with 117 HD, so it must not set this. |
| `runelite.rendererpanel` | Loads both GPU plugins into the panel without starting them. |
| `runelite.nosafemode` | Always set by both launchers. Keeps RuneLite out of safe mode, which would refuse to load GPU plugins. |
| `runelite.gpuframedump` (+ `.dir`) | Writes every composited in-world GPU frame to `routec-frames/gpuframe-*.png`. Android debug builds set it for GPU and 117 HD boots. Expensive; never ship it on. |
| `runelite.rlhdOverlaySelfTest` | Android: force-compiles 117 HD's debug overlay shaders once 117 HD is up, so a typing error in one shows in the log. Armed by an `rlhd_overlay_selftest` file in the app's files dir. |
| `runelite.cpu.unlockfps` | `CpuFpsStarter` experiment: ask the engine for N fps instead of its own ~50. |

## The CPU renderer

The OSRS engine draws every frame in software into an `int[]` pixel buffer. On a phone the work after that is
getting the pixels to the screen without wasting a frame's worth of time per frame.

- **iOS** feeds the frame to an `AVSampleBufferDisplayLayer`, the layer the app also uses for Picture-in-Picture.
  A `UIImageView` is kept only as a fallback.
- **Android** runs a native render thread (`renderLoop` in `android/app/src/main/cpp/jvm_bootstrap.cpp`). It copies
  the frame out of the Java array into a reused native buffer, locks the `ANativeWindow`, swizzles the pixels into
  the window's byte order and posts. The loop is paced by `AChoreographer` vsync callbacks; set
  `adb shell setprop debug.runemobile.cpupace sleep` before launch to compare against the older flat 16 ms sleep.

Both blits used to allocate and copy a whole frame every frame. `fe724fffde` removed that on both ports: iOS
backs its images with a rotating ring of scratch buffers instead of building a fresh copy, and Android stopped using
`GetIntArrayElements`, which on ART is a malloc and copy per call. Android later moved again, from pinning the array
with `GetPrimitiveArrayCritical` to one `GetIntArrayRegion` copy into a buffer reused across frames, because the
swizzle is the slow part and a critical section holds off any GC the engine thread needs for as long as it lasts.
Keep both properties: no per-frame allocation, and no long critical sections. Either shows up as hitches and
thermal load on a phone long before it shows up on a Mac.

Two CPU facts that save time when reading numbers:

- The engine paces itself at about 50 fps on a 20 ms timer, so on a 60 Hz panel the frames land on a 2/2/3 vsync
  cadence. That is expected, not a present bug.
- On Android the CPU renderer is very sensitive to thermal state; the same build can run at less than half its
  cool frame rate when the phone is hot or charging. Check the thermal state before calling a CPU regression
  (see [Measuring performance](#measuring-performance)).

## The base GPU plugin on GLES

RuneLite's `gpu` plugin targets desktop OpenGL through LWJGL and the `rlawt` native AWT bridge. Neither exists for
iOS or Android, so the plugin runs against a replacement.

### Jar surgery

Each port's stager reads the pristine shaded client jar and writes a variant in which every `org.lwjgl.*`,
`net.runelite.rlawt.AWTContext` and `net.runelite.client.plugins.gpu.*` class comes from one place: a Java facade
whose GL and AWT methods are declared `native`, plus the unmodified plugin source recompiled against it. LWJGL is
physically stripped from the variant, so there is exactly one provider of each symbol and no desktop dynamic
library is ever loaded on a phone.

| | iOS | Android |
|---|---|---|
| Stager | [`ios/dev-tools/gpu-routec/stage-ios-gpu-jar.sh`](../../ios/dev-tools/gpu-routec/stage-ios-gpu-jar.sh) | [`android/dev-tools/gpu/stage-android-gpu-jar.sh`](../../android/dev-tools/gpu/stage-android-gpu-jar.sh) |
| Facade source | `ios/dev-tools/gpu-zone/facade/` (shared with 117 HD) | `android/dev-tools/gpu/facade-src/` |
| Output | `ios/app/jvm-resources/client-shaded.jar` | `android/app/src/main/assets/jvm/client-<version>-gpu.jar` |
| Natives | `RouteCBridge.m` and `jni/routec_gl_jni.m` in `ios/dev-tools/gpu-routec/`, compiled into the app | `librlawt.cpp` in `android/app/src/main/cpp/`, bound with `RegisterNatives` |

Both stagers read the client version from `gradle.properties` (`project.build.version`) and refresh the delomboked
plugin sources each run. On iOS, stage with these scripts and not with `tools/stage-mobile-runtime.sh`, which
copies the pristine jar over `client-shaded.jar` and drops the facade; the app's build phase then refuses the jar.
[ios.md](ios.md) and [android.md](android.md) give the full staging order for each port.

### iOS: EAGL

The iOS bridge drives Apple's EAGL OpenGL ES 3.0. It renders into an offscreen framebuffer. For the base GPU
plugin the frame is read back with `glReadPixels` and handed to the same Picture-in-Picture feed the CPU renderer
uses.

ES 3.0 on iOS has no `glClipControl`, so the plugin's reverse-Z depth is squeezed into a narrow window-z range at
distance and far geometry z-fights. The bridge's shader rewrite writes `gl_FragDepth = clip.z / clip.w` in the
scene shader instead, which restores full precision (`RouteCBridge.m`, `depthFixActive`). Writing `gl_FragDepth`
disables early-Z, and the measured GPU cost of that was accepted over the alternatives below.

An ANGLE-over-Metal backend is still wired in as a compile-time option (`RC_BACKEND_ANGLE` in
`ios/app/project.yml`), but EAGL is the active backend. ANGLE gave `glClipControl` but brought back a near-plane
geometry bug and added nothing 117 HD needed.

### Android: librlawt

Android has real GLES 3.x drivers, so `librlawt.cpp` is a thin translation layer: it creates an EGL context with an
offscreen RGBA8/depth-24 framebuffer that stands in for desktop "framebuffer 0", registers the facade's natives,
and forwards calls. The parts that are not one-to-one:

- **Reverse-Z.** Where the driver offers `GL_EXT_clip_control`, the bridge calls
  `glClipControlEXT(LOWER_LEFT, ZERO_TO_ONE)`, runs a small red/green self-test, and reverts if the result is wrong.
  `adb shell setprop debug.routec.clipcontrol 0` forces it off for an A/B.
- **Present.** Once the native side has installed its window callbacks, `swapBuffers` blits the offscreen
  framebuffer to an EGL window surface on the `SurfaceView` and calls `eglSwapBuffers`: pure GPU, vsync-paced, no
  readback. Without the callbacks it falls back to `glReadPixels` into the Java frame buffer. The window surface is
  recreated whenever the `Surface` is (for example after returning from the background).
- **Swap interval.** The plugin's requested interval is applied to the window surface.
  `debug.routec.swapinterval` overrides it on the EGL side only (0 uncapped, 1 display rate, 2 half rate).
- **Format and type fixes**: BGRA uploads become RGBA with a swizzle, `GL_PROGRAM_POINT_SIZE` is dropped, and the
  depth-texture remap described under [Platform limits](#platform-limits-and-the-fixes-for-them).

### Engaging the plugin

`RouteCGpuStarter` runs from `Hooks.draw`. Once the client is at the login screen or in the world it:

1. forces `gpu.uiScalingMode=LINEAR`, because the HYBRID and xBR scaling shaders mix `int` and `float` in ways
   strict GLSL ES rejects;
2. seeds `gpu.vsyncMode=ON` once (sentinel `mobileVsyncSeeded`), so a user's later choice is kept;
3. validates the canvas on the EDT under the AWT tree lock, because the plugin's `startUp` bails if the canvas is not
   valid yet;
4. loads and starts the plugin through `MobileUiBridge.loadAndStartPlugin`, since the core class-path scan does not
   find the staged `gpu` package.

It retries on a 1.5 s throttle, up to 30 attempts, and stops once `client.isGpu()` is true.

## 117 HD

117 HD is an external plugin: it is not in `net.runelite.client.plugins`, so RuneLite never discovers it on its
own. `RLHDStarter` loads it once through `loadAndStartPlugin` (plugin loading is not idempotent, so it must not be
repeated), retries up to 40 times while the game cache arrives, and leaves the base GPU plugin alone because
117 HD declares `conflicts = "GPU"` and replaces it.

### The pin

The 117 HD version is pinned in two places that must agree: `RLHD_REV` in
[`android/dev-tools/gpu/stage-rlhd-zone-jar.sh`](../../android/dev-tools/gpu/stage-rlhd-zone-jar.sh) and in
[`ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh`](../../ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh).
[`ios/dev-tools/gpu-zone/rlhd-src/PROVENANCE.md`](../../ios/dev-tools/gpu-zone/rlhd-src/PROVENANCE.md) records which
release it is, the previous pin, and what moving it involved. Read the revision from those files, not from any doc.

Each stager fetches the pristine 117 HD source at that revision into a gitignored work tree, compiles it (with
Lombok's annotation processor) against the LWJGL-stripped client jar plus the facade, lays the port's Java
overrides and then its shader overlays on top, and writes `client-<version>-rlhd.jar` (Android assets) or
`client-rlhd.jar` (iOS `jvm-resources`). Because 117 HD is compiled against the facade, a GL symbol the facade lacks
is a `javac` error at staging time rather than a crash on the phone. The facade itself ships in the GPU jar, so
after changing it re-stage the GPU jar too.

### Override trees go stale

Each port keeps a small tree of 117 HD files that replace upstream's at staging time:

| | Java overrides | Shader overrides |
|---|---|---|
| iOS | `ios/dev-tools/gpu-zone/java-overrides/` (plugin entry point, scene and shadow shader programs, light and material uniforms, buffer helpers) | `ios/dev-tools/gpu-zone/ios-overrides/` |
| Android | `android/dev-tools/gpu/java-overlay/` (`HdPlugin` only, with null guards for the AWT context) | `android/dev-tools/gpu/shader-overlay/` |

These are **whole-file copies**, not patches. When upstream 117 HD (or RuneLite) changes a file that has an
override, the override silently keeps the old version. The failure usually arrives later, somewhere else: in July
2026 upstream added `byte getTransparency()` to the `Model` interface, and the cached-model override, frozen at the
older pin, no longer implemented it, so the whole 117 HD recompile failed (`d3dc5911e7`). Moving the pin to the
1.6 line later let several overrides be deleted outright because upstream had fixed what they patched.

When you move the pin or merge upstream:

1. diff every override against the new upstream copy of the same file, and re-apply only the mobile change;
2. delete overrides that upstream has made unnecessary;
3. re-stage both ports and run the shader matrix on both (below).

Two iOS overrides exist because of hard Apple limits rather than bugs: 117 HD's texture-buffer face data
(`isamplerBuffer`, ES 3.2) is repacked into a 2D integer texture, and the material store moves from a uniform block
into a texture (Apple caps uniform blocks at 16 KB). The iOS 117 HD natives that support them live in
`ios/dev-tools/gpu-zone/jni/routec_zone_jni.m`.

### Shaders are rewritten at run time, per port

117 HD builds its shaders at run time from `#version 330` desktop GLSL. Each port rewrites the source at
`glShaderSource` time:

- **Android**: `rc_downport` in `librlawt.cpp` replaces the version with `#version 320 es`, `310 es` or `300 es` to
  match the context, strips `#line`, drops `noperspective`, adds sampler precisions, and inserts explicit casts at
  known sites. Extension directives are only added for 3.10.
- **iOS**: `downportShaderSource` in `RouteCBridge.m` targets GLSL ES 3.00 for Apple's driver, with the same kinds of
  edits.

Both strip the `f` suffix from float literals, and both learned the same lesson: the pattern must not match a digit,
a dot and an identifier starting with `f`, or `material1.flowMap` becomes `material1.lowMap`. Only strip an `f` that
is not followed by an identifier character.

To see exactly what the Android driver received, create the dump toggle and relaunch; each shader is logged as
`SHDR[n]` lines:

```sh
adb shell run-as dev.audaro.runemobile touch files/rlhd_shaderdump
adb shell am force-stop dev.audaro.runemobile   # then launch again
adb logcat -s 'librlawt:*' | grep 'SHDR\['
```

**A desktop run never compiles these shaders the way a phone does.** On a Mac, 117 HD compiles its original sources
against desktop OpenGL with no rewrite (and the headless harness runs in safe mode, with no GPU plugin at all), so a
clean desktop run says nothing about the ES rewrite. Use the shader matrix for that.

### Config the phones force or seed

`RLHDStarter` sets some 117 HD options on every launch, because the plugin breaks or misbehaves without them, and
seeds others once (first launch, behind a sentinel) so the user's later edits survive. `migrateRlhd16Config()` first
converts values saved by older 117 HD releases (boolean tiled lighting to `ON`/`OFF`, the renamed shadow filtering
values) before any 117 HD class loads.

Forced every launch, both ports:

- `uiScalingMode=LINEAR`: the HYBRID/xBR scaling shaders are not validated on GLES. It is also set first and used as
  the readiness probe: if the client thread cannot take a config write yet, the starter retries next tick.
- `asyncModelProcessing=false`: the bridge has one thread-affine GL context, and 117 HD's worker threads would touch
  GL buffers from other threads and corrupt animated models.
- `daylightCycle=OFF`: the day/night cycle that arrived in 117 HD 1.6 has not run on either phone yet. See the
  `DAY_NIGHT_NOTE` comment in `RLHDStarter.java`.

Android additionally forces `tiledLighting=OFF`. Its tiled-lighting shaders are ES-ported in the shader overlay, but
the feature has never been enabled and validated on Android hardware. iOS seeds it on.

The seeded defaults (MSAA, resolution scale, draw distance, shadow mode and resolution, normal mapping, dynamic
lights and so on) differ per port; read them in `RLHDStarter.java` rather than here, since they get retuned.

## Platform limits and the fixes for them

| Problem | Symptom | Fix |
|---|---|---|
| 117 HD allocates shadow-map depth textures as `DEPTH_COMPONENT24` or `16` with type `GL_FLOAT`; desktop GL allows it, GLES 3 does not | The shadow framebuffer is incomplete, every shadow lookup reads depth 0, and the whole scene draws dark with no sun shadows | Both bridges pass `GL_UNSIGNED_INT` (24-bit) or `GL_UNSIGNED_SHORT` (16-bit). Android logs `[shadowmap]`, iOS `SHADOW-FIX`. iOS fixed the 24-bit case first; the terrain shadow map always uses 16-bit and was fixed later with Android (`ac39a84ab7`). |
| Shadows are expensive on mobile GPUs | Lower frame rate in 117 HD | Measured at about 5.5 ms per frame on a mid-range Mali phone (one thermal state, 1K map: shadows off 47 fps, Detailed 38 fps). Treat older fps figures that predate the shadow fix as invalid. |
| Android's reverse-Z uses the `[0,1]` clip range, and the sky was written at the `[-1,1]` far plane | Sky clipped on Android | The Android sky shader writes the far plane for `[0,1]` (`c6cf212712`). |
| GLSL ES has no implicit int-to-float conversion | 117 HD's gamma-calibration and debug overlays failed to compile on every iOS launch, yet the app still reached the login screen | Ported copies in `ios-overrides/overlays/` (`a7a15bd076`). |
| `smoothstep` with `edge0 >= edge1` is undefined in GLSL ES | The calibration dots relied on a driver happening to mirror the curve | Rewritten as `1.0 - smoothstep(lo, hi, x)` in both ports' copies (`0bb9e1b015`). |
| Day/night cycle untested on phones | n/a | Forced off on both ports every launch. |

The overlay row carries the general lesson: **reaching `LOGIN_SCREEN` proves nothing about 117 HD's shaders.** Most
programs compile lazily, many only in the world, and a failed compile is logged and skipped rather than fatal. Look
for shader errors in the log (`tools/log-scan/` counts them separately and never lets them be excused as noise) and
run the shader matrix.

### Heat

117 HD has a thermal governor on both ports (`ThermalGovernor.kt` on Android, `heatApplyScaleLimit` in
`ViewController.m` on iOS): under sustained thermal pressure it lowers `sceneResolutionScale` and restores the
user's own value once the phone cools. It only acts while 117 HD is the live renderer, and while throttled it
records the true baseline (a marker file on Android, a user-defaults key on iOS) so a session killed mid-throttle
cannot make the throttled value permanent. On iOS, a player who moves the setting sets a new baseline: the governor
compares the live value before each write, but only once its own last write has landed (`getProcessedWriteId`),
because bridge writes queue on the client thread, and that thread can stall for minutes.

iOS also limits the frame rate, on every renderer. `RMHeatPolicy` (`ios/app/RuneMobile/RMHeat.m`) maps the phone's
state to limits, and `heatTick` applies them. The values are starting values, not measured ones:

| State | Frame rate | 117 HD scale |
|---|---|---|
| nominal | none | none |
| fair | 40 | none |
| serious | 30 | 65 |
| critical | 20 | 50 |
| Low Power Mode | 30 at most | none |

A limit comes on at the first reading that calls for it and lifts one step per 60 calm seconds; Low Power Mode comes
and goes with its switch. The frame limit is `HeatFrameCap`, reached through `MobileUiBridge.setHeatFpsCap`. It does
not use FPS Control's setting, which is saved to the profile and can sync: a session that died hot would leave its
limit behind. It sleeps on the draw path like FPS Control, so game ticks and audio keep their time.

Why the scale stays behind the frame rate: it is a saved setting that changes the picture, and it only exists on one
renderer. Why 117 HD isn't the iOS default: on a 17 Pro Max in June 2026, base GPU spent 6-8 ms of GPU time a frame
and 117 HD about 55 ms. Nobody has measured heat on any iPhone for either. Share logs carries a Heat section (a line
a minute of thermal state, frame rate, limits and battery), so the first real numbers can come from a player's report.

## The Android GL bridge lags iOS

iOS reached the GPU renderers first, so several bridge bugs were fixed there months before Android hit them. The
clearest case: LWJGL passes an NIO buffer's `remaining()` elements starting at `position()`, but the bridge sized
buffer arguments by `capacity()` from the base address. With the plugin's reused, `flip()`ed draw-range buffers,
`glMultiDrawArrays` replayed hundreds of stale ranges per call: a translucent wedge across part of the screen for
seconds, and wall pieces dropping out for a frame while the camera turned. iOS fixed it in June 2026 (`daabcddfc1`);
the identical Android fix came in October (`51b8c41d5d`), and a 30-second capture at a busy spot went from 34 bad
frames to none.

So when Android's GPU or 117 HD output is wrong and iOS's is not, **diff `librlawt.cpp` against the iOS bridges
first** (`ios/dev-tools/gpu-routec/jni/routec_gl_jni.m` and `ios/dev-tools/gpu-zone/jni/routec_zone_jni.m`) for the
GL entry points involved. Look especially at buffer sizing, `glBufferSubData`, mapped ranges and texture formats.

Glitches like these last one or a few frames, which is too short to judge by eye or catch with a screenshot. Record
the screen and score every frame:

```sh
adb shell screenrecord --time-limit 30 /sdcard/rec.mp4
adb pull /sdcard/rec.mp4
mkdir -p frames
ffmpeg -i rec.mp4 -fps_mode passthrough frames/%05d.png
```

`screenrecord` writes a variable-frame-rate file. Without `-fps_mode passthrough` ffmpeg resamples to a constant rate,
duplicating some frames and dropping others, which is exactly where one-frame glitches hide. Then count the frames
that show the artifact (by a pixel test on a known region, or by diffing against a neighbour) before and after the
fix, at the same spot and camera angle.

## Validating shader changes

```sh
tools/shader-matrix/run-matrix.sh ios
tools/shader-matrix/run-matrix.sh android
```

The matrix repeats each port's staging and run-time rewrite on the Mac and validates every shader stage with
glslang across a set of 117 HD setting variants, with no phone, in a minute or two per port. Between them the
variants give every config-driven shader define each value it can take at least once (each value, not each
combination), so a new config-driven define after a pin move needs a new variant in `run-matrix.sh`. A second
argument runs only the variants whose name starts with it (`run-matrix.sh android pcss`). It needs
`glslangValidator`, a JDK 21 and the stager's work directory from a previous stage. It ends with
`SHADER_MATRIX_GREEN (<port>, <n> variants)` or `SHADER_MATRIX_RED`, and writes a `report.txt` per variant with
every error and the source line it points at.

Run it after changing a shader override, either port's rewrite, or the pin (both ports for the pin). glslang is a
filter, not the authority: a stage it accepts can still fail on a real driver, and it says nothing about what the
shader draws. The Mali depth-type and Apple `smoothstep` problems above are both things it could not have caught.
For iOS, `ios/dev-tools/sim-gate.sh` also boots each renderer in the Simulator. For Android and anything visual,
check on a phone. [tools/shader-matrix/README.md](../../tools/shader-matrix/README.md) has the details, and
[testing-qa.md](testing-qa.md) places it among the other gates.

## Measuring performance

### Arm the perf probe

```sh
tools/perfprobe.sh android on        # or: tools/perfprobe.sh ios on
tools/perfprobe.sh android status
tools/perfprobe.sh android off
```

The app reads the switch once, when the JVM starts, so force-stop and relaunch after changing it. Armed, the VM runs
with `-Drunelite.fpsprobe` and `-Xlog:gc,safepoint`, and logs once a second:

| Line | From | Meaning |
|---|---|---|
| `[fpsprobe]` | `Hooks` / `FrameStats` | The engine's smoothed fps and game state |
| `[frameprobe]` | the same | Frame-interval min/avg/p95/max over the last second |
| `[framebins]` | the same | Frame-time histogram buckets, GC count and time, heap use |
| `[framehist]` | the same | Session percentiles, every 10 s |
| `[presentprobe]` | the native present path | Presents, longest gap, swap or blit cost |
| `[gpuprobe]` | `librlawt` | GPU time per frame; Android only, with `adb shell setprop debug.routec.gputime 1` |

`perfprobe.sh ... marker NAME VALUE` sets A/B switches read at the same point (Android ones only in debug builds):
`cpufps N`, `xms SIZE`, `jfr SECS` (Android) and `pipfeed main` (iOS). The script's header lists them.

On Android a debug build is always armed, and a release build forwards only the probe's lines. On iOS the marker is a
file in the app's `Documents`; Debug keeps the lines in `jvm-stdio.log`, Release in `perf-probe.log`.

### Capture and summarise

```sh
android/dev-tools/gpu/fps-measure.sh -d 60 -o baseline.csv baseline     # live, over adb
android/dev-tools/gpu/fps-measure.sh --from-file jvm-stdio.log ios      # a pulled iOS log
```

`fps-measure.sh` prints fps mean, median, min and max, frame-time percentiles and the device's thermal state, and
counts only `LOGGED_IN` samples. Frame-time percentiles, not one smoothed fps figure, are what separate a 2–3 fps
change from noise. Its header explains every CSV column. To A/B a 117 HD setting on Android without a restart, a
debug build accepts live config flips:

```sh
adb shell am broadcast -a dev.audaro.runemobile.SET_HD_CONFIG --es key drawDistance --es value 20
```

A live flip only reaches disk on RuneLite's periodic config save, so a force-stop soon after loses it.

### Rules for numbers you can trust

- **Hold everything else still**: same spot, same camera, same time of day in game, same crowd, back to back.
- **Check thermals first.** On Android, `adb shell dumpsys thermalservice` and the CPU frequency caps under
  `/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq`; a hot or charging phone can halve the CPU renderer's
  frame rate. A thermal-governor scale change in the middle of a capture splits it into two workloads, and
  `fps-measure.sh` flags it.
- **The iOS Simulator is not a performance signal.** Its GPU modes run on Apple's software renderer on the Mac's
  CPU, with no memory cap and no thermals. Use it to check that a renderer boots and draws, never how fast.
- **A desktop number is not a phone number** either, for the same reasons.
- For JVM-side hotspots on Android, the `jfr` marker records a Java Flight Recording (see
  [debugging.md](debugging.md#jvm-tools)).

## Historical experiment directories

`ios/dev-tools/` holds several self-contained probes from the period when the GPU path was being chosen. They
answered one question each, and their verdicts are sealed against md5-pinned logs. None of them is part of the app
build; keep them for the record and for re-running if a question reopens.

| Directory | What it answered |
|---|---|
| [`gpu-angle/`](../../ios/dev-tools/gpu-angle/README.md) | On a device, does MetalANGLE give `glClipControl`, compute shaders and MSAA? Clip control yes; that build was ES 3.0 only. |
| [`gpu-angle-mac/`](../../ios/dev-tools/gpu-angle-mac/README.md) | Can the ANGLE near-plane geometry bug be reproduced on a Mac's ANGLE? Not with synthetic geometry. |
| [`gpu-b1/`](../../ios/dev-tools/gpu-b1/gpu-b1-verdict.sh) | Do the base GPU plugin's shaders, downported to GLSL ES 3.00, compile, link and draw on a real GLES 3.0 driver (Simulator)? No README; the verdict script documents it. |
| [`gpu-clipremap/`](../../ios/dev-tools/gpu-clipremap/README.md) | Which reverse-Z strategy works on EAGL without clip control? Only `gl_FragDepth` restores precision. |
| [`gpu-depthsim/`](../../ios/dev-tools/gpu-depthsim/depthsim-verdict.sh) | Does `gl_FragDepth` reverse-Z reduce a controlled z-fight on GLES 3.0 (Simulator)? No README; see the verdict script. |
| [`gpu-present/`](../../ios/dev-tools/gpu-present/README.md) | Can an ANGLE EGL window surface present to the screen on a device? |
| [`gpu-tbo2d/`](../../ios/dev-tools/gpu-tbo2d/README.md) | Can 117 HD's texture-buffer face data be repacked into a 2D integer texture with the same fetch results? |

Their READMEs describe the state at the time, including a branch and plans that no longer exist. Where one
disagrees with this page or the code, the code wins. The live iOS GPU code is in `gpu-routec/` and `gpu-zone/`; their
READMEs ([gpu-routec](../../ios/dev-tools/gpu-routec/README.md), [gpu-zone](../../ios/dev-tools/gpu-zone/README.md))
also carry history and should be read the same way.

## See also

- [architecture.md](architecture.md): the headless client, AWT on Caciocavallo, and the bridge.
- [ios.md](ios.md) and [android.md](android.md): staging order, building and installing each port.
- [testing-qa.md](testing-qa.md): the gates, including the shader matrix and the Simulator gate.
- [debugging.md](debugging.md): logs, the probes in depth, and a symptom table.
- [gotchas.md](gotchas.md): traps that cost time.
- [android/dev-tools/gpu/README.md](../../android/dev-tools/gpu/README.md): Android GPU staging and the measurement log.
- [tools/shader-matrix/README.md](../../tools/shader-matrix/README.md)
