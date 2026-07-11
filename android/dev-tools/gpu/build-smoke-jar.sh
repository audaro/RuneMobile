#!/usr/bin/env bash
# AG1a — build the facade-only smoke jar: the device facade (org.lwjgl.* + net.runelite.rlawt.AWTContext with
# native methods) + RouteCSmoke, and NOTHING else (no real LWJGL, no shaded jar). The host boots this jar ALONE
# when -Drunelite.routec.smoke=true, so the facade is provably the only provider; jvm_bootstrap RegisterNatives
# the GL bridge (librlawt.so) before it runs. Output -> android/app/src/debug/assets/jvm/gpu-smoke.jar (the DEBUG
# source set — SLM-JAR-05: this dev smoke path is BuildConfig.DEBUG-gated, so the jar must NOT ship in release).
# Bundled into the debug APK + unpacked to filesDir/jvm by AssetInstaller. Regenerate with this.
set -euo pipefail
cd "$(dirname "$0")"   # android/dev-tools/gpu

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$JAVA_HOME/bin/jar"
OUT="out"
DEST="../../app/src/debug/assets/jvm/gpu-smoke.jar"

[ -x "$JAVAC" ] || { echo "!! javac not found at $JAVAC (set JAVA_HOME)" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
# --release 11: the embedded VM is 21, but 11 bytecode keeps the facade portable + matches the iOS L1 jar.
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" --release 11 -d "$OUT" $(find facade-src -name '*.java') RouteCSmoke.java
N=$(find "$OUT" -name '*.class' | wc -l | tr -d ' ')
mkdir -p "$(dirname "$DEST")"
"$JAR" --create --file "$DEST" -C "$OUT" .
echo "wrote $DEST ($N classes)"
"$JAR" --list --file "$DEST" | grep -E '\.class$' | sort | head -40
