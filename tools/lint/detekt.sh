#!/usr/bin/env bash
# Static analysis of the Android Kotlin shell with detekt, layered on the default ruleset.
# Config (android/config/detekt/detekt.yml) disables rules ktlint already owns + MagicNumber; existing
# complexity/exception debt is grandfathered in android/config/detekt/baseline.xml, so this enforces on
# NEW code only. Refresh the baseline intentionally (see the failure hint) when you accept new debt.
#
# Usage:  tools/lint/detekt.sh             # analyze, non-zero exit on NEW findings
#         tools/lint/detekt.sh --require    # FAIL if detekt is absent (the release gate uses this)
# Exit:   0 clean · 1 new findings (or absent under --require) · 0 soft-skip if absent without --require.
#
# Requires detekt + git on PATH (brew install detekt). For a dev/CI shell, not the app runtime.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1
require=0
for a in "$@"; do [ "$a" = "--require" ] && require=1; done

if ! command -v detekt >/dev/null 2>&1; then
	if [ "$require" -eq 1 ]; then
		echo "detekt: not installed, but --require is set — failing (brew install detekt)." >&2
		exit 1
	fi
	echo "detekt: not installed — skipping (brew install detekt). Lint not enforced this run." >&2
	exit 0
fi

cfg="android/config/detekt/detekt.yml"
base="android/config/detekt/baseline.xml"
echo "detekt: analyzing android/ (config: $cfg, baseline: $base)"
if detekt --build-upon-default-config --config "$cfg" --baseline "$base" --input android; then
	echo "✓ detekt clean (no new findings beyond the baseline)"
	exit 0
fi
echo "✋ detekt found NEW issues not in the baseline. Fix them, or — if you accept the new debt — refresh:"
echo "    detekt --build-upon-default-config --config $cfg --input android --baseline $base --create-baseline"
exit 1
