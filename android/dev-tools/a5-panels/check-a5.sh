#!/usr/bin/env bash
# Phase A5 (Tier-1 panel seam) GREEN gate — the host opens a plugin's Swing side-panel off-screen (CACIO)
# and pulls its rendered ARGB image across the ART<->HotSpot boundary (the rendered-image fallback that works
# for ANY plugin panel). Run under census mode (--ez census true); the host self-test logs the result.
#
# Usage: check-a5.sh [logcat-file]
set -euo pipefail
SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi
LINE="$(printf '%s\n' "$RAW" | grep -oE 'ANDROID_A5_SEAM_(GREEN|RED).*' | tail -1 || true)"
echo "$LINE"
if printf '%s' "$LINE" | grep -q 'ANDROID_A5_SEAM_GREEN'; then
	echo "(host opened a plugin side-panel off-screen and pulled its rendered ARGB image over the VM boundary)"
	exit 0
else
	echo "ANDROID_A5_SEAM_RED (no GREEN sentinel)"; exit 1
fi
