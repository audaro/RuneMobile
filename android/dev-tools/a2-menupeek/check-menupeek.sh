#!/usr/bin/env bash
# Phase A2 press-and-peek gate.
#
# Automatable on the emulator: a long-press (held DOWN) opens the engine right-click menu AND builds the native
# overlay composited over the live SurfaceView (the primary A2 risk), and release commits through
# JavaBridge.selectMenuPoint — the release-off-row / cancel path clicks the engine's own Cancel row, exercising
# the same commit mechanism. What is NOT adb-injectable on this emulator is a *continuous* hold-drag-release, so
# sliding the highlight onto a non-cancel row and committing it is a manual/device confirm (see README).
#
# GREEN requires: menu opened + native overlay built + a selectMenuPoint commit fired (row or cancel).
set -euo pipefail

SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi

SIG="$(printf '%s\n' "$RAW" \
	| grep -oE 'a2: (long-press -> menu open|native menu [0-9]+ entries|select row [0-9]+|menu cancelled)' \
	| sed -E 's/long-press -> menu open/menu-open/; s/native menu [0-9]+ entries/native-overlay-built/; s/select row [0-9]+/commit-row/; s/menu cancelled/commit-cancel/; s/^a2: //' \
	| awk '!seen[$0]++' | LC_ALL=C sort)"

printf '%s\n' "$SIG"
echo "----"
MD5="$(printf '%s' "$SIG" | md5)"
echo "signals_md5=$MD5"

if printf '%s\n' "$SIG" | grep -q 'menu-open' \
	&& printf '%s\n' "$SIG" | grep -q 'native-overlay-built' \
	&& printf '%s\n' "$SIG" | grep -qE 'commit-row|commit-cancel'; then
	echo "ANDROID_A2_MENUPEEK_GREEN md5=$MD5"
else
	echo "ANDROID_A2_MENUPEEK_RED (need menu-open + native-overlay-built + a selectMenuPoint commit)"
	exit 1
fi
