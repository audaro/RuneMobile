#!/usr/bin/env bash
# Incremental clang-format check for native code (C / C++ / Objective-C / Obj-C++). Style: .clang-format.
#
# The existing native tree is hand-formatted with intentional alignment (aligned trailing comments,
# declarations) that predates this config; a flag-day reformat would be ~23k lines of churn and would
# destroy that structure. So we enforce INCREMENTALLY via git clang-format: only lines CHANGED vs a base
# ref must conform; untouched code is grandfathered and migrates as it is next edited. Vendored JDK headers
# (ios/app/RuneMobile/jni/*) are excluded.
#
# Usage:  tools/lint/clang-format.sh [<base-ref>]   # check working-tree changes vs base (default HEAD)
#         tools/lint/clang-format.sh --staged         # check staged changes (used by the pre-commit hook)
#         tools/lint/clang-format.sh --require ...      # FAIL if clang-format is absent (release gate)
# Exit:   0 clean · 1 unformatted changed lines (or absent under --require) · 0 soft-skip if absent.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1
require=0
staged=0
base="HEAD"
for a in "$@"; do
	case "$a" in
		--require) require=1 ;;
		--staged)  staged=1 ;;
		--*)       ;;            # ignore unknown flags
		*)         base="$a" ;;
	esac
done

if ! command -v git-clang-format >/dev/null 2>&1; then
	if [ "$require" -eq 1 ]; then
		echo "clang-format: git-clang-format not installed, but --require is set — failing (brew install clang-format)." >&2
		exit 1
	fi
	echo "clang-format: git-clang-format not installed — skipping (brew install clang-format). Not enforced." >&2
	exit 0
fi

gcf=(git clang-format --diff --extensions "c,cc,cpp,cxx,h,hpp,m,mm")
[ "$staged" -eq 1 ] && gcf+=(--staged)
out="$("${gcf[@]}" "$base" -- \
	':(exclude)ios/app/RuneMobile/jni/jni.h' ':(exclude)ios/app/RuneMobile/jni/jni_md.h' 2>/dev/null || true)"

scope="$base"; [ "$staged" -eq 1 ] && scope="--staged $base"
case "$out" in
	*"did not modify"*|*"no modified files"*|"")
		echo "✓ clang-format: native changes conform (or none) vs $scope"
		exit 0
		;;
esac
echo "✋ clang-format: changed native lines are not formatted. Apply with:"
echo "    git clang-format $scope"
echo "── needed changes ──"
printf '%s\n' "$out"
exit 1
