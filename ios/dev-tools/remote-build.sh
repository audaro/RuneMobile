#!/usr/bin/env bash
# remote-build.sh — runs ON the remote Mac (the one tethered to the iPhone).
#
# Does only the Mac-and-device-only steps: xcodegen -> xcodebuild -> devicectl install.
# The heavy Java compile (shaded jar, gpu jar-surgery, probe jars) is done on the DEV Mac and
# rsync'd in via deploy-remote.sh, so by the time we get here ios/app/jvm-resources/ already holds
# the staged jars. Pass --with-jars to make this box self-contained (build the jars here too).
#
# Required env:
#   DEV          devicectl device UUID of the iPhone as seen by THIS Mac (xcrun devicectl list devices)
# Optional env:
#   JAVA_HOME    default /opt/homebrew/opt/openjdk@21   (only used with --with-jars)
#   MODE         gpu | cpu   (default gpu; selects jar-surgery vs plain copy, only with --with-jars)
#   REPO         repo root   (default: two levels up from this script)
set -euo pipefail

WITH_JARS=0
[ "${1:-}" = "--with-jars" ] && WITH_JARS=1

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
MODE="${MODE:-gpu}"
# Build configuration. Default Debug (today's dev daily-driver). CONFIG=Release builds the hardened build
# (QA-P1-12/13: Documents file-sharing off, log/capture sinks compiled out, .runelite in App Support). NOTE:
# StikDebug attach / JIT under Release is device-unverified — get-task-allow comes from the dev profile so it
# should hold, but confirm on-device before relying on a Release daily-driver.
CONFIG="${CONFIG:-Debug}"
# Validate: xcodebuild matches config names case-sensitively and silently falls back to Debug on a no-match,
# while the ${CONFIG}-iphoneos product path would then miss — fail fast instead.
case "$CONFIG" in Debug|Release) ;; *) echo "CONFIG must be Debug or Release (got '$CONFIG')" >&2; exit 1 ;; esac
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO"

# Local signing config (gitignored): exports DEVELOPMENT_TEAM for xcodegen's ${DEVELOPMENT_TEAM} expansion.
[ -f ios/dev-tools/signing.env ] && . ios/dev-tools/signing.env

: "${DEV:?set DEV to the iPhone devicectl UUID (xcrun devicectl list devices)}"

# QA-P1-15: read the real version key (project.build.version, e.g. 1.12.29-SNAPSHOT). The old grep for
# `runeLiteVersion` matched nothing and silently fell back to a hardcoded 1.12.29 — breaks on the next bump.
VERSION="$(sed -n 's/^project\.build\.version=//p' gradle.properties)"
[ -n "$VERSION" ] || { echo "!! could not read project.build.version from gradle.properties" >&2; exit 1; }

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

if [ "$WITH_JARS" = 1 ]; then
  log "Building jars on remote (MODE=$MODE, VERSION=$VERSION)"
  JAVA_HOME="$JAVA_HOME" ./gradlew :client:shadowJar
  if [ "$MODE" = gpu ]; then
    ( cd ios/dev-tools/gpu-routec && JAVA_HOME="$JAVA_HOME" ./stage-ios-gpu-jar.sh )
  else
    cp "runelite-client/build/libs/client-${VERSION}-shaded.jar" ios/app/jvm-resources/client-shaded.jar
  fi
  # client-rlhd.jar is a mandatory bundled resource (project.yml) in every mode — 117HD is a selectable plugin.
  ( cd ios/dev-tools/gpu-zone && JAVA_HOME="$JAVA_HOME" ./stage-ios-zone-jar.sh )
  ( cd ios/app && JAVA_HOME="$JAVA_HOME" ./build-probes.sh )
  ( cd ios/dev-tools/gpu-routec/l1 && JAVA_HOME="$JAVA_HOME" ./build-l1-probe.sh )
fi

# Sanity: the staged shaded jar must be present (carried by rsync, or built above). Version-agnostic name
# (the stagers rename on stage) so an upstream version bump can't break this check or the bundle.
SHADED="ios/app/jvm-resources/client-shaded.jar"
[ -f "$SHADED" ] || { echo "!! staged shaded jar missing: $SHADED — run deploy with jars, or pass --with-jars" >&2; exit 1; }

log "xcodegen generate"
( cd ios/app && xcodegen generate )

log "xcodebuild (device, $CONFIG, allowProvisioningUpdates)"
xcodebuild -project ios/app/RuneMobile.xcodeproj -scheme RuneMobile -configuration "$CONFIG" \
  -destination "id=$DEV" -derivedDataPath build/dd-mui -allowProvisioningUpdates build

log "devicectl install -> $DEV"
xcrun devicectl device install app --device "$DEV" \
  "build/dd-mui/Build/Products/${CONFIG}-iphoneos/RuneMobile.app"

log "DONE — app installed on device $DEV"
echo "Next (manual, phone-side): attach StikDebug, then launch the app for per-launch JIT."
