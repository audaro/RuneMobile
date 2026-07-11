# gpu-zone/facade — the iOS RLHD (117HD) LWJGL facade

> Branch `gpu`, Phase **B0.1**. The pure-Java `org.lwjgl.{opengl,opencl,system}` + `net.runelite.rlawt.AWTContext`
> surface that the **unmodified RLHD** source compiles against (lwjgl physically stripped from the compile
> classpath), so a symbol RLHD uses but we don't declare is a `javac` error at stage time, not a runtime
> `NoClassDefFound`. Consumed by `../stage-ios-zone-jar.sh`.

## Provenance & relationship to the base-gpu facade

This is a **superset** of the base-gpu Route C facade (`../../gpu-routec/facade-native/`, 14 classes). It adds the
**21 classes RLHD references beyond base gpu** — the OpenCL symbols-only stub (`org/lwjgl/opencl/*`, the Zone path
never creates a CL context), the higher GL version classes (`GL40`/`GL41C`/`GL43`/`GL44`/`ARB*`), and
`org/lwjgl/system/{MemoryStack,MemoryUtil,Platform}` + `Version`. The shared classes (`GL33C`, `GL45C`, …) are
byte-identical to the base-gpu facade. Surface seeded from the Android RLHD facade (`android/dev-tools/gpu/
facade-src`, which compiled the same RLHD `@7dded59` green) since the device-native method **signatures** are
platform-agnostic; only the JNI binding differs.

## What's real vs pending

- **Compile-time (B0.1, DONE):** every method is declared so RLHD links. `stage-ios-zone-jar.sh` is GREEN — 304
  RLHD classes compile, 0 lwjgl leak.
- **Drop-in superset (host-verified):** the **base** gpu plugin (delombok'd) also compiles GREEN against this
  facade with lwjgl stripped (29 classes, 0 errors) — so re-staging the base gpu jar with this superset at B0.5
  won't break the base path. (Verified non-destructively; the base bridge then services its 100 calls, this facade
  just additionally *declares* the RLHD delta.)
- **Runtime (B0.3, PENDING):** the `native` methods are **not yet bound**. This facade is the **spec** for the
  `RouteCBridge.m` `RegisterNatives` delta — the ~50 GL calls (e.g. `glDrawBuffers`, `glFramebufferTextureLayer`,
  conditional draw-indirect, `glTexBuffer`→2D TBO repack) the iOS bridge must service beyond the base-gpu 100-method
  surface. The OpenCL `cl*` methods stay unbound on purpose (no CL context on the Zone path).

At runtime the facade ships in the base-gpu `client-<ver>-shaded.jar`; the staged `client-<ver>-rlhd.jar` carries
**no** `org/lwjgl` or `rlawt` (one provider, all bridge-backed).
