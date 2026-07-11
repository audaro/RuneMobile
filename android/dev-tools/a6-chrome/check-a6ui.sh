#!/usr/bin/env bash
# Phase A6 (chrome UI) GREEN gate — the native OSRS-mobile 2-col tab grid draws at the bottom-right with the
# engine's own tab stones hidden, and a cell tap opens that tab.
#
# The overlay (ChromeOverlayView) reads the render-thread-published MobileChromeBridge snapshot each frame
# (lock-free, no HotSpot attach) for the active tab + supported layout (toplevel 164), hides the 14 engine
# stones (HudVeneerBridge.setStonesHidden) and draws all 14 tabs as a 2-col x 7-row grid using the bundled OSRS
# stone sprites + glyphs. A cell tap opens the tab by replaying its engine stone op script (openTab) — works
# while hidden, so the engine + plugins stay authoritative and no widget is moved or covered.
#
#   DRAW : ANDROID_A6_UI_GREEN native 2-col tab grid drawn ...   (the grid laid out, engine stones hidden)
#   TAP  : a6: native tab <i> tap -> openTab   (a cell tap opened that tab) — optional, only present if a tap
#          was injected this run; the gate passes on DRAW alone (tap is verified interactively — see README).
#
# Usage: check-a6ui.sh [logcat-file]
set -euo pipefail
SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi

DRAW="$(printf '%s\n' "$RAW" | grep -oE 'ANDROID_A6_UI_(GREEN|RED).*' | tail -1 || true)"
PROXY="$(printf '%s\n' "$RAW" | grep -oE 'a6: native tab [0-9]+ tap -> onClickPrecise.*' | tail -1 || true)"
echo "$DRAW"
[ -n "$PROXY" ] && echo "$PROXY"
if printf '%s' "$DRAW" | grep -q 'ANDROID_A6_UI_GREEN'; then
	echo "A6 chrome UI GREEN — native cover-and-proxy rails drew over the live tab stones${PROXY:+ (+ a rail tap proxied onClickPrecise onto the live stone)}."
	exit 0
else
	echo "A6 chrome UI not GREEN (need ANDROID_A6_UI_GREEN — the overlay parsed the snapshot and laid out rails)"; exit 1
fi
