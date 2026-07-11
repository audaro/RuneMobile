#!/usr/bin/env bash
# Mobile-UX audit OQ1 / Finding #9 — "Sticky Shift" feasibility spike (DESKTOP de-risk).
#
# Same device-shaped boot + autologin as the other A-probes, with ShiftFeedSpike enabled
# (-Drunelite.shiftfeed=true). On a logged-in player it reads isKeyPressed(KC_SHIFT), posts a synthetic held
# KEY_PRESSED VK_SHIFT (no release), re-reads, then (fallback) re-posts each frame + re-reads, then releases +
# re-reads. GREEN = downOnce||downRepeat => synthetic shift reaches the engine backing state => ship native
# sticky-Shift via a JavaBridge.setShiftHeld bridge. RED => infeasible without forking (skip Findings #9/#10/#16).
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
OUT="out-shiftfeed"
TOKENS="${TOKENS:-../tokens.json}"
RUN_SECONDS="${RUN_SECONDS:-200}"

if [ ! -f "$SHADED" ]; then (cd "$REPO" && ./gradlew :client:shadowJar --console=plain); fi
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
echo "== launching real RuneLite under UnsafePoke CTC + autologin + shiftfeed spike (${RUN_SECONDS}s) =="
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
  -Drunelite.shiftfeed=true \
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
  if grep -q "\[shiftfeed\] SHIFTFEED" "$LOG" 2>/dev/null; then
    echo "== SHIFTFEED verdict observed at ~${i}s — stopping =="
    sleep 1
    break
  fi
  kill -0 "$PID" 2>/dev/null || break
done
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== login =="; grep -E "gameState .* LOGGED_IN" "$LOG" | tail -1 || echo "(none)"
echo "== [shiftfeed] =="; grep -E "\[shiftfeed\]" "$LOG" || echo "(no [shiftfeed] lines — check $LOG)"
echo "== full log: $LOG =="
