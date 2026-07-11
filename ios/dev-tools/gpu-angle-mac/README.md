# gpu-angle-mac — off-device ANGLE-Metal reproduction harness (macOS)

Runs ANGLE-on-Metal **on the Mac** (no iOS device, no StikDebug, no screenshots) so the Route C / 117HD ANGLE
render path can be iterated fast. macOS ANGLE (from Google Chrome) shares ANGLE's Metal backend with the iOS build,
so backend bugs (clipping/projection/shader) generally reproduce here.

**CAVEAT:** macOS ANGLE != iOS ANGLE bit-for-bit. The iOS libs (Amethyst IPA) are **ANGLE 2.1.2440**; Chrome's macOS
libs are **ANGLE 2.1.27515** (years newer) on a different GPU. So a clean result here does NOT prove the device is
clean — a version-specific bug can be present on the old iOS ANGLE and fixed in the new macOS one. Final confirmation
still needs one device run (same caveat class as the gpu-b1 Simulator proxy).

## Setup + run
```sh
cd ios/dev-tools/gpu-angle-mac
CHROME="/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Libraries"
mkdir -p angle && cp "$CHROME/libGLESv2.dylib" "$CHROME/libEGL.dylib" angle/   # gitignored, third-party
clang -arch arm64 -fobjc-arc -DGL_SILENCE_DEPRECATION -I ../gpu-angle/include angle_mac_repro.m -o repro \
  -L angle -lEGL -lGLESv2 -framework Foundation -framework CoreGraphics -framework ImageIO
DYLD_LIBRARY_PATH="$PWD/angle" ./repro      # writes repro-clip-on.png / repro-clip-off.png
```

## Result so far (2026-06-07)
The on-device wedge bug (giant white degenerate triangles) did NOT reproduce with the synthetic reverse-Z
near/behind-camera triangle test on macOS ANGLE 2.1.27515 — behind-camera + near-plane geometry clip cleanly. Either
the wedge needs the real plugin geometry (a fuller harness: plugin -> facade -> bridge -> macOS ANGLE) or it is an
old-iOS-ANGLE-version bug fixed since 2.1.2440.
