# gpu-present — ANGLE/Metal window-surface present-path de-risk (Phase A1)

> Branch `gpu`. The Phase A1 backend swap (EAGL → MetalANGLE in Route C) needs the rendered frame **on screen**.
> EAGL did that with `renderbufferStorage:fromDrawable:` on a `CAEAGLLayer`; ANGLE has no equivalent — its on-screen
> path is an **EGL window surface** created from a native layer + `eglSwapBuffers`. The handoff calls this present
> path "the main risk — solve/de-risk it FIRST." This probe does exactly that, in isolation, with **no JVM/JIT**
> (pure GLES via ANGLE): bring up an ANGLE/Metal EGL display + ES3 context, create a window surface from a
> full-screen `CAMetalLayer`, and **live-present** an animated pattern (3 colour bars + a sweeping white stripe).

## What it proves

| question | how |
|---|---|
| EGL **window surface** scans out to the device screen | the colour bars + moving stripe are visible (screenshot) |
| the window default framebuffer is a real, readable FBO | one-shot `glReadPixels` of the green-bar centre (`fb_readback`) |
| `EXT_clip_control` reverse-Z works under the **window** context (not just the gpu-angle pbuffer) | `clip_control` |
| an MSAA config is honoured | `GL_MAX_SAMPLES>=4` + complete MSAA fbo (`msaa`) |

GREEN present path = `window_present=YES` + `fb_readback=YES` + a clean run **and** the screenshot showing the bars.

## Build + run (device only — the ANGLE libs are arm64-iOS)

```sh
cd ios/dev-tools/gpu-present
# the ANGLE frameworks + Khronos headers are reused (gitignored) from ../gpu-angle (regenerate via gpu-angle/README)
xcodegen generate
xcodebuild -project GpuPresent.xcodeproj -scheme GpuPresent -destination "generic/platform=iOS" \
  -derivedDataPath build/dd -allowProvisioningUpdates build
DEV=<YOUR_DEVICE_UDID>   # e.g. `xcrun devicectl list devices` to find it
xcrun devicectl device install app --device "$DEV" build/dd/Build/Products/Debug-iphoneos/GpuPresent.app
xcrun devicectl device process launch --device "$DEV" dev.audaro.gpupresent
# LOOK at the device: 3 colour bars (red|green|blue) with a white stripe sweeping left->right == present works.
xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
  --domain-identifier dev.audaro.gpupresent --source Documents/gpu-present-verdict.log --destination /tmp/p.log
./present-verdict.sh /tmp/p.log               # prints the md5; paste it back into present-verdict.sh to seal
```

No JIT/StikDebug needed — this is a plain GLES app. The ANGLE frameworks are third-party (Amethyst/Pojav lineage)
and are not committed here.
