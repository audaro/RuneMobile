#!/usr/bin/env bash
# Lint all tracked Kotlin with ktlint. Style/config (indent, max-line-length, the Compose @Composable
# naming exception) live in .editorconfig. Auto-fix most findings with: ktlint --format <files>.
#
# Usage:  tools/lint/ktlint.sh             # lint, non-zero exit on any finding
#         tools/lint/ktlint.sh --require    # FAIL if ktlint is absent (the release gate uses this)
# Exit:   0 clean · 1 findings (or absent under --require) · 0 soft-skip if absent without --require.
#
# Requires ktlint + git on PATH (brew install ktlint). For a dev/CI shell, not the app runtime.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1
require=0
for a in "$@"; do [ "$a" = "--require" ] && require=1; done

if ! command -v ktlint >/dev/null 2>&1; then
	if [ "$require" -eq 1 ]; then
		echo "ktlint: not installed, but --require is set — failing (brew install ktlint)." >&2
		exit 1
	fi
	echo "ktlint: not installed — skipping (brew install ktlint). Lint not enforced this run." >&2
	exit 0
fi

# Our Kotlin lives under android/. The rest of the tree is vendored upstream RuneLite (see .gitattributes
# linguist-vendored) and must not diverge from upstream over formatting — scope the lint to android/ only.
files="$(git ls-files '*.kt' '*.kts' | grep -E '^android/' | grep -vE '(^|/)gradlew$' || true)"
if [ -z "$files" ]; then echo "ktlint: no Kotlin files tracked under android/."; exit 0; fi
count="$(printf '%s\n' "$files" | grep -c .)"

echo "ktlint: linting $count Kotlin files"
# shellcheck disable=SC2086  # intentional: pass the file list as separate path args
if printf '%s\n' "$files" | xargs ktlint --relative; then
	echo "✓ ktlint clean ($count files)"
	exit 0
fi
echo "✋ ktlint findings above — auto-fix most with: ktlint --format <files>"
exit 1
