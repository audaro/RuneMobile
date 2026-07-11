#!/usr/bin/env bash
# Track G AG2.5-b gate — run the 117HD (RLHD) class-load + loader-data probe on an adb-reachable device/emulator
# and assert MEGAVERDICT=ANDROID_RLHD_PROBE_GREEN. This is a CLASS-LOAD / verify / JSON-parse test — it has NO GL
# execution, so the emulator (ANGLE/SwiftShader) is authoritative for it (unlike AG0/AG1b/AG2, which need real Mali).
#
# Prereqs: the app installed; client-<ver>-gpu.jar (run stage-android-gpu-jar.sh) AND client-<ver>-rlhd.jar (run
# stage-rlhd-zone-jar.sh) staged into assets/jvm (a fresh install copies them; to iterate without a reinstall,
# push both to files/jvm via run-as — they MUST be staged from the SAME facade-src revision). Usage: ./check-rlhdprobe.sh
set -euo pipefail
ADB="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
PKG="${PKG:-dev.audaro.runemobile}"

"$ADB" shell am force-stop "$PKG" >/dev/null 2>&1 || true
"$ADB" logcat -c >/dev/null 2>&1 || true
"$ADB" shell am start -n "$PKG/.MainActivity" --ez rlhdprobe true >/dev/null 2>&1
echo "launched rlhdprobe; waiting for MEGAVERDICT..."
for _ in $(seq 1 30); do
	sleep 4
	if "$ADB" logcat -d 2>/dev/null | grep -q "MEGAVERDICT ="; then break; fi
done

LOG=$("$ADB" logcat -d 2>/dev/null | grep -E "ANDROID_RLHD_PROBE|MEGAVERDICT =" || true)
echo "$LOG"

LINK=$(printf '%s\n' "$LOG" | grep -oE "linked=[0-9]+/[0-9]+ failures=[0-9]+" | tail -1)
OCL=$(printf '%s\n' "$LOG" | grep -oE "openclGraph init=[a-z]+ OPENCL_EXPLICIT_INIT=[a-z]+" | tail -1)
JSON=$(printf '%s\n' "$LOG" | grep -oE "loaderJson parsed=[0-9]+/[0-9]+" | tail -1)

OK=yes
printf '%s\n' "$LOG" | grep -q "MEGAVERDICT = ANDROID_RLHD_PROBE_GREEN" || OK=no
echo "$OCL"  | grep -q "init=true OPENCL_EXPLICIT_INIT=true" || OK=no
echo "$LINK" | grep -qE "failures=0" || OK=no

if [ "$OK" = yes ]; then echo "MEGAVERDICT = ANDROID_RLHD_PROBE_GREEN ($LINK; $OCL; $JSON)"; exit 0; fi
echo "MEGAVERDICT = ANDROID_RLHD_PROBE_NOT_GREEN" >&2; exit 1
