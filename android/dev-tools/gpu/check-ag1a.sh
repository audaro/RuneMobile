#!/usr/bin/env bash
# Track G AG1a GREEN gate — the facade-bind EGL smoke. Proves `GL.createCapabilities().OpenGL33 == true` through
# the org.lwjgl.opengl facade on a LIVE Android EGL/GLES context, headless, plus a real glCreateProgram() id and
# the census shims clean. This is the cheapest GPU go/no-go: emulator-RED kills the GPU track instantly.
#
# !! emulator-GREEN != AG1-GREEN. The emulator is ANGLE->SwiftShader (lenient). AG1a proves the facade link + the
#    EGL context + RegisterNatives completeness (~75%). AG1b (real shaders compile/link/glValidateProgram on a
#    real Adreno/Mali driver, under the real DeviceHeadlessBoot HotSpot render thread, against the CACIO canvas)
#    is the device-only coin-flip — see android/GPU-TRACK-PLAN.md.
#
# Run:
#   android/dev-tools/gpu/build-smoke-jar.sh                 # (re)build the facade-only jar into assets
#   cd android && JAVA_HOME=… ./gradlew :app:assembleDebug
#   adb install -r app/build/outputs/apk/debug/app-debug.apk
#   adb shell am start -n dev.audaro.runemobile/.MainActivity --ez gpuSmoke true
#   android/dev-tools/gpu/check-ag1a.sh                      # greps logcat for the verdict
set -euo pipefail
SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi

LINE="$(printf '%s\n' "$RAW" | grep -oE 'ANDROID_AG1A OpenGL33=.*' | tail -1 || true)"
VERDICT="$(printf '%s\n' "$RAW" | grep -oE 'ANDROID_AG1A VERDICT=(PASS|FAIL)' | tail -1 || true)"
echo "$LINE"
echo "$VERDICT"
if printf '%s' "$VERDICT" | grep -q 'VERDICT=PASS' && printf '%s' "$LINE" | grep -q 'OpenGL33=true'; then
	echo "AG1a GREEN — OpenGL33==true through the facade on a live EGL/GLES context, headless (emulator; NOT yet AG1)."
	exit 0
else
	echo "AG1a not GREEN (need ANDROID_AG1A VERDICT=PASS with OpenGL33=true)"; exit 1
fi
