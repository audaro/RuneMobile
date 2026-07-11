#!/usr/bin/env bash
# A0 (W3 Feature-A) DESKTOP de-risk — HUD suppression + route-back click-through.
#
# Reuses the device-shaped boot (UnsafePokeActivation.activate() + DeviceHeadlessBoot, NO byte-buddy /
# NO CacioExtension — exactly what JVMLauncher.m runs) + the JX_* launcher handoff + HeadlessLogin
# two-stage autologin from run-headless-login-unsafepoke.sh. Adds the HudIsolationTest probe
# (-Drunelite.hudisolation=true) which, once in-world, cycles four suppression modes (none / draw2DMask /
# setHidden / transparent) and for each measures (a) whether the minimap/chat/orbs HUD is removed from the
# render and (b) whether a synth-click at the run/spec orb still flips OPTION_RUN/SA_ATTACK (route-back).
#
# GREEN (predictions hold) = the orb instrument flips at baseline, draw2DMask does NOT remove the interface
# HUD, setHidden DOES, and setHidden kills click-through. The transparent-mode result is the DISCOVERY this
# run exists to settle (does opacity blank the HUD while staying clickable?). Read the [hud-iso] VERDICT line
# and the hud-*.png frames. Pair with hud-isolation-verdict.sh.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"; JAVAC="$JAVA_HOME/bin/javac"
SHADED="$REPO/runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar"
AWTSMOKE="../awtsmoke"
OUT="out-hud-isolation"
TOKENS="${TOKENS:-../tokens.json}"
RUN_SECONDS="${RUN_SECONDS:-200}"

if [ ! -f "$SHADED" ]; then
  echo "== building shaded client on JDK 21 =="
  (cd "$REPO" && ./gradlew :client:shadowJar --console=plain)
fi
if [ ! -f "$TOKENS" ]; then
  echo "!! $TOKENS missing — mint it first: ../fetch-shield-tokens.sh (throwaway account)" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "!! jq required to read $TOKENS" >&2; exit 1; }

# ---- Map tokens.json -> JX_* env (the official-launcher handoff the gamepack reads) ----
export JX_ACCESS_TOKEN="$(jq -r '.access_token // ""' "$TOKENS")"
export JX_REFRESH_TOKEN="$(jq -r '.refresh_token // ""' "$TOKENS")"
export JX_SESSION_ID="$(jq -r '.session_id // ""' "$TOKENS")"
export JX_CHARACTER_ID="$(jq -r '.chosen_account_id // ""' "$TOKENS")"
export JX_DISPLAY_NAME="$(jq -r '.chosen_display_name // ""' "$TOKENS")"
if [ -z "$JX_SESSION_ID" ] || [ -z "$JX_CHARACTER_ID" ]; then
  echo "!! tokens.json has no session_id/chosen_account_id — re-mint with fetch-shield-tokens.sh" >&2
  exit 1
fi
echo "== JX handoff: displayName='${JX_DISPLAY_NAME}' characterId=${JX_CHARACTER_ID} session=${JX_SESSION_ID:0:6}… =="

rm -rf "$OUT"; mkdir -p "$OUT/cap" "$OUT/hud"
echo "== compile DeviceHeadlessBoot + activation (against shaded+cacio) =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
echo "== launching real RuneLite under UnsafePoke CTC + autologin + HUD-isolation probe (no OS window, ${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Dheadless.captureTargetFrames=999 \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-25}" \
  -Drunelite.headless.capture.preLoginMax="${PRELOGIN_MAX:-20}" \
  -Drunelite.headless.resize="${RESIZE:-1269x720}" \
  -Drunelite.headless.autologin="${AUTOLOGIN:-true}" \
  -Drunelite.headless.autologin.eula="${AUTOLOGIN_EULA:-true}" \
  -Drunelite.headless.autologin.eula.point="${AUTOLOGIN_EULA_POINT:-302,312}" \
  -Drunelite.headless.autologin.eula.loginIndex="${AUTOLOGIN_EULA_INDEX:-12}" \
  -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}" \
  -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}" \
  -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}" \
  -Drunelite.hudisolation=true \
  -Drunelite.hudisolation.dir="$PWD/$OUT/hud" \
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
# Poll the log for the VERDICT line so we can bail early once the probe is done (saves the full clock).
for i in $(seq 1 "$((RUN_SECONDS + 15))"); do
  sleep 1
  if grep -q "\[hud-iso\] VERDICT" "$LOG" 2>/dev/null; then
    echo "== VERDICT observed at ~${i}s — stopping =="
    sleep 1
    break
  fi
  kill -0 "$PID" 2>/dev/null || break
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== login progression =="
grep -E "\[headless-capture\] (gameState|loginIndex)|\[headless-login\]" "$LOG" | tail -12 || echo "(none)"
echo "== [hud-iso] trail =="
grep -E "\[hud-iso\]" "$LOG" || echo "(no [hud-iso] lines — probe never ran; check $LOG)"
echo "== HUD mode frames =="; ls -la "$OUT/hud"/*.png 2>/dev/null || echo "(none)"
echo "== full log: $LOG =="
