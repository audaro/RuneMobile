#!/usr/bin/env bash
# Verdict gate for run-edge2edge.sh (A1 — edge-to-edge scene-only frame at the wide device aspect).
# GREEN = the resizable 3D viewport fills the wide canvas (viewportFillsCanvas=true) AND every engine 2D HUD
# target got hidden (hudHidden == hudTotal). Removal is also visually confirmed in edge2edge-scene-*.png.
set -euo pipefail
cd "$(dirname "$0")"
LOG="${1:-out-edge2edge/run.log}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }
LINE="$(grep -E "\[edge2edge\] EDGE2EDGE" "$LOG" | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "EDGE2EDGE_NO_VERDICT — probe never emitted. [edge2edge] trail:"
  grep -E "\[edge2edge\]" "$LOG" | tail -10 || echo "(none)"
  exit 2
fi
echo "verdict line: $LINE"

FILLS="$(echo "$LINE" | grep -oE 'viewportFillsCanvas=[a-z]+' | cut -d= -f2)"
TOTAL="$(echo "$LINE" | grep -oE 'hudTotal=[0-9]+' | cut -d= -f2)"
HIDDEN="$(echo "$LINE" | grep -oE 'hudHidden=[0-9]+' | cut -d= -f2)"
CANVAS="$(echo "$LINE" | grep -oE 'canvas=[0-9]+x[0-9]+' | cut -d= -f2)"
VIEWPORT="$(echo "$LINE" | grep -oE 'viewport=[0-9]+x[0-9]+' | cut -d= -f2)"

echo
echo "  canvas=$CANVAS viewport=$VIEWPORT"
fills_ok=$([ "$FILLS" = "true" ] && echo 1 || echo 0)
hud_ok=$([ "${HIDDEN:-0}" = "${TOTAL:-1}" ] && echo 1 || echo 0)
printf "  viewport fills wide canvas: %s\n" "$fills_ok"
printf "  all HUD hidden (%s/%s):      %s\n" "$HIDDEN" "$TOTAL" "$hud_ok"

ACTUAL="fills=$fills_ok|hud=$hud_ok"
EXPECT="fills=1|hud=1"
ACTUAL_MD5="$(printf '%s' "$ACTUAL" | md5)"
EXPECT_MD5="$(printf '%s' "$EXPECT" | md5)"
echo
echo "actual md5=$ACTUAL_MD5"
echo "expect md5=$EXPECT_MD5"
if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ]; then
  echo "VERDICT: EDGE2EDGE_GREEN_AS_EXPECTED"
else
  echo "VERDICT: EDGE2EDGE_RED — inspect (viewport letterboxed, or a HUD widget survived); see the scene PNG."
  exit 4
fi
