#!/usr/bin/env bash
# GPU B1 — shader-downport gate verdict (md5-gated, anti-fabrication).
#
# Recomputes pass/fail in bash from the VERBATIM Simulator-pulled log and pins its md5, so a fabricated/edited
# verdict can't pass. GREEN = both real base-`gpu`-plugin programs (scene vert+frag, UI vertui+fragui), downported
# to GLSL ES 3.00, COMPILE + LINK + VALIDATE on a real native GLES 3.0 driver AND render non-blank to an offscreen
# FBO (glReadPixels). Usage: gpu-b1-verdict.sh [log] [expected_md5]
set -euo pipefail
cd "$(dirname "$0")"

LOG="${1:-evidence/gpu-b1-sim-verdict-20260605.log}"
EXPECT_MD5="${2:-56e6ef3ceeaa3458897b1b0da5df6615}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }

ACTUAL_MD5="$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | awk '{print $1}')"
g() { grep -qF "$1" "$LOG" && echo OK || echo MISSING; }

ES300=$(grep -q "GL_SLVERSION = OpenGL ES GLSL ES 3.00" "$LOG" && echo YES || echo NO)
SCENE_VERT=$(g "[b1] COMPILE scene.vert = OK")
SCENE_FRAG=$(g "[b1] COMPILE scene.frag = OK")
SCENE_PROG=$(g "[b1] SCENE_PROGRAM link=OK validate=OK")
UI_VERT=$(g "[b1] COMPILE ui.vert = OK")
UI_FRAG=$(g "[b1] COMPILE ui.frag = OK")
UI_PROG=$(g "[b1] UI_PROGRAM link=OK validate=OK")
UI_RENDER=$(grep -qE "^\[b1\] UI_RENDER .* -> OK$" "$LOG" && echo OK || echo FAIL)
SCENE_RENDER=$(grep -qE "^\[b1\] SCENE_RENDER .* -> OK$" "$LOG" && echo OK || echo FAIL)
NO_FAIL=$(grep -qE "= FAIL|-> FAIL|link=FAIL|validate=FAIL" "$LOG" && echo DIRTY || echo CLEAN)

echo "log               : $LOG"
echo "md5 actual        : $ACTUAL_MD5"
echo "md5 expected      : $EXPECT_MD5"
echo "es300 driver      : $ES300"
echo "scene.vert compile: $SCENE_VERT"
echo "scene.frag compile: $SCENE_FRAG"
echo "scene program     : $SCENE_PROG"
echo "ui.vert compile   : $UI_VERT"
echo "ui.frag compile   : $UI_FRAG"
echo "ui program        : $UI_PROG"
echo "ui render         : $UI_RENDER"
echo "scene render      : $SCENE_RENDER"
echo "no-FAIL lines     : $NO_FAIL"

TUPLE="$ES300/$SCENE_VERT/$SCENE_FRAG/$SCENE_PROG/$UI_VERT/$UI_FRAG/$UI_PROG/$UI_RENDER/$SCENE_RENDER/$NO_FAIL"
EXPECT="YES/OK/OK/OK/OK/OK/OK/OK/OK/CLEAN"

if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && [ "$TUPLE" = "$EXPECT" ]; then
	echo "MEGAVERDICT = B1_SHADER_GATE_GREEN_AS_EXPECTED"
	exit 0
else
	echo "MEGAVERDICT = B1_SHADER_GATE_NOT_GREEN (tuple=$TUPLE md5_match=$([ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && echo yes || echo no))"
	exit 2
fi
