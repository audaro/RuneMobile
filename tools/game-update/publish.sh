#!/usr/bin/env bash
# publish.sh - put a make-manifest.py output live for the apps (docs/GAME-UPDATES-PLAN.md, local).
#
#   tools/game-update/publish.sh DIR            # dry run: check DIR and say what would change
#   tools/game-update/publish.sh DIR --apply    # upload, then re-read the live manifest and verify it
#
# DIR holds game-update.json, game-update.json.sig and the jar assets it names. The assets go to the `game-update`
# prerelease of the PUBLIC repo (created on first use). Every phone running a build that a set names takes it at its
# next launch, so this is a release in all but name. Order: the jars first, then the signature and the manifest,
# so a manifest never names a file that isn't there yet. A phone that reads the new manifest with the old signature
# in that window refuses both and tries again later. Afterwards assets that no set names any more are deleted.
#
# Refuses: a manifest whose signature doesn't verify with the key the apps pin first (or the spare), a revision not
# above the live one, a file whose size or hash doesn't match, a URL that isn't this release's.
set -euo pipefail

REPO_SLUG="${PUBLISH_REPO:-audaro/runemobile}"
TAG="game-update"
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
BASE_URL="https://github.com/$REPO_SLUG/releases/download/$TAG/"

die() { echo "publish: $*" >&2; exit 1; }
log() { echo "publish: $*"; }

DIR="${1:-}"
APPLY=0
[ "${2:-}" = "--apply" ] && APPLY=1
[ -n "$DIR" ] && [ -d "$DIR" ] || die "usage: publish.sh DIR [--apply]"
[ -f "$DIR/game-update.json" ] && [ -f "$DIR/game-update.json.sig" ] || die "$DIR has no game-update.json + .sig"
command -v gh >/dev/null || die "gh is not installed"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The keys the apps pin, as PEM, from the same source make-manifest.py checks.
python3 - "$ROOT" "$WORK" <<'EOF'
import base64, importlib.util, sys, textwrap
root, work = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("mm", f"{root}/tools/game-update/make-manifest.py")
mm = importlib.util.module_from_spec(spec); spec.loader.exec_module(mm)
ios, android = mm.app_pins()
if len(ios) != 2 or ios != android:
    sys.exit("publish: the apps' pinned keys disagree")
for i, p in enumerate(ios):
    with open(f"{work}/pin{i}.pem", "w") as f:
        f.write("-----BEGIN PUBLIC KEY-----\n" + "\n".join(textwrap.wrap(p, 64)) + "\n-----END PUBLIC KEY-----\n")
EOF

verify() { # verify JSON SIG: signed by a pinned key?
	local p
	for p in "$WORK/pin0.pem" "$WORK/pin1.pem"; do
		openssl dgst -sha256 -verify "$p" -signature "$2" "$1" >/dev/null 2>&1 && return 0
	done
	return 1
}

verify "$DIR/game-update.json" "$DIR/game-update.json.sig" || die "the local manifest's signature doesn't verify with a pinned key"

# The assets the manifest names: each must be in DIR with the right size and hash, under this release's URL.
python3 - "$DIR" "$BASE_URL" >"$WORK/assets" <<'EOF'
import hashlib, json, os, sys
d, base = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(d, "game-update.json")))
print(m["revision"])
for s in m["sets"]:
    for f in s["files"]:
        url = f["url"]
        if not url.startswith(base):
            sys.exit(f"publish: {url} is not under {base}")
        asset = url[len(base):]
        p = os.path.join(d, asset)
        if "/" in asset or not os.path.isfile(p):
            sys.exit(f"publish: {asset} is not in {d}")
        h = hashlib.sha256(open(p, "rb").read()).hexdigest()
        if os.path.getsize(p) != f["size"] or h != f["sha256"]:
            sys.exit(f"publish: {asset} doesn't match the manifest")
        print(asset)
    print(f"  set {s['id']}: {s['port']} build {s['shell'][:12]}, game revision {s['gameRevision']}", file=sys.stderr)
EOF
NEW_REV="$(head -1 "$WORK/assets")"
tail -n +2 "$WORK/assets" | sort -u >"$WORK/names"
log "local manifest: revision $NEW_REV, $(wc -l <"$WORK/names" | tr -d ' ') assets"

# The live manifest, if any: the new revision must be above it, or every phone that saw it refuses this one.
LIVE_REV=0
if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
	if gh release download "$TAG" --repo "$REPO_SLUG" --pattern 'game-update.json' --dir "$WORK/live" >/dev/null 2>&1; then
		LIVE_REV="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$WORK/live/game-update.json")"
	fi
	gh release view "$TAG" --repo "$REPO_SLUG" --json assets --jq '.assets[].name' | sort >"$WORK/live-names"
	log "live: release $TAG exists, manifest revision $LIVE_REV"
else
	: >"$WORK/live-names"
	log "live: no $TAG release yet (it will be created as a prerelease)"
fi
[ "$NEW_REV" -gt "$LIVE_REV" ] || die "revision $NEW_REV is not above the live $LIVE_REV (make-manifest.py --revision $((LIVE_REV + 1)))"

STALE="$(comm -23 "$WORK/live-names" <(sort -u "$WORK/names" <(printf 'game-update.json\ngame-update.json.sig\n')) || true)"
if [ "$APPLY" != 1 ]; then
	log "dry run: would upload $(wc -l <"$WORK/names" | tr -d ' ') assets + the manifest, then delete: ${STALE:-nothing}"
	log "re-run with --apply to publish"
	exit 0
fi

if ! gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
	gh release create "$TAG" --repo "$REPO_SLUG" --prerelease --target master --title "Game update files" \
		--notes "Files the apps download by themselves when the game updates. Nothing here to install by hand." >/dev/null
	log "created prerelease $TAG"
fi
# shellcheck disable=SC2046
(cd "$DIR" && gh release upload "$TAG" --repo "$REPO_SLUG" --clobber $(cat "$WORK/names"))
(cd "$DIR" && gh release upload "$TAG" --repo "$REPO_SLUG" --clobber game-update.json.sig game-update.json)
log "uploaded"

# Read it back the way a phone does (through the CDN, which can lag a few seconds) and check it is ours.
for i in $(seq 1 20); do
	rm -rf "$WORK/back"; mkdir -p "$WORK/back"
	curl -fsSL -o "$WORK/back/m.json" "${BASE_URL}game-update.json" && curl -fsSL -o "$WORK/back/m.sig" "${BASE_URL}game-update.json.sig" &&
		cmp -s "$WORK/back/m.json" "$DIR/game-update.json" && verify "$WORK/back/m.json" "$WORK/back/m.sig" && break
	[ "$i" = 20 ] && die "the live manifest still isn't the new one after 20 tries: check $BASE_URL by hand"
	sleep 3
done
log "live manifest verified: revision $NEW_REV"
while read -r name; do
	[ -n "$name" ] || continue
	gh release delete-asset "$TAG" "$name" --repo "$REPO_SLUG" --yes >/dev/null && log "deleted old asset $name"
done <<<"$STALE"
log "done"
