#!/usr/bin/env bash
# Lint every tracked shell script with ShellCheck at --severity=warning.
#
# Scope: all tracked *.sh plus the git hooks, MINUS the generated Gradle wrappers (gradlew). Config and
# the one repo-wide mute (SC2155) live in .shellcheckrc. Notes/info findings are surfaced when you run
# `shellcheck <file>` directly but are not gate-blocking here.
#
# Usage:  tools/lint/shellcheck.sh            # lint, non-zero exit on any warning+
#         tools/lint/shellcheck.sh --quiet    # only print on failure
#         tools/lint/shellcheck.sh --require   # FAIL (exit 1) if shellcheck is absent, instead of soft-skip
# Exit:   0 clean · 1 findings (or absent under --require) · 0+notice if absent without --require (soft-skip).
#
# Soft-skip is the default so pre-commit and lean clones aren't blocked by a missing optional tool. The
# release gate passes --require, because the authoritative pre-publish check must not pass silently when
# the linter isn't even present.
#
# Requires `shellcheck` and `git` on PATH (brew/apt install shellcheck). Run from a normal dev/CI shell —
# not from inside the Android Gradle build or the runtime app shell, which never invoke this.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1
quiet=0; require=0
for a in "$@"; do
	case "$a" in
		--quiet)   quiet=1 ;;
		--require) require=1 ;;
	esac
done

if ! command -v shellcheck >/dev/null 2>&1; then
	if [ "$require" -eq 1 ]; then
		echo "shellcheck: not installed, but --require is set — failing (brew install shellcheck)." >&2
		exit 1
	fi
	echo "shellcheck: not installed — skipping (brew install shellcheck). Lint not enforced this run." >&2
	exit 0
fi

# Build the file list: tracked .sh + the hooks, excluding the generated gradlew wrappers.
files="$( { git ls-files '*.sh'; printf '%s\n' tools/git-hooks/pre-commit tools/git-hooks/commit-msg; } \
	| grep -vE '(^|/)gradlew$' | sort -u )"
# Keep only paths that still exist (hooks may be uninstalled in a bare checkout).
list=""
while IFS= read -r f; do [ -n "$f" ] && [ -f "$f" ] && list="$list$f"$'\n'; done <<< "$files"
list="${list%$'\n'}"
count="$(printf '%s\n' "$list" | grep -c .)"

[ "$quiet" -eq 1 ] || echo "shellcheck: linting $count scripts at --severity=warning"
# shellcheck disable=SC2086  # intentional: pass the newline list as separate path args
out="$(printf '%s\n' "$list" | xargs shellcheck -f gcc --severity=warning 2>/dev/null)"
rc=$?

if [ -n "$out" ]; then
	echo "$out"
	echo "✋ shellcheck: $(printf '%s\n' "$out" | grep -c .) finding(s) at warning+ — fix, or add a justified '# shellcheck disable=SCxxxx' directive."
	exit 1
fi
[ "$quiet" -eq 1 ] || echo "✓ shellcheck clean ($count scripts)"
exit "$rc"
