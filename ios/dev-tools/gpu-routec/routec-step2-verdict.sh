#!/usr/bin/env bash
# GPU Route C step 2 — native GL bridge core verdict (md5-gated, anti-fabrication).
#
# Recomputes pass/fail from the VERBATIM Simulator-pulled log and pins its md5. GREEN = the native bridge core
# (EAGL ES3 offscreen depth-FBO AWTContext analogue + the non-1:1 shims) works on a real GLES 3.0 driver AND the
# plugin's reverse-Z depth ordering survives WITHOUT glClipControl: depth-ON yields the near colour (depth test
# rejects the later-drawn far triangle) while the depth-OFF control yields the far colour (paint order).
set -euo pipefail
cd "$(dirname "$0")"
LOG="${1:-evidence/routec-step2-sim-verdict-20260605.log}"
EXPECT_MD5="${2:-801addb63184729fe40baa24f42e86df}"
[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }
MD5="$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | awk '{print $1}')"

CTX=$(grep -q "depthFBO complete=YES" "$LOG" && echo OK || echo FAIL)
ES300=$(grep -q "SLVERSION=OpenGL ES GLSL ES 3.00" "$LOG" && echo YES || echo NO)
RZ=$(grep -qE "PASS1 .* -> GREEN\(near wins\)" "$LOG" && echo OK || echo FAIL)
CTL=$(grep -qE "PASS2 .* -> RED\(far last\)" "$LOG" && echo OK || echo FAIL)
VERDICT=$(grep -qF "VERDICT reverseZ=OK control=OK multidraw_loop=OK map_shim=OK" "$LOG" && echo OK || echo FAIL)
NOFAIL=$(grep -qE "NO-GO|=FAIL|NOT-GREEN|NOT-RED|EXCEPTION" "$LOG" && echo DIRTY || echo CLEAN)

echo "log              : $LOG"
echo "md5 actual/expect: $MD5 / $EXPECT_MD5"
echo "es300 driver     : $ES300"
echo "AWTContext ctx   : $CTX"
echo "reverseZ (PASS1) : $RZ"
echo "control (PASS2)  : $CTL"
echo "verdict tuple    : $VERDICT"
echo "no-FAIL lines    : $NOFAIL"

TUPLE="$ES300/$CTX/$RZ/$CTL/$VERDICT/$NOFAIL"
if [ "$MD5" = "$EXPECT_MD5" ] && [ "$TUPLE" = "YES/OK/OK/OK/OK/CLEAN" ]; then
	echo "MEGAVERDICT = ROUTEC_STEP2_GREEN_AS_EXPECTED"
	exit 0
else
	echo "MEGAVERDICT = ROUTEC_STEP2_NOT_GREEN (tuple=$TUPLE)"
	exit 2
fi
