#!/usr/bin/env bash
# Builds the app's RMHeat.m for the Mac and checks the heat limits, the 117HD scale keeper and the session log. Expect
# HEAT_POLICY_GREEN.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
clang -fobjc-arc -Wall -Werror -framework Foundation -I "$ROOT/ios/app/RuneMobile" \
	"$ROOT/ios/app/RuneMobile/RMHeat.m" "$HERE/heat-main.m" -o "$OUT/heat"
"$OUT/heat"
