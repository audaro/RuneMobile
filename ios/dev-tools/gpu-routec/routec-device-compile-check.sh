#!/usr/bin/env bash
# GPU Route C — compile-check the device JNI GL bridge for iOS arm64 (DEVICE-ONLY runtime; this is the static gate
# before a device build). Compiles RouteCBridge.m + the generated routec_gl_jni.m for BOTH backends selected by
# RC_BACKEND_ANGLE (see app/routec_gl_compat.h): the MetalANGLE/EGL backend (Phase A1) and the EAGL fallback.
# GREEN = every (source x backend) produces an object file with zero `error:` diagnostics. The ANGLE pass needs the
# vendored Khronos EGL/GLES3 headers (gitignored; regenerate via ../gpu-angle/README); it is skipped if absent.
set -euo pipefail
cd "$(dirname "$0")"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
JNI_INC=../../app/RuneMobile/jni
ANGLE_INC=../gpu-angle/include
OUT=$(mktemp -d)
BASE=(-arch arm64 -isysroot "$SDK" -fobjc-arc -DGLES_SILENCE_DEPRECATION=1 -Wall
      -Wno-deprecated-declarations -I app -I jni -I "$JNI_INC")

rc=0
check_backend() {  # $1 = label, rest = extra cflags
	local label="$1"; shift
	echo "--- backend: $label ---"
	for src in app/RouteCBridge.m jni/routec_gl_jni.m; do
		local obj="$OUT/$(basename "${src%.m}")-$label.o"
		local log="$OUT/$(basename "${src%.m}")-$label.log"
		if clang "${BASE[@]}" "$@" -c "$src" -o "$obj" 2>"$log"; then
			local ERRS; ERRS=$(grep -c 'error:' "$log" || true)
			local SZ; SZ=$(stat -f%z "$obj" 2>/dev/null || echo 0)
			echo "OK   $src   (obj ${SZ}B, ${ERRS} errors)"
			[ "$ERRS" = 0 ] && [ "$SZ" -gt 0 ] || rc=1
		else
			echo "FAIL $src:"; grep -E 'error:' "$log" | head -30; rc=1
		fi
	done
}

check_backend EAGL
if [ -f "$ANGLE_INC/GLES3/gl32.h" ]; then
	check_backend ANGLE -DRC_BACKEND_ANGLE=1 -I "$ANGLE_INC"
else
	echo "--- backend: ANGLE --- SKIPPED (vendored headers absent: $ANGLE_INC; see ../gpu-angle/README)"
fi

if [ "$rc" = 0 ]; then echo "MEGAVERDICT = ROUTEC_BRIDGE_COMPILES_ARM64 (both backends)"; else echo "MEGAVERDICT = ROUTEC_BRIDGE_COMPILE_FAIL" >&2; fi
rm -rf "$OUT"
exit $rc
