#!/usr/bin/env bash
# Verdict gate for run-hud-isolation.sh (A0 — HUD suppression + route-back de-risk).
#
# Parses the single [hud-iso] VERDICT line and adjudicates against the PREDICTIONS. REMOVAL is judged by the
# engine contract (isHidden — a hidden widget does not render) and CONFIRMED VISUALLY by the captured PNGs
# (hud-baseline/mask/hidden/transparent). It is NOT judged by a region pixel-diff: the live minimap changes
# frame-to-frame whether or not the HUD is removed, which would give false positives. CLICKABILITY is judged by
# whether the run-orb click flips OPTION_RUN. md5-gated per project convention.
#
# Outcomes:
#   INSTRUMENT_INVALID — the orb click did not flip OPTION_RUN even at baseline → the click-through test is
#                        meaningless; fix the instrument (orb coords / settle frames) first.
#   HUD_ISO_GREEN_AS_EXPECTED — instrument valid AND all six predictions held (see below).
#   HUD_ISO_RED — a prediction was violated → inspect (reality differs from the model).
set -euo pipefail
cd "$(dirname "$0")"
LOG="${1:-out-hud-isolation/run.log}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }
LINE="$(grep -E "\[hud-iso\] VERDICT" "$LOG" | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "HUD_ISO_NO_VERDICT — the probe never reached DONE. [hud-iso] trail:"
  grep -E "\[hud-iso\]" "$LOG" | tail -20 || echo "(no [hud-iso] lines at all)"
  exit 2
fi
echo "verdict line: $LINE"

get() { echo "$LINE" | grep -oE "$1=[a-z0-9]+" | head -1 | cut -d= -f2; }
INSTRUMENT_OK="$(get instrument_ok)"
BASE_RUN="$(get base_run_flip)"
MASK_HIDDEN="$(get mask_hidden)"
HIDDEN_HELD="$(get hidden_held)"; HIDDEN_CLICK="$(get hidden_clickable)"
TRANS_HELD="$(get trans_held)"; TRANS_CLICK="$(get trans_clickable)"
RESOLVER="$(echo "$LINE" | grep -oE "resolver=[a-z]+" | cut -d= -f2)"

echo
echo "---- instrument ----"
echo "  instrument_ok=$INSTRUMENT_OK (base_run_flip=$BASE_RUN)"
if [ "$INSTRUMENT_OK" != "true" ]; then
  echo
  echo ">>> INSTRUMENT_INVALID — the run-orb click did not flip OPTION_RUN at baseline."
  echo ">>> The hidden/transparent click-through results are NOT trustworthy. Fix the orb instrument first."
  exit 3
fi

echo "---- predictions (gated; removal also confirmed visually in hud-*.png) ----"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS $1=$2"; pass=$((pass+1)); else echo "  FAIL $1=$2 (expected $3)"; fail=$((fail+1)); fi; }
check mask_hidden       "$MASK_HIDDEN"  false   # setDraw2DMask does NOT hide the interface HUD
check hidden_held       "$HIDDEN_HELD"  true    # setHidden hides it (engine contract; PNG = visual proof)
check hidden_clickable  "$HIDDEN_CLICK" false   # ...and a hidden widget is not clickable
check trans_held        "$TRANS_HELD"   false   # setOpacity does NOT hide (still renders — PNG shows it)
check trans_clickable   "$TRANS_CLICK"  true    # ...but a transparent widget stays clickable

echo "---- CONCLUSION ----"
echo "  resolver=$RESOLVER  (a single lever that BOTH removes the HUD AND stays clickable)"
echo "  setHidden = the ONLY clean remover (PNG-confirmed) but is NOT clickable."
echo "  setOpacity(255) stays clickable but does NOT remove the HUD (only rectangle fills; minimap/orbs/text remain)."
echo "  => No single lever resolves both. Native-HUD route-back must DECOUPLE removal (setHidden) from action"
echo "     invocation: cover-in-place for un-repositioned elements (click-through preserved), or hide + direct"
echo "     invoke (clientscript/varc/native-filter) for repositioned ones (e.g. chat->top)."

ACTUAL="instrument_ok=true|mask_hidden=$MASK_HIDDEN|hidden_held=$HIDDEN_HELD|hidden_clickable=$HIDDEN_CLICK|trans_held=$TRANS_HELD|trans_clickable=$TRANS_CLICK"
EXPECT="instrument_ok=true|mask_hidden=false|hidden_held=true|hidden_clickable=false|trans_held=false|trans_clickable=true"
ACTUAL_MD5="$(printf '%s' "$ACTUAL" | md5)"
EXPECT_MD5="$(printf '%s' "$EXPECT" | md5)"
echo
echo "actual md5=$ACTUAL_MD5"
echo "expect md5=$EXPECT_MD5"
if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ]; then
  echo "VERDICT: HUD_ISO_GREEN_AS_EXPECTED"
else
  echo "VERDICT: HUD_ISO_RED — predictions violated ($fail fail / $pass pass); inspect the trail + PNGs."
  exit 4
fi
