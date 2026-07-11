#!/usr/bin/env bash
# BrowserStack App Automate gate runner — drive a real-device gate end-to-end and md5-verify it on real
# hardware, REUSING the emulator gate scripts (check-loggedin.sh / check-gates.sh) on the fetched logcat.
# This is how the real-device gates (A0-device, A-1b-on-device, AG0) run hands-free once a key is set.
#
# Setup:
#   cp bs-credentials.env.example bs-credentials.env   # fill in your App Automate username + access key
#   source bs-credentials.env                          # (bs-credentials.env is gitignored)
#   pip install "Appium-Python-Client>=3"
#
# Usage:
#   ./bs-gate.sh login    [apk]   # A0-device: pushed tokens.json -> autologin -> LOGGED_IN on a real device
#   ./bs-gate.sh census   [apk]   # A-1b on real hardware: the runtime gate-flip census
#   ./bs-gate.sh recon    [apk]   # AG0: GLES tier readout (needs the recon APK; AG0 is not built yet)
#
# Env knobs: BS_DEVICE (default "Google Pixel 8"), BS_OS_VERSION ("14.0"), BS_WAIT (150), TOKENS (path).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-login}"
APK="${2:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
TOKENS="${TOKENS:-$ROOT/ios/dev-tools/tokens.json}"   # the same tokens.json the emulator autologin uses
OUT="$HERE/bs-devicelogs-$MODE.txt"

: "${BROWSERSTACK_USERNAME:?set it — see bs-credentials.env.example}"
: "${BROWSERSTACK_ACCESS_KEY:?set it — see bs-credentials.env.example}"
[ -f "$APK" ] || { echo "APK not found: $APK (build it: gradlew :app:assembleDebug)" >&2; exit 2; }

echo "== upload APK to BrowserStack App Automate =="
APP_URL="$(curl -s -u "$BROWSERSTACK_USERNAME:$BROWSERSTACK_ACCESS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/upload" \
  -F "file=@$APK" | python3 -c 'import sys,json; print(json.load(sys.stdin)["app_url"])')"
[ -n "$APP_URL" ] || { echo "upload failed (check creds/network)" >&2; exit 2; }
echo "   app_url=$APP_URL"

echo "== run session (mode=$MODE, device=${BS_DEVICE:-Google Pixel 8}) =="
TOK_ARG=()
if [ "$MODE" != "recon" ] && [ -f "$TOKENS" ]; then TOK_ARG=(--tokens "$TOKENS"); fi
python3 "$HERE/bs-run.py" --app "$APP_URL" \
  --device "${BS_DEVICE:-Google Pixel 8}" --os-version "${BS_OS_VERSION:-14.0}" \
  --mode "$MODE" "${TOK_ARG[@]}" --wait "${BS_WAIT:-150}" --out "$OUT"

echo "== md5-gate the fetched logcat (reusing the emulator gates) =="
case "$MODE" in
  login)  "$ROOT/android/dev-tools/a0-login/check-loggedin.sh" "$OUT" ;;
  census) "$ROOT/android/dev-tools/a1b-gatecensus/check-gates.sh" "$OUT" ;;
  recon)  grep -E "GL_VERSION|RENDERER|MAX_COMPUTE|EXT_clip_control|ANDROID_GLES" "$OUT" \
            || { echo "no GLES recon lines in logcat — is the recon APK built?" >&2; exit 1; } ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac
