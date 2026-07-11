#!/usr/bin/env bash
# W1 P3 §6.2 DESKTOP de-risk — boot real RuneLite headless under CACIO CTC activated by the
# DEVICE-shaped path (UnsafePokeActivation.activate(), NO byte-buddy / NO CacioExtension / NO agent),
# not the JUnit CacioExtension that run-headless-cacio.sh uses. Proves the activation SWAP works with
# the real client before the device build (the W2 "develop on desktop first" rule). Entry class:
# ios/dev-tools/awtsmoke/DeviceHeadlessBoot (the same class that is the device entrypoint).
#
# GREEN here = toolkit/graphicsenv = CTC, HeadlessClientUI realizes its frame, engine drives
# Hooks.draw with nullGraphics=0, and frame-LOGIN_SCREEN-*.png (the live-OSRS login screen) land in
# out-unsafepoke/. Then the device build is just: bundle the shaded jar + set -Xmx + capture dir.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVA="$JAVA_HOME/bin/java"; JAVAC="$JAVA_HOME/bin/javac"
SHADED="$REPO/runelite-client/build/libs/client-1.12.28-SNAPSHOT-shaded.jar"
CACIOLIB="../cacio-smoke/lib"
CACIO="$CACIOLIB/cacio-tta-1.18.jar:$CACIOLIB/cacio-shared-1.18.jar"   # NO byte-buddy — UnsafePoke needs none
AWTSMOKE="../awtsmoke"
OUT="out-unsafepoke"
RUN_SECONDS="${RUN_SECONDS:-40}"

if [ ! -f "$SHADED" ]; then
  echo "== building shaded client on JDK 21 =="
  (cd "$REPO" && ./gradlew :client:assemble --console=plain)
fi

rm -rf "$OUT"; mkdir -p "$OUT/cap"
echo "== compile DeviceHeadlessBoot + activation (against shaded+cacio) =="
"$JAVAC" -cp "$SHADED:$CACIO" -d "$OUT" \
  "$AWTSMOKE/AwtActivation.java" "$AWTSMOKE/UnsafePokeActivation.java" "$AWTSMOKE/DeviceHeadlessBoot.java"

LOG="$OUT/run.log"
echo "== launching real RuneLite under UnsafePoke CTC (no OS window, safe-mode, ${RUN_SECONDS}s) =="
set +e
"$JAVA" \
  -Dheadless.runSeconds="$RUN_SECONDS" \
  -Drunelite.headless.capture.dir="$PWD/$OUT/cap" \
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
  -cp "$OUT:$CACIO:$SHADED" DeviceHeadlessBoot > "$LOG" 2>&1 &
PID=$!
sleep "$((RUN_SECONDS + 15))"
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
set -e

echo "== summary =="
grep -E '\[boot\]|\[headless\]|\[headless-capture\]|injected-client|ERROR|Exception|UnsatisfiedLink' "$LOG" | tail -25 || true
echo "== frames =="; ls -la "$OUT/cap"/*.png 2>/dev/null || echo "(none)"
