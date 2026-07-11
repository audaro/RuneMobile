#!/usr/bin/env bash
# Phase A-1 bridge census (static half) — desktop runner.
#
# Compiles + runs BridgeCensus against the Android-staged shaded jar on desktop OpenJDK 21 (no device, no
# emulator). Proves every bridge method the A0-A8 mainline depends on resolves in the embedded jar, and emits
# an md5-gated sentinel so a re-run after any jar update is a one-line GREEN/RED comparison — the Android analog
# of the iOS md5-gated-log discipline.
#
# Usage: run-census-desktop.sh [path-to-shaded-jar]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

JAVAC="${JAVAC:-/opt/homebrew/opt/openjdk@21/bin/javac}"
JAVA="${JAVA:-/opt/homebrew/opt/openjdk@21/bin/java}"
# Default to the freshly-built shaded client jar, globbing the version so a bump needs no edit here. Prefer the
# shadowJar output under build/libs (the canonical source); fall back to the iOS-staged copy. The Android APK no
# longer bundles shaded (SLM-JAR-01 — not on its boot classpath), so the old android-assets default is gone.
if [ -n "${1:-}" ]; then
  JAR="$1"
else
  shopt -s nullglob
  cands=("$ROOT"/runelite-client/build/libs/client-*-shaded.jar "$ROOT"/ios/app/jvm-resources/client-*-shaded.jar)
  shopt -u nullglob
  JAR="${cands[0]:-}"
fi

[ -x "$JAVAC" ] || { echo "javac not found at $JAVAC (set JAVAC=...)" >&2; exit 2; }
[ -f "$JAR" ]   || { echo "shaded jar not found at $JAR" >&2; exit 2; }

OUT="$HERE/out"
mkdir -p "$OUT"

"$JAVAC" -d "$OUT" "$HERE/BridgeCensus.java"

# initialize=false in the probe means no AWT/CACIO activation is needed; the jar is on the classpath (unnamed
# module) so no --add-exports either.
RAW="$("$JAVA" -cp "$OUT:$JAR" BridgeCensus)"
echo "$RAW"

# Deterministic sentinel: the sorted RESOLVED/MISSING block (the probe already sorts it) drives the md5.
BODY="$(printf '%s\n' "$RAW" | grep -E '^(RESOLVED|MISSING )' | LC_ALL=C sort)"
SUMMARY="$(printf '%s\n' "$RAW" | grep '^BRIDGE_CENSUS' || true)"
MD5="$(printf '%s' "$BODY" | md5)"

echo "----"
echo "jar=$JAR"
echo "$SUMMARY"
echo "census_md5=$MD5"

if printf '%s' "$SUMMARY" | grep -q 'verdict=GREEN'; then
	echo "ANDROID_BRIDGE_CENSUS_GREEN md5=$MD5"
else
	echo "ANDROID_BRIDGE_CENSUS_RED"
	exit 1
fi
