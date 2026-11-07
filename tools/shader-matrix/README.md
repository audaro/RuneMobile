# Shader matrix

A host check for the 117 HD shaders as each phone compiles them, with no phone. It catches the shader errors a
117 HD update or a change to a shader override would otherwise show first as a black or broken 117 HD screen on a
device.

```sh
tools/shader-matrix/run-matrix.sh ios              # every variant, the iOS port
tools/shader-matrix/run-matrix.sh android          # every variant, the Android port
tools/shader-matrix/run-matrix.sh android pcss     # only the variants whose name starts with "pcss"
```

It ends with `SHADER_MATRIX_GREEN (<port>, <n> variants)` or `SHADER_MATRIX_RED (<port>)`, and exits non-zero on
red. A full run takes a minute or two per port.

## What it checks

117 HD assembles its shaders at run time: each program is a set of source files plus `#include`s and `#define`s that
depend on the plugin's settings. Each phone then rewrites that source for its own GL before compiling it, and the
rewrite lives in native code, so neither step happens in a desktop build. The matrix repeats both:

1. **`RlhdShaderDump.java`** assembles every program the zone renderer builds (scene, water, gap filler, the shadow
   passes, tiled lighting, UI, sky, stars, the nebula bake and the debug overlays) through 117 HD's own
   `HdPlugin.getShaderIncludes()`, once per settings variant. The 12 variants in `run-matrix.sh` between them give
   each settings-driven `#define` every value it can take.
2. **`downport_check.py`** applies the port's run-time rewrite and validates each stage with `glslangValidator`:
   - **ios:** `RouteCBridge.m`'s `downportShaderSource`, for Apple's OpenGL ES 3.0 driver. It also scans the live
     code for ES 3.1+ built-ins, which glslang accepts at the version it validates with and that driver rejects.
   - **android:** `librlawt.cpp`'s `rc_downport` at `#version 320 es`.

   On both ports it flags a sampler type with no precision: ES gives only `sampler2D` and `samplerCube` a default,
   and that default is `lowp`. The checker reads
   the rewrite rules out of the native sources rather than keeping its own copy, and a read that finds none fails
   the run, so it can't drift from the code the phones run.

The shaders it checks are the port's overrides from the working tree laid over 117 HD's own sources, as the staged
jar carries them: `ios/dev-tools/gpu-zone/ios-overrides/` and `android/dev-tools/gpu/shader-overlay/`.

## When to run it

- after a change to a shader override on either port;
- after a change to a port's rewrite (`RouteCBridge.m` on iOS, `librlawt.cpp` on Android);
- after moving the 117 HD pin, on both ports. If the new version adds a settings-driven `#define`, add a variant to
  `VARIANTS` in `run-matrix.sh` that sets it.

## Needs

- `glslangValidator` (`brew install glslang`);
- JDK 21 (`JAVA_HOME`, default `/opt/homebrew/opt/openjdk@21`) and `/usr/bin/python3`;
- the port's stage work directory from a prior stager run: `ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh` or
  `android/dev-tools/gpu/stage-rlhd-zone-jar.sh`. The script names the one it is missing.

Each variant's output goes to `<stage work dir>/shader-matrix/<variant>/`: the assembled stages, each stage as it
was validated (`chk-*.glsl`), and `report.txt`, which lists every error with the source line it points at.

## What it doesn't cover

glslang is a fast filter, not the authority. A stage it accepts can still fail on a phone's driver, and it says
nothing about what the shaders draw. On iOS, `ios/dev-tools/sim-gate.sh` boots 117 HD in the iOS Simulator, whose
GL is Apple's software renderer; on Android, and for anything visual, check on the device.
