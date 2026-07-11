#!/usr/bin/env bash
# DESKTOP one-shot: extract the chat tab-button sprites (CHATBOX_BUTTON*) + census the 7 chat tabs' geometry/
# state, so the native enlarged chat-tab veneer can be built + coloured from ground truth. Same device-shaped
# boot + autologin as run-chat-reloc.sh, with MobileChromeSpriteDump enabled.
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
OUT="out-chat-sprites"
TOKENS="${TOKENS:-../tokens.json}"
RUN_SECONDS="${RUN_SECONDS:-160}"
RESIZE="${RESIZE:-1560x720}"

if [ ! -f "$SHADED" ]; then echo "!! $SHADED missing — build :client:shadowJar" >&2; exit 1; fi
if [ ! -f "$TOKENS" ]; then echo "!! $TOKENS missing — mint via ../fetch-shield-tokens.sh" >&2; exit 1; fi
command -v jq >/dev/null || { echo "!! jq required" >&2; exit 1; }

export JX_ACCESS_TOKEN="$(jq -r '.access_token // ""' "$TOKENS")"
export JX_REFRESH_TOKEN="$(jq -r '.refresh_token // ""' "$TOKENS")"
export JX_SESSION_ID="$(jq -r '.session_id // ""' "$TOKENS")"
export JX_CHARACTER_ID="$(jq -r '.chosen_account_id // ""' "$TOKENS")"
export JX_DISPLAY_NAME="$(jq -r '.chosen_display_name // ""' "$TOKENS")"
if [ -z "$JX_SESSION_ID" ] || [ -z "$JX_CHARACTER_ID" ]; then echo "!! tokens.json missing session/account" >&2; exit 1; fi
echo "== JX handoff: displayName='${JX_DISPLAY_NAME}' resize=${RESIZE} =="

rm -rf "$OUT"; mkdir -p "$OUT/cap"
echo "== compile DeviceHeadlessBoot + activation =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
echo "== launching real RuneLite under UnsafePoke CTC + autologin + sprite-dump @${RESIZE} (${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Dheadless.captureTargetFrames=999 \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
  -Drunelite.headless.capture.interval=9999 \
  -Drunelite.headless.capture.preLoginMax=2 \
  -Drunelite.headless.resize="${RESIZE}" \
  -Drunelite.headless.autologin=true \
  -Drunelite.headless.autologin.eula=true \
  -Drunelite.headless.autologin.eula.point="302,312" \
  -Drunelite.headless.autologin.eula.loginIndex=12 \
  -Drunelite.headless.autologin.point="382,248" \
  -Drunelite.headless.autologin.world=301 \
  -Drunelite.headless.autologin.worldAddress="oldschool1.runescape.com" \
  -Drunelite.mobilechrome.spritedump=true \
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
  if grep -q "SPRITE_DUMP" "$LOG" 2>/dev/null; then
    echo "== SPRITE_DUMP observed at ~${i}s — stopping =="
    sleep 1
    break
  fi
  kill -0 "$PID" 2>/dev/null || break
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== login progression =="; grep -E "gameState .* LOGGED_IN" "$LOG" | tail -2 || echo "(none)"
echo "== SPRITE_DUMP + CHAT_LAYOUT =="; grep -E "\[sprite-dump\]" "$LOG" || echo "(none — check $LOG)"
echo "== extracted PNGs =="; ls -la "$OUT/cap"/tabasset-chat*.png 2>/dev/null || echo "(none)"
echo "== full log: $LOG =="
