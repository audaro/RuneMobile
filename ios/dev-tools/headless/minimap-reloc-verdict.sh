#!/usr/bin/env bash
# Verdict gate for run-minimap-reloc.sh (A4 — can the engine minimap be RELOCATED?).
# GREEN = the minimap's reported bounds moved to the target (moved=true) AND clicking the relocated minimap issued
# a walk (walked=true) => A4 can relocate the engine's pixel-perfect minimap (no native terrain redraw), the cheap
# A3-style path. The PNG (out-minimap-reloc/cap/minimapreloc-*.png) is the ground truth for "renders / not occluded".
set -euo pipefail
cd "$(dirname "$0")"
LOG="${1:-out-minimap-reloc/run.log}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }
LINE="$(grep -E "\[minimapreloc\] MINIMAPRELOC" "$LOG" | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "MINIMAPRELOC_NO_VERDICT — probe never emitted. [minimapreloc] trail:"
  grep -E "\[minimapreloc\]" "$LOG" | tail -14 || echo "(none)"
  exit 2
fi
echo "verdict line: $LINE"

MOVED="$(echo "$LINE" | grep -oE 'moved=[a-z]+' | cut -d= -f2)"
WALKED="$(echo "$LINE" | grep -oE 'walked=[a-z]+' | cut -d= -f2)"
CONCL="$(echo "$LINE" | grep -oE 'conclusion=[a-z-]+' | cut -d= -f2)"

echo
printf "  moved=%s  walked=%s  conclusion=%s\n" "$MOVED" "$WALKED" "$CONCL"
echo "---- conclusion ----"
if [ "$MOVED" = "true" ] && [ "$WALKED" = "true" ]; then
  echo "  A4 = RELOCATE the engine's own minimap (setForcedPosition, re-applied each frame, like the A3 chat). It"
  echo "  keeps real terrain/dots/compass AND stays click-to-walk (it IS the live engine minimap). Inspect the PNG"
  echo "  to confirm it renders at the target and is not occluded by the 3D viewport, then build it in HudVeneerBridge."
elif [ "$MOVED" = "true" ]; then
  echo "  Minimap MOVED but the relocated minimap did not walk — relocate breaks click-to-walk. Fall back to"
  echo "  cover-in-place (keep the engine minimap at its default spot, draw native over it, proxy walk-clicks)."
else
  echo "  Minimap did NOT move to the target (setForcedPosition not honoured for the minimap) — fall back to"
  echo "  cover-in-place native draw. Inspect the [minimapreloc] trail + assembly dump."
fi

ACTUAL="moved=$MOVED|walked=$WALKED"
EXPECT="moved=true|walked=true"
ACTUAL_MD5="$(printf '%s' "$ACTUAL" | md5)"
EXPECT_MD5="$(printf '%s' "$EXPECT" | md5)"
echo
echo "actual md5=$ACTUAL_MD5"
echo "expect md5=$EXPECT_MD5"
if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ]; then
  echo "VERDICT: MINIMAPRELOC_GREEN_AS_EXPECTED"
else
  echo "VERDICT: MINIMAPRELOC_RED — relocate not viable, use cover-in-place. Inspect the trail + PNG."
  exit 4
fi
