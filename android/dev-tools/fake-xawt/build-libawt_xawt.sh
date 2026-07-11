#!/usr/bin/env bash
# Build the fake libawt_xawt.so (arm64 android) and drop it into the staged jre assets.
# See xawt_fake.c for why. Usage: ./build-libawt_xawt.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT=libawt_xawt.so
JRE_LIB=../../app/src/main/assets/jvm/jre/lib

SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
NDK=$(ls -d "$SDK"/ndk/* 2>/dev/null | sort | head -1)
[ -n "$NDK" ] || { echo "!! no NDK under $SDK/ndk"; exit 1; }
TOOL=$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/bin 2>/dev/null | head -1)
CLANG="$TOOL/aarch64-linux-android28-clang"
READELF="$TOOL/llvm-readelf"
[ -x "$CLANG" ] || { echo "!! clang not found: $CLANG"; exit 1; }

HEADLESS="$JRE_LIB/libawt_headless.so"
[ -f "$HEADLESS" ] || { echo "!! $HEADLESS not found — need the staged jre present"; exit 1; }

# DT_NEEDED libawt_headless.so keeps its REAL Font/PlatformFont initIDs reachable via bionic dlsym
# dependency search (the JVM's native lookup walks our handle's deps). --no-as-needed forces the
# NEEDED record even though our C references none of headless's symbols directly. --allow-shlib-
# -undefined: libawt_headless pulls libjvm/libjava/libawt, whose symbols stay unresolved at link
# time (resolved at load on-device); -L paths let the linker read those deps for the NEEDED chain.
"$CLANG" --target=aarch64-linux-android28 -shared -fPIC -O2 \
  -o "$OUT" xawt_fake.c \
  -Wl,-soname,libawt_xawt.so \
  -Wl,-z,max-page-size=16384 \
  -L"$JRE_LIB" -L"$JRE_LIB/server" \
  -Wl,--no-as-needed -lawt_headless \
  -Wl,--allow-shlib-undefined

echo "built:"; file "$OUT"
echo "DT_NEEDED (expect libawt_headless.so):"; "$READELF" -d "$OUT" | grep -iE 'NEEDED|SONAME'
echo "headful stub symbols (sample):"; "$TOOL/llvm-nm" -D --defined-only "$OUT" | grep -E 'awt_(Component|Container|Window|AWTEvent)_initIDs' || true

cp "$OUT" "$JRE_LIB/$OUT"
echo "installed -> $JRE_LIB/$OUT"
