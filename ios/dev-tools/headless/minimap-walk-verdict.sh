#!/usr/bin/env bash
# Verdict gate for run-minimap-walk.sh (A — minimap-walk route-back).
# GREEN = clicking the LIVE engine minimap issued a walk (visibleWalked=true) AND hiding it killed the walk
# (hiddenWalked=false) => a native minimap routes walks by clicking the live engine minimap kept covered.
set -euo pipefail
cd "$(dirname "$0")"
LOG="${1:-out-minimap-walk/run.log}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }
LINE="$(grep -E "\[minimapwalk\] MINIMAPWALK" "$LOG" | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "MINIMAPWALK_NO_VERDICT — probe never emitted. [minimapwalk] trail:"
  grep -E "\[minimapwalk\]" "$LOG" | tail -12 || echo "(none)"
  exit 2
fi
echo "verdict line: $LINE"

VIS="$(echo "$LINE" | grep -oE 'visibleWalked=[a-z]+' | cut -d= -f2)"
HID="$(echo "$LINE" | grep -oE 'hiddenWalked=[a-z]+' | cut -d= -f2)"
CONCL="$(echo "$LINE" | grep -oE 'conclusion=[a-z-]+' | cut -d= -f2)"

echo
printf "  visibleWalked=%s  hiddenWalked=%s  conclusion=%s\n" "$VIS" "$HID" "$CONCL"
if [ "$VIS" != "true" ]; then
  echo ">>> INCONCLUSIVE — clicking the visible minimap did not issue a walk (no walkable offset, or the click"
  echo ">>> missed the minimap clickbox). Re-run (different spot) or adjust OFFSET/DIRS before trusting this."
  exit 3
fi
echo "---- conclusion ----"
if [ "$HID" = "false" ]; then
  echo "  Native minimap walk = KEEP THE ENGINE MINIMAP LIVE + cover it natively; translate native-minimap taps"
  echo "  to engine-minimap pixels and synth-click. The minimap CANNOT be setHidden (that kills the walk), so it"
  echo "  is a cover-in-place element (vs chat, which is fully native + repositionable)."
else
  echo "  UNEXPECTED: the hidden minimap also walked — revisit the hidden-click timing."
fi

ACTUAL="visible=$VIS|hidden=$HID"
EXPECT="visible=true|hidden=false"
ACTUAL_MD5="$(printf '%s' "$ACTUAL" | md5)"
EXPECT_MD5="$(printf '%s' "$EXPECT" | md5)"
echo
echo "actual md5=$ACTUAL_MD5"
echo "expect md5=$EXPECT_MD5"
if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ]; then
  echo "VERDICT: MINIMAPWALK_GREEN_AS_EXPECTED"
else
  echo "VERDICT: MINIMAPWALK_RED — inspect the trail."
  exit 4
fi
