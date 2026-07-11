# Track G — GPU rendering (base `gpu`, then 117HD)

The canonical, source-verified plan is [`android/GPU-TRACK-PLAN.md`](../../GPU-TRACK-PLAN.md). This directory holds
the **AG1a** deliverable: the facade-bind EGL smoke that is the cheapest GPU go/no-go.

## What AG1a proves

The base RuneLite `gpu` plugin hard-gates on `GL.createCapabilities().OpenGL33 == true` (`GpuPlugin.java:317`
aborts otherwise) and builds its context through `net.runelite.rlawt.AWTContext`. There is **no `natives-android`
LWJGL classifier** (`runelite-client/build.gradle.kts:93-94`), so the approach (proven on iOS as "Route C") is to
*replace* real LWJGL with a pure-Java facade + a native EGL `.so`. AG1a stands that up on Android and asserts the
gate is satisfiable, headless, on a live EGL/GLES context — **before** any plugin wiring.

## Pieces (all on the `android` branch)

| File | What |
|---|---|
| `facade-src/org/lwjgl/opengl/*`, `org/lwjgl/system/*`, `net/runelite/rlawt/AWTContext.java` | the pure-Java facade, ported verbatim from the `gpu` branch (`ios/dev-tools/gpu-routec/facade-native/`). `GLALL` holds the GL surface; `GL33C/42C/43C/45C` are thin subclasses; `Configuration`/`Callback` are self-contained stubs (no real liblwjgl load). |
| `RouteCSmoke.java` | the Android L1 probe (mirrors the iOS `RouteCL1Probe`): `new AWTContext(null)` → `createGLContext()` → `GL.createCapabilities()` → `glCreateProgram()` + the 5 shims → `ANDROID_AG1A VERDICT=`. |
| `build-smoke-jar.sh` | javac's the facade + probe into a **facade-only** `gpu-smoke.jar` (no shaded jar, no real LWJGL → the facade is provably the only provider) → `app/src/main/assets/jvm/gpu-smoke.jar`. |
| `app/src/main/cpp/librlawt.cpp` | the **per-ABI `librlawt` replacement**: an Android EGL offscreen pbuffer ES3 context + COLOR/DEPTH FBO, the full `kGLALL`/`kAWT`/`kGL` `RegisterNatives` table forwarding to GLES, `createCapabilities()` returning `OpenGL33=true`, exported `RouteC_registerGLNatives`. Ported from the iOS `routec_gl_jni.m` + `RouteCBridge.m` EGL path, EAGL→EGL, ANGLE/water/2x-SS/present/perf stripped. |
| `CMakeLists.txt` (`rlawt` target) | builds `librlawt.so` linking Android's native `EGL` + `GLESv3`. |
| host wiring | `jvm_bootstrap.cpp` smoke branch (dlopen `librlawt.so` + `RouteC_registerGLNatives`, skip CACIO/engine); `MainActivity.bootGpuSmoke` boots `RouteCSmoke` on the facade-only jar via `--ez gpuSmoke true`. |

## Run + gate

```
android/dev-tools/gpu/build-smoke-jar.sh
cd android && JAVA_HOME=… ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n dev.audaro.runemobile/.MainActivity --ez gpuSmoke true
android/dev-tools/gpu/check-ag1a.sh
```

## Emulator GREEN (rl_arm64, 2026-06-08)

```
librlawt: RegisterNatives glall=0 awt=0 gl=0 (0=OK)
librlawt: createGLContext DONE fbo=1 512x512 complete=1 GL_VERSION=OpenGL ES 3.1 (ANGLE 2.1.1 …)
ANDROID_AG1A OpenGL33=true createProgram=1 fbo=1 bufMode=36064 glErrAfterProg=0 glErrAfterShims=0 texStorage3D=1 …
ANDROID_AG1A VERDICT=PASS
```

(`evidence/ag1a-emulator-verdict-20260608.log`.) The librlawt EGL context comes up, `OpenGL33==true` resolves
through the facade, a real `glCreateProgram()` returns non-zero, and the shims (`glClearDepth`, `glClipControl`)
run clean — so the facade link + EGL bring-up + RegisterNatives completeness all hold.

## ⚠ This is NOT AG1-GREEN

The emulator is **ANGLE → SwiftShader** (`GL_RENDERER` confirms) — lenient, and an invalid proxy for a real GPU
driver. AG1a closes the *easy ~75%*. The coin-flip (**AG1b**, ~50%, the project-wide GPU go/no-go) is **device-only**:
the real base shaders compiling/linking/**`glValidateProgram`**-ing on a real Adreno/Mali driver, under the real
`DeviceHeadlessBoot`/`JNI_CreateJavaVM` HotSpot render thread, against the live CACIO canvas, producing one frame.
Run that on a real device (BrowserStack). See `android/GPU-TRACK-PLAN.md` §AG1 + the OPEN questions.

## AG2.5-b — 117HD (RLHD) class-load + loader probe (GREEN, emulator, 2026-06-08)

`stage-rlhd-zone-jar.sh` compiles the unmodified RLHD source (vendored at `rlhd-src/`, rev 7dded59) against
[`facade-src/` : a **lwjgl-stripped** client jar] — the facade is the sole LWJGL provider, so any missing GL/CL/
system symbol is a `javac` error, not a runtime crash. Output: `client-<ver>-rlhd.jar` (rs117/** + shaders/JSON/
textures; the facade ships in `client-<ver>-gpu.jar`, so **re-stage the gpu jar from the same facade-src**).

`check-rlhdprobe.sh` runs `RLHDProbe` (`--ez rlhdprobe`) on `[gpu jar + rlhd jar]` — a headless class-load test
(host activates CACIO, skips bridge/render/login). It link/verifies every rs117.* class against the facade, runs
the OpenCL class-load graph, and parses the 9 bundled loader JSON files. This gate has **no GL execution**, so the
emulator is authoritative for it.

```
ANDROID_RLHD_PROBE linkSweep linked=304/304 failures=0
ANDROID_RLHD_PROBE openclGraph init=true OPENCL_EXPLICIT_INIT=true
ANDROID_RLHD_PROBE loaderJson parsed=9/9
MEGAVERDICT = ANDROID_RLHD_PROBE_GREEN
```

(`evidence/ag25b-rlhdprobe-emulator-20260608.log`.) Proves the OpenCL stub + Zone facade delta resolve at
class-load (no NoClassDefFound) and the loader data ships + parses on-device. The full `HdPlugin.startUp` (typed
loader data-load + GL/VAO/UBO/shader init against a live EGL context) is AG3 — it exercises the librlawt GL-delta
forwarders, which this class-load probe does not.
