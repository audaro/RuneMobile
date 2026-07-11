#!/usr/bin/env bash
# Phase A1 (input parity) — runtime read-surface gate.
#
# The A1 *write* inputs (onWheel via pinch, onText/onKeyStroke via the soft keyboard) need a multitouch gesture
# / an in-game text field + IME, neither of which `adb` can inject — those are manual/device confirms (see
# README). What IS automatable on the emulator is the A1 READ-surface: the render thread polls
# getInteractTapSeq()/isTextInputOpen()/snapRadius() and the UI thread reads them each frame. This gate proves
# that path end-to-end: tap an interactable in-world and the per-frame poll observes interactTapSeq advance
# (firing the haptic). Same poll loop drives the keyboard auto-raise, so the mechanism is proven.
#
# Usage:
#   check-input.sh             # live `adb logcat -d`
#   check-input.sh saved.txt   # a saved dump
set -euo pipefail

SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi

# Normalized A1 signals (drop the volatile counter/timestamps -> stable md5, no secret).
SIGNALS="$(printf '%s\n' "$RAW" \
	| grep -oE 'a1: (interactTapSeq -> [0-9]+ \(haptic\)|textInputOpen=(true|false))' \
	| sed -E 's/interactTapSeq -> [0-9]+ \(haptic\)/interactTapSeq:advanced/; s/textInputOpen=true/textInputOpen:raise/; s/textInputOpen=false/textInputOpen:dismiss/' \
	| sed -E 's/^a1: //' \
	| awk '!seen[$0]++' | LC_ALL=C sort || true)"

printf '%s\n' "$SIGNALS"
echo "----"
MD5="$(printf '%s' "$SIGNALS" | md5)"
echo "signals_md5=$MD5"

if printf '%s\n' "$SIGNALS" | grep -q 'interactTapSeq:advanced'; then
	echo "ANDROID_A1_READSURFACE_GREEN md5=$MD5"
else
	echo "ANDROID_A1_READSURFACE_RED (no interactTapSeq advance — tap an interactable in-world first)"
	exit 1
fi
