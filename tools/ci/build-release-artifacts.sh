#!/usr/bin/env bash
# build-release-artifacts.sh — build the shippable RuneMobile APK + IPA in one pass, ready to publish.
#
# This script IS the build (the CI workflow, .github/workflows/release-hosted.yml, supplies its inputs and
# calls it — same "script is the source of truth" convention as android/dev-tools/ci/release-gate.sh). It is
# fully runnable on a developer Mac, so the pipeline has real, reproducible evidence outside GitHub Actions.
#
# What it produces (into $DIST, default dist/ci):
#   RuneMobile-<version>.apk   release-signed APK (real 45:E3 keystore when configured, else debug key)
#   RuneMobile-<version>.ipa   Payload IPA. Default (IOS_ADHOC=1): built unsigned then ad-hoc-sealed with the
#                              codesign tool + app entitlements applied from source. SideStore/AltStore re-sign
#                              the whole bundle on install, so this signature is disposable. IOS_ADHOC=0
#                              team-signs instead, which embeds the developer's provisioning profile (name,
#                              Apple ID email, team, device UDIDs): never publish that one; both publish
#                              scripts refuse it.
#   runelite-jit.js            the StikDebug JIT launch template, copied verbatim
#   manifest.env              version / sha / apk fingerprint, sourced by publish-rolling-release.sh
#
# Secrets never live in the repo: on a Mac they stay in $HOME, and in CI the release-hosted workflow writes them
# from its GitHub secrets. Config is read from $CI_CONFIG_DIR
# (default ~/.runemobile-ci): keystore.properties, signing.env (DEVELOPMENT_TEAM), keychain.pw.
# See tools/ci/README.md for the one-time setup.
#
# Usage:
#   tools/ci/build-release-artifacts.sh                 # build both ports (needs macOS for iOS)
#   PLATFORMS=android tools/ci/build-release-artifacts.sh   # APK only (e.g. a Linux runner)
#   REUSE_JARS=1 tools/ci/build-release-artifacts.sh    # skip the heavy iOS jar rebuild if already staged
#   BUILD_NUMBER=42 GIT_SHA=abc1234 tools/ci/build-release-artifacts.sh   # stamp a rolling build id
#
# Env knobs (all optional):
#   PLATFORMS      space list of "android" "ios" (default: "android ios" on macOS, "android" elsewhere)
#   BUILD_NUMBER   monotonic build number (default: 0 for a local build; CI passes github.run_number)
#   GIT_SHA        short commit sha for the version-name suffix (default: `git rev-parse --short HEAD`)
#   REUSE_JARS     1 = reuse already-staged ios/app/jvm-resources jars instead of rebuilding them
#   IOS_ADHOC      1 = ad-hoc-seal the IPA (default); 0 = team-sign it with DEVELOPMENT_TEAM (local use only)
#   DIST           output directory (default: <repo>/dist/ci)
#   CI_CONFIG_DIR  signing/config dir (default: ~/.runemobile-ci)
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd "$ROOT"

DIST="${DIST:-$ROOT/dist/ci}"
CI_CONFIG_DIR="${CI_CONFIG_DIR:-$HOME/.runemobile-ci}"
BUILD_NUMBER="${BUILD_NUMBER:-0}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
REUSE_JARS="${REUSE_JARS:-0}"
IOS_ADHOC="${IOS_ADHOC:-1}"

# Default platform set: iOS needs Xcode, so only attempt it on macOS.
if [ -z "${PLATFORMS:-}" ]; then
	if [ "$(uname -s)" = "Darwin" ]; then PLATFORMS="android ios"; else PLATFORMS="android"; fi
fi

log()  { printf '\n\033[1;35m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# The commit both apps stamp (iOS Info.plist RMSourceCommit, Android BuildConfig.SOURCE_COMMIT). Game updates are
# published per exact commit (tools/game-update/), so a build from a tree with modified tracked files stamps
# "<sha>-dirty" and takes none. Say so loudly: a stable release from a dirty tree can never be updated.
SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$SOURCE_COMMIT" != unknown ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	SOURCE_COMMIT="$SOURCE_COMMIT-dirty"
	printf '::warning::tracked files are modified: this build stamps %s and takes no game updates\n' "$SOURCE_COMMIT" >&2
fi

# ── Version scheme ────────────────────────────────────────────────────────────────────────────────────
# Semver base comes from android/app/build.gradle.kts (single source of truth). Rolling CI builds append a
# -master.<N> suffix and use a versionCode base of 1_000_000 + N so every merge-built APK is strictly newer
# than the last AND stays above the semver-derived range (which maxes at 99*10000+99*100+99 = 999999).
SEMVER="$(sed -nE 's/^[[:space:]]*val verMajor = ([0-9]+).*/\1/p;' android/app/build.gradle.kts | head -1)"
_mn="$(sed -nE 's/^[[:space:]]*val verMinor = ([0-9]+).*/\1/p;' android/app/build.gradle.kts | head -1)"
_pt="$(sed -nE 's/^[[:space:]]*val verPatch = ([0-9]+).*/\1/p;' android/app/build.gradle.kts | head -1)"
SEMVER="${SEMVER}.${_mn}.${_pt}"
[ "$SEMVER" != ".." ] || die "could not parse semver from android/app/build.gradle.kts"

if [ "$BUILD_NUMBER" -gt 0 ] 2>/dev/null; then
	VERSION="${SEMVER}-master.${BUILD_NUMBER}"
	VERSION_CODE=$(( 1000000 + BUILD_NUMBER ))
	VERSION_NAME_SUFFIX="-master.${BUILD_NUMBER}+${GIT_SHA}"
else
	VERSION="$SEMVER"
	VERSION_CODE=""              # empty → gradle uses the plain semver code
	VERSION_NAME_SUFFIX=""
fi
JARVER="$(sed -n 's/^project\.build\.version=//p' gradle.properties)"; [ -n "$JARVER" ] || die "no project.build.version"

log "RuneMobile build — version=$VERSION  code=${VERSION_CODE:-semver}  sha=$GIT_SHA  jars=$JARVER  platforms=[$PLATFORMS]"
rm -rf "$DIST"; mkdir -p "$DIST"
# Canonicalize DIST to an absolute path: the IPA-packaging step cd's into a work dir before zipping to $DIST,
# so a relative DIST (e.g. DIST=dist/release-0.1.0) would resolve against the wrong cwd and fail.
DIST="$(cd "$DIST" && pwd)"

# ── Config (secrets stay in $HOME) ────────────────────────────────────────────────────────────────────
# android/keystore.properties selects the release signing key (absent → gradle falls back to the debug key,
# so a keyless run still builds an installable-but-differently-signed APK). Copy it in from the CI config
# dir if the working tree doesn't already carry it (a fresh runner checkout won't have the gitignored file).
if [ ! -f android/keystore.properties ] && [ -f "$CI_CONFIG_DIR/keystore.properties" ]; then
	cp "$CI_CONFIG_DIR/keystore.properties" android/keystore.properties
	log "staged android/keystore.properties from $CI_CONFIG_DIR"
fi

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
[ -x "$JAVA_HOME/bin/java" ] || die "JAVA_HOME has no java: $JAVA_HOME (set JAVA_HOME to an OpenJDK 21)"
export JAVA_HOME
GRADLEW=(./gradlew --no-daemon --console=plain)

wants() { case " $PLATFORMS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── Android ───────────────────────────────────────────────────────────────────────────────────────────
if wants android; then
	log "Android :app:assembleRelease (self-stages JRE + jars + native)"
	GRADLE_ARGS=()
	[ -n "$VERSION_CODE" ] && GRADLE_ARGS+=("-PversionCodeOverride=$VERSION_CODE")
	[ -n "$VERSION_NAME_SUFFIX" ] && GRADLE_ARGS+=("-PversionNameSuffix=$VERSION_NAME_SUFFIX")
	# ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty — a plain "${arr[@]}" trips `set -u`
	# on bash 3.2 (macOS's /bin/bash) for an empty array, which is exactly the no-BUILD_NUMBER (semver) path.
	( cd android && "${GRADLEW[@]}" :app:assembleRelease ${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"} ) || die "assembleRelease failed"
	APK="android/app/build/outputs/apk/release/app-release.apk"
	[ -f "$APK" ] || die "no app-release.apk emitted"
	cp "$APK" "$DIST/RuneMobile-${VERSION}.apk"
	log "→ $DIST/RuneMobile-${VERSION}.apk ($(du -h "$APK" | cut -f1))"
fi

# ── iOS (macOS only) ──────────────────────────────────────────────────────────────────────────────────
APK_FP=""
if wants ios; then
	[ "$(uname -s)" = "Darwin" ] || die "iOS build requested but not on macOS"
	have xcodegen  || die "xcodegen not found (brew install xcodegen)"
	have xcodebuild || die "xcodebuild not found (install Xcode)"
	[ -f "$CI_CONFIG_DIR/signing.env" ] && . "$CI_CONFIG_DIR/signing.env" || { [ -f ios/dev-tools/signing.env ] && . ios/dev-tools/signing.env; }
	# IOS_ADHOC=1 (the default, and what every published build uses) ad-hoc-signs instead of team-signing: the IPA
	# is re-signed on-device by AltStore/SideStore at install, so the build needs no Apple account/cert/team — it
	# only emits a valid bundle.
	if [ "$IOS_ADHOC" != 1 ]; then
		[ -n "${DEVELOPMENT_TEAM:-}" ] || die "DEVELOPMENT_TEAM unset — add it to $CI_CONFIG_DIR/signing.env"
	fi

	APPDIR="ios/app"
	# 0) The embedded JRE (ios/dev-tools/jre) is verified + patched local state (patch-jre-txm.sh) — NOT
	#    reproducible from a URL, so a fresh workspace seeds it from the CI config dir.
	#    One-time seed:  cp -R <dev-checkout>/ios/dev-tools/jre ~/.runemobile-ci/ios-jre
	if [ ! -f ios/dev-tools/jre/lib/server/libjvm.dylib ]; then
		[ -d "$CI_CONFIG_DIR/ios-jre" ] || die "ios/dev-tools/jre missing and no seed at $CI_CONFIG_DIR/ios-jre (see tools/ci/README.md)"
		log "Seed ios/dev-tools/jre from $CI_CONFIG_DIR/ios-jre"
		rm -rf ios/dev-tools/jre
		cp -R "$CI_CONFIG_DIR/ios-jre" ios/dev-tools/jre
	fi

	# 1) Stage the 4 embedded jars (shaded client + rlhd + probes + routec-l1). Staged names are
	#    version-agnostic (client-shaded.jar / client-rlhd.jar) so the tracked references in project.yml +
	#    JVMLauncher.m survive upstream version bumps; the stagers read version-precise SOURCE jars.
	#    REUSE_JARS trusts whatever is staged — a local fast path only; CI never sets it.
	NEED_JARS=1
	if [ "$REUSE_JARS" = 1 ]; then
		NEED_JARS=0
		for j in client-shaded.jar client-rlhd.jar probes.jar routec-l1.jar; do
			[ -f "$APPDIR/jvm-resources/$j" ] || NEED_JARS=1
		done
	fi
	if [ "$NEED_JARS" = 1 ]; then
		log "Stage iOS jars (shadowJar + gpu-routec + gpu-zone + probes + l1)"
		# Clear first: the workspace persists across runs, and an orphaned jar from a prior naming/version
		# would otherwise sit in jvm-resources forever (harmless to the bundle, confusing to debug).
		rm -f "$APPDIR"/jvm-resources/*.jar
		"${GRADLEW[@]}" :client:shadowJar || die "shadowJar failed"
		( cd ios/dev-tools/gpu-routec && JAVA_HOME="$JAVA_HOME" ./stage-ios-gpu-jar.sh ) || die "stage-ios-gpu-jar failed"
		( cd ios/dev-tools/gpu-zone && JAVA_HOME="$JAVA_HOME" ./stage-ios-zone-jar.sh ) || die "stage-ios-zone-jar failed"
		( cd "$APPDIR" && JAVA_HOME="$JAVA_HOME" ./build-probes.sh ) || die "build-probes failed"
		( cd ios/dev-tools/gpu-routec/l1 && JAVA_HOME="$JAVA_HOME" ./build-l1-probe.sh ) || die "build-l1-probe failed"
	else
		log "Reusing already-staged iOS jars"
	fi
	for j in client-shaded.jar client-rlhd.jar probes.jar routec-l1.jar; do
		[ -f "$APPDIR/jvm-resources/$j" ] || die "staged jar missing: $j"
	done

	# 2) Unlock the dedicated build keychain so codesign works from a non-interactive (service/tmux) session.
	#    (The login keychain may be locked or out of the search list under a launchd runner.)
	if [ -f "$CI_CONFIG_DIR/keychain.pw" ] && [ -f "$HOME/Library/Keychains/build.keychain-db" ]; then
		security unlock-keychain -p "$(cat "$CI_CONFIG_DIR/keychain.pw")" "$HOME/Library/Keychains/build.keychain-db"
		security list-keychains -d user -s "$HOME/Library/Keychains/build.keychain-db" "$HOME/Library/Keychains/login.keychain-db" >/dev/null
		log "build.keychain unlocked + in search list"
	fi

	# 3) Generate the xcodeproj and build a signed device .app (no device needed).
	log "xcodegen generate"
	( cd "$APPDIR" && xcodegen generate >/dev/null ) || die "xcodegen failed"
	DD="$APPDIR/build/dd-ci"
	# CFBundleVersion floors to 1: a semver build has BUILD_NUMBER=0, but 0 reads as a build-number regression
	# vs any prior release (and `${BUILD_NUMBER:-1}` yields 0 since 0 is set, not empty). Rolling builds keep run #.
	IOS_BUILD="$BUILD_NUMBER"; [ "$IOS_BUILD" -gt 0 ] 2>/dev/null || IOS_BUILD=1
	if [ "$IOS_ADHOC" = 1 ]; then
		# Build UNSIGNED: the iOS SDK rejects ad-hoc ("-") code signing at xcodebuild time
		# ("Ad Hoc code signing is not allowed with SDK 'iOS NN'") — that guard is xcodebuild's, not the
		# codesign tool's. So emit an unsigned bundle here (no Apple cert/keychain/team needed) and ad-hoc-seal
		# the whole tree with `codesign` post-build (step 4). SideStore re-signs everything on-device at install.
		log "xcodebuild RuneMobile (Release, generic/iOS, unsigned — ad-hoc sealed post-build; SideStore re-signs on install)"
		IOS_SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= CODE_SIGN_ENTITLEMENTS= PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM=)
	else
		log "xcodebuild RuneMobile (Release, generic/iOS, signed)"
		IOS_SIGN_ARGS=(-allowProvisioningUpdates)
	fi
	xcodebuild -project "$APPDIR/RuneMobile.xcodeproj" -scheme RuneMobile -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath "$DD" "${IOS_SIGN_ARGS[@]}" \
		MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$IOS_BUILD" build || die "xcodebuild failed"
	APP="$DD/Build/Products/Release-iphoneos/RuneMobile.app"
	[ -d "$APP" ] || die "no .app produced at $APP"
	STAMPED="$(/usr/libexec/PlistBuddy -c "Print :RMSourceCommit" "$APP/Info.plist" 2>/dev/null || echo none)"
	[ "$STAMPED" = "$SOURCE_COMMIT" ] || die "the app stamps source commit '$STAMPED', expected '$SOURCE_COMMIT' (app/scripts/stamp-source-commit.sh)"

	# 4) Package Payload/*.app -> IPA and stamp the version. xcodebuild already took MARKETING_VERSION (Info.plist
	#    reads it); the stamp pins the packaged plist whatever the build settings did. SideStore re-signs on
	#    install, so touching the bundle is harmless.
	log "package IPA"
	WORK="$DIST/ipa-work"; rm -rf "$WORK"; mkdir -p "$WORK/Payload"
	cp -R "$APP" "$WORK/Payload/"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $IOS_BUILD" \
		"$WORK/Payload/RuneMobile.app/Info.plist" >/dev/null
	# xcodebuild built the bundle UNSIGNED (the iOS SDK forbids ad-hoc signing at build time). The codesign
	# TOOL has no such SDK restriction, so ad-hoc-seal the whole tree here. --deep is deliberately AVOIDED: it
	# only descends recognized code (frameworks/appex/standard dirs), so it skips the loose Mach-Os the embedded
	# JRE ships under the nonstandard jre/ resource dir, and its --entitlements scope is ambiguous. Instead sign
	# nested code FIRST and WITHOUT entitlements (they belong only on the app's main executable), then the app
	# wrapper WITH entitlements — the same nested-first contract the self-hosted path's resign-jre.sh follows.
	# SideStore reads the app-executable entitlements to request increased-memory-limit when it re-signs
	# on-device (its dev profile injects get-task-allow); this also replaces the seal the plist stamp broke.
	# (Guarded to IOS_ADHOC so the team-signed IOS_ADHOC=0 path keeps Xcode's signature untouched.)
	if [ "$IOS_ADHOC" = 1 ]; then
		ENTS="$APPDIR/RuneMobile/RuneMobile.entitlements"
		[ -f "$ENTS" ] || die "entitlements file missing: $ENTS"
		APPB="$WORK/Payload/RuneMobile.app"
		# Every signature is REMOVED before the ad-hoc one goes on. `codesign --force` writes the new, smaller
		# signature into the old one's space and leaves the rest of the old bytes, so a binary that arrived
		# team-signed (an incremental Xcode build can reuse a JRE copy a device build signed) kept the old
		# certificate, with the team ID and Apple ID email, inside the IPA. The first 0.7.1 IPA shipped 40 such JRE
		# binaries. --remove-signature cuts those bytes off, and is a no-op on an unsigned file.
		# 1) Embedded frameworks/dylibs (e.g. ANGLE) — CODE_SIGNING_ALLOWED=NO left these unsigned; --deep would
		#    have caught them, but sign explicitly so nothing depends on --deep's discovery rules.
		if [ -d "$APPB/Frameworks" ]; then
			while IFS= read -r -d '' fw; do
				codesign --remove-signature "$fw" || die "remove signature failed: $fw"
				codesign --force --sign - --timestamp=none "$fw" || die "ad-hoc sign framework failed: $fw"
			done < <(find "$APPB/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0)
		fi
		# 2) Every remaining Mach-O in the bundle (the embedded JRE's lib/*.dylib + bin/* execs), except the
		#    app's own main executable (signed last, with entitlements) and the Frameworks handled above.
		while IFS= read -r -d '' f; do
			case "$f" in "$APPB/RuneMobile"|"$APPB/Frameworks/"*) continue;; esac
			file -b "$f" | grep -q "Mach-O" || continue
			codesign --remove-signature "$f" || die "remove signature failed: $f"
			codesign --force --sign - --timestamp=none "$f" || die "ad-hoc sign nested failed: $f"
		done < <(find "$APPB" -type f \( -name '*.dylib' -o -perm -u+x \) -print0)
		# 3) Finally the app wrapper WITH entitlements.
		codesign --remove-signature "$APPB/RuneMobile" || die "remove signature failed: $APPB/RuneMobile"
		codesign --force --sign - --generate-entitlement-der --entitlements "$ENTS" "$APPB" || die "ad-hoc sign app failed"
		# --deep --strict verifies recursively: every nested component signed above must validate, not just the
		# wrapper. (Everything is explicitly signed, so strict passes; a failure here is a real seal defect.)
		codesign --verify --deep --strict "$APPB" || die "ad-hoc signature verify failed"
		# Nothing identifying may be left: no profile, no .xcent, no certificate text in any file.
		"$ROOT/tools/ci/check-ipa-clean.sh" "$APPB" || die "the sealed app still carries the developer's identity (see above)"
		# The dump proves what the CI artifact declares — but the CI signature is disposable: SideStore strips it
		# and re-signs on-device, and MAY filter entitlements against its own generated profile. Whether
		# increased-memory-limit actually survives that re-sign is a DEVICE-INSTALL assertion (see needs-device).
		log "ad-hoc IPA entitlements (disposable CI seal; a SideStore device install must confirm these survive):"
		codesign -d --entitlements :- "$APPB" 2>/dev/null || true
	fi
	( cd "$WORK" && zip -qry "$DIST/RuneMobile-${VERSION}.ipa" Payload )
	rm -rf "$WORK"
	log "→ $DIST/RuneMobile-${VERSION}.ipa ($(du -h "$DIST/RuneMobile-${VERSION}.ipa" | cut -f1))"
fi

# ── The StikDebug JIT template rides along with every iOS release ──────────────────────────────────────
cp ios/app/stikdebug/runelite-jit.js "$DIST/runelite-jit.js"

# ── Fingerprint the APK for the release notes / signing verification ──────────────────────────────────
if wants android; then
	APKSIGNER="$(command -v apksigner || true)"
	if [ -z "$APKSIGNER" ]; then
		for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
			[ -n "$d" ] || continue
			c="$(ls "$d"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)"; [ -n "$c" ] && APKSIGNER="$c" && break
		done
	fi
	[ -n "$APKSIGNER" ] && APK_FP="$("$APKSIGNER" verify --print-certs "$DIST/RuneMobile-${VERSION}.apk" 2>/dev/null | sed -nE 's/.*SHA-256 digest: ([0-9a-f]+).*/\1/p' | head -1)"

	# A missing keystore.properties makes gradle silently fall back to the debug key. That is fine for a local
	# keyless build, but a PUBLISHED build MUST carry the documented release cert (README apksigner fingerprint) —
	# a debug-signed APK breaks user `apksigner verify` trust AND can't upgrade a release-signed install. So when
	# REQUIRE_RELEASE_KEY=1 (a local stable build sets it), refuse to proceed unless the cert matches. The hosted
	# pipeline builds with the debug key on purpose and re-signs in a separate job, which checks the same
	# constant (.github/workflows/release-hosted.yml, also android/dev-tools/ci/release-gate.sh Stage 2b).
	EXPECTED_RELEASE_FP="45e305844d53a6265dc86eb399be997ab3fa2776f90f18b16fd4ec90f43d3c9e"
	if [ "${REQUIRE_RELEASE_KEY:-0}" = 1 ]; then
		[ -n "$APKSIGNER" ] || die "REQUIRE_RELEASE_KEY=1 but apksigner not found — cannot verify the signing cert"
		[ "$APK_FP" = "$EXPECTED_RELEASE_FP" ] || die "APK is NOT signed with the release key (got '${APK_FP:-none}', expected 45:E3…). \
Refusing to build a publishable artifact with the wrong/debug key — check $CI_CONFIG_DIR/keystore.properties."
		log "signing verified: release cert 45:E3… ✓"
	fi
fi

# ── Manifest for the publish step ─────────────────────────────────────────────────────────────────────
# Written with printf %q so it is safe to `source` even if a value contains spaces or shell metacharacters
# (e.g. a DIST path with a space) — a bare KEY=value here would break parsing or allow injection when sourced.
{
	printf 'VERSION=%q\n'        "$VERSION"
	printf 'BUILD_NUMBER=%q\n'   "$BUILD_NUMBER"
	printf 'GIT_SHA=%q\n'        "$GIT_SHA"
	# The full commit both apps stamp, which game-update sets are published for.
	printf 'SOURCE_COMMIT=%q\n'  "$SOURCE_COMMIT"
	# The upstream RuneLite the jars were built from, so a published build states which client it IS.
	printf 'RUNELITE_VERSION=%q\n' "$JARVER"
	printf 'APK_FINGERPRINT=%q\n' "$APK_FP"
	printf 'DIST=%q\n'           "$DIST"
} > "$DIST/manifest.env"

# AltStore/SideStore source manifest. Only meaningful when an IPA was built (iOS-only or both); an
# Android-only build has nothing to advertise, so skip it rather than publish a feed pointing at no file.
if [ -f "$DIST/RuneMobile-$VERSION.ipa" ]; then
	log "AltStore source manifest"
	"$ROOT/tools/ci/make-altstore-source.sh" "$DIST"
fi

log "DONE — artifacts in $DIST:"
ls -la "$DIST" | sed 's/^/    /'
