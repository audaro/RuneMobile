# gpu-angle — MetalANGLE on-device capability probe

> Branch `gpu`. Evaluates **MetalANGLE** (ANGLE-over-Metal) as a possible GPU backend for Route C, vs. the current
> native EAGL GLES 3.0 path. Answers three go/no-go questions in one device run: is it really ANGLE/Metal + which
> GLES version; does **`EXT_clip_control`** work (the root-cause fix for the river depth z-fight); do **compute
> shaders + SSBOs** work (the 117HD enabler); plus MSAA. Device-only (the ANGLE libs are arm64-iOS); no JIT/StikDebug
> needed (pure GLES, no JVM) — install + launch + pull log via `devicectl`.

## Result (sealed: `evidence/gpu-angle-device-verdict.log`, `./angle-verdict.sh` → `DEPTH_FIX`)

On iPhone 17 Pro Max / A19 Pro, iOS 26.5, via ANGLE 2.1.2440 Metal backend (from the Amethyst IPA):

| question | result |
|---|---|
| Real ANGLE-on-Metal, real GPU? | **YES** — `ANGLE Metal Renderer: Apple A19 Pro GPU` |
| `EXT_clip_control` works? | **YES** — far-plane stored window_z: clip **OFF = 0.5083** (the squeezed `(NDC.z+1)/2`) → clip **ON = 0.0167** (`= NDC.z`, desktop-equivalent full precision). This is the root-cause fix for the depth z-fight. |
| Compute shaders + SSBO? | **NO** — this ANGLE build exposes **ES 3.0 only** (ES 3.1 context request fails), so no compute → **117HD still blocked**. (Symbols are exported but the context caps at 3.0.) |
| MSAA | `GL_MAX_SAMPLES = 8`, 4× MSAA FBO complete |

**Takeaway:** MetalANGLE is valuable here as a **depth-correctness backend** (it gives the `glClipControl` native EAGL
GLES lacks), **not** as a 117HD enabler — this build is ES 3.0. Enabling 117HD would need a newer/custom ANGLE built
with ES 3.1 Metal compute (unverified, much larger lift).

## Reproduce (the `angle/` frameworks and `include/` headers are gitignored — regenerate them)

```sh
cd ios/dev-tools/gpu-angle

# 1) extract ANGLE (libEGL + libGLESv2, the Metal backend) from the Amethyst IPA
IPA="$HOME/Library/Mobile Documents/com~apple~CloudDocs/org.angelauramc.amethyst.slimmed-1.0-ios.ipa"
mkdir -p angle && cd angle
unzip -o -q "$IPA" "Payload/*/Frameworks/libEGL.framework/*" "Payload/*/Frameworks/libGLESv2.framework/*"
mv Payload/*/Frameworks/libEGL.framework Payload/*/Frameworks/libGLESv2.framework . && rm -rf Payload && cd ..

# 2) fetch Khronos EGL/GLES3 headers
mkdir -p include/KHR include/EGL include/GLES3
B_EGL=https://registry.khronos.org/EGL/api ; B_GL=https://registry.khronos.org/OpenGL/api
curl -fsSL $B_EGL/KHR/khrplatform.h  -o include/KHR/khrplatform.h
curl -fsSL $B_EGL/EGL/eglplatform.h  -o include/EGL/eglplatform.h
curl -fsSL $B_EGL/EGL/egl.h          -o include/EGL/egl.h
curl -fsSL $B_EGL/EGL/eglext.h       -o include/EGL/eglext.h
curl -fsSL $B_GL/GLES3/gl3platform.h -o include/GLES3/gl3platform.h
curl -fsSL $B_GL/GLES3/gl32.h        -o include/GLES3/gl32.h

# 3) build for device + run
xcodegen generate
xcodebuild -project GpuAngle.xcodeproj -scheme GpuAngle -destination "generic/platform=iOS" \
  -derivedDataPath build/dd -allowProvisioningUpdates build
DEV=<device-udid>
xcrun devicectl device install app --device "$DEV" build/dd/Build/Products/Debug-iphoneos/GpuAngle.app
xcrun devicectl device process launch --device "$DEV" dev.audaro.gpuangle
xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
  --domain-identifier dev.audaro.gpuangle --source Documents/gpu-angle-verdict.log --destination /tmp/a.log
./angle-verdict.sh /tmp/a.log   # recompute + md5-seal
```

The ANGLE frameworks are third-party (from Amethyst / Pojav lineage: GL4ES + MetalANGLE + MoltenVK + Mesa) and are
**not** committed here.
