#!/usr/bin/env bash
# serve-ipa.sh — build the dev IPA and serve it over Tailscale HTTPS from ANY network, two ways (see
# ios/dev-tools/DEPLOY-REMOTE.md for why a direct-to-phone install can't cross the tailnet):
#   - an install page: open https://<host>.ts.net/ in Safari and tap Install, and iOS installs the build itself
#     (an itms-services manifest; the development signature is kept, so StikDebug still attaches for JIT);
#   - an AltStore/SideStore source: add https://<host>.ts.net/apps.json in SideStore once, and each run shows an
#     "Update" there (SideStore re-signs it as its own copy of the app).
#
#   ios/dev-tools/serve-ipa.sh              # reuse staged jars, build IPA, (re)start the tailnet HTTPS source
#   ios/dev-tools/serve-ipa.sh --jars       # rebuild the jars first (shaded + gpu jar-surgery + probes + l1)
#   ios/dev-tools/serve-ipa.sh --build-only # build IPA + manifest only; don't touch `tailscale serve`
#   ios/dev-tools/serve-ipa.sh --stop       # tear down: stop the static server + remove this script's tailnet handler
#
# EACH deploy: run this, then on the phone (Tailscale ON) open the printed page in Safari and tap Install.
# JIT is unchanged either way: the build is development-signed (get-task-allow), so StikDebug attaches per launch.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APPDIR="$REPO/ios/app"
WORK="$HERE/.serve-ipa"           # local-only (ignored in ios/.gitignore)
DIST="$WORK/dist"
STATE="$WORK/build.txt"
HTTPD_PID="$WORK/httpd.pid"
DD="$REPO/build/dd-serveipa"
PORT="${PORT:-8787}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"

BUILD_JARS=0; SERVE=1; STOP=0
for a in "$@"; do case "$a" in
  --jars)       BUILD_JARS=1 ;;
  --cpu)        echo "--cpu was removed: every renderer runs from the one staged jar set (picked in the plugins panel)" >&2; exit 2 ;;
  --build-only) SERVE=0 ;;
  --stop)       STOP=1 ;;
  -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
  *) echo "unknown arg: $a" >&2; exit 2 ;;
esac; done

log()  { printf '\n\033[1;35m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
mkdir -p "$WORK"

# The tailscale CLI. The standalone Mac app does not put it on PATH, and a symlink into /usr/local/bin does
# not survive a reinstall, so look inside the app bundle before giving up — the old `command -v` failure
# surfaced as "is Tailscale up?" while the tunnel was up, connected, and serving the phone.
TS="$(command -v tailscale || true)"
if [ -z "$TS" ]; then
  for c in /Applications/Tailscale.app/Contents/MacOS/Tailscale \
           "$HOME/Applications/Tailscale.app/Contents/MacOS/Tailscale"; do
    if [ -x "$c" ]; then TS="$c"; break; fi
  done
fi
# No die() here: --stop must still kill the local server when the CLI is missing, or a missing CLI leaves a
# static server serving an IPA with no way to stop it. The build path checks TS for itself, below.

# --- teardown -------------------------------------------------------------------------------------
if [ "$STOP" = 1 ]; then
  [ -f "$HTTPD_PID" ] && kill "$(cat "$HTTPD_PID")" 2>/dev/null && rm -f "$HTTPD_PID" && echo "static server stopped"
  if [ -n "$TS" ]; then
    # Only the handler this script adds, the root of the default HTTPS port. `tailscale serve reset` would also take
    # down every other service this machine shares on the tailnet, and other paths on :443 stay as they are.
    if "$TS" serve --https=443 --set-path=/ off >/dev/null 2>&1; then
      echo "tailscale serve: / on :443 removed"
    else
      echo "tailscale serve: no / handler on :443 to remove"
    fi
  else
    echo "no tailscale CLI found — local server stopped, but 'tailscale serve' was left as it is" >&2
  fi
  exit 0
fi

cd "$REPO"
# Local signing config (gitignored): exports DEVELOPMENT_TEAM for xcodegen's ${DEVELOPMENT_TEAM} expansion.
[ -f ios/dev-tools/signing.env ] && . ios/dev-tools/signing.env
[ -n "$TS" ] || die "no tailscale CLI on PATH or in /Applications/Tailscale.app — is Tailscale installed?"
FQDN="$("$TS" status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')" \
  || die "couldn't read this Mac's tailnet name (is Tailscale up?)"
[ -n "$FQDN" ] || die "empty tailnet FQDN"
# QA-P1-15: read the real version key (full version, e.g. 1.12.29-SNAPSHOT). The old grep for the non-existent
# `runeLiteVersion` key silently fell back to a hardcoded 1.12.29 — correct only by luck, broken on the next bump.
JARVER="$(sed -n 's/^project\.build\.version=//p' gradle.properties)"; [ -n "$JARVER" ] || die "could not read project.build.version from gradle.properties"
# SideStore re-signs this build and the hosted release channel's under one bundle ID, so it only offers this one as
# an update when its version is higher. Stamp <release>.<build>: the release's semver, read where
# tools/ci/build-release-artifacts.sh reads it, then this counter. 0.5.0.49 sorts above 0.5.0 and its rolling
# 0.5.0-master.N builds, and below the next release. (project.yml's MARKETING_VERSION is the bare semver, which
# would not sort above the release.)
SEMVER="$(sed -nE 's/^[[:space:]]*val verMajor = ([0-9]+).*/\1/p' android/app/build.gradle.kts | head -1)"
SEMVER="$SEMVER.$(sed -nE 's/^[[:space:]]*val verMinor = ([0-9]+).*/\1/p' android/app/build.gradle.kts | head -1)"
SEMVER="$SEMVER.$(sed -nE 's/^[[:space:]]*val verPatch = ([0-9]+).*/\1/p' android/app/build.gradle.kts | head -1)"
[[ "$SEMVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not read the release semver from android/app/build.gradle.kts (got '$SEMVER')"
BUILD="$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))"
VERSTR="${SEMVER}.${BUILD}"
# The counter is gitignored, so a fresh clone / cleaned .serve-ipa silently restarts at 1 — and a version
# LOWER than the one already on the phone is not an update, so SideStore just shows nothing to do and the
# build looks installed when it isn't. Say so rather than let it look like a successful publish.
if [ ! -f "$STATE" ]; then
  printf '\033[1;33m!! no build counter at %s — starting at %s. If the phone has a HIGHER build already (an\n   earlier worktree, or the hosted release channel), SideStore will not offer this as an update.\n   Bump it first:  echo <n> > %s\033[0m\n' "$STATE" "$BUILD" "$STATE" >&2
fi

# 1) jars (default: reuse what's staged; --jars rebuilds the same set deploy-remote.sh does) ---------
if [ "$BUILD_JARS" = 1 ]; then
  log "Rebuild jars (VERSION=$JARVER)"
  JAVA_HOME="$JAVA_HOME" ./gradlew :client:shadowJar
  ( cd ios/dev-tools/gpu-routec && JAVA_HOME="$JAVA_HOME" ./stage-ios-gpu-jar.sh )
  ( cd ios/dev-tools/gpu-zone && JAVA_HOME="$JAVA_HOME" ./stage-ios-zone-jar.sh )
  ( cd ios/app && JAVA_HOME="$JAVA_HOME" ./build-probes.sh )
  ( cd ios/dev-tools/gpu-routec/l1 && JAVA_HOME="$JAVA_HOME" ./build-l1-probe.sh )
fi
for j in client-shaded.jar client-rlhd.jar probes.jar routec-l1.jar; do
  [ -f "$APPDIR/jvm-resources/$j" ] || die "staged jar missing: $j — re-run with --jars"
done

# 2) regenerate the xcodeproj + build a device .app (no device needed; development-signed) -----------
log "xcodegen generate"
( cd "$APPDIR" && xcodegen generate >/dev/null )

# Build configuration. Default Debug (today's behaviour). CONFIG=Release builds the hardened daily-driver
# (QA-P1-12/13): Documents file-sharing off, log/capture sinks compiled out, .runelite in App Support. NOTE:
# StikDebug attach / JIT under Release is device-unverified — confirm on-device before relying on it.
CONFIG="${CONFIG:-Debug}"
case "$CONFIG" in Debug|Release) ;; *) die "CONFIG must be Debug or Release (got '$CONFIG')" ;; esac
# Signing uses the login keychain. The release script (tools/ci/build-release-artifacts.sh) puts its own build
# keychain first in the user's keychain search list, and that setting outlives the script. Left there, codesign
# picks the identity out of the build keychain, finds it locked, and waits for its password in a dialog on the
# Mac's screen with no output (2026-11-08: a 30-minute silent stall). Stop with the fix instead of changing a
# setting that belongs to the whole account.
if security list-keychains -d user | grep -qF "/build.keychain-db"; then
  die "build.keychain-db is in the keychain search list, so codesign would wait on a password dialog. Put the
   list back and rerun:  security list-keychains -d user -s \"\$HOME/Library/Keychains/login.keychain-db\""
fi
log "xcodebuild RuneMobile $VERSTR ($CONFIG, generic/iOS, signed)"
xcodebuild -project "$APPDIR/RuneMobile.xcodeproj" -scheme RuneMobile -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSTR" CURRENT_PROJECT_VERSION="$BUILD" build

APP="$DD/Build/Products/${CONFIG}-iphoneos/RuneMobile.app"
[ -d "$APP" ] || die "build produced no app at $APP"

# 3) check what the install page will hand to iOS, then package Payload/*.app -> IPA -----------------
# iOS installs this IPA with Xcode's signature as it is, so nothing may touch the bundle after the build (the version
# comes in on the build line; Info.plist reads it), the signature has to verify, and the profile has to be current
# and carry get-task-allow for StikDebug's JIT attach. iOS refuses an install it can't verify and gives no reason,
# so each of these stops the publish instead.
log "check the signature and profile"
rm -rf "$DIST/Payload"; mkdir -p "$DIST/Payload"
cp -R "$APP" "$DIST/Payload/"
PAPP="$DIST/Payload/RuneMobile.app"
GOTVER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PAPP/Info.plist")"
[ "$GOTVER" = "$VERSTR" ] || die "the app says version '$GOTVER', not $VERSTR — does Info.plist still read \$(MARKETING_VERSION)?"
GOTBUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PAPP/Info.plist")"
[ "$GOTBUILD" = "$BUILD" ] || die "the app says build '$GOTBUILD', not $BUILD — does Info.plist still read \$(CURRENT_PROJECT_VERSION)?"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$PAPP/Info.plist")"
codesign --verify --deep --strict "$PAPP" || die "the app's signature does not verify, so iOS would refuse the install"
security cms -D -i "$PAPP/embedded.mobileprovision" -o "$WORK/profile.plist" 2>/dev/null \
  || die "could not decode the app's provisioning profile"
FACTS="$(python3 - "$WORK/profile.plist" <<'PY'
import datetime, plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
devices = p.get("ProvisionedDevices") or []
expires = p["ExpirationDate"]  # naive UTC
days = (expires - datetime.datetime.now(datetime.UTC).replace(tzinfo=None)).days
jit = p.get("Entitlements", {}).get("get-task-allow") is True
print(len(devices), expires.date(), days, "yes" if jit else "no")
PY
)" || die "could not read the app's provisioning profile"
read -r NDEV EXPIRES DAYS JIT <<< "$FACTS"
[ "$NDEV" -gt 0 ] 2>/dev/null || die "the profile provisions no devices, so no phone will install this build"
[ "$DAYS" -ge 0 ] 2>/dev/null || die "the profile expired on $EXPIRES; iOS would refuse the install without saying why"
[ "$JIT" = yes ] || die "the profile has no get-task-allow, so StikDebug could not attach for JIT"
echo "profile: $NDEV device(s), expires $EXPIRES ($DAYS days), get-task-allow on"
if [ "$DAYS" -lt 14 ]; then
  printf '\033[1;33m!! the profile expires in %s days; after that this IPA installs on nothing\033[0m\n' "$DAYS" >&2
fi

log "package IPA"
( cd "$DIST" && rm -f RuneLite.ipa && zip -qry RuneLite.ipa Payload && rm -rf Payload )
SIZE="$(stat -f%z "$DIST/RuneLite.ipa")"
echo "$BUILD" > "$STATE"   # only burn the build number on success

# 4) icons, the install page + its itms-services manifest, and the AltStore/SideStore source --------
ICON="$REPO/docs/brand/runemobile-icon.png"
sips -z 57 57 "$ICON" --out "$DIST/icon-57.png" >/dev/null || die "could not size the icon"
sips -z 512 512 "$ICON" --out "$DIST/icon-512.png" >/dev/null || die "could not size the icon"
COMMIT="$(git rev-parse --short HEAD)"
git diff --quiet HEAD -- . || COMMIT="$COMMIT+local changes"
python3 - "$DIST" "$FQDN" "$VERSTR" "$SIZE" "$BUILD" "$ICON" "$BUNDLE_ID" "$COMMIT" <<'PY'
import sys, json, datetime, os, shutil, html, plistlib, urllib.parse
dist, fqdn, ver, size, build, icon = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6]
bundle_id, commit = sys.argv[7], sys.argv[8]
shutil.copyfile(icon, os.path.join(dist, "icon.png"))
base = "https://" + fqdn

# The install page's manifest: iOS fetches it, then the IPA, over the tailnet's TLS (it needs a trusted certificate,
# which tailscale serve has for the MagicDNS name).
with open(os.path.join(dist, "manifest.plist"), "wb") as f:
    plistlib.dump({"items": [{
        "assets": [
            {"kind": "software-package", "url": base + "/RuneLite.ipa"},
            {"kind": "display-image", "url": base + "/icon-57.png"},
            {"kind": "full-size-image", "url": base + "/icon-512.png"},
        ],
        # bundle-version is the app's CFBundleVersion, the build number, not the marketing version.
        "metadata": {"bundle-identifier": bundle_id, "bundle-version": build, "kind": "software", "title": "RuneMobile"},
    }]}, f)
install = html.escape("itms-services://?action=download-manifest&url="
                      + urllib.parse.quote(base + "/manifest.plist", safe=""), quote=True)
e = lambda v: html.escape(str(v))
page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Install RuneMobile</title>
<link rel="apple-touch-icon" href="icon-512.png">
<style>
  :root {{ color-scheme: light dark; --accent: #E8620C; }}
  body {{ font: 17px/1.3 system-ui, -apple-system, sans-serif; margin: 0; min-height: 100vh; box-sizing: border-box;
         display: grid; place-items: center; padding: 24px 16px; }}
  main {{ max-width: 21rem; width: 100%; text-align: center; }}
  img {{ width: 96px; height: 96px; border-radius: 22px; }}
  h1 {{ font-size: 1.6rem; margin: 0.75rem 0 0; }}
  dl {{ display: grid; grid-template-columns: auto auto; gap: 0.25rem 1rem; justify-content: center;
       margin: 1.25rem 0 1.5rem; font-size: 0.9rem; }}
  dt {{ text-align: right; opacity: 0.6; }}
  dd {{ text-align: left; margin: 0; font-variant-numeric: tabular-nums; }}
  a.install {{ display: block; padding: 0.95rem; border-radius: 0.8rem; background: var(--accent); color: #fff;
              font-weight: 600; font-size: 1.05rem; text-decoration: none; }}
  p.note {{ font-size: 0.8rem; opacity: 0.65; margin: 1.25rem 0 0; line-height: 1.45; text-align: left; }}
  code {{ font-size: 0.75rem; word-break: break-all; }}
</style>
</head>
<body>
<main>
  <img src="icon-512.png" alt="">
  <h1>RuneMobile</h1>
  <dl>
    <dt>version</dt><dd>{e(ver)}</dd>
    <dt>commit</dt><dd>{e(commit)}</dd>
    <dt>size</dt><dd>{size / 1048576:.0f} MB</dd>
    <dt>published</dt><dd>{datetime.datetime.now().strftime("%Y-%m-%d %H:%M")}</dd>
  </dl>
  <a class="install" href="{install}">Install</a>
  <p class="note">Open this page in Safari with Tailscale on: other browsers don't hand the link to iOS. Installing
  replaces the RuneMobile dev app in place, so your login and settings stay; SideStore's copy is a separate app.
  Launch it through StikDebug as always, for JIT.</p>
  <p class="note">SideStore source: <code>{e(base)}/apps.json</code></p>
</main>
</body>
</html>
"""
open(os.path.join(dist, "index.html"), "w").write(page)

manifest = {
  "name": "RuneLite iOS (dev)",
  "identifier": "dev.audaro.source",
  "sourceURL": base + "/apps.json",
  "apps": [{
    "name": "RuneLite",
    "bundleIdentifier": "dev.audaro.runemobile",
    "developerName": "Jordan Simpson",
    "subtitle": "RuneLite on iOS (on-device JVM)",
    "version": ver,
    "versionDate": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "versionDescription": "Dev build " + ver,
    "downloadURL": base + "/RuneLite.ipa",
    "localizedDescription": "RuneLite on iOS via an on-device JVM. Personal dev build #" + build + ".",
    "iconURL": base + "/icon.png",
    "tintColor": "E8620C",
    "size": size,
    "permissions": []
  }]
}
open(os.path.join(dist, "apps.json"), "w").write(json.dumps(manifest, indent=2))
PY

# 5) serve dist over the tailnet via HTTPS (local static server + tailscale serve port-proxy) ------
if [ "$SERVE" = 1 ]; then
  log "serve over Tailscale HTTPS"
  [ -f "$HTTPD_PID" ] && kill "$(cat "$HTTPD_PID")" 2>/dev/null || true
  # The page is one port for the whole Mac, so a server another checkout (a worktree) left running keeps serving
  # ITS build: the new server dies on the bind, and the phone installs the old IPA while this one looks published.
  sleep 0.3
  holder="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  if [ -n "$holder" ]; then
    die "port $PORT is still held by pid $holder: $(ps -o command= -p "$holder" | cut -c1-200)
   The install page would serve that build, not $VERSTR. Stop it (kill $holder, or --stop from its checkout), then rerun."
  fi
  # range/resume-capable static server (stdlib http.server ignores Range -> a flaky phone tunnel can't resume)
  nohup python3 "$HERE/serve-static.py" "$DIST" "$PORT" >"$WORK/httpd.log" 2>&1 &
  echo $! > "$HTTPD_PID"; disown 2>/dev/null || true
  sleep 1
  # Up, and serving THIS build: an answer from the port alone could still be someone else's page.
  served="$(curl -fsS --max-time 5 "http://127.0.0.1:$PORT/apps.json" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["apps"][0]["version"])' 2>/dev/null || true)"
  kill -0 "$(cat "$HTTPD_PID")" 2>/dev/null && [ "$served" = "$VERSTR" ] \
    || die "the static server isn't serving $VERSTR (it answers '${served:-nothing}'); see $WORK/httpd.log"
  "$TS" serve --bg "$PORT" >/dev/null
fi

printf '\n\033[1;32m=== built RuneLite %s (%d MB) ===\033[0m\n' "$VERSTR" "$(( SIZE / 1048576 ))"
printf '  IPA      %s\n' "$DIST/RuneLite.ipa"
printf '  manifest %s\n' "$DIST/apps.json"
if [ "$SERVE" = 1 ]; then
  printf '  install  https://%s/   <- open in Safari on the phone and tap Install\n' "$FQDN"
  printf '  source   https://%s/apps.json   <- or add this in SideStore -> Sources (once)\n' "$FQDN"
  printf '  download https://%s/RuneLite.ipa\n' "$FQDN"
  printf '\nStatic server backgrounded (pid %s); stop with: %s --stop\n' "$(cat "$HTTPD_PID")" "$0"
fi
printf '\nPhone (Tailscale ON): open the install page in Safari -> Install (or SideStore -> Update to %s).\n' "$VERSTR"
printf 'Then attach StikDebug and launch for per-launch JIT (unchanged).\n'
