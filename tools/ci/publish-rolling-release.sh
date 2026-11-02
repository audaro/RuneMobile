#!/usr/bin/env bash
# publish-rolling-release.sh — publish the built artifacts as an immutable per-build prerelease on this repo
# (audaro/runemobile), atomically. The hosted build runs on every merge to master and this step publishes the
# APK/IPA/jit-script to the repo's Releases page.
#
# ATOMICITY: each merge gets its OWN immutable prerelease, tag `master-<BUILD_NUMBER>`. It is created as a
# DRAFT (invisible), ALL assets are uploaded to the draft, and only then is it flipped to published in a single
# `gh release edit --draft=false` — an atomic metadata change. So a failed/cancelled publish can only ever
# leave an invisible, incomplete draft (cleaned up by retention); users never see a half-uploaded or
# mixed-version release. The newest prerelease at the top of the Releases page IS "latest master"; old rolling
# builds are pruned to $RETAIN. Tagged `v*` semver releases are never touched.
#
# Auth: needs a token with contents:write on $PUBLISH_REPO as $PUBLISH_TOKEN (preferred) or $GH_TOKEN. Since
# the build and the release live on the same repo, the workflow's built-in GITHUB_TOKEN suffices. Never written to disk.
#
# Usage:
#   PUBLISH_TOKEN=<pat> tools/ci/publish-rolling-release.sh [DIST_DIR]
#
# Env knobs:
#   PUBLISH_REPO   target repo (default: audaro/runemobile)
#   TAG_PREFIX     rolling tag prefix (default: master → tags master-<BUILD_NUMBER>)
#   RETAIN         how many rolling prereleases to keep (default: 5; older ones + their tags are deleted)
#   PRERELEASE     1 = mark prerelease (default: 1)
#   BUILD_DATE     human timestamp for the notes (default: `date -u`)
#   TARGET_COMMIT  commit the new tag points at (default: master; the workflow passes the commit it built)
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
DIST="${1:-${DIST:-$ROOT/dist/ci}}"
PUBLISH_REPO="${PUBLISH_REPO:-audaro/runemobile}"
TAG_PREFIX="${TAG_PREFIX:-master}"
RETAIN="${RETAIN:-5}"
PRERELEASE="${PRERELEASE:-1}"
BUILD_DATE="${BUILD_DATE:-$(date -u '+%Y-%m-%d %H:%M UTC')}"
TARGET_COMMIT="${TARGET_COMMIT:-master}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }

[ -f "$DIST/manifest.env" ] || die "no manifest.env in $DIST — run build-release-artifacts.sh first"
# Read manifest.env as data, never source it. In the hosted pipeline it comes from the build job, which runs
# third-party build code, while this script holds a token that can write releases: sourcing the file would run
# whatever that build wrote, with the token. Each value must match a strict pattern (printf %q, which wrote the
# file, leaves such values unquoted); DIST is ignored, since it names the build runner's path.
manifest_value() {	# <key> <extended regex>
	local v
	v="$(sed -n "s/^$1=//p" "$DIST/manifest.env" | head -1)"
	[[ "$v" =~ $2 ]] || die "manifest.env: $1='$v' does not match $2"
	printf '%s' "$v"
}
VERSION="$(manifest_value VERSION '^[0-9]+\.[0-9]+\.[0-9]+(-master\.[0-9]+)?$')"
BUILD_NUMBER="$(manifest_value BUILD_NUMBER '^[0-9]+$')"
GIT_SHA="$(manifest_value GIT_SHA '^([0-9a-f]{4,40}|unknown)$')"
RUNELITE_VERSION="$(manifest_value RUNELITE_VERSION '^[0-9A-Za-z._+-]*$')"
APK_FINGERPRINT="$(manifest_value APK_FINGERPRINT '^([0-9a-f]{64})?$')"

export GH_TOKEN="${PUBLISH_TOKEN:-${GH_TOKEN:-}}"
[ -n "$GH_TOKEN" ] || die "no PUBLISH_TOKEN / GH_TOKEN — need a token with contents:write on $PUBLISH_REPO"
command -v gh >/dev/null || die "gh CLI not found"

TAG="${TAG_PREFIX}-${BUILD_NUMBER}"

# Collect the assets that exist (Android-only runs won't have an .ipa). Immutable release → keep the versioned
# names; each release is separate, so there is no asset-accumulation problem.
ASSETS=()
for f in "RuneMobile-${VERSION}.apk" "RuneMobile-${VERSION}.ipa" "runelite-jit.js"; do
	[ -f "$DIST/$f" ] && ASSETS+=("$DIST/$f")
done
[ "${#ASSETS[@]}" -gt 0 ] || die "no assets found in $DIST for version $VERSION"
# Same guard as publish-stable-release.sh: no provisioning profile (name, Apple ID email, team, device UDIDs) and no
# certificate left in a binary's signature space. A public release must never carry either.
IPA="$DIST/RuneMobile-${VERSION}.ipa"
if [ -f "$IPA" ]; then
	"$ROOT/tools/ci/check-ipa-clean.sh" "$IPA" || die "$IPA carries the developer's identity — rebuild with IOS_ADHOC=1 (the default)"
fi

FP_LINE=""
# RuneLite base: present in manifests written by current build-release-artifacts.sh; older ones omit it,
# so the line is simply left out rather than printing an empty value.
RL_LINE=""
[ -n "${RUNELITE_VERSION:-}" ] && RL_LINE=$'\n'"- RuneLite base: \`${RUNELITE_VERSION}\`"
[ -n "${APK_FINGERPRINT:-}" ] && FP_LINE=$'\nAPK signer SHA-256: `'"${APK_FINGERPRINT}"'` (verify with `apksigner verify --print-certs`)'

# GIT_SHA is the master commit this build was cut from — a public, auditable reference on this repo.
NOTES="Automated build of RuneMobile from \`master\` (one immutable prerelease per merge).

- Version: \`${VERSION}\`
- Commit: \`${GIT_SHA}\`
- Built: ${BUILD_DATE}${RL_LINE}${FP_LINE}

The newest prerelease here is the latest \`master\` build; older rolling builds are pruned automatically. For a
stable, curated build use a tagged \`v*\` release instead.

Install instructions are in the [README](../../blob/master/README.md). RuneMobile is an unofficial, self-built
client and is not on the approved-client list for live Old School RuneScape — use a throwaway account."

PRE_FLAG=(); [ "$PRERELEASE" = 1 ] && PRE_FLAG=(--prerelease)

# A re-run of the SAME build number replaces its own release — delete it first (only ever this exact version,
# never a different live one, so no other release has a gap).
if gh release view "$TAG" --repo "$PUBLISH_REPO" >/dev/null 2>&1; then
	echo ">> $TAG already exists — deleting to republish this build"
	gh release delete "$TAG" --repo "$PUBLISH_REPO" --yes --cleanup-tag 2>/dev/null || true
fi

# 1) Create as a DRAFT (invisible) and upload ALL assets to it.
echo ">> creating draft $TAG on $PUBLISH_REPO and uploading ${#ASSETS[@]} assets"
gh release create "$TAG" --repo "$PUBLISH_REPO" --target "$TARGET_COMMIT" --draft ${PRE_FLAG[@]+"${PRE_FLAG[@]}"} \
	--title "RuneMobile ${VERSION}" --notes "$NOTES"
gh release upload "$TAG" --repo "$PUBLISH_REPO" "${ASSETS[@]}"

# 2) Atomically publish (single metadata flip). Up to here nothing was visible; if a step above failed the
#    draft stays hidden + incomplete and is reaped by retention below on the next run.
echo ">> publishing $TAG (atomic un-draft)"
gh release edit "$TAG" --repo "$PUBLISH_REPO" --draft=false

# 3) Retention: keep the newest $RETAIN rolling prereleases (tags matching <prefix>-<number>), delete older
#    ones + any stale drafts. Deleting an OLD release never affects the one just published.
echo ">> pruning rolling prereleases to the newest $RETAIN"
gh release list --repo "$PUBLISH_REPO" --limit 100 --json tagName \
	--jq '.[].tagName' 2>/dev/null \
	| grep -E "^${TAG_PREFIX}-[0-9]+$" \
	| sort -t- -k2,2 -n -r \
	| tail -n +"$((RETAIN + 1))" \
	| while IFS= read -r old; do
		[ -n "$old" ] || continue
		# Report the ACTUAL outcome. This used to echo "deleting $old" BEFORE trying, send stderr to
		# /dev/null and swallow the exit with `|| true` — so a prune that deleted nothing logged exactly
		# like one that worked (observed on master-1024: it claimed to delete master-1019, which is still
		# there with all 3 assets). Still non-fatal: a failed prune must not fail an otherwise-good
		# publish — but it now says so instead of lying.
		if err="$(gh release delete "$old" --repo "$PUBLISH_REPO" --yes --cleanup-tag 2>&1)"; then
			echo "   deleted $old"
		else
			echo "   !! prune FAILED for $old (left in place): ${err//$'\n'/ }" >&2
		fi
	done

echo ">> published: https://github.com/$PUBLISH_REPO/releases/tag/$TAG"
