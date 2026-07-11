#!/usr/bin/env bash
# gpu-tbo2d — 117HD blocker #1 (texture-buffer -> 2D integer-texture repack), RLHD-FAITHFUL verdict (md5-gated).
#
# Recomputes pass/fail in bash from the VERBATIM Simulator-pulled log and pins its md5, so a fabricated/edited verdict
# can't pass. GREEN = on native iOS GLES 3.0, RLHD's per-face GL_TEXTURE_BUFFER (`uniform isamplerBuffer textureFaces`,
# GL_RGB32I, ES 3.2-only) can be repacked into a 2D RGB32I texture and fetched via the downporter rewrite
# texelFetch(tex, ivec2((idx) % W, (idx) / W), 0) BYTE-EXACT, using RLHD's REAL fetch idiom (idx / idx+1 / idx+2 per
# face, with both .xyz and dynamic [vertex] component indexing, spans straddling row boundaries), for all 16000 faces,
# in BOTH the fragment and the VERTEX stage (the scene_vert/shadow_vert pathway), at a texel count (48000) that
# EXCEEDS GL_MAX_TEXTURE_SIZE (so a 1D layout is impossible). RGB32I being sampleable means ZERO host data transform
# (the buffer bytes upload directly as a 2D image). Integer 2D textures + texelFetch + vertex texture fetch are ES 3.0
# CORE -> a software-renderer pass is high-confidence for the device GPU (PHASE A format support is the one device-
# checkable item, reported explicitly).
#
# Usage: tbo2d-verdict.sh [log] [expected_md5]
set -euo pipefail
cd "$(dirname "$0")"

LOG="${1:-evidence/gpu-tbo2d-sim-verdict.log}"
EXPECT_MD5="${2:-2ffc9a6343358b821a6d8de40114b77e}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }
ACTUAL_MD5="$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | awk '{print $1}')"

ES300=$(grep -q "GL_SLVERSION = OpenGL ES GLSL ES 3.00" "$LOG" && echo YES || echo NO)
TWOD_REQ=$(grep -q "2D REQUIRED" "$LOG" && echo YES || echo NO)
RGB32I=$(grep -qF "[tbo] A_RGB32I_SAMPLEABLE = YES" "$LOG" && echo YES || echo NO)
REPACK_FMT=$(grep -oE "REPACK_FORMAT = (RGB32I|RGBA32I)" "$LOG" | head -1 | awk '{print $3}')
PFRAG=$(grep -qF "[tbo] PROGRAM P_FRAG = OK" "$LOG" && echo OK || echo MISSING)
PVERT=$(grep -qF "[tbo] PROGRAM P_VERT = OK" "$LOG" && echo OK || echo MISSING)
B_EXACT=$(grep -qF "[tbo] B_FRAG_EXACT = YES" "$LOG" && echo YES || echo NO)
C_EXACT=$(grep -qF "[tbo] C_VERT_EXACT = YES" "$LOG" && echo YES || echo NO)
VERDICT=$(grep -qF "[tbo] VERDICT tbo2d_repack_exact = YES" "$LOG" && echo YES || echo NO)
NO_FAIL=$(grep -qE "= FAIL|-> NO-GO|INCOMPLETE -> SKIP|EXCEPTION|FAILED" "$LOG" && echo DIRTY || echo CLEAN)

echo "log                       : $LOG"
echo "md5 actual                : $ACTUAL_MD5"
echo "md5 expected              : $EXPECT_MD5"
echo "es300 driver              : $ES300"
echo "2D required (>max 1D)      : $TWOD_REQ"
echo "RGB32I sampleable (real fmt): $RGB32I"
echo "repack format chosen       : $REPACK_FMT"
echo "programs (frag/vert)       : $PFRAG/$PVERT"
echo "B fragment byte-exact      : $B_EXACT"
echo "C vertex byte-exact        : $C_EXACT"
echo "VERDICT line               : $VERDICT"
echo "no-FAIL/skip lines         : $NO_FAIL"

TUPLE="$ES300/$TWOD_REQ/$RGB32I/$REPACK_FMT/$PFRAG/$PVERT/$B_EXACT/$C_EXACT/$VERDICT/$NO_FAIL"
EXPECT="YES/YES/YES/RGB32I/OK/OK/YES/YES/YES/CLEAN"

if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && [ "$TUPLE" = "$EXPECT" ]; then
	echo "MEGAVERDICT = TBO2D_RLHD_REPACK_EXACT_GREEN_AS_EXPECTED  (RGB32I native, zero host transform; frag+vert byte-exact)"
	exit 0
else
	echo "MEGAVERDICT = TBO2D_NOT_GREEN (tuple=$TUPLE md5_match=$([ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && echo yes || echo no))"
	exit 2
fi
