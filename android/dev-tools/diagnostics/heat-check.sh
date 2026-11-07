#!/usr/bin/env bash
# Drives the DEBUG app's ThermalGovernor on an emulator with forced thermal statuses, and reads the saved profile
# and the marker file after each step: cooling down, a player moving the setting mid-throttle, a kill mid-throttle, a
# kill right after a player's move, and a swipe-away. Each has to end with the player's value on disk before the marker
# goes. Expect ANDROID_HEAT_GREEN.
#   android/dev-tools/diagnostics/heat-check.sh [-s <serial>]
# Emulator only: it boots 117HD with the rlhd.mode marker, force-stops the app and rewrites the saved scale. Install the
# debug APK first. About three minutes.
set -euo pipefail
PKG=dev.audaro.runemobile
ADB=(adb)
if [[ "${1:-}" == "-s" && -n "${2:-}" ]]; then ADB=(adb -s "$2"); fi
FILES="/sdcard/Android/data/$PKG/files"
PLAYER=90 # the player's own scale, set to something the governor's 65 and 50 can't be mistaken for
FAILED=0

fail() {
	echo "  FAILED: $1"
	FAILED=1
}

saved_scale() {
	"${ADB[@]}" exec-out run-as "$PKG" sh -c 'cat files/.runelite/profiles2/*.properties' |
		tr -d '\r' | sed -n 's/^hd\.sceneResolutionScale=//p' | tail -1
}

marker() {
	"${ADB[@]}" exec-out run-as "$PKG" sh -c 'cat files/thermal-throttle.marker 2>/dev/null' | tr -d '\r\n' || true
}

status() {
	"${ADB[@]}" shell am broadcast -a "$PKG.SET_THERMAL_STATUS" --ei level "$1" >/dev/null
}

set_scale() {
	"${ADB[@]}" shell am broadcast -a "$PKG.SET_HD_CONFIG" --es key sceneResolutionScale --es value "$1" >/dev/null
}

# The app's own save on its way to the background, so it has to be in the foreground to start with.
save() {
	"${ADB[@]}" shell am start -W -n "$PKG/.MainActivity" >/dev/null
	"${ADB[@]}" logcat -c
	"${ADB[@]}" shell input keyevent HOME
	wait_log 'a8: flushConfig on background' 15 || fail "the app didn't save on its way to the background"
}

wait_log() { # <pattern> <seconds>
	local i
	for ((i = 0; i < $2; i++)); do
		if "${ADB[@]}" logcat -d | grep -q "$1"; then return 0; fi
		sleep 1
	done
	return 1
}

wait_saved() { # <scale> <seconds>
	local i
	for ((i = 0; i < $2; i++)); do
		if [[ "$(saved_scale)" == "$1" ]]; then return 0; fi
		sleep 1
	done
	return 1
}

# The write queues on the client thread, which is busy for a while after login, and a save doesn't wait for it.
save_until() { # <scale>
	local i
	for ((i = 0; i < 10; i++)); do
		sleep 3
		save
		if wait_saved "$1" 3; then return 0; fi
	done
	fail "$1 wasn't saved, so this proves nothing: saved scale $(saved_scale)"
}

# Waits for the marker to go, then reads the saved scale at once: that it's the player's by then is the point.
marker_goes_with_scale_saved() { # <scale> <seconds>
	local i
	for ((i = 0; i < $2; i++)); do
		if [[ -z "$(marker)" ]]; then
			local saved
			saved="$(saved_scale)"
			echo "  marker gone after ${i} s, saved scale $saved"
			[[ "$saved" == "$1" ]] || fail "the marker went with $saved on disk, wanted $1"
			return 0
		fi
		sleep 1
	done
	fail "the marker was still there after $2 s: $(marker)"
}

launch() {
	"${ADB[@]}" shell am force-stop "$PKG"
	"${ADB[@]}" logcat -c
	"${ADB[@]}" shell am start -W -f 0x10008000 -n "$PKG/.MainActivity" >/dev/null
}

# Throttled, with that throttle saved: what a kill or a cool-down has to clean up.
throttle_and_save() {
	"${ADB[@]}" logcat -c
	status 3
	wait_log 'thermal status=3 -> sceneResolutionScale .*->50 ' 30 || fail "no throttle to 50"
	save_until 50
	[[ "$(marker)" == "$PLAYER" ]] || fail "marker [$(marker)] while throttled, wanted $PLAYER"
}

if [[ "$("${ADB[@]}" shell getprop ro.kernel.qemu | tr -d '\r')" != 1 ]]; then
	echo "ANDROID_HEAT_RED not an emulator: this rewrites the saved scale, so it won't run on a phone"
	exit 1
fi
cleanup() {
	"${ADB[@]}" shell rm -f "$FILES/rlhd.mode" || true
}
trap cleanup EXIT
"${ADB[@]}" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS
"${ADB[@]}" shell mkdir -p "$FILES"
"${ADB[@]}" shell touch "$FILES/rlhd.mode"

echo "booting 117HD:"
launch
wait_log 'state=LOGIN_SCREEN' 180 || {
	echo "ANDROID_HEAT_RED the app never reached the login screen"
	exit 1
}
set_scale "$PLAYER"
save_until "$PLAYER"
echo "  saved scale $(saved_scale), marker [$(marker)]"

echo "cooling down, with the throttle saved:"
throttle_and_save
status 0
marker_goes_with_scale_saved "$PLAYER" 30

echo "a player moves the setting mid-throttle:"
"${ADB[@]}" logcat -c
status 2
wait_log 'thermal status=2 -> sceneResolutionScale .*->65 ' 30 || fail "no throttle to 65"
set_scale 80
sleep 2
status 0
wait_log 'thermal: player set sceneResolutionScale=80 ' 30 || fail "the governor didn't see the player's 80"
save_until 80
[[ -z "$(marker)" ]] || fail "the marker outlived the throttle: $(marker)"
echo "  saved scale $(saved_scale), marker [$(marker)]"
set_scale "$PLAYER"
save_until "$PLAYER"

echo "killed mid-throttle:"
throttle_and_save
echo "  killed with $(saved_scale) saved, marker [$(marker)]"
launch
marker_goes_with_scale_saved "$PLAYER" 120
wait_log 'thermal: recovered a leaked throttle' 5 || fail "no recovery in the log"

echo "a player moves the setting during a steady throttle, and is killed:"
wait_log 'state=LOGIN_SCREEN' 120 || fail "the app never came back to the login screen"
throttle_and_save
set_scale 80
wait_log 'thermal: player set sceneResolutionScale=80 ' 30 || fail "the governor didn't see the player's 80"
save_until 50
[[ "$(marker)" == 80 ]] || fail "marker [$(marker)] after the player's move, wanted 80"
echo "  killed with $(saved_scale) saved, marker [$(marker)]"
launch
marker_goes_with_scale_saved 80 120
wait_log 'state=LOGIN_SCREEN' 120 || fail "the app never came back to the login screen"
set_scale "$PLAYER"
save_until "$PLAYER"

# Android often kills the process within milliseconds of destroying the activity, before onDestroy, so the governor's
# stop() may or may not run. Either way the marker can't go until the player's value is on disk.
echo "swiped away mid-throttle:"
throttle_and_save
"${ADB[@]}" shell am start -W -n "$PKG/.MainActivity" >/dev/null
task="$("${ADB[@]}" shell am stack list | sed -n "s/.*taskId=\([0-9]*\): $PKG.*/\1/p" | head -1)"
[[ -n "$task" ]] || fail "no task to remove"
"${ADB[@]}" shell am stack remove "$task"
sleep 5
if [[ -z "$("${ADB[@]}" shell pidof "$PKG" | tr -d '\r')" ]]; then
	echo "  the process was killed, so the next launch has to finish it"
	launch
else
	echo "  the process lived, so stop() has to finish it"
fi
marker_goes_with_scale_saved "$PLAYER" 120

if [[ "$FAILED" != 0 ]]; then
	echo "ANDROID_HEAT_RED"
	exit 1
fi
echo "ANDROID_HEAT_GREEN"
