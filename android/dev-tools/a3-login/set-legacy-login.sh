#!/usr/bin/env bash
# Set up legacy (non-Jagex) username/password autologin for the Android emulator client.
#
# Prompts for the account credentials (password hidden), saves them OUTSIDE the repo
# (~/.config/runelite-ios/legacy_login.json, chmod 600), and pushes the file to the emulator's
# app-external files dir. The app reads it at every boot: LegacyCreds maps it to the
# RL_LEGACY_USER/RL_LEGACY_PASS env and HeadlessLogin's legacy stage types it into the classic
# login form — so every emulator launch logs straight in. The file persists on the emulator,
# so this only needs re-running when the credentials change or the AVD is wiped.
#
# NOTE: a tokens.json (Jagex session) on the device WINS over legacy credentials. This script
# moves any pushed tokens.json aside (tokens.json.bak) so the legacy account takes effect.
#
# Usage: ./set-legacy-login.sh [-s SERIAL]   (default serial: emulator-5554)
set -euo pipefail

SERIAL="${2:-emulator-5554}"
[ "${1:-}" = "-s" ] && SERIAL="$2"

PKG=dev.audaro.runemobile
DEVDIR="/sdcard/Android/data/$PKG/files"
CFGDIR="$HOME/.config/runelite-ios"
CFG="$CFGDIR/legacy_login.json"

read -r -p "OSRS username (legacy account): " RL_USER
read -r -s -p "Password: " RL_PASS; echo
[ -n "$RL_USER" ] && [ -n "$RL_PASS" ] || { echo "!! username/password must be non-empty" >&2; exit 1; }

mkdir -p "$CFGDIR"
umask 177
python3 - "$RL_USER" "$RL_PASS" > "$CFG" <<'EOF'
import json, sys
print(json.dumps({"username": sys.argv[1], "password": sys.argv[2]}))
EOF
chmod 600 "$CFG"
echo "saved: $CFG (chmod 600)"

adb -s "$SERIAL" shell "[ -f $DEVDIR/tokens.json ] && mv $DEVDIR/tokens.json $DEVDIR/tokens.json.bak && echo 'moved device tokens.json -> tokens.json.bak (legacy creds now win)' || true"
adb -s "$SERIAL" push "$CFG" "$DEVDIR/legacy_login.json" >/dev/null
echo "pushed: $DEVDIR/legacy_login.json on $SERIAL"
echo "done — restart the app (it reads the file at boot):"
echo "  adb -s $SERIAL shell am force-stop $PKG && adb -s $SERIAL shell am start -n $PKG/.MainActivity"
