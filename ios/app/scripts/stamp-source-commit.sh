#!/bin/sh
# Stamp the commit this app was built from into the built Info.plist as RMSourceCommit (Xcode build phase).
#
# Game updates (RMGameUpdate.m) are published per shell commit, so only a released, clean build may match one. A tree
# with tracked changes stamps "<sha>-dirty", and no checkout stamps "unknown": neither ever matches a published set, so
# such builds keep their bundled jars. Untracked files don't count (staged jars and build output are untracked).
# A non-Release build stamps "debug", like Android's debug builds: otherwise a simulator build at a release commit
# with freshly staged (untracked) jars would quietly boot a downloaded set instead of them. The simulator tests pose
# as a release with the RMGameUpdateShell user default (tools/game-update/serve-local.sh).
set -eu
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
[ -f "$PLIST" ] || { echo "stamp-source-commit: no built Info.plist at $PLIST" >&2; exit 1; }
SHA="unknown"
if ROOT="$(git -C "$SRCROOT" rev-parse --show-toplevel 2>/dev/null)"; then
	SHA="$(git -C "$ROOT" rev-parse HEAD)"
	if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
		SHA="$SHA-dirty"
	fi
fi
[ "${CONFIGURATION:-}" = "Release" ] || SHA="debug"
/usr/libexec/PlistBuddy -c "Delete :RMSourceCommit" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :RMSourceCommit string $SHA" "$PLIST"
echo "stamp-source-commit: RMSourceCommit = $SHA"
