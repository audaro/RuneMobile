#!/usr/bin/env bash
# gpu-present — ANGLE/Metal WINDOW-surface present-path verdict (md5-gated, anti-fabrication).
#
# Recomputes the outcome in bash from the VERBATIM device-pulled log and pins its md5 (the project has been burned
# by fabricated GREENs — verify by md5). The probe answers the Phase A1 #1 risk: does an EGL window surface scan
# out to the screen? Tokens come from the one VERDICT line: window_present / fb_readback / clip_control / msaa.
# A GREEN present path = window_present=YES + fb_readback=YES + no NO-GO/EXCEPTION (+ visual screenshot confirm).
# Usage: present-verdict.sh [log] [expected_md5]
set -euo pipefail
cd "$(dirname "$0")"

LOG="${1:-evidence/gpu-present-device-verdict.log}"
EXPECT_MD5="${2:-36cc83dd4472501c67fd6ff4c620cf78}"
[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }

ACTUAL_MD5="$(md5 -q "$LOG" 2>/dev/null || md5sum "$LOG" | awk '{print $1}')"
v(){ grep -qF "$1" "$LOG" && echo YES || echo NO; }

WINDOW=$(v "window_present=YES")
FBRB=$(v "fb_readback=YES")
CLIP=$(v "clip_control=YES")
MSAA=$(v "msaa=YES")
NO_NOGO=$(grep -qE "NO-GO|EXCEPTION|start FAILED" "$LOG" && echo DIRTY || echo CLEAN)

echo "log            : $LOG"
echo "md5 actual     : $ACTUAL_MD5"
echo "md5 expected   : $EXPECT_MD5"
echo "window present : $WINDOW   (EGL window surface created + swapped)"
echo "fb readback    : $FBRB   (default framebuffer is real + readable)"
echo "clip_control   : $CLIP   (reverse-Z depth precision in a window-context FBO)"
echo "msaa           : $MSAA   (GL_MAX_SAMPLES>=4 + complete MSAA fbo)"
echo "run clean      : $NO_NOGO"

if [ "$WINDOW" = YES ] && [ "$FBRB" = YES ] && [ "$NO_NOGO" = CLEAN ]; then
	PASS=YES; else PASS=NO; fi
echo "PRESENT_PATH   : $PASS   (GREEN also needs the screenshot showing the bars on screen)"

if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && [ "$PASS" = YES ]; then
	echo "MEGAVERDICT = PRESENT_PROBE_SEALED"
	exit 0
else
	echo "MEGAVERDICT = PRESENT_PROBE_UNSEALED (md5_match=$([ "$ACTUAL_MD5" = "$EXPECT_MD5" ] && echo yes || echo no), pass=$PASS)"
	exit 2
fi
