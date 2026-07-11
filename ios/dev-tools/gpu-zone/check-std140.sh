#!/usr/bin/env bash
# B0.5 materials subsystem — host gate: the GLSL texelFetch decode map (ios-overrides/uniforms/materials.glsl)
# matches the real UniformBuffer std140 layout engine. Needs stage-zone-work/ from a prior ./stage-ios-zone-jar.sh
# run (it compiles the verifier against the ACTUAL staged rlhd classes, so layout drift on an RLHD rev bump is
# caught here, not on device). Verdict: STD140_DECODE_MAP_MATCHES.
set -euo pipefail
cd "$(dirname "$0")"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
WORK="$(pwd)/stage-zone-work"
[ -d "$WORK/rlhd_out" ] || { echo "!! stage-zone-work/rlhd_out missing — run ./stage-ios-zone-jar.sh first" >&2; exit 1; }

OUT="$WORK/verify-std140"
mkdir -p "$OUT"
"$JAVA_HOME/bin/javac" -nowarn -cp "$WORK/rlhd_out:$WORK/cp:$WORK/facade_out" -d "$OUT" verify-std140/VerifyStd140.java
"$JAVA_HOME/bin/java" -cp "$OUT:$WORK/rlhd_out:$WORK/cp:$WORK/facade_out" VerifyStd140
