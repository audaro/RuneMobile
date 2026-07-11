#!/usr/bin/env bash
# World-map mobile de-risk (WORLDMAP-MOBILE-PLAN.md Phase 0) — answers every input-model unknown headless:
# does a synthetic left-drag PAN the map (the touch-pan primitive), does a synthetic wheel ZOOM it (the pinch
# primitive), does the ZOOM_IN button work (pinch fallback), does SEARCH open a text field (soft-keyboard
# trigger), does setForcedPosition on the map window STICK (safe-area relocate) or get re-pinned, does CLOSE
# close. Same device-shaped boot + autologin as the other A-probes, with WorldMapProbe enabled
# (-Drunelite.worldmapprobe=true). Verdict = the "[worldmap] WORLDMAP ..." line; the PNGs
# (out-worldmap/cap/worldmap-*.png) are the layout-recon ground truth (open / panned / relocated-*).
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"; JAVAC="$JAVA_HOME/bin/javac"
SHADED="$(ls "$REPO"/runelite-client/build/libs/client-*-shaded.jar 2>/dev/null | head -1)"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar"
AWTSMOKE="../awtsmoke"
OUT="out-worldmap"
TOKENS="${TOKENS:-../tokens.json}"
RUN_SECONDS="${RUN_SECONDS:-220}"

if [ -z "$SHADED" ] || [ ! -f "$SHADED" ]; then (cd "$REPO" && ./gradlew :client:shadowJar --console=plain); SHADED="$(ls "$REPO"/runelite-client/build/libs/client-*-shaded.jar | head -1)"; fi
[ -f "$TOKENS" ] || { echo "!! $TOKENS missing — mint via ../fetch-shield-tokens.sh" >&2; exit 1; }
command -v jq >/dev/null || { echo "!! jq required" >&2; exit 1; }

export JX_ACCESS_TOKEN="$(jq -r '.access_token // ""' "$TOKENS")"
export JX_REFRESH_TOKEN="$(jq -r '.refresh_token // ""' "$TOKENS")"
export JX_SESSION_ID="$(jq -r '.session_id // ""' "$TOKENS")"
export JX_CHARACTER_ID="$(jq -r '.chosen_account_id // ""' "$TOKENS")"
export JX_DISPLAY_NAME="$(jq -r '.chosen_display_name // ""' "$TOKENS")"
[ -n "$JX_SESSION_ID" ] && [ -n "$JX_CHARACTER_ID" ] || { echo "!! tokens.json missing session/account" >&2; exit 1; }
echo "== JX handoff: displayName='${JX_DISPLAY_NAME}' =="

rm -rf "$OUT"; mkdir -p "$OUT/cap"
echo "== compile DeviceHeadlessBoot + activation =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/GateCensus.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
echo "== launching real RuneLite under UnsafePoke CTC + autologin + world-map probe (${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Dheadless.captureTargetFrames=999 \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-50}" \
  -Drunelite.headless.capture.preLoginMax="${PRELOGIN_MAX:-20}" \
  -Drunelite.headless.resize="${RESIZE:-1173x540}" \
  -Drunelite.headless.autologin="${AUTOLOGIN:-true}" \
  -Drunelite.headless.autologin.eula="${AUTOLOGIN_EULA:-true}" \
  -Drunelite.headless.autologin.eula.point="${AUTOLOGIN_EULA_POINT:-302,312}" \
  -Drunelite.headless.autologin.eula.loginIndex="${AUTOLOGIN_EULA_INDEX:-12}" \
  -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}" \
  -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}" \
  -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}" \
  -Drunelite.headless.welcomeplay=true \
  -Drunelite.worldmapprobe=true \
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
  if grep -q "\[worldmap\] WORLDMAP" "$LOG" 2>/dev/null; then
    echo "== WORLDMAP verdict observed at ~${i}s — stopping =="
    sleep 1
    break
  fi
  kill -0 "$PID" 2>/dev/null || break
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== login =="; grep -E "gameState .* LOGGED_IN" "$LOG" | tail -1 || echo "(none)"
echo "== [worldmap] =="; grep -E "\[worldmap\]" "$LOG" || echo "(no [worldmap] lines — check $LOG)"
echo "== captures =="; ls -1 "$OUT/cap"/worldmap-*.png 2>/dev/null || echo "(no worldmap PNG)"
echo "== full log: $LOG =="
