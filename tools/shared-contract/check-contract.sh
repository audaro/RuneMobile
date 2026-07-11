#!/usr/bin/env bash
# Compare the current shared iOS/Android contract against the committed baseline.
#
#   check-contract.sh            # diff vs baseline; exit 0 unchanged, 1 additive-only, 2 removed/changed
#   check-contract.sh --update   # rewrite the baseline (acknowledge the current contract)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASELINE="$HERE/baseline.txt"
CUR="$(python3 "$HERE/extract-contract.py")"

if [ "${1:-}" = "--update" ]; then
	printf '%s\n' "$CUR" > "$BASELINE"
	echo "baseline updated ($(printf '%s\n' "$CUR" | grep -c . ) entries)"
	exit 0
fi

[ -f "$BASELINE" ] || { echo "no baseline yet; run: $0 --update" >&2; exit 3; }

removed="$(comm -23 <(LC_ALL=C sort "$BASELINE") <(printf '%s\n' "$CUR" | LC_ALL=C sort) || true)"
added="$(comm -13 <(LC_ALL=C sort "$BASELINE") <(printf '%s\n' "$CUR" | LC_ALL=C sort) || true)"

if [ -z "$removed" ] && [ -z "$added" ]; then
	echo "shared contract: UNCHANGED ($(printf '%s\n' "$CUR" | grep -c .) entries)"
	exit 0
fi

echo "shared contract: CHANGED — affects BOTH iOS and Android"
if [ -n "$removed" ]; then
	echo "  REMOVED / CHANGED (breaking risk for the other port):"
	printf '%s\n' "$removed" | sed 's/^/    - /'
fi
if [ -n "$added" ]; then
	echo "  ADDED (additive — the other port simply won't call it yet):"
	printf '%s\n' "$added" | sed 's/^/    + /'
fi

[ -n "$removed" ] && exit 2 || exit 1
