#!/usr/bin/env bash
#
# ONE-TIME setup: copy your Android signing key + the iOS JRE into GitHub, so releases build fully hosted.
#
#   Run this ONCE. After it finishes, every release happens on GitHub with your computer completely out of the
#   loop — click Merge, GitHub rebuilds both apps and publishes them. Re-run only if the Android key changes.
#
# Only Android needs a real signing key (the APK installs directly). The iOS IPA is ad-hoc-signed in CI and
# re-signed on-device by AltStore/SideStore at install, so there is NO Apple cert, profile, or team to upload.
#
# What it does (nothing is printed to screen or written to the repo):
#   • reads the Android keystore from your local ~/.runemobile-ci and uploads it as 2 secrets
#   • uploads the ~166 MB iOS JRE as the `ios-jre-dep` release asset the workflow fetches
#
# Requirements: gh CLI logged in with admin on the repo (`gh auth login`), run from the repo root on your Mac.
#
set -euo pipefail

REPO="${REPO:-audaro/runemobile}"                       # the public repo that will build releases
CI_CONFIG_DIR="${CI_CONFIG_DIR:-$HOME/.runemobile-ci}"  # where your local signing config lives
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── preflight ─────────────────────────────────────────────────────────────────────────────────────────────
command -v gh >/dev/null      || die "gh CLI not found — install with: brew install gh"
gh auth status >/dev/null 2>&1 || die "not logged in — run: gh auth login"
gh repo view "$REPO" >/dev/null 2>&1 || die "cannot access $REPO with the current gh login (need admin)"
[ -d "$CI_CONFIG_DIR" ] || die "no local signing config at $CI_CONFIG_DIR (set CI_CONFIG_DIR=… if it moved)"
say "Target repo: $REPO"
echo

set_secret() { # <name>  (value on stdin)
  gh secret set "$1" --repo "$REPO" >/dev/null && ok "secret $1"
}

# ── 1. Android keystore ───────────────────────────────────────────────────────────────────────────────────
say "Android keystore"
KP="$CI_CONFIG_DIR/keystore.properties"
[ -f "$KP" ] || die "missing $KP"
JKS_RAW="$(sed -n 's/^[[:space:]]*storeFile[[:space:]]*=[[:space:]]*//p' "$KP" | head -1)"
[ -n "$JKS_RAW" ] || die "no storeFile= line in $KP"
# resolve the keystore path: as-is (absolute), then relative to the config dir, then relative to android/
if   [ -f "$JKS_RAW" ];                    then JKS="$JKS_RAW"
elif [ -f "$CI_CONFIG_DIR/$JKS_RAW" ];     then JKS="$CI_CONFIG_DIR/$JKS_RAW"
elif [ -f "android/$JKS_RAW" ];            then JKS="android/$JKS_RAW"
else die "storeFile '$JKS_RAW' from $KP not found — edit the path or set it and re-run"; fi
base64 < "$JKS" | set_secret ANDROID_KEYSTORE_B64
# the properties MINUS storeFile — the workflow re-adds storeFile as the runner's absolute path
grep -v '^[[:space:]]*storeFile[[:space:]]*=' "$KP" | set_secret ANDROID_KEYSTORE_PROPERTIES
echo

# NOTE: iOS needs NO signing material here. The IPA is ad-hoc-signed in CI and re-signed on-device by
# AltStore/SideStore at install, so there's no Apple cert, profile, team, or keychain to upload — only the
# Android release key (above) and the iOS JRE build input (below).

# ── 2. iOS JRE → release asset ────────────────────────────────────────────────────────────────────────────
say "iOS JRE build dependency (~166 MB)"
JRE_SRC="$CI_CONFIG_DIR/ios-jre"
[ -f "$JRE_SRC/lib/libjvm.dylib" ] || JRE_SRC="ios/dev-tools/jre"
[ -f "$JRE_SRC/lib/libjvm.dylib" ] || die "no iOS JRE found (looked for lib/libjvm.dylib in $CI_CONFIG_DIR/ios-jre and ios/dev-tools/jre)"
echo "  packing $JRE_SRC …"
tar czf "$TMP/jre.tar.gz" -C "$(dirname "$JRE_SRC")" "$(basename "$JRE_SRC")"
ok "packed ($(du -h "$TMP/jre.tar.gz" | cut -f1))"
if gh release view ios-jre-dep --repo "$REPO" >/dev/null 2>&1; then
  gh release upload ios-jre-dep "$TMP/jre.tar.gz" --repo "$REPO" --clobber >/dev/null
else
  gh release create ios-jre-dep "$TMP/jre.tar.gz" --repo "$REPO" --prerelease \
    --title "iOS JRE build dependency" \
    --notes "Build input fetched by release-hosted.yml. Not an app release. OpenJDK build (GPLv2+CE)." >/dev/null
fi
ok "uploaded as the ios-jre-dep release asset"
echo

say "Done — GitHub now has everything it needs to build and sign on its own."
echo "  Next: enable Actions on $REPO, then run the 'release-hosted' workflow (Actions tab → Run workflow)"
echo "  to prove a signed APK + IPA come out. After that, flipping it to run on every merge is a one-line change."
