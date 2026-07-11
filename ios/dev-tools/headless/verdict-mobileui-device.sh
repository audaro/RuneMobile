#!/usr/bin/env bash
# Phase-6 (W3) STEP-0 DEVICE confirm for MobileUiBridge. The device app boots real RuneLite headless and —
# with the JVMLauncher opts -Drunelite.mobileui=true + -Drunelite.mobileui.smoke=true + the surgical
# -ea:...PluginManager — runs MobileUiSmokeRunner's daemon, logging MUI_* to Documents/jvm-stdio.log.
#
# Device launches are USER-DRIVEN (per-launch StikDebug attach). This script just pulls the verbatim log via
# devicectl into a slot and, once two launches are captured, computes the SAME md5-gated verdict as desktop
# (mobileui-verdict.sh) — including cross-launch persistence (launch-2 reads launch-1's sentinel off disk).
#
# Rhythm:
#   1. Build+install the app (with the Phase-6 opts), attach StikDebug, launch, let it reach the smoke.
#   2. ./verdict-mobileui-device.sh <UDID>          # pulls -> launch1.log
#   3. Re-attach StikDebug, launch again.
#   4. ./verdict-mobileui-device.sh <UDID>          # pulls -> launch2.log, then prints the verdict
set -euo pipefail
cd "$(dirname "$0")"

UDID="${1:?usage: verdict-mobileui-device.sh <device-UDID> [slot]}"
BUNDLE_ID="${BUNDLE_ID:-dev.audaro.runemobile}"
OUT="out-mobileui-device"
mkdir -p "$OUT"

L1="$OUT/launch1.log"
L2="$OUT/launch2.log"

# Slot: explicit 2nd arg, else auto (1 if launch1 missing, else 2).
SLOT="${2:-}"
if [ -z "$SLOT" ]; then
  if [ -f "$L1" ]; then SLOT=2; else SLOT=1; fi
fi
DEST="$OUT/launch${SLOT}.log"

echo "== pulling Documents/jvm-stdio.log from $UDID ($BUNDLE_ID) -> $DEST =="
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" --source Documents/jvm-stdio.log --destination "$DEST"

if ! grep -q "^MUI_DONE=1" "$DEST"; then
  echo "!! $DEST has no MUI_DONE=1 — the smoke daemon did not finish."
  echo "   Check it was launched with -Drunelite.mobileui.smoke=true and that StikDebug stayed attached."
  grep -E "^MUI_|MUI_FATAL|mui-smoke" "$DEST" | tail -20 || true
  exit 1
fi

echo "== captured launch $SLOT (MUI_DONE present) =="
if [ -f "$L1" ] && [ -f "$L2" ]; then
  ./mobileui-verdict.sh "$L1" "$L2"
else
  echo "(single launch captured — running single-launch gates; do a 2nd launch for cross-launch persistence)"
  ./mobileui-verdict.sh "$DEST"
fi
