# gpu-zone/jni — RLHD Zone JNI delta bridge

> Branch `gpu`, Phase **B0.2/B0.3**. `routec_zone_jni.m` = the iOS-bridge half of the facade delta
> (`../facade-delta.md`): the GL + off-heap calls RLHD makes beyond the base gpu plugin's 100-call surface. It is
> **registered on top of** the base bridge (`../../gpu-routec/jni/routec_gl_jni.m`) — the proven base path is
> untouched. **Compile-checked for iOS arm64** by `../zone-bridge-compile-check.sh`
> (`ZONE_BRIDGE_COMPILES_ARM64`); device-only at runtime (no JVM on the Simulator), exactly like base step 3b.

## What it registers (53 entries, exact match to the delta)

- **50 GL methods on `org/lwjgl/opengl/GLALL`** (all GL facade classes are `extends GLALL {}` shims, so every GL
  native lives on GLALL). Verified to match `facade-delta.txt`'s opengl set exactly.
  - **Bucket A** (~31): GLES-3.0-core forwarders — FBO attach, uniforms, buffer up/copy/map, 3D-tex uploads, ES3
    sync fences, introspection getters.
  - **#11 / #1 shims**: `glDrawBuffer`→`glDrawBuffers(1,&buf)`; `glTexBuffer`→2D `glTexImage2D(GL_RGB32I,W,ceil(N/W))`
    repack (blocker #1, byte-exact per `gpu-tbo2d`).
  - **Bucket B** (~17): no-op stubs for the compute / indirect-draw / timer-query / KHR_debug calls that are
    caps-gated OFF on the iOS zone path (`../B0-conformance-notes.md`) so they never fire — present only so the
    table is complete and a stray call can't `UnsatisfiedLinkError`. They reference **no** GL symbol (those are ES
    3.1+/desktop-only and absent from iOS GLES).
- **3 off-heap on `org/lwjgl/system/MemoryUtil`**: `nmemAllocChecked`→`malloc`, `nmemFree`→`free`,
  `memAddress0`→`GetDirectBufferAddress` (RLHD `ModelCache`).

## Device wiring (B0.5, pending)

1. The runtime classpath = base gpu jar (which must ship the **grown** `facade/` superset so the single in-jar
   facade declares all the delta natives) + the staged `client-<ver>-rlhd.jar`. ⇒ re-run `stage-ios-gpu-jar.sh`
   with the zone facade before booting RLHD.
2. Compile `routec_zone_jni.m` into the app alongside `routec_gl_jni.m`.
3. After `JNI_CreateJavaVM`, in zone mode, call `RouteC_registerGLNatives(env)` **then**
   `RouteC_registerZoneNatives(env)` (they register disjoint method sets on the same GLALL class).

## TODO(device) carried in the source

- `glBufferSubData`/`glGetProgramBinary` NIO sizing uses `GetDirectBufferCapacity` — LWJGL sizes by `remaining()`;
  the device-correct refinement is to size in the Java facade (same note as the base bridge).
- `glTexBuffer` repack uploads to the bound `GL_TEXTURE_2D`; the **companion** `glBindTexture(GL_TEXTURE_BUFFER,…)`
  → `GL_TEXTURE_2D` remap (the only piece touching the base bridge) is the matching device edit.
- `glTexSubImage3D` BGRA→RGBA swizzle (the Android real-Mali fix) is per-format, applied here when it surfaces.
- `glFramebufferTexture` (ES 3.2) is emulated as layer-0 attach; true layered attach is B5 (tiled lighting).
