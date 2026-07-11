#!/usr/bin/env bash
# Gate 1c-ii experiment 2 (CACIO CTC, NO OS window) — boot real RuneLite headless with the throwaway
# Jagex account under the offscreen virtual display, trying to reach LOGGED_IN and capture an in-game
# frame with a real plugin overlay composited. This is the honest iOS-shaped proof of the overlay-
# compositing long pole.
#
# Maps ios/dev-tools/tokens.json → the JX_* env vars the gamepack reads, then activates CACIO exactly
# like run-headless-cacio.sh (CacioExtension via the JUnit console launcher installs the CTC toolkit
# before AWT init). The env vars are inherited by the JVM, so the gamepack sees the launcher handoff.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$REPO/runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
TOKENS="${TOKENS:-$REPO/ios/dev-tools/tokens.json}"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar:$CACIOLIB/byte-buddy-1.14.11.jar:$CACIOLIB/byte-buddy-agent-1.14.11.jar"
JUNIT="$CACIOLIB/junit-platform-console-standalone-1.10.2.jar"
OUT="out-login"
RUN_SECONDS="${RUN_SECONDS:-120}"

if [ ! -f "$JAR" ]; then
  echo "== building shaded client on JDK 21 =="
  (cd "$REPO" && ./gradlew :client:assemble --console=plain)
fi
if [ ! -f "$CACIOLIB/cacio-tta-1.18.jar" ] || [ ! -f "$JUNIT" ]; then
  echo "!! cacio/junit jars missing in $CACIOLIB — see ../cacio-smoke/README.md to fetch them" >&2
  exit 1
fi
if [ ! -f "$TOKENS" ]; then
  echo "!! $TOKENS missing — mint it first: ios/dev-tools/fetch-shield-tokens.sh (throwaway account)" >&2
  exit 1
fi
command -v jq >/dev/null || { echo "!! jq required to read $TOKENS" >&2; exit 1; }

# ---- Map tokens.json → JX_* env vars (inherited by the JVM the gamepack runs in) ----
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

echo "== compile CacioHeadlessTest =="
"$JAVAC" -cp "$CACIO:$JUNIT:$JAR" -d "$OUT" CacioHeadlessTest.java

LOG="$OUT/run-cacio-login.log"
echo "== launching headless RuneLite under CACIO CTC (no OS window, safe-mode, Jagex login, ${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Djdk.attach.allowAttachSelf=true \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Drunelite.headless.capture.dir="$PWD/$OUT" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-50}" \
  -Drunelite.headless.autologin="${AUTOLOGIN:-true}" \
  -Drunelite.headless.autologin.point="${AUTOLOGIN_POINT:-382,248}" \
  -Drunelite.headless.autologin.world="${AUTOLOGIN_WORLD:-301}" \
  -Drunelite.headless.autologin.worldAddress="${AUTOLOGIN_WORLD_ADDRESS:-oldschool1.runescape.com}" \
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
  -jar "$JUNIT" \
  -cp "$OUT:$CACIO:$JAR" \
  --select-class=CacioHeadlessTest \
  --details=tree \
  > "$LOG" 2>&1 &
PID=$!
sleep "$((RUN_SECONDS + 15))"
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
set -e

echo "== gameState progression =="
grep -E "\[headless-capture\] gameState" "$LOG" || echo "(no state transitions logged — check $LOG)"
echo "== cacio + headless-capture summary =="
grep -E "\[cacio\]|\[headless\]|\[headless-capture\]|\[headless-login\]|LOGGED_IN|LOGGING_IN|injected-client|Cache is ready|ERROR|Exception|redefinition" "$LOG" | tail -45 || true
echo "== frames written (state-tagged) =="
ls -la "$OUT"/frame-*.png 2>/dev/null || echo "(none)"
echo "== full log: ios/dev-tools/headless/$LOG =="
