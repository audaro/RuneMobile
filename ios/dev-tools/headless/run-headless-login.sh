#!/usr/bin/env bash
# Gate 1c-ii experiment 1 (native toolkit) — boot real RuneLite headless with the throwaway Jagex account,
# trying to reach LOGGED_IN and capture an in-game frame with a real plugin overlay composited.
#
# Maps ios/dev-tools/tokens.json → the JX_* environment variables the OSRS gamepack reads when "launched
# from the Jagex launcher", then launches RuneLiteHeadless exactly like run-headless.sh. The decisive
# observation is the gameState progression in the log: does the JX_* handoff carry the client to
# LOGGED_IN on its own, or stall at the authenticated login screen (which would mean a synthesized click
# is needed — a Phase-4 input-injection fork).
#
# A tiny native window appears here (bring-up crutch). The no-OS-window proof is run-headless-login-cacio.sh.
# Runs for $RUN_SECONDS then kills the client. Frames + log land in out/.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repo root

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"
JAR="runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
TOKENS="${TOKENS:-ios/dev-tools/tokens.json}"
OUT="ios/dev-tools/headless/out-login"
RUN_SECONDS="${RUN_SECONDS:-120}"   # login + cache fetch + world load takes longer than the login-screen run

if [ ! -f "$JAR" ]; then
  echo "== building shaded client on JDK 21 =="
  ./gradlew :client:assemble --console=plain
fi
if [ ! -f "$TOKENS" ]; then
  echo "!! $TOKENS missing — mint it first: ios/dev-tools/fetch-shield-tokens.sh (throwaway account)" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "!! jq required to read $TOKENS" >&2; exit 1; }

# ---- Map tokens.json → JX_* env vars (the official-launcher handoff the gamepack reads) ----
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

mkdir -p "$OUT"
rm -f "$OUT"/frame-*.png
LOG="$OUT/run-native-login.log"

echo "== launching headless RuneLite (native toolkit, safe-mode, Jagex login, ${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Drunelite.headless.capture.dir="$OUT" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-50}" \
  -Drunelite.headless.autologin="${AUTOLOGIN:-true}" \
  -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}" \
  -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}" \
  -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}" \
  --add-exports java.desktop/com.apple.eawt=ALL-UNNAMED \
  --add-opens   java.base/java.lang.reflect=ALL-UNNAMED \
  -cp "$JAR" net.runelite.client.headless.RuneLiteHeadless --safe-mode "$@" \
  > "$LOG" 2>&1 &
PID=$!
sleep "$RUN_SECONDS"
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
set -e

echo "== gameState progression =="
grep -E "\[headless-capture\] gameState" "$LOG" || echo "(no state transitions logged — check $LOG)"
echo "== headless-capture summary =="
grep -E "\[headless\]|\[headless-capture\]|\[headless-login\]|LOGGED_IN|LOGGING_IN|injected-client|Cache is ready|ERROR|Exception" "$LOG" | tail -40 || true
echo "== frames written (state-tagged) =="
ls -la "$OUT"/frame-*.png 2>/dev/null || echo "(none)"
echo "== full log: $LOG =="
