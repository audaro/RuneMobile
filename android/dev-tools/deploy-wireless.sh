#!/usr/bin/env bash
# Build the Android app and install it onto the phone over Wi-Fi — no USB cable.
#
# One-time pairing (modern Wireless debugging, Android 11+ — survives reboot/sleep):
#   On the phone: Settings > System > Developer options > Wireless debugging > ON (tick "Always allow"),
#   then "Pair device with pairing code" to read an  ip:port  and a 6-digit code, then:
#       ./deploy-wireless.sh --pair 192.168.1.100:37000 000000
# Every run after that (no cable, auto-discovers the current endpoint via mDNS):
#       ./deploy-wireless.sh              # debug build
#       ./deploy-wireless.sh release      # signed release build
#       ./deploy-wireless.sh debug launch # install + launch
#
# Remote over Tailscale (phone NOT on this Mac's Wi-Fi — e.g. cellular/elsewhere; both on the tailnet):
#       ./deploy-wireless.sh --tailnet <port> [debug|release] [launch]
#   The tailnet IP is STABLE; the Wireless-debugging PORT is dynamic and mDNS does NOT cross Tailscale, so read
#   the port off the phone (Settings > Developer options > Wireless debugging > "IP address & Port") and pass it.
#   The port is cached, so later runs can omit it (./deploy-wireless.sh --tailnet) UNTIL the phone reboots
#   (then re-read + re-pass it). Pairing persists; keep Tailscale exempt from Android battery optimisation.
#
# Legacy fallback (cable plugged in) if mDNS/pairing isn't available:  ./deploy-wireless.sh --bootstrap
#   NOTE: the legacy `adb tcpip 5555` mode RESETS on reboot AND on deep doze (and this LAN can then return
#   "No route to host" on :5555) — prefer --pair, which uses a paired, mDNS-discovered endpoint instead.
#
# For normal (non-tailnet) runs the phone must be on the SAME Wi-Fi/LAN as this Mac.
set -euo pipefail

# --- config (override via env) ----------------------------------------------------------------------------
USB_SERIAL="${USB_SERIAL:-YOUR_DEVICE_SERIAL}"     # the device serial; also appears in its mDNS service name
DEVICE_IP="${DEVICE_IP:-192.168.1.100}"        # the phone's LAN IP (for matching + legacy fallback)
LEGACY_PHONE="${LEGACY_PHONE:-$DEVICE_IP:5555}" # legacy `adb tcpip` endpoint (fallback only)
TAILNET_HOST="${TAILNET_HOST:-100.100.100.100}"  # the phone's STABLE Tailscale IP (for --tailnet remote deploys)
TAILNET_CACHE="${TMPDIR:-/tmp}/runemobile-tailnet-port"   # last-known wireless-debug port over Tailscale
PHONE="${PHONE:-}"                              # optional explicit ip:port override (skips auto-discovery)
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
# JAVA_HOME: prefer JDK 21 (AGP needs 17+); fall back to whatever's on PATH.
if [ -z "${JAVA_HOME:-}" ]; then
  for c in /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home /opt/homebrew/opt/openjdk@21; do
    [ -x "$c/bin/java" ] && export JAVA_HOME="$c" && break
  done
fi
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$ANDROID_HOME/platform-tools:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # android/ project root
cd "$HERE"

say() { printf '\033[1;36m[deploy-wireless]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[deploy-wireless] %s\033[0m\n' "$*" >&2; exit 1; }

# Current modern Wireless-debugging connect endpoint (ip:port) for this device, discovered via mDNS — the port
# is dynamic (changes per reboot/toggle), so never hard-code it. Prefers the entry whose service name carries
# our USB_SERIAL; falls back to any advertised _adb-tls-connect, then to nothing.
discover_endpoint() {
  adb mdns services 2>/dev/null | awk -v s="$USB_SERIAL" '$0 ~ s && /_adb-tls-connect/ {print $3; exit}' \
    || true
}

# --- one-time pairing: modern Wireless debugging (preferred) -----------------------------------------------
if [ "${1:-}" = "--pair" ]; then
  command -v adb >/dev/null || die "adb not found (ANDROID_HOME=$ANDROID_HOME)"
  pep="${2:-}"; code="${3:-}"
  [ -n "$pep" ] && [ -n "$code" ] || die "usage: ./deploy-wireless.sh --pair <ip:port> <6-digit-code>  (from the phone's 'Pair device with pairing code' screen)"
  say "pairing with $pep (code times out fast)..."
  adb pair "$pep" "$code" || die "pair failed — regenerate a fresh code on the phone and retry (try 'adb kill-server' first if it says 'protocol fault')"
  sleep 1
  ep="$(discover_endpoint)"; [ -n "$ep" ] || ep="$LEGACY_PHONE"
  say "connecting to $ep..."
  adb connect "$ep" || true
  adb devices -l | grep -vE "emulator-|^List of" || true
  say "paired. Future runs auto-discover the endpoint: ./deploy-wireless.sh"
  exit 0
fi

# --- legacy bootstrap: flip the cabled phone into `adb tcpip` mode (fallback) ------------------------------
if [ "${1:-}" = "--bootstrap" ]; then
  command -v adb >/dev/null || die "adb not found (ANDROID_HOME=$ANDROID_HOME)"
  adb -s "$USB_SERIAL" get-state >/dev/null 2>&1 || die "phone $USB_SERIAL not on USB — plug in the cable and approve the debugging prompt"
  port="${LEGACY_PHONE##*:}"
  say "switching adbd to TCP/IP on port $port (over USB)... (NOTE: resets on reboot/doze — prefer --pair)"
  adb -s "$USB_SERIAL" tcpip "$port"
  say "connecting to $LEGACY_PHONE over Wi-Fi..."
  until adb connect "$LEGACY_PHONE" 2>&1 | grep -qiE "connected"; do sleep 1; done
  if adb devices | grep -qE "${LEGACY_PHONE}[[:space:]]+unauthorized"; then
    say "approve the 'Allow wireless debugging' prompt on the phone (tick 'Always allow'), then re-run --bootstrap"
  fi
  adb devices -l | grep -E "$LEGACY_PHONE|$USB_SERIAL" || true
  say "bootstrap done — you can unplug the cable."
  exit 0
fi

# --- remote over Tailscale: target the phone's stable tailnet IP (mDNS can't cross the tailnet) ------------
if [ "${1:-}" = "--tailnet" ]; then
  command -v adb >/dev/null || die "adb not found (ANDROID_HOME=$ANDROID_HOME)"
  shift
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then echo "$1" > "$TAILNET_CACHE"; shift; fi   # explicit port -> cache it
  port="$(cat "$TAILNET_CACHE" 2>/dev/null || true)"
  [ -n "$port" ] || die "no Wireless-debugging port known. Read it from the phone (Settings > Developer options > Wireless debugging > 'IP address & Port') and run: ./deploy-wireless.sh --tailnet <port> [debug|release] [launch]"
  PHONE="$TAILNET_HOST:$port"   # explicit override — ensure_connected uses it directly
  say "remote (Tailscale) target: $PHONE  — re-pass --tailnet <port> after a phone reboot (the port changes)"
  # remaining args ($1=config, $2=action) fall through to the normal run below
fi

# --- normal run: ensure the wireless link, build, install --------------------------------------------------
CONFIG="${1:-debug}"; ACTION="${2:-}"
case "$CONFIG" in
  debug)   TASK="assembleDebug" ;;
  release) TASK="assembleRelease" ;;
  *) die "unknown config '$CONFIG' (use: debug | release)" ;;
esac

ensure_connected() {
  # 1) explicit override (PHONE env or --tailnet) wins; 2) reuse an already-connected LAN transport;
  # 3) mDNS discovery; 4) legacy :5555.
  local ep="${PHONE:-}"
  if [ -z "$ep" ]; then ep="$(adb devices | awk -v ip="$DEVICE_IP" '$2=="device" && $1 ~ "^"ip":" {print $1; exit}')"; fi
  if [ -z "$ep" ]; then ep="$(discover_endpoint)"; fi
  if [ -z "$ep" ]; then ep="$LEGACY_PHONE"; fi
  if [ "$(adb -s "$ep" get-state 2>/dev/null || true)" != "device" ]; then
    say "connecting to $ep..."
    adb connect "$ep" >/dev/null 2>&1 || true
  fi
  PHONE="$ep"
  local state; state="$(adb -s "$PHONE" get-state 2>/dev/null || true)"
  case "$state" in
    device) say "wireless link up: $PHONE" ;;
    unauthorized) die "phone shows 'unauthorized' — approve the debugging prompt on the phone, then re-run" ;;
    *) die "phone not reachable (tried $PHONE). Same Wi-Fi? First time -> pair once: ./deploy-wireless.sh --pair <ip:port> <code> (Settings > Developer options > Wireless debugging > Pair device with pairing code). Legacy USB fallback: ./deploy-wireless.sh --bootstrap" ;;
  esac
}

ensure_connected

say "building :app:$TASK..."
./gradlew ":app:$TASK" -q
APK="app/build/outputs/apk/$CONFIG/app-$CONFIG.apk"
[ -f "$APK" ] || die "APK not found: $APK"

say "installing $(basename "$APK") ($(du -h "$APK" | cut -f1)) over Wi-Fi..."
adb -s "$PHONE" install -r "$APK"
adb -s "$PHONE" shell am force-stop dev.audaro.runemobile || true

if [ "$ACTION" = "launch" ]; then
  say "launching..."
  adb -s "$PHONE" shell am start -n dev.audaro.runemobile/.MainActivity >/dev/null
fi
say "done — installed on $PHONE (cable not required)."
