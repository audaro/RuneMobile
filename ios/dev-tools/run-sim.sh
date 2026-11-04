#!/usr/bin/env bash
# run-sim.sh — build RuneMobile for the iOS Simulator, install it and launch it. No phone and no StikDebug: the
# simulator build retags the bundled JRE for the simulator (app/scripts/resign-jre.sh) and services HotSpot's JIT
# breakpoint in-process (JVMLauncher.m, simJitArm).
#
#   ios/dev-tools/run-sim.sh                 # build Debug, install, launch and press Play
#   ios/dev-tools/run-sim.sh --jars          # rebuild + stage the jars first (after a Java change)
#   ios/dev-tools/run-sim.sh --no-build      # reinstall + relaunch the last simulator build
#   ios/dev-tools/run-sim.sh --manual        # launch to the Play cover and wait for a click
#   ios/dev-tools/run-sim.sh --player-login  # log in as a player does: no automatic Play Now, no forced world
#   ios/dev-tools/run-sim.sh --from-phone    # start from the paired phone's settings (below)
#   ios/dev-tools/run-sim.sh --desktop-login # log the simulator in with the desktop harness's Jagex session (below)
#   ios/dev-tools/run-sim.sh --logout        # remove the simulator's Jagex session
#   ios/dev-tools/run-sim.sh --no-launch     # build + install only (callers that launch with their own arguments)
#   ios/dev-tools/run-sim.sh --print-udid    # print the simulator this script would use, and stop
#   RENDERER=gpu ios/dev-tools/run-sim.sh    # cpu (default) | gpu | 117hd, for this launch only
#   SIM_NAME="iPhone 17 Pro Max" (default) or SIM_UDID=<udid> picks the simulator.
#
# --from-phone copies the phone app's settings over the simulator's before launch, so the simulator starts the way
# the phone does: the native UI settings (pinned keys, renderer, layout notice), the active RuneLite profile
# (plugins, their config, the Plugin Hub list) and the game's own preferences (login music and the like). It copies
# those files and nothing else; the login (tokens, RuneLite session) stays on the phone, so the simulator is logged
# out. The phone must be paired with this Mac and reachable (cable or the same network). The renderer follows the
# phone's unless RENDERER is set. PHONE_UDID=<id> picks the phone, PHONE_BUNDLE_ID the app on it (a SideStore
# install has its own bundle ID). The copy is kept in build/sim-phone-state/phone, and the simulator settings it
# replaced in build/sim-phone-state/sim-before.
#
# --desktop-login copies the session from the desktop harness's tokens file (TOKENS, default
# ios/dev-tools/tokens.json, minted by fetch-shield-tokens.sh) into the app, where the in-app login would write it:
# session_id, chosen_account_id and chosen_display_name only. The launcher access/refresh tokens are left out,
# because with them set the game server refuses the login. The simulator stays logged in across reinstalls until
# --logout. Use a throwaway account, and don't run the desktop harness on the same account at the same time: one
# session kicks the other.
#
# What the simulator does NOT tell you: performance (Mac CPU, no memory cap, no thermals), the device JIT path
# (StikDebug), GPU driver quirks of the phone (GPU modes draw with Apple's software renderer), real multi-touch,
# and background/PiP behaviour. Check those on the phone. With no memory cap, os_proc_available_memory() is 0
# here, so the residency log's "0MB free" lines mean nothing.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro Max}"
RENDERER="${RENDERER:-}"
case "$RENDERER" in ''|cpu|gpu|117hd) ;; *) echo "RENDERER must be cpu, gpu or 117hd (got '$RENDERER')" >&2; exit 1 ;; esac
BUNDLE_ID=dev.audaro.runemobile
DERIVED="$REPO/build/dd-sim"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/RuneMobile.app"
STATE="$REPO/build/sim-phone-state"
# Paths inside the app's data container that --from-phone copies (with the settings plist).
PROFILES=Documents/.runelite/profiles2
LIVE=Documents/.runelite/jagexcache/oldschool/LIVE

BUILD=yes
JARS=no
AUTOPLAY=YES
AUTOLOGIN=YES
FROM_PHONE=no
LAUNCH=yes
PRINT_UDID=no
LOGIN=keep
for a in "$@"; do
  case "$a" in
    --jars)       JARS=yes ;;
    --no-build)   BUILD=no ;;
    --manual)     AUTOPLAY=NO ;;
    --player-login) AUTOLOGIN=NO ;;
    --from-phone) FROM_PHONE=yes ;;
    --no-launch)  LAUNCH=no ;;
    --print-udid) PRINT_UDID=yes ;;
    --desktop-login) LOGIN=desktop ;;
    --logout)     LOGIN=out ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

log() { printf '\n\033[1;35m>> %s\033[0m\n' "$*"; }
die() { echo "!! $*" >&2; exit 1; }
cd "$REPO"

# 1) Pick the simulator: an explicit UDID, else the first available device with this exact name.
if [ -z "${SIM_UDID:-}" ]; then
  SIM_UDID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name:
            print(d["udid"])
            sys.exit(0)
' "$SIM_NAME")" || true
fi
[ -n "${SIM_UDID:-}" ] || { echo "!! no available simulator named '$SIM_NAME' (set SIM_NAME or SIM_UDID)" >&2; exit 1; }
[ "$PRINT_UDID" = no ] || { echo "$SIM_UDID"; exit 0; }
log "Simulator $SIM_NAME ($SIM_UDID)"
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
open -a Simulator --args -CurrentDeviceUDID "$SIM_UDID"

# 2) --from-phone: copy the phone's settings now, so a phone that can't be reached fails before the build.
if [ "$FROM_PHONE" = yes ]; then
  PHONE_BUNDLE_ID="${PHONE_BUNDLE_ID:-$BUNDLE_ID}"
  rm -rf "$STATE/phone"
  mkdir -p "$STATE/phone"
  if [ -z "${PHONE_UDID:-}" ]; then
    xcrun devicectl list devices -t 60 -q --json-output "$STATE/devices.json" >/dev/null || die "devicectl can't list devices"
    PHONE_UDID="$(/usr/bin/python3 -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("deviceType") == "iPhone" and d["connectionProperties"].get("pairingState") == "paired":
        print(d["identifier"])
        break
' "$STATE/devices.json")"
  fi
  [ -n "$PHONE_UDID" ] || die "no paired iPhone (pair it in Xcode's Devices and Simulators window, or set PHONE_UDID)"
  log "Copy settings from the phone ($PHONE_UDID, app $PHONE_BUNDLE_ID)"
  phone_get() { # <path in the phone's container> <path under $STATE/phone>
    xcrun devicectl device copy from --device "$PHONE_UDID" --domain-type appDataContainer \
      --domain-identifier "$PHONE_BUNDLE_ID" --source "$1" --destination "$STATE/phone/$2" -t 60 -q >/dev/null ||
      die "could not copy $1 from the phone (unlocked and reachable? has the app there reached the login screen?)"
  }
  # The plist is named after the bundle ID on each side.
  phone_get "Library/Preferences/$PHONE_BUNDLE_ID.plist" "Library/Preferences/$BUNDLE_ID.plist"
  phone_get "$LIVE/preferences.dat" "$LIVE/preferences.dat"
  phone_get "$LIVE/preferences2.dat" "$LIVE/preferences2.dat"
  # From profiles2, only profiles.json and the profile files: the directory also holds RuneLite's temp files.
  xcrun devicectl device info files --device "$PHONE_UDID" --domain-type appDataContainer \
    --domain-identifier "$PHONE_BUNDLE_ID" --subdirectory "$PROFILES" -t 60 -q \
    --json-output "$STATE/profiles2.json" >/dev/null || die "could not list $PROFILES on the phone"
  names="$(/usr/bin/python3 -c '
import json, sys
for f in json.load(open(sys.argv[1]))["result"]["files"]:
    n = f["relativePath"]
    if not f["resources"]["isDirectory"] and "/" not in n and (n == "profiles.json" or n.endswith(".properties")):
        print(n)
' "$STATE/profiles2.json")"
  while IFS= read -r n; do
    [ -z "$n" ] || phone_get "$PROFILES/$n" "$PROFILES/$n"
  done <<<"$names"

  plutil -lint -s "$STATE/phone/Library/Preferences/$BUNDLE_ID.plist" || die "the phone's settings plist doesn't parse"
  [ -f "$STATE/phone/$PROFILES/profiles.json" ] || die "the phone has no $PROFILES/profiles.json"
  # RuneLite loads the active profile from <name>-<id>.properties (ProfileManager). Profiles synced from a RuneLite
  # account have no local file, so only the active one has to be there.
  /usr/bin/python3 -c '
import json, os, sys
active = [p for p in json.load(open(os.path.join(sys.argv[1], "profiles.json")))["profiles"] if p.get("active")]
if len(active) != 1:
    sys.exit("profiles.json has %d active profiles, expected 1" % len(active))
f = "%s-%s.properties" % (active[0]["name"], active[0]["id"])
if not os.path.isfile(os.path.join(sys.argv[1], f)):
    sys.exit("the active profile %s is not among the copied files" % f)
' "$STATE/phone/$PROFILES" || die "the phone's RuneLite profiles can't be used as they are"

  if [ -z "$RENDERER" ]; then
    RENDERER="$(plutil -extract rendererPref raw "$STATE/phone/Library/Preferences/$BUNDLE_ID.plist" 2>/dev/null || true)"
    case "$RENDERER" in cpu|gpu|117hd) ;; *) die "the phone's rendererPref is '$RENDERER'; set RENDERER=cpu|gpu|117hd" ;; esac
  fi
fi
RENDERER="${RENDERER:-cpu}"

# 3) Jars (only on request: the staged ones are reused otherwise). Same steps as deploy-remote.sh's local build.
if [ "$JARS" = yes ]; then
  log "Jar build + staging"
  JAVA_HOME="$JAVA_HOME" ./gradlew :client:shadowJar
  ( cd ios/dev-tools/gpu-routec && JAVA_HOME="$JAVA_HOME" ./stage-ios-gpu-jar.sh )
  ( cd ios/dev-tools/gpu-zone && JAVA_HOME="$JAVA_HOME" ./stage-ios-zone-jar.sh )
  ( cd ios/app && JAVA_HOME="$JAVA_HOME" ./build-probes.sh )
fi

# 4) Build for the simulator. No provisioning: simulator builds sign ad-hoc.
if [ "$BUILD" = yes ]; then
  # Local signing config (gitignored): exports DEVELOPMENT_TEAM for xcodegen's ${DEVELOPMENT_TEAM} expansion.
  # shellcheck disable=SC1091
  [ -f ios/dev-tools/signing.env ] && . ios/dev-tools/signing.env
  log "xcodegen generate"
  ( cd ios/app && xcodegen generate )
  log "xcodebuild (simulator, Debug)"
  xcodebuild -project ios/app/RuneMobile.xcodeproj -scheme RuneMobile -configuration Debug \
    -destination "id=$SIM_UDID" -derivedDataPath "$DERIVED" build -quiet
fi
[ -d "$APP" ] || { echo "!! no simulator build at $APP (run without --no-build)" >&2; exit 1; }

# 5) Install + launch. Launch arguments land in NSUserDefaults' argument domain, which wins over the app's own
#    saved values for this launch only: rendererPref picks the renderer, RMAutoPlay presses Play.
if [ "$LAUNCH" = yes ]; then log "Install + launch (renderer $RENDERER, autoplay $AUTOPLAY)"; else log "Install"; fi
xcrun simctl install "$SIM_UDID" "$APP"
# RuneLite's audio startup enumerates input devices, which raises the first-run microphone prompt over the game.
# Answer it the way a phone that has been through first run already has, so an unattended run's screenshots show
# the game. To see the prompt again: xcrun simctl privacy <udid> reset microphone dev.audaro.runemobile
xcrun simctl privacy "$SIM_UDID" grant microphone "$BUNDLE_ID"
if [ "$FROM_PHONE" = yes ]; then
  # The app must not be running (it would save its own settings back over the copy), and the simulator's cfprefsd
  # serves the old plist from its cache until it restarts.
  DATA="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)"
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
  rm -rf "$STATE/sim-before"
  for p in "Library/Preferences/$BUNDLE_ID.plist" "$PROFILES" "$LIVE/preferences.dat" "$LIVE/preferences2.dat"; do
    [ ! -e "$DATA/$p" ] || ditto "$DATA/$p" "$STATE/sim-before/$p"
  done
  # Replace profiles2 whole, so the simulator's own profile files don't linger next to the phone's.
  rm -rf "${DATA:?}/$PROFILES"
  ditto "$STATE/phone" "$DATA"
  rc=0
  xcrun simctl spawn "$SIM_UDID" launchctl kill SIGKILL user/foreground/com.apple.cfprefsd.xpc.daemon 2>/dev/null || rc=$?
  # 3 = not running, so nothing is cached either.
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || die "could not restart the simulator's cfprefsd (launchctl $rc): the app would read its old settings"
  echo "   Settings now match the phone's (the simulator's previous ones: $STATE/sim-before)."
fi
if [ "$LOGIN" != keep ]; then
  # Where JVMLauncher's +tokensPath reads and the in-app login writes.
  TOKENS_DST="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)/Library/Application Support/tokens.json"
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" 2>/dev/null || true
  if [ "$LOGIN" = out ]; then
    rm -f "$TOKENS_DST"
    echo "   Logged out: the simulator has no Jagex session."
  else
    TOKENS="${TOKENS:-$HERE/tokens.json}"
    [ -f "$TOKENS" ] || die "no desktop session at $TOKENS (mint one with ios/dev-tools/fetch-shield-tokens.sh)"
    mkdir -p "$(dirname "$TOKENS_DST")"
    /usr/bin/python3 - "$TOKENS" "$TOKENS_DST" <<'PY' || die "could not copy the desktop session"
import json, os, sys
src, dst = sys.argv[1], sys.argv[2]
t = json.load(open(src))
keep = {k: t[k] for k in ("session_id", "chosen_account_id", "chosen_display_name") if isinstance(t.get(k), str) and t[k]}
if "session_id" not in keep or "chosen_account_id" not in keep:
    sys.exit(f"{src} has no session_id/chosen_account_id")
fd = os.open(dst + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(keep, f)
os.replace(dst + ".tmp", dst)
PY
    echo "   Logged in with the desktop session from $TOKENS (fetched $(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("fetched_at", "?"))' "$TOKENS"))."
  fi
fi
if [ "$LAUNCH" = no ]; then
  echo "   Installed on $SIM_UDID; not launched (--no-launch)."
  exit 0
fi
xcrun simctl launch --terminate-running-process "$SIM_UDID" "$BUNDLE_ID" \
  -rendererPref "$RENDERER" -RMAutoPlay "$AUTOPLAY" -RMAutoLogin "$AUTOLOGIN"

DOCS="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)/Documents"
log "Running. Logs: $DOCS/jvm-stdio.log and $DOCS/hello-shell.log"
echo "   A fresh install downloads the game cache first (~40 MB): expect ~30 s to the login screen, ~7 s after that."
echo "   Screenshot: xcrun simctl io $SIM_UDID screenshot <file.png>"
