#!/usr/bin/env bash
# DESKTOP off-device capture of the A3 native-chat VENEER geometry — the engine-side chat (relocate + enlarged
# tab-row push-down + message-area resize) rendered to PNG on the Mac, so chat width / bottom-clip / wrapping can
# be verified WITHOUT a device + StikDebug. (The native UIKit tab BUTTONS are iOS-only and won't appear here; this
# validates the engine half — CHATAREA/CHATDISPLAY geometry — which is where the width/clip bugs live.)
#
# Boots the real RuneLite client under CACIO + autologin at the device canvas (1304x600 ≈ iPhone 17 Pro Max
# full-screen render), arms HudVeneerBridge (-Drunelite.hudveneer=true) + the off-device auto-apply
# (-Drunelite.hudveneer.test=true), and dumps composited frames via HeadlessCapture. Inspect out-chat-veneer/cap/
# frame-LOGGED_IN-*.png + the [veneer] chat-layout dump in the log.
#
# Env overrides: RESIZE, TRANSPARENT (true/false — false = opaque box to read dimensions), ROWH, AREAW, RUN_SECONDS.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"; JAVAC="$JAVA_HOME/bin/javac"
# QA-P1-15: derive the version from gradle.properties instead of a hardcoded literal (broken on the next bump).
VERSION="$(sed -n 's/^project\.build\.version=//p' "$REPO/gradle.properties")"
[ -n "$VERSION" ] || { echo "!! could not read project.build.version from $REPO/gradle.properties" >&2; exit 1; }
SHADED="$REPO/runelite-client/build/libs/client-${VERSION}-shaded.jar"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar"
AWTSMOKE="../awtsmoke"
OUT="out-chat-veneer"
TOKENS="${TOKENS:-../tokens.json}"
# 1269x720 is the canvas where the shared autologin reliably reaches the WORLD (the welcome-screen "CLICK HERE TO
# PLAY" point is canvas-size-dependent and misses at the device's 1304x600). Chat-widget geometry is fixed engine
# px (519 etc.), canvas-independent, so this validates the same chat layout as the device.
RUN_SECONDS="${RUN_SECONDS:-170}"
RESIZE="${RESIZE:-1269x720}"
TRANSPARENT="${TRANSPARENT:-true}"
ROWH="${ROWH:-32}"
AREAW="${AREAW:-0}"

if [ ! -f "$SHADED" ]; then
  echo "== building shaded client on JDK 21 =="
  (cd "$REPO" && ./gradlew :client:shadowJar --console=plain)
fi
if [ ! -f "$TOKENS" ]; then echo "!! $TOKENS missing — mint via ../fetch-shield-tokens.sh" >&2; exit 1; fi
command -v jq >/dev/null || { echo "!! jq required" >&2; exit 1; }

export JX_ACCESS_TOKEN="$(jq -r '.access_token // ""' "$TOKENS")"
export JX_REFRESH_TOKEN="$(jq -r '.refresh_token // ""' "$TOKENS")"
export JX_SESSION_ID="$(jq -r '.session_id // ""' "$TOKENS")"
export JX_CHARACTER_ID="$(jq -r '.chosen_account_id // ""' "$TOKENS")"
export JX_DISPLAY_NAME="$(jq -r '.chosen_display_name // ""' "$TOKENS")"
if [ -z "$JX_SESSION_ID" ] || [ -z "$JX_CHARACTER_ID" ]; then echo "!! tokens.json missing session/account" >&2; exit 1; fi
echo "== JX handoff: displayName='${JX_DISPLAY_NAME}' resize=${RESIZE} transparent=${TRANSPARENT} rowH=${ROWH} areaW=${AREAW} =="

rm -rf "$OUT"; mkdir -p "$OUT/cap"
echo "== compile DeviceHeadlessBoot + activation =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/GateCensus.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
echo "== launching real RuneLite under UnsafePoke CTC + autologin + HUD chat veneer @${RESIZE} (${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Dheadless.captureTargetFrames=999 \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-50}" \
  -Drunelite.headless.capture.preLoginMax="${PRELOGIN_MAX:-3}" \
  -Drunelite.headless.capture.max="${CAPTURE_MAX:-16}" \
  -Drunelite.headless.resize="${RESIZE}" \
  -Drunelite.headless.autologin=true \
  -Drunelite.headless.autologin.eula=true \
  -Drunelite.headless.autologin.eula.point="302,312" \
  -Drunelite.headless.autologin.eula.loginIndex=12 \
  -Drunelite.headless.autologin.point="382,248" \
  -Drunelite.headless.autologin.world=301 \
  -Drunelite.headless.autologin.worldAddress="oldschool1.runescape.com" \
  -Drunelite.hudveneer=true \
  ${MUI:+-Drunelite.mobileui=true} \
  -Drunelite.hudveneer.test=true \
  -Drunelite.hudveneer.test.transparent="${TRANSPARENT}" \
  -Drunelite.hudveneer.test.rowH="${ROWH}" \
  -Drunelite.hudveneer.test.areaW="${AREAW}" \
  ${EXTRA_JVM_ARGS:-} \
  --add-exports=java.desktop/java.awt=ALL-UNNAMED \
  --add-exports=java.desktop/java.awt.peer=ALL-UNNAMED \
  --add-exports=java.desktop/sun.awt.image=ALL-UNNAMED \
  --add-exports=java.desktop/sun.java2d=ALL-UNNAMED \
  --add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED \
  --add-exports=java.desktop/sun.awt=ALL-UNNAMED \
  --add-exports=java.desktop/sun.awt.event=ALL-UNNAMED \
  --add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED \
  --add-exports=java.base/sun.security.action=ALL-UNNAMED \
  --add-opens=java.base/java.util=ALL-UNNAMED \
  --add-opens=java.desktop/java.awt=ALL-UNNAMED \
  --add-opens=java.desktop/sun.java2d=ALL-UNNAMED \
  --add-opens=java.base/java.lang.reflect=ALL-UNNAMED \
  -cp "$OUT:$CACIO:$SHADED" DeviceHeadlessBoot > "$LOG" 2>&1 &
PID=$!
for i in $(seq 1 "$((RUN_SECONDS + 15))"); do
  sleep 1
  # capture spreads over many draws (interval 50); 12 LOGGED_IN frames spans welcome-screen -> in-world, so the
  # later frames are the real chat. Stop once we have enough.
  if [ "$(ls "$OUT/cap"/frame-LOGGED_IN-*.png 2>/dev/null | wc -l | tr -d ' ')" -ge 12 ]; then
    echo "== >=12 LOGGED_IN frames captured at ~${i}s — stopping =="
    sleep 1
    break
  fi
  kill -0 "$PID" 2>/dev/null || break
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== login progression =="; grep -E "gameState .* LOGGED_IN" "$LOG" | tail -1 || echo "(none)"
echo "== [veneer] chat-layout =="; grep -E "\[veneer\] chat-layout (CHAT_CONTAINER|CHATAREA|CHATDISPLAY|SCROLLAREA)" "$LOG" | tail -4 || echo "(none)"
echo "== LOGGED_IN frames =="; ls -la "$OUT/cap"/frame-LOGGED_IN-*.png 2>/dev/null | tail -6 || echo "(none — check $LOG)"
echo "== full log: $LOG =="
