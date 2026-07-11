#!/usr/bin/env bash
# WorldMapProbe on the LEGACY (username/password) account, desktop headless — the stock-engine A/B for the
# Android Phase-5 Finding 1 (the world map will not open for the legacy account on the emulator). No JX_*
# handoff: HeadlessLogin's legacy stage types RL_LEGACY_USER/RL_LEGACY_PASS (read from
# ~/.config/runelite-ios/legacy_login.json — never echoed) into the classic login form. If the map ALSO
# refuses to open here — with none of the Android chrome/veneer running — the refusal is server-side
# account state, not the port.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"; JAVAC="$JAVA_HOME/bin/javac"
# ls|head -1 would pick the STALE 1.12.28 jar (predates the legacy-login stage) — sort and take the newest.
SHADED="$(ls "$REPO"/runelite-client/build/libs/client-*-shaded.jar 2>/dev/null | sort -V | tail -1)"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar"
AWTSMOKE="../awtsmoke"
OUT="out-worldmap-legacy2"
CFG="$HOME/.config/runelite-ios/legacy_login.json"
RUN_SECONDS="${RUN_SECONDS:-260}"

[ -f "$SHADED" ] || { echo "!! shaded jar missing — run ./gradlew :client:shadowJar" >&2; exit 1; }
[ -f "$CFG" ] || { echo "!! $CFG missing — run android/dev-tools/a3-login/set-legacy-login.sh" >&2; exit 1; }
command -v jq >/dev/null || { echo "!! jq required" >&2; exit 1; }

# Legacy creds via env (the HeadlessLogin legacy stage reads these). Deliberately NO JX_* exports —
# a Jagex session in the env would win over the typed legacy login.
export RL_LEGACY_USER="$(jq -r '.username // ""' "$CFG")"
export RL_LEGACY_PASS="$(jq -r '.password // ""' "$CFG")"
[ -n "$RL_LEGACY_USER" ] && [ -n "$RL_LEGACY_PASS" ] || { echo "!! legacy_login.json missing username/password" >&2; exit 1; }
unset JX_ACCESS_TOKEN JX_REFRESH_TOKEN JX_SESSION_ID JX_CHARACTER_ID JX_DISPLAY_NAME
echo "== legacy handoff: credentials loaded (not shown) =="

rm -rf "$OUT"; mkdir -p "$OUT/cap"
echo "== compile DeviceHeadlessBoot + activation =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/GateCensus.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
echo "== launching real RuneLite, legacy autologin + world-map probe (${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Dheadless.captureTargetFrames=999 \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-50}" \
  -Drunelite.headless.capture.preLoginMax="${PRELOGIN_MAX:-20}" \
  -Drunelite.headless.resize="${RESIZE:-1280x720}" \
  -Drunelite.headless.autologin="${AUTOLOGIN:-true}" \
  -Drunelite.headless.autologin.legacy=true \
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
  if grep -q "map never opened\|\[worldmap\] WORLDMAP" "$LOG" 2>/dev/null; then
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
