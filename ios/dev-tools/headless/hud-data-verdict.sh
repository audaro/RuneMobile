#!/usr/bin/env bash
# Verdict gate for run-hud-data.sh (A2 — HUD data bridge).
#
# Parses the single [huddata] HUDDATA_READ line and gates on FAITHFUL + STRUCTURAL + LIVE predicates (md5-gated):
#   welcomeMsg=1        — the login "Welcome to Old School RuneScape" line is in the chat snapshot (faithful chat)
#   hp>0 & hpMax>0      — boosted/real hitpoints resolved (faithful orb)
#   energy in [0,100]   — run energy plausible
#   localPlayerResolved — px != Integer.MIN_VALUE (minimap local player present)
#   chatN>0             — chat snapshot non-empty
#   live=1              — the fingerprint changed over the ~2.4s window (data tracks live state)
set -euo pipefail
cd "$(dirname "$0")"
LOG="${1:-out-hud-data/run.log}"

[ -f "$LOG" ] || { echo "!! log not found: $LOG" >&2; exit 1; }
LINE="$(grep -E "\[huddata\] HUDDATA_READ" "$LOG" | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "HUD_DATA_NO_VERDICT — the bridge never emitted HUDDATA_READ. [huddata] trail:"
  grep -E "\[huddata\]" "$LOG" | tail -10 || echo "(no [huddata] lines at all)"
  exit 2
fi
echo "verdict line: $LINE"
echo
echo "snapshot:"; grep -E "\[huddata\] SNAPSHOT" "$LOG" | tail -1 | sed 's/.*SNAPSHOT //' | cut -c1-700
echo

get() { echo "$LINE" | grep -oE "$1=-?[0-9]+" | head -1 | cut -d= -f2; }
CHATN="$(get chatN)"; WELCOME="$(get welcomeMsg)"; HP="$(get hp)"; HPMAX="$(get hpMax)"
ENERGY="$(get energy)"; PX="$(get px)"; NPCS="$(get npcs)"; DOTS="$(get dots)"; LIVE="$(get live)"

# Booleans (md5-gate on these, not the raw values which vary run to run).
welcome_ok=$([ "$WELCOME" = "1" ] && echo 1 || echo 0)
hp_ok=$([ "${HP:-0}" -gt 0 ] && [ "${HPMAX:-0}" -gt 0 ] && echo 1 || echo 0)
energy_ok=$([ "${ENERGY:-99999}" -ge 0 ] && [ "${ENERGY:-99999}" -le 100 ] && echo 1 || echo 0)
player_ok=$([ "${PX:-0}" != "-2147483648" ] && echo 1 || echo 0)
chat_ok=$([ "${CHATN:-0}" -gt 0 ] && echo 1 || echo 0)
live_ok=$([ "$LIVE" = "1" ] && echo 1 || echo 0)

echo "---- predicates ----"
printf "  faithful chat (welcomeMsg=1): %s\n" "$welcome_ok"
printf "  faithful orb (hp=%s/%s >0):   %s\n" "$HP" "$HPMAX" "$hp_ok"
printf "  energy in [0,100] (=%s):       %s\n" "$ENERGY" "$energy_ok"
printf "  local player resolved (px=%s): %s\n" "$PX" "$player_ok"
printf "  chat non-empty (chatN=%s):     %s\n" "$CHATN" "$chat_ok"
printf "  live (fingerprint moved):      %s   [npcs=%s dots=%s]\n" "$live_ok" "$NPCS" "$DOTS"

ACTUAL="welcome=$welcome_ok|hp=$hp_ok|energy=$energy_ok|player=$player_ok|chat=$chat_ok|live=$live_ok"
EXPECT="welcome=1|hp=1|energy=1|player=1|chat=1|live=1"
ACTUAL_MD5="$(printf '%s' "$ACTUAL" | md5)"
EXPECT_MD5="$(printf '%s' "$EXPECT" | md5)"
echo
echo "actual md5=$ACTUAL_MD5"
echo "expect md5=$EXPECT_MD5"
if [ "$ACTUAL_MD5" = "$EXPECT_MD5" ]; then
  echo "VERDICT: HUD_DATA_GREEN_AS_EXPECTED"
else
  echo "VERDICT: HUD_DATA_RED — a predicate failed ($ACTUAL); inspect the SNAPSHOT + trail."
  exit 4
fi
