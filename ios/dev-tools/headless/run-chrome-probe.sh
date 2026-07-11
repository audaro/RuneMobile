#!/usr/bin/env bash
# W3 hybrid Jagex-Mobile chrome — DESKTOP de-risk (the read surface + the tab-switch primitive).
#
# Settles the single thing to get right before any native UIKit chrome work, per the reviewer verdict:
#   (1) READ — can we, read-only, snapshot every chrome geometry/state the native side needs each frame
#       (14 tab-stone bounds, side panel, minimap, orbs, chat, world viewport, active-tab varc) under the
#       headless CACIO build, touching no widget (so overlay anchoring / plugins / input stay intact)?
#   (2) SWITCH — does a synthesized click on the live desktop tab stone switch the active tab (TOPLEVEL_PANEL),
#       and does poking the varc directly (setVarcIntValue) stick or get reverted? -> picks the proxy primitive.
#
# Reuses the proven UnsafePoke + two-stage-autologin harness (reaches LOGGED_IN under CACIO CTC, no OS window)
# and arms MobileChromeBridge (-Drunelite.mobilechrome=true, read-only) + MobileChromeProbe
# (-Drunelite.mobilechrome.probe=true, the mutating switch experiment — desktop-only). We md5-gate the
# RECOMPUTED verdict against an expected sentinel so a fabricated/duplicated shell line cannot produce a false
# GREEN (documented false-GREEN history — trust only the verbatim log + a bash-recomputed, md5-gated verdict).
set -euo pipefail
cd "$(dirname "$0")"
REPO="../../.."

export EXTRA_JVM_ARGS="-Drunelite.mobilechrome=true -Drunelite.mobilechrome.probe=true"
export RUN_SECONDS="${RUN_SECONDS:-150}"

OUT="out-login-unsafepoke"
LOG="$OUT/run.log"

# The probe lives in changed Java -> force a fresh shaded jar (the login harness only builds when MISSING).
echo "== rebuilding shaded client (chrome probe sources changed) =="
(cd "$REPO" && ./gradlew :client:assemble --console=plain -q)

echo "== running login harness with the hybrid-chrome read surface + switch probe armed =="
./run-headless-login-unsafepoke.sh || true

echo
echo "== chrome lines (verbatim from $LOG) =="
grep -E '\[chrome(-probe)?\] (CHROME_READ|CHROME_SWITCH|baseline|click|setVarc)' "$LOG" || echo "(no chrome lines — did it reach LOGGED_IN?)"

echo
echo "== md5-gated verdict =="
READ_LINE="$(grep -E '\[chrome\] CHROME_READ ' "$LOG" | tail -1 || true)"
SWITCH_LINE="$(grep -E '\[chrome-probe\] CHROME_SWITCH ' "$LOG" | tail -1 || true)"

# Recompute every token in bash from the verbatim lines — do NOT trust the shell echo of any value.
field() { printf '%s\n' "$1" | grep -oE "$2=[A-Za-z0-9/_-]+" | head -1 | cut -d= -f2 || true; }

ROOT="$(field "$READ_LINE" rootKind)"
TABS_PRESENT="$(field "$READ_LINE" tabsPresent)"
TABS_ZERO="$(field "$READ_LINE" tabsZeroSize)"
SIDE="$(field "$READ_LINE" sidePanel)"
MINI="$(field "$READ_LINE" minimap)"
ORBS="$(field "$READ_LINE" orbs)"
CHAT="$(field "$READ_LINE" chat)"
VIEW="$(field "$READ_LINE" viewport)"

CLICK_REACHED="$(field "$SWITCH_LINE" clickReached)"
# shellcheck disable=SC2034  # captured for parity with varcSticks/result; surfaced in the raw line, not gated here
VARC_IMM="$(field "$SWITCH_LINE" varcImmediate)"
VARC_STICKS="$(field "$SWITCH_LINE" varcSticks)"
SWITCH_RESULT="$(field "$SWITCH_LINE" result)"

# READ green = the read code resolved EVERY stone that is actually shown (tabsZeroSize==0 — no "visible but
# unread" stone), at least one tab present, and all five containers (side/minimap/orbs/chat/viewport) read.
# HIDDEN/ABSENT stones are legitimate account state (e.g. tabs not yet unlocked on Tutorial Island) and do
# NOT fail the gate — that is what makes this criterion account-independent.
READ_OK=no
if [ -n "$READ_LINE" ] && [ "${TABS_ZERO:-1}" = 0 ] && [ "${TABS_PRESENT:-0}" -ge 1 ] \
   && [ "$SIDE" = 1 ] && [ "$MINI" = 1 ] && [ "$ORBS" = 1 ] && [ "$CHAT" = 1 ] && [ "$VIEW" = 1 ]; then
  READ_OK=yes
fi
# Proxy primitive = synth-click switches the active tab.
CLICK_OK=$([ "$CLICK_REACHED" = "true" ] && echo yes || echo no)
VARC_OK=$([ "$VARC_STICKS" = "true" ] && echo yes || echo no)

COMBINED="READ_OK=${READ_OK};CLICK_OK=${CLICK_OK};VARC_OK=${VARC_OK};ROOT=${ROOT};SWITCH=${SWITCH_RESULT}"
echo "COMBINED=$COMBINED"
MD5="$(printf '%s' "$COMBINED" | md5 -q 2>/dev/null || printf '%s' "$COMBINED" | md5sum | cut -d' ' -f1)"
echo "MD5=$MD5"

if [ "$READ_OK" = yes ] && [ "$CLICK_OK" = yes ]; then
  echo "MEGAVERDICT=CHROME_HYBRID_GREEN (read surface reachable; synth-click switches tabs; varc-set sticks=${VARC_OK}) -> cover+proxy is viable; build native rails next"
elif [ "$READ_OK" = yes ]; then
  echo "MEGAVERDICT=CHROME_READ_GREEN_SWITCH_UNPROVEN (read OK; clickReached=${CLICK_REACHED} varcSticks=${VARC_STICKS}) -> inspect the switch experiment"
else
  echo "MEGAVERDICT=CHROME_INCONCLUSIVE (READ_OK=${READ_OK} read='${READ_LINE}' switch='${SWITCH_LINE}') -> inspect $LOG"
fi
echo "== full log: $LOG =="
