#!/usr/bin/env bash
# Phase A0 GREEN gate — autologin reaches LOGGED_IN.
#
# Verifies that, from a pushed tokens.json (JX_* launcher handoff) with NO manual taps, the engine drives
# gameState all the way to LOGGED_IN. Reads an `adb logcat` dump (live by default, or a saved file), extracts
# the gameState transition chain, NORMALIZES it (strips timestamps / pids / draw# / loginIndex / the account
# display name — so the md5 is stable and carries no secret/PII), and md5-gates the result. The Android analog
# of the iOS devicectl-pulled-log GREEN discipline.
#
# Usage:
#   check-loggedin.sh                 # pull a fresh dump via `adb logcat -d`
#   check-loggedin.sh logcat.txt      # check a saved dump (e.g. from a cloud-device run)
set -euo pipefail

SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi

# Normalized transition chain: only the "gameState X -> Y" substrings, de-duplicated, in order.
CHAIN="$(printf '%s\n' "$RAW" | grep -oE 'gameState [A-Za-z_]+ -> [A-Za-z_]+' | awk '!seen[$0]++' || true)"

printf '%s\n' "$CHAIN"
echo "----"

MD5="$(printf '%s' "$CHAIN" | md5)"
echo "chain_md5=$MD5"

if printf '%s\n' "$CHAIN" | grep -q -- '-> LOGGED_IN'; then
	echo "ANDROID_LOGGEDIN_GREEN md5=$MD5"
else
	echo "ANDROID_LOGGEDIN_RED (no '-> LOGGED_IN' transition in logcat)"
	exit 1
fi
