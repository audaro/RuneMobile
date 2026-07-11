#!/usr/bin/env bash
# Phase B0.3 / Z0.4 — facade-delta scan. Static source of truth for the RouteCBridge.m native work.
#
# Disassembles the staged RLHD jar (rs117/** classes, facade-backed) and extracts EVERY method RLHD actually
# invokes on a facade class (org/lwjgl/{opengl,opencl,system}, net/runelite/rlawt/AWTContext) as
# `owner.method:descriptor`. Subtracts the base-gpu serviced set (gpu-routec/used-descriptors.txt, the 100 calls
# the base Route C bridge already forwards) to yield THE DELTA — the calls the iOS bridge must add for RLHD.
#
# Output: used-descriptors-rlhd.txt (full RLHD facade surface) + facade-delta.txt (delta vs base). Deterministic.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../../.. && pwd)"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVAP="$JAVA_HOME/bin/javap"
JAR="${JAR:-$ROOT/ios/app/jvm-resources/client-rlhd.jar}"
BASE="${BASE:-../gpu-routec/used-descriptors.txt}"

[ -f "$JAR" ]  || { echo "!! staged rlhd jar missing: $JAR (run ./stage-ios-zone-jar.sh)" >&2; exit 1; }
[ -f "$BASE" ] || { echo "!! base used-descriptors missing: $BASE" >&2; exit 1; }

WORK="$(pwd)/scan-work"; rm -rf "$WORK"; mkdir -p "$WORK"
(cd "$WORK" && unzip -q "$JAR" 'rs117/*')

# javap -v dumps the constant pool; facade method references appear as `// Methodref … owner.name:desc` and
# `// InterfaceMethodref …`. Pull owner+name+desc for facade owners only, normalize, sort -u.
find "$WORK/rs117" -name '*.class' -print0 \
  | xargs -0 "$JAVAP" -v -p 2>/dev/null \
  | grep -E '(Methodref|InterfaceMethodref)' \
  | grep -oE '(org/lwjgl/(opengl|opencl|system)|net/runelite/rlawt/AWTContext)[A-Za-z0-9/$]*\.[A-Za-z0-9_<>$]+:\([^)]*\)[A-Za-z0-9/;\[]+' \
  | sort -u > "$WORK/rlhd-used.txt"

cp "$WORK/rlhd-used.txt" used-descriptors-rlhd.txt

# Delta = RLHD-used minus base-serviced (both as owner.name:desc).
comm -23 used-descriptors-rlhd.txt <(sort -u "$BASE") > facade-delta.txt

RLHD_N=$(wc -l < used-descriptors-rlhd.txt | tr -d ' ')
DELTA_N=$(wc -l < facade-delta.txt | tr -d ' ')

# Bucket the delta for the bridge spec: GL (forwardable) vs OpenCL (stub-only, no CL context on the zone path)
# vs system/rlawt (host/marshalling).
GL_N=$(grep -cE 'org/lwjgl/opengl/' facade-delta.txt || true)
CL_N=$(grep -cE 'org/lwjgl/opencl/' facade-delta.txt || true)
SYS_N=$(grep -cE 'org/lwjgl/system/|net/runelite/rlawt/' facade-delta.txt || true)

echo "rlhd facade calls    : $RLHD_N   (used-descriptors-rlhd.txt)"
echo "base serviced calls  : $(sort -u "$BASE" | wc -l | tr -d ' ')   ($BASE)"
echo "DELTA (rlhd - base)  : $DELTA_N   (facade-delta.txt)"
echo "  ├─ opengl (forward): $GL_N"
echo "  ├─ opencl (stub)   : $CL_N"
echo "  └─ system/rlawt    : $SYS_N"
echo "VERDICT = ZONE_FACADE_DELTA_SCANNED"
