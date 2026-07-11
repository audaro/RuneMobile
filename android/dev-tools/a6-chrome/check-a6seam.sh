#!/usr/bin/env bash
# Phase A6 (chrome seam) GREEN gate — the Android HOST reaches the Jagex-Mobile chrome read surface across the
# VM boundary, AND that surface resolves real geometry in the engine's current (FIXED 765x503) headless layout.
#
# A6's native edge tab-rails are cover-and-proxy: each frame the host reads MobileChromeBridge.getSnapshot()
# (tab-stone / minimap / orb / chat / viewport canvas bounds) and draws native rails over the live widgets,
# proxying taps via JavaBridge.onClickPrecise. This gate proves the host can pull that snapshot on the
# rl-bridge thread (-Drunelite.mobilechrome, census mode) and that it resolves a viewport or a tab stone once
# the world is loaded — i.e. there is real geometry to cover-and-proxy. (The bridge's own one-shot CHROME_READ
# verdict fires ~60 LOGGED_IN frames in, possibly pre-scene; the host probe polls the LIVE snapshot instead.)
#
# Usage:
#   check-a6seam.sh                # live `adb logcat -d`
#   check-a6seam.sh saved.log      # a saved/cloud dump
set -euo pipefail

SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi

SEAM="$(printf '%s\n' "$RAW" | grep -oE 'ANDROID_A6_SEAM_(GREEN|RED).*' | tail -1 || true)"
echo "$SEAM"
if printf '%s' "$SEAM" | grep -q 'ANDROID_A6_SEAM_GREEN'; then
	echo "A6 chrome seam GREEN — host pulled the MobileChromeBridge snapshot over the VM boundary and the read surface resolved real geometry (viewport / tab stones)."
	exit 0
else
	echo "A6 chrome seam not GREEN (need ANDROID_A6_SEAM_GREEN — the host snapshot resolved a viewport or tab stone)"; exit 1
fi
