#!/usr/bin/env bash
# A1 (W3 Feature-A) DESKTOP de-risk — relocate the engine chatbox to the top (exact OSRS skin) vs occluded.
#
# Same device-shaped boot + autologin as run-hud-isolation.sh, at a WIDE ~19.5:9 canvas (RESIZE, default
# 1560x720 ≈ the device full-screen render) with the ChatRelocateProbe enabled (-Drunelite.chatreloc=true): once
# in-world it hides the ENTIRE engine 2D HUD (minimap/orbs/chat/side-panels/tab-stones) and captures the
# scene-only frame. GREEN = the resizable 3D viewport fills the wide canvas edge-to-edge AND every HUD target
# is hidden. Inspect chatreloc-scene-*.png. Pair with chatreloc-verdict.sh.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"; JAVAC="$JAVA_HOME/bin/javac"
SHADED="$REPO/runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar"
AWTSMOKE="../awtsmoke"
OUT="out-chatreloc"
TOKENS="${TOKENS:-../tokens.json}"
RUN_SECONDS="${RUN_SECONDS:-200}"
RESIZE="${RESIZE:-1560x720}"

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
echo "== JX handoff: displayName='${JX_DISPLAY_NAME}' resize=${RESIZE} =="

rm -rf "$OUT"; mkdir -p "$OUT/cap" "$OUT/scene"
echo "== compile DeviceHeadlessBoot + activation =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
echo "== launching real RuneLite under UnsafePoke CTC + autologin + chatreloc probe @${RESIZE} (${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Dheadless.captureTargetFrames=999 \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-25}" \
  -Drunelite.headless.capture.preLoginMax="${PRELOGIN_MAX:-20}" \
  -Drunelite.headless.resize="${RESIZE}" \
  -Drunelite.headless.autologin="${AUTOLOGIN:-true}" \
  -Drunelite.headless.autologin.eula="${AUTOLOGIN_EULA:-true}" \
  -Drunelite.headless.autologin.eula.point="${AUTOLOGIN_EULA_POINT:-302,312}" \
  -Drunelite.headless.autologin.eula.loginIndex="${AUTOLOGIN_EULA_INDEX:-12}" \
  -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}" \
  -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}" \
  -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}" \
  -Drunelite.chatreloc=true \
  -Drunelite.chatreloc.dir="$PWD/$OUT/scene" \
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
  if grep -q "\[chatreloc\] CHATRELOC" "$LOG" 2>/dev/null; then
    echo "== CHATRELOC verdict observed at ~${i}s — stopping =="
    sleep 1
    break
  fi
  kill -0 "$PID" 2>/dev/null || break
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== login progression =="; grep -E "gameState .* LOGGED_IN" "$LOG" | tail -2 || echo "(none)"
echo "== [chatreloc] =="; grep -E "\[chatreloc\]" "$LOG" || echo "(no [chatreloc] lines — check $LOG)"
echo "== scene PNG =="; ls -la "$OUT/scene"/*.png 2>/dev/null || echo "(none)"
echo "== full log: $LOG =="
