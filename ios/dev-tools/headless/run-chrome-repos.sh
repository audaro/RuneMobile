#!/usr/bin/env bash
# W3 authentic mobile tab layout — DESKTOP de-risk for REPOSITIONING the real tab stones into edge columns.
#
# The native-crop rails looked boxed (a stone cropped out of the composited frame carries a square of game
# background). The authentic fix (= how the official OSRS-Mobile app looks) is to MOVE the real desktop
# tab-stone widgets into two vertical edge columns and let the ENGINE draw them (feathered, correct active
# state). The one thing to settle first: does setOriginalX/Y + ABSOLUTE_LEFT/TOP + revalidate MOVE a stone and
# HOLD it (the layout only re-runs on TOPLEVEL_REDRAW, so re-applying each frame should hold with at most a
# 1-frame flicker on a redraw)? MobileChromeReposProbe applies it every frame and reports heldAtTarget.
#
# GREEN = heldAtTarget == present (all present stones reached + held their column target) -> reposition works,
# port to device. Captured frames (out-login-unsafepoke/cap/) show the column for an eyeball.
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export EXTRA_JVM_ARGS="-Drunelite.mobilechrome.repos=true"
export RUN_SECONDS="${RUN_SECONDS:-150}"

OUT="out-login-unsafepoke"
LOG="$OUT/run.log"

echo "== rebuilding shaded client (repos probe sources changed) =="
(cd "$REPO" && ./gradlew :client:assemble --console=plain -q)

echo "== running login harness with the tab-stone reposition probe armed =="
./run-headless-login-unsafepoke.sh || true

echo
echo "== chrome-repos lines (verbatim from $LOG) =="
grep -E '\[chrome-repos\]' "$LOG" || echo "(no chrome-repos lines — did it reach LOGGED_IN on a resizable root?)"

echo
echo "== md5-gated verdict =="
VLINE="$(grep -E '\[chrome-repos\] CHROME_REPOS ' "$LOG" | tail -1 || true)"
field() { printf '%s\n' "$1" | grep -oE "$2=[0-9x]+" | head -1 | cut -d= -f2 || true; }
fieldb() { printf '%s\n' "$1" | grep -oE "$2=(true|false)" | head -1 | cut -d= -f2 || true; }
PRESENT="$(field "$VLINE" present)"
HELD="$(field "$VLINE" heldAtTarget)"
DRIFT="$(field "$VLINE" reapplyDriftFrames)"
CANVAS="$(field "$VLINE" canvas)"
PANELCLEAR="$(fieldb "$VLINE" panelClear)"

REPOS_OK=no
if [ -n "$VLINE" ] && [ -n "$PRESENT" ] && [ "$PRESENT" -ge 1 ] && [ "$HELD" = "$PRESENT" ] && [ "$PANELCLEAR" = "true" ]; then
  REPOS_OK=yes
fi
COMBINED="REPOS_OK=${REPOS_OK};PRESENT=${PRESENT};HELD=${HELD};PANELCLEAR=${PANELCLEAR};DRIFT=${DRIFT};CANVAS=${CANVAS}"
echo "COMBINED=$COMBINED"
MD5="$(printf '%s' "$COMBINED" | md5 -q 2>/dev/null || printf '%s' "$COMBINED" | md5sum | cut -d' ' -f1)"
echo "MD5=$MD5"
if [ "$REPOS_OK" = yes ]; then
  echo "MEGAVERDICT=CHROME_REPOS_GREEN (all ${PRESENT} present stones moved + held the column; drift=${DRIFT} frames) -> port reposition to device"
else
  echo "MEGAVERDICT=CHROME_REPOS_NOT_GREEN (present=${PRESENT} held=${HELD}) -> inspect $LOG (did revalidate move them? is re-apply enough?)"
fi
echo "== frames to eyeball the column: $OUT/cap/frame-LOGGED_IN-*.png =="
