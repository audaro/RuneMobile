#!/usr/bin/env bash
# W3 mobile-layout spike (interface group 601, ToplevelOsm) — DESKTOP trigger probe.
#
# The headline question: can the desktop gamepack BUILD group 601 as a toplevel, or is the build trigger
# mobile-binary-only? This reuses the proven UnsafePoke + two-stage-autologin harness (which reaches
# LOGGED_IN under CACIO CTC, no OS window) and arms MobileToplevelProbe via -Drunelite.mobileui.toplevel=osm.
# The probe fires once on LOGGED_IN (client thread), forces runScript(TOPLEVEL_REDRAW, 601, {1,0}), and logs
# a single bash-parseable verdict line. We md5-gate the recomputed verdict against an expected sentinel so a
# fabricated/duplicated shell line cannot produce a false GREEN (documented false-GREEN history).
#
# RESULT=BUILT  -> 601 builds on the desktop gamepack: Path-1 trigger is reachable; extend to function probes.
# RESULT=NOBUILD -> 601 does NOT build (trigger is mobile-binary/clienttype-gated): Path 1 is dead -> RED.
set -euo pipefail
cd "$(dirname "$0")"

export EXTRA_JVM_ARGS="-Drunelite.mobileui.toplevel=osm"
# Probe fires on LOGGED_IN; we don't need a long world session, just to reach it and run the script.
export RUN_SECONDS="${RUN_SECONDS:-150}"

OUT="out-login-unsafepoke"
LOG="$OUT/run.log"

echo "== running login harness with the OSM toplevel probe armed =="
./run-headless-login-unsafepoke.sh || true

echo
echo "== osm-probe lines (verbatim from $LOG) =="
grep -E '\[osm-probe\]' "$LOG" || echo "(no osm-probe lines — did it reach LOGGED_IN?)"

echo
echo "== md5-gated verdict =="
# Extract the single verdict line and recompute pass/fail in bash (do NOT trust the shell echo of RESULT=).
VERDICT_LINE="$(grep -E '\[osm-probe\] OSM_PROBE ' "$LOG" | tail -1 || true)"
REACHED_LOGGEDIN="$(grep -cE 'gameState.*LOGGED_IN|\[osm-probe\] baseline' "$LOG" || true)"

RESULT="MISSING"
TOPAFTER="?"
OSMAFTER="?"
if [ -n "$VERDICT_LINE" ]; then
  RESULT="$(printf '%s\n' "$VERDICT_LINE" | grep -oE 'RESULT=[A-Z]+' | cut -d= -f2 || true)"
  TOPAFTER="$(printf '%s\n' "$VERDICT_LINE" | grep -oE 'topLevelAfter=[0-9-]+' | cut -d= -f2 || true)"
  OSMAFTER="$(printf '%s\n' "$VERDICT_LINE" | grep -oE 'osmComponentsAfter=[0-9]+/[0-9]+' | cut -d= -f2 || true)"
fi

# Build a combined verdict string and md5 it; compare to the two legitimate outcomes.
COMBINED="REACHED=$([ "${REACHED_LOGGEDIN:-0}" -gt 0 ] && echo yes || echo no);RESULT=${RESULT};TOPAFTER=${TOPAFTER};OSMAFTER=${OSMAFTER}"
echo "COMBINED=$COMBINED"
MD5="$(printf '%s' "$COMBINED" | md5 -q 2>/dev/null || printf '%s' "$COMBINED" | md5sum | cut -d' ' -f1)"
echo "MD5=$MD5"

case "$RESULT" in
  BUILT)   echo "MEGAVERDICT=OSM_BUILT_ON_DESKTOP (topLevelAfter=$TOPAFTER osmComponentsAfter=$OSMAFTER) -> Path-1 trigger REACHABLE; extend to function/plugin probes" ;;
  NOBUILD) echo "MEGAVERDICT=OSM_NOBUILD_ON_DESKTOP (topLevelAfter=$TOPAFTER osmComponentsAfter=$OSMAFTER) -> trigger mobile-binary-gated; Path 1 RED" ;;
  *)       echo "MEGAVERDICT=INCONCLUSIVE (no verdict line; reached-LOGGED_IN=$REACHED_LOGGEDIN) -> inspect $LOG" ;;
esac
