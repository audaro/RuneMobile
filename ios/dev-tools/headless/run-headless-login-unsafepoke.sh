#!/usr/bin/env bash
# Phase 4 sub-goal A DESKTOP de-risk — the closest desktop mirror of the device login run.
#
# Combines two proven harnesses: the DEVICE-shaped activation path (UnsafePokeActivation.activate() +
# DeviceHeadlessBoot, NO byte-buddy / NO CacioExtension — exactly what JVMLauncher.m runs) from
# run-headless-unsafepoke.sh, PLUS the JX_* launcher handoff + HeadlessLogin two-stage autologin from
# run-headless-login.sh. This validates the Java login logic on desktop OpenJDK 21 (the W2 rule) before
# the device round-trip; the device then validates the device-specific delta (the EULA gate at
# loginIndex=12 and whether the on-device CTC EventQueue accepts the posted clicks).
#
# NOTE: desktop typically goes straight to the welcome screen (loginIndex=10) — the first-run EULA dialog
# is already accepted here — so the EULA stage is inert and only the Play Now click fires. That is the
# point: prove the two-stage machine still drives LOGIN_SCREEN -> LOGGING_IN -> LOADING -> LOGGED_IN and
# captures a frame-LOGGED_IN-*.png. The EULA-Accept click itself is device-only-validated.
#
# GREEN here = gameState reaches LOGGED_IN and a frame-LOGGED_IN-*.png lands in out-login-unsafepoke/cap/.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"; JAVAC="$JAVA_HOME/bin/javac"
SHADED="$REPO/runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar"   # NO byte-buddy — UnsafePoke needs none
AWTSMOKE="../awtsmoke"
OUT="out-login-unsafepoke"
TOKENS="${TOKENS:-../tokens.json}"
RUN_SECONDS="${RUN_SECONDS:-180}"   # login + cache fetch + world load takes longer than the login-screen run

if [ ! -f "$SHADED" ]; then
  echo "== building shaded client on JDK 21 =="
  (cd "$REPO" && ./gradlew :client:assemble --console=plain)
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
  echo "!! tokens.json has no session_id/chosen_account_id — Stage A of fetch-shield-tokens.sh must succeed" >&2
  exit 1
fi
echo "== JX handoff: displayName='${JX_DISPLAY_NAME}' characterId=${JX_CHARACTER_ID} session=${JX_SESSION_ID:0:6}… access=${JX_ACCESS_TOKEN:+set}${JX_ACCESS_TOKEN:-empty} =="

rm -rf "$OUT"; mkdir -p "$OUT/cap"
echo "== compile DeviceHeadlessBoot + activation (against shaded+cacio) =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
echo "== launching real RuneLite under UnsafePoke CTC with two-stage autologin (no OS window, ${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Dheadless.captureTargetFrames=999 \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-10}" \
  -Drunelite.headless.capture.preLoginMax="${PRELOGIN_MAX:-40}" \
  -Drunelite.headless.autologin="${AUTOLOGIN:-true}" \
  -Drunelite.headless.autologin.eula="${AUTOLOGIN_EULA:-true}" \
  -Drunelite.headless.autologin.eula.point="${AUTOLOGIN_EULA_POINT:-302,312}" \
  -Drunelite.headless.autologin.eula.loginIndex="${AUTOLOGIN_EULA_INDEX:-12}" \
  -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}" \
  -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}" \
  -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}" \
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
sleep "$((RUN_SECONDS + 15))"
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== gameState + loginIndex progression =="
grep -E "\[headless-capture\] (gameState|loginIndex)|\[headless-login\]" "$LOG" || echo "(no transitions logged — check $LOG)"
echo "== summary =="
grep -E '\[boot\]|\[headless\]|injected-client|LOGGED_IN|LOGGING_IN|ERROR|Exception|UnsatisfiedLink' "$LOG" | tail -30 || true
echo "== frames (state-tagged) =="; ls -la "$OUT/cap"/*.png 2>/dev/null || echo "(none)"
echo "== full log: $LOG =="
