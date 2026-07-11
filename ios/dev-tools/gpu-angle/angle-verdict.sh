#!/usr/bin/env bash
# gpu-angle — MetalANGLE capability verdict (md5-gated, anti-fabrication).
#
# Recomputes the outcome in bash from the VERBATIM device-pulled log and pins its md5. This is an EVALUATION probe:
# it classifies what MetalANGLE gives us, rather than asserting a single pass. Tokens come from the one VERDICT line:
#   angle_metal / es31 / clip_control / compute
# Classification:
#   clip+compute     -> MULTI_WIN     (depth root-cause fix AND 117HD compute both enabled by adopting ANGLE)
#   clip only        -> DEPTH_FIX     (fixes the z-fight at root; 117HD still blocked)
#   compute only     -> COMPUTE_ONLY  (117HD reachable; depth unchanged)
#   neither          -> MINIMAL       (ANGLE adds little here)
# Usage: angle-verdict.sh [log] [expected_md5]
set -euo pipefail
cd "$(dirname "$0")"

LOG="${1:-evidence/gpu-angle-device-verdict.log}"
EXPECT_MD5="${2:-2a69b45dcfb07e98ed3531b1c60f8501}"
[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }

ACTUAL_MD5="$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | awk '{print $1}')"
v(){ grep -qF "$1" "$LOG" && echo YES || echo NO; }

ANGLE_METAL=$(v "angle_metal=YES")
ES31=$(v "es31=YES")
CLIP=$(v "clip_control=YES")
COMPUTE=$(v "compute=YES")
NO_NOGO=$(grep -qE "NO-GO|EXCEPTION" "$LOG" && echo DIRTY || echo CLEAN)

if   [ "$CLIP" = YES ] && [ "$COMPUTE" = YES ]; then CLASS=MULTI_WIN
elif [ "$CLIP" = YES ];                          then CLASS=DEPTH_FIX
elif [ "$COMPUTE" = YES ];                        then CLASS=COMPUTE_ONLY
else                                                  CLASS=MINIMAL
fi

echo "log            : $LOG"
echo "md5 actual     : $ACTUAL_MD5"
echo "md5 expected   : $EXPECT_MD5"
echo "angle/metal    : $ANGLE_METAL"
echo "es 3.1         : $ES31"
echo "clip_control   : $CLIP   (root-cause depth z-fight fix)"
echo "compute+ssbo   : $COMPUTE   (117HD enabler)"
echo "run clean      : $NO_NOGO"
echo "CLASSIFICATION : $CLASS"

if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && [ "$NO_NOGO" = CLEAN ]; then
	echo "MEGAVERDICT = ANGLE_PROBE_SEALED ($CLASS)"
	exit 0
else
	echo "MEGAVERDICT = ANGLE_PROBE_UNSEALED (md5_match=$([ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && echo yes || echo no), class=$CLASS)"
	exit 2
fi
