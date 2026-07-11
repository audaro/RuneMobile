#!/usr/bin/env bash
# Route C — build the L1 kill-test jar: the device facade (facade-native: org.lwjgl.* + rlawt.AWTContext with
# native methods) + RouteCL1Probe, and NOTHING else (no LWJGL, no shaded jar). The shell puts this jar ALONE on
# the L1 classpath, so the facade is provably the only provider and the probe isolates the JNI bridge.
# Output -> ios/app/jvm-resources/routec-l1.jar (gitignored build artifact, bundled into the .app).
set -euo pipefail
cd "$(dirname "$0")"   # ios/dev-tools/gpu-routec/l1

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$JAVA_HOME/bin/jar"
FACADE="../facade-native"
OUT="out"
DEST="../../../app/jvm-resources/routec-l1.jar"

[ -x "$JAVAC" ] || { echo "!! javac not found at $JAVAC (set JAVA_HOME)" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" --release 11 -d "$OUT" $(find "$FACADE" -name '*.java') RouteCL1Probe.java
CLASSES=$(find "$OUT" -name '*.class' | wc -l | tr -d ' ')
"$JAR" --create --file "$DEST" -C "$OUT" .

echo "wrote $DEST ($CLASSES classes)"
"$JAR" --list --file "$DEST" | sort
