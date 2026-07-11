#!/usr/bin/env bash
# Gate 1c experiment 2 — boot real RuneLite with HeadlessClientUI under the CACIO CTC toolkit (the
# offscreen virtual display, NO OS window) — the honest iOS proxy. GPU off (--safe-mode). Captures the
# engine buffer to PNG. Proves the engine drives Hooks.draw with a non-null Graphics even when the
# canvas is realized to a CACIO peer rather than a native window.
#
# Activation uses the same proven path as the Gate 1b overlay smoke: CacioExtension via the JUnit
# console launcher installs the CTC toolkit before AWT init (a bare programmatic inject from main fails
# with a class-redefinition schema error). Reuses the cacio jars in ../cacio-smoke/lib.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$REPO/runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar:$CACIOLIB/byte-buddy-1.14.11.jar:$CACIOLIB/byte-buddy-agent-1.14.11.jar"
JUNIT="$CACIOLIB/junit-platform-console-standalone-1.10.2.jar"
OUT="out"
RUN_SECONDS="${RUN_SECONDS:-45}"

if [ ! -f "$JAR" ]; then
  echo "== building shaded client on JDK 21 =="
  (cd "$REPO" && ./gradlew :client:assemble --console=plain)
fi
if [ ! -f "$CACIOLIB/cacio-tta-1.18.jar" ] || [ ! -f "$JUNIT" ]; then
  echo "!! cacio/junit jars missing in $CACIOLIB — see ../cacio-smoke/README.md to fetch them" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -f "$OUT"/frame-*.png

echo "== compile CacioHeadlessTest =="
"$JAVAC" -cp "$CACIO:$JUNIT:$JAR" -d "$OUT" CacioHeadlessTest.java

LOG="$OUT/run-cacio.log"
echo "== launching headless RuneLite under CACIO CTC (no OS window, safe-mode, ${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Djdk.attach.allowAttachSelf=true \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Drunelite.headless.capture.dir="$PWD/$OUT" \
  -Drunelite.headless.capture.interval="${CAPTURE_INTERVAL:-50}" \
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

echo "== cacio + headless-capture summary =="
grep -E "\[cacio\]|\[headless\]|\[headless-capture\]|injected-client|Cache is ready|ERROR|Exception|redefinition" "$LOG" | tail -45 || true
echo "== frames written =="
ls -la "$OUT"/frame-*.png 2>/dev/null || echo "(none)"
echo "== full log: ios/dev-tools/headless/$LOG =="
