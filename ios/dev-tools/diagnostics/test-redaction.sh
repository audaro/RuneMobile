#!/usr/bin/env bash
# Builds the app's RMRedact.m for the Mac and runs it over the shared redaction cases and the sample tokens.json.
# Expect ACCOUNT_WALK_GREEN and REDACTION_CASES_GREEN. Android's RedactTest.kt checks Redact.kt against the same files.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
clang -fobjc-arc -Wall -Werror -framework Foundation -I "$ROOT/ios/app/RuneMobile" \
	"$ROOT/ios/app/RuneMobile/RMRedact.m" "$HERE/redaction-cases-main.m" -o "$OUT/redaction-cases"
D="$ROOT/tools/diagnostics"
"$OUT/redaction-cases" "$D/redaction-cases.txt" "$D/tokens-sample.json" "$D/tokens-sample.expect"
