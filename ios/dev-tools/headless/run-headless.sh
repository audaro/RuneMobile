#!/usr/bin/env bash
# Gate 1c experiment 1 — boot real RuneLite with the window-less HeadlessClientUI on the desktop
# NATIVE toolkit (the audit-sanctioned bring-up crutch), GPU off (--safe-mode), capture the engine
# buffer to PNG. Settles the kill risk: does the OSRS engine drive Hooks.draw with a non-null Graphics
# when ClientUI builds no real desktop window? A tiny native window appears here; the no-OS-window
# proof is run-headless-cacio.sh.
#
# Runs for $RUN_SECONDS then kills the client. Frames + log land in out/.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repo root

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"
JAR="runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
OUT="ios/dev-tools/headless/out"
RUN_SECONDS="${RUN_SECONDS:-45}"

if [ ! -f "$JAR" ]; then
  echo "== building shaded client on JDK 21 =="
  ./gradlew :client:assemble --console=plain
fi

mkdir -p "$OUT"
rm -f "$OUT"/frame-*.png
LOG="$OUT/run-native.log"

echo "== launching headless RuneLite (native toolkit, safe-mode, ${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Drunelite.headless.capture.dir="$OUT" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-50}" \
  --add-exports java.desktop/com.apple.eawt=ALL-UNNAMED \
  --add-opens   java.base/java.lang.reflect=ALL-UNNAMED \
  -cp "$JAR" net.runelite.client.headless.RuneLiteHeadless --safe-mode "$@" \
  > "$LOG" 2>&1 &
PID=$!
sleep "$RUN_SECONDS"
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
set -e

echo "== headless-capture summary =="
grep -E "\[headless\]|\[headless-capture\]|LOGIN_SCREEN|Showing frame|injected-client|Cache is ready|ERROR|Exception" "$LOG" | tail -40 || true
echo "== frames written =="
ls -la "$OUT"/frame-*.png 2>/dev/null || echo "(none)"
echo "== full log: $LOG =="
