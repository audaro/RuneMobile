#!/usr/bin/env bash
# serve-local.sh - serve a make-manifest.py output on loopback, for testing game updates on a debug build.
#
#   tools/game-update/make-manifest.py --out DIR --revision N --base-url http://127.0.0.1:8765/ --ios-shell ...
#   tools/game-update/serve-local.sh DIR [PORT]
#
# The apps pin only the real keys, so a test manifest is signed with the real key. Keep test revisions small: a
# phone that reads a manifest records its revision and refuses anything older, so a test manifest that reached a
# real phone with a high revision would lock it out of real updates. Its loopback URLs keep it off the public
# release (publish.sh refuses any URL outside it), and a release build refuses plain HTTP anyway.
#
# Point a debug build at it:
#   iOS Simulator: xcrun simctl spawn booted defaults write dev.audaro.runemobile RMGameUpdateURL \
#                  http://127.0.0.1:8765/game-update.json   (plus RMGameUpdateShell <40-hex> to pose as a release)
#   Android:       adb reverse tcp:8765 tcp:8765, then write the URL to the app's external files dir as
#                  game-update-url (and game-update-shell), chmod 666 so the app can read them through FUSE.
# Only debug builds accept plain HTTP, and only to 127.0.0.1 / localhost.
set -euo pipefail
DIR="${1:?usage: serve-local.sh DIR [PORT]}"
PORT="${2:-8765}"
[ -f "$DIR/game-update.json" ] || { echo "serve-local: no game-update.json in $DIR" >&2; exit 1; }
command -v adb >/dev/null && adb reverse "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1 && echo "serve-local: adb reverse tcp:$PORT set"
echo "serve-local: http://127.0.0.1:$PORT/game-update.json (Ctrl-C to stop)"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR"
