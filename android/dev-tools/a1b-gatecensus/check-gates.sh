#!/usr/bin/env bash
# Phase A-1b GREEN gate — runtime gate-flip census.
#
# Verifies that, under a booted + LOGGED_IN engine with each -D gate set, every headless bridge flips
# inert->active at RUNTIME: isEnabled()==true AND a first read returns without throwing (the gate is what wires
# the bridge into Hooks.draw's per-frame tick). The GateCensus probe (folded into probes.jar, armed once
# post-LOGGED_IN by DeviceHeadlessBoot when launched with `am start ... --ez census true`) emits one
# deterministic line per gate; this normalizes them (drops the human-only detail after the tab), sorts, and
# md5-gates the result — the Android analog of the iOS devicectl-pulled-log discipline.
#
# Usage:
#   check-gates.sh                 # pull a fresh dump via `adb logcat -d`
#   check-gates.sh logcat.txt      # check a saved dump (e.g. from a cloud-device run)
set -euo pipefail

SRC="${1:-}"
if [ -n "$SRC" ]; then
	[ -f "$SRC" ] || { echo "logcat file not found: $SRC" >&2; exit 2; }
	RAW="$(cat "$SRC")"
else
	command -v adb >/dev/null || { echo "adb not on PATH and no logcat file given" >&2; exit 2; }
	RAW="$(adb logcat -d 2>/dev/null)"
fi

# Deterministic sentinel: just the per-gate lines (the -o match excludes the logcat prefix AND the trailing
# tab+detail), de-duped and sorted so the md5 is stable across runs.
BODY="$(printf '%s\n' "$RAW" | grep -oE 'GATE_CENSUS [a-z]+ enabled=(true|false) live=(true|false)' | LC_ALL=C sort -u)"
SUMMARY="$(printf '%s\n' "$RAW" | grep -oE 'ANDROID_GATE_CENSUS verdict=[A-Z]+ active=[0-9]+/[0-9]+' | tail -1 || true)"

printf '%s\n' "$BODY"
echo "----"
echo "$SUMMARY"
MD5="$(printf '%s' "$BODY" | md5)"
echo "gates_md5=$MD5"

if printf '%s' "$SUMMARY" | grep -q 'verdict=GREEN' && [ -n "$BODY" ]; then
	echo "ANDROID_GATE_CENSUS_GREEN md5=$MD5"
else
	echo "ANDROID_GATE_CENSUS_RED"
	exit 1
fi
