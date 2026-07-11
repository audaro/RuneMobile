#!/usr/bin/env bash
# Phase B0.3 — compile-check the RLHD Zone JNI delta bridge for iOS arm64 (DEVICE-ONLY runtime; this is the static
# gate before a device build, mirroring ../gpu-routec/routec-device-compile-check.sh). GREEN = jni/routec_zone_jni.m
# produces an object file with zero `error:` diagnostics against jni.h + OpenGLES (EAGL) + the base RouteCBridge.h.
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
ROUTEC=../gpu-routec
JNI_INC=../../app/RuneMobile/jni
OUT=$(mktemp -d)
BASE=(-arch arm64 -isysroot "$SDK" -fobjc-arc -DGLES_SILENCE_DEPRECATION=1 -Wall
      -Wno-deprecated-declarations -I "$ROUTEC/app" -I jni -I "$JNI_INC")

rc=0
src=jni/routec_zone_jni.m
log="$OUT/zone.log"; obj="$OUT/zone.o"
if clang "${BASE[@]}" -c "$src" -o "$obj" 2>"$log"; then
	ERRS=$(grep -c 'error:' "$log" || true)
	WARNS=$(grep -c 'warning:' "$log" || true)
	SZ=$(stat -f%z "$obj" 2>/dev/null || echo 0)
	echo "OK   $src   (obj ${SZ}B, ${ERRS} errors, ${WARNS} warnings)"
	[ "$ERRS" = 0 ] && [ "$SZ" -gt 0 ] || rc=1
	[ "$WARNS" = 0 ] || { echo "--- warnings ---"; grep -E 'warning:' "$log" | head -20; }
else
	echo "FAIL $src:"; grep -E 'error:' "$log" | head -40; rc=1
fi

if [ "$rc" = 0 ]; then echo "MEGAVERDICT = ZONE_BRIDGE_COMPILES_ARM64"; else echo "MEGAVERDICT = ZONE_BRIDGE_COMPILE_FAIL" >&2; fi
rm -rf "$OUT"
exit $rc
