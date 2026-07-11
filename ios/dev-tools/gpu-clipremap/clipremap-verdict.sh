#!/usr/bin/env bash
# gpu-clipremap — 3-way reverse-Z depth A/B verdict (md5-gated, anti-fabrication).
#
# Recomputes the result in bash from the VERBATIM Simulator-pulled log and pins its md5, so a fabricated/edited
# verdict can't pass. This harness does NOT have a single GREEN/RED outcome — it MEASURES which of three reverse-Z
# depth strategies fixes the river z-fight on native EAGL GLES (no glClipControl), head-to-head on identical geometry:
#   baseline  — fixed-function window_z=(NDC.z+1)/2 (the z-fight).
#   fragdepth — gl_FragDepth = NDC.z (full precision; DISABLES Apple TBDR early-Z — device-only perf cost).
#   clipremap — vertex gl_Position.z = 2*clip.z - clip.w (keeps early-Z; precision capped by the (z+1)/2 cancellation).
#
# MEASURED CONCLUSION (this evidence): fragdepth recovers 64x float32 precision and cuts the FAR z-fight ~15x;
# the early-Z-preserving clipremap recovers only ~4x precision (NOT full) — so it is a weak mitigation, not a fix.
# All three preserve the plugin's PER-VERTEX coplanar bias layering. => On EAGL, gl_FragDepth is the only full
# depth fix and its early-Z perf cost must be measured on device; otherwise ANGLE clip_control (which needs the
# wedge bug fixed) is the clean route. Phase 2 magnitudes are SOFTWARE-renderer-indicative; Phase 1 (float32) is
# the device-relevant precision proof (the device depth buffer is a confirmed true 32F).
#
# Usage: clipremap-verdict.sh [log] [expected_md5]
set -euo pipefail
cd "$(dirname "$0")"

LOG="${1:-evidence/gpu-clipremap-sim-verdict.log}"
EXPECT_MD5="${2:-5df5089531f8e4340100978e65591955}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }

ACTUAL_MD5="$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | awk '{print $1}')"

ES300=$(grep -q "GL_SLVERSION = OpenGL ES GLSL ES 3.00" "$LOG" && echo YES || echo NO)
PB=$(grep -qF "[cr] PROGRAM P_BASELINE = OK"  "$LOG" && echo OK || echo MISSING)
PF=$(grep -qF "[cr] PROGRAM P_FRAGDEPTH = OK" "$LOG" && echo OK || echo MISSING)
PC=$(grep -qF "[cr] PROGRAM P_CLIPREMAP = OK" "$LOG" && echo OK || echo MISSING)
P1_FRAG_FINER=$(grep -qF "[cr] RESULT P1_FRAGDEPTH_FINER = YES"   "$LOG" && echo YES || echo NO)
P1_CLIP_RECOV=$(grep -qF "[cr] RESULT P1_CLIPREMAP_RECOVERS = YES" "$LOG" && echo YES || echo NO)
P2_FRAG_CLEAN=$(grep -qF "[cr] RESULT P2_FRAGDEPTH_CLEANER = YES" "$LOG" && echo YES || echo NO)
P3_LAYER=$(grep -qF "[cr] RESULT P3_LAYERING_ALL = YES" "$LOG" && echo YES || echo NO)
CONCLUSION=$(grep -oE "CONCLUSION = [A-Z_]+" "$LOG" | head -1 | awk '{print $3}')
NO_FAIL=$(grep -qE "= FAIL|-> NO-GO|INCOMPLETE -> SKIP|EXCEPTION" "$LOG" && echo DIRTY || echo CLEAN)

echo "log                       : $LOG"
echo "md5 actual                : $ACTUAL_MD5"
echo "md5 expected              : $EXPECT_MD5"
echo "es300 driver              : $ES300"
echo "programs (base/frag/clip) : $PB/$PF/$PC"
echo "P1 fragdepth finer        : $P1_FRAG_FINER"
echo "P1 clipremap recovers     : $P1_CLIP_RECOV  (measured NO: ~4x precision, not full)"
echo "P2 fragdepth cleaner      : $P2_FRAG_CLEAN"
echo "P3 per-vertex layering    : $P3_LAYER"
echo "CONCLUSION                : $CONCLUSION"
echo "no-FAIL/skip lines        : $NO_FAIL"

TUPLE="$ES300/$PB/$PF/$PC/$P1_FRAG_FINER/$P1_CLIP_RECOV/$P2_FRAG_CLEAN/$P3_LAYER/$CONCLUSION/$NO_FAIL"
EXPECT="YES/OK/OK/OK/YES/NO/YES/YES/FRAGDEPTH_ONLY/CLEAN"

if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && [ "$TUPLE" = "$EXPECT" ]; then
	echo "MEGAVERDICT = CLIPREMAP_FRAGDEPTH_ONLY_AS_EXPECTED  (fragdepth=full-fix; clipremap=weak-4x; need device early-Z perf or ANGLE clip_control)"
	exit 0
else
	echo "MEGAVERDICT = CLIPREMAP_VERDICT_MISMATCH (tuple=$TUPLE md5_match=$([ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && echo yes || echo no))"
	exit 2
fi
