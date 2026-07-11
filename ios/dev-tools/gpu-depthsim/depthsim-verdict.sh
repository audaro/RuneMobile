#!/usr/bin/env bash
# gpu-depthsim — controlled depth z-fight verdict (md5-gated, anti-fabrication).
#
# Recomputes pass/fail in bash from the VERBATIM Simulator-pulled log and pins its md5, so a fabricated/edited
# verdict can't pass. GREEN = on a real native GLES 3.0 driver with no glClipControl, writing the reverse-Z depth
# via gl_FragDepth (window_z = NDC.z = 100/viewZ) (a) carries finer depth precision at the far plane than the
# default (NDC.z+1)/2 half-range (PHASE 1), AND (b) substantially reduces a real DEPTH_COMPONENT32F z-fight on two
# near-coplanar intersecting planes at distance (PHASE 2). Usage: depthsim-verdict.sh [log] [expected_md5]
set -euo pipefail
cd "$(dirname "$0")"

LOG="${1:-evidence/gpu-depthsim-sim-verdict.log}"
EXPECT_MD5="${2:-0196b9f764689506e322fdd144ca0d68}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }

ACTUAL_MD5="$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | awk '{print $1}')"

ES300=$(grep -q "GL_SLVERSION = OpenGL ES GLSL ES 3.00" "$LOG" && echo YES || echo NO)
PC=$(grep -qF "[ds] PROGRAM P_CONTROL = OK" "$LOG" && echo OK || echo MISSING)
PF=$(grep -qF "[ds] PROGRAM P_FIX = OK" "$LOG" && echo OK || echo MISSING)
HONORED=$(grep -qF "[ds] FRAGDEPTH_HONORED = YES" "$LOG" && echo YES || echo NO)
P1_FINER=$(grep -qF "[ds] P1_FIX_FINER = YES" "$LOG" && echo YES || echo NO)
P2_CLEANER=$(grep -qF "[ds] P2_FIX_CLEANER = YES" "$LOG" && echo YES || echo NO)
P3_LAYER=$(grep -qF "[ds] P3_FIX_PRESERVES_LAYERING = YES" "$LOG" && echo YES || echo NO)
VERDICT=$(grep -qF "[ds] VERDICT fragdepth_resolves_zfight = YES" "$LOG" && echo YES || echo NO)
NO_FAIL=$(grep -qE "= FAIL|-> NO-GO|INCOMPLETE -> SKIP|EXCEPTION" "$LOG" && echo DIRTY || echo CLEAN)

echo "log                 : $LOG"
echo "md5 actual          : $ACTUAL_MD5"
echo "md5 expected        : $EXPECT_MD5"
echo "es300 driver        : $ES300"
echo "P_CONTROL program   : $PC"
echo "P_FIX program       : $PF"
echo "fragdepth honored   : $HONORED"
echo "P1 fix finer        : $P1_FINER"
echo "P2 fix cleaner      : $P2_CLEANER"
echo "P3 layering intact  : $P3_LAYER"
echo "VERDICT line        : $VERDICT"
echo "no-FAIL/skip lines  : $NO_FAIL"

TUPLE="$ES300/$PC/$PF/$HONORED/$P1_FINER/$P2_CLEANER/$P3_LAYER/$VERDICT/$NO_FAIL"
EXPECT="YES/OK/OK/YES/YES/YES/YES/YES/CLEAN"

if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && [ "$TUPLE" = "$EXPECT" ]; then
	echo "MEGAVERDICT = DEPTHSIM_FRAGDEPTH_RESOLVES_ZFIGHT_GREEN_AS_EXPECTED"
	exit 0
else
	echo "MEGAVERDICT = DEPTHSIM_NOT_GREEN (tuple=$TUPLE md5_match=$([ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && echo yes || echo no))"
	exit 2
fi
