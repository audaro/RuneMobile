#!/usr/bin/env bash
# Builds a real "Share logs" report on a connected phone running the DEBUG app and checks what is in it
# (tools/diagnostics/check_report.py): every section, the engine's answer, and no name or secret from the phone's
# tokens.json. Expect SHARE_LOGS_REPORT_GREEN. Start the app first; logged in is the stronger check.
#   android/dev-tools/diagnostics/device-report-check.sh [-s <serial>]
# The phone's tokens.json is read with run-as into a private temp dir and deleted on exit; only counts are printed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PKG=dev.audaro.runemobile
ADB=(adb)
if [[ "${1:-}" == "-s" && -n "${2:-}" ]]; then ADB=(adb -s "$2"); fi
OUT="$(mktemp -d)"
chmod 700 "$OUT"
trap 'rm -rf "$OUT"' EXIT

"${ADB[@]}" logcat -c
"${ADB[@]}" shell am broadcast -a "$PKG.WRITE_SHARE_LOGS_REPORT" >/dev/null
for _ in $(seq 1 30); do
	sleep 1
	if "${ADB[@]}" logcat -d -s MainActivity:I | grep -q "WRITE_SHARE_LOGS_REPORT: "; then break; fi
	if "${ADB[@]}" logcat -d -s MainActivity:W | grep -q "WRITE_SHARE_LOGS_REPORT failed"; then
		echo "SHARE_LOGS_REPORT_RED the app couldn't write the report:"
		"${ADB[@]}" logcat -d -s MainActivity:W | grep -A3 "WRITE_SHARE_LOGS_REPORT failed"
		exit 1
	fi
done
"${ADB[@]}" logcat -d -s MainActivity:I | grep -q "WRITE_SHARE_LOGS_REPORT: " ||
	{ echo "SHARE_LOGS_REPORT_RED no report within 30 s (is the debug app running?)"; exit 1; }
"${ADB[@]}" pull "/sdcard/Android/data/$PKG/files/share-logs-report.txt" "$OUT/report.txt" >/dev/null
LOGGED_IN=()
if "${ADB[@]}" shell run-as "$PKG" cat files/tokens.json >"$OUT/tokens.json" 2>/dev/null && [[ -s "$OUT/tokens.json" ]]; then
	LOGGED_IN=(--tokens "$OUT/tokens.json" --logged-in)
fi
python3 "$ROOT/tools/diagnostics/check_report.py" "$OUT/report.txt" --port android ${LOGGED_IN[@]+"${LOGGED_IN[@]}"}
