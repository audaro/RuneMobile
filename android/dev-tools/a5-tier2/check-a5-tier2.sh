#!/usr/bin/env bash
# Phase A5 Tier-2 (native reflow seam) GREEN gate — the host reaches the two curated native-screen bridges
# (QuestHelperBridge + WorldSwitcherBridge) across the ART<->HotSpot boundary on the rl-bridge thread, the
# exact path the native Quest Helper / World Switcher screens use.
#
#   * QUEST: GREEN once the seam resolves and returns parseable JSON — available=true OR false. Quest Helper
#     is a HUB plugin (absent on a fresh emulator), so isAvailable() is normally false here and the native
#     screen falls back to the Tier-1 rendered panel; the seam is proven either way.
#   * WORLD: GREEN requires available=true && worlds>0 — World Switcher is built-in and we're LOGGED_IN, so
#     the real native screen is exercisable on the emulator.
#
# Run under census mode (--ez census true); the host self-test logs the sentinels.
# Usage: check-a5-tier2.sh [logcat-file]
set -euo pipefail
SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi

QUEST="$(printf '%s\n' "$RAW" | grep -oE 'ANDROID_A5_TIER2_QUEST_(GREEN|RED).*' | tail -1 || true)"
WORLD="$(printf '%s\n' "$RAW" | grep -oE 'ANDROID_A5_TIER2_WORLD_(GREEN|RED).*' | tail -1 || true)"
echo "$QUEST"
echo "$WORLD"
if printf '%s' "$QUEST" | grep -q 'ANDROID_A5_TIER2_QUEST_GREEN' \
	&& printf '%s' "$WORLD" | grep -q 'ANDROID_A5_TIER2_WORLD_GREEN'; then
	echo "A5 Tier-2 seam GREEN — host reached QuestHelperBridge (avail-or-fallback) + WorldSwitcherBridge (live world list) across the VM boundary."
	exit 0
else
	echo "A5 Tier-2 seam not fully GREEN (quest seam + world live-list both required)"; exit 1
fi
