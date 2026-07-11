#!/usr/bin/env bash
# Build the fake libawt_xawt.dylib (arm64 iphoneos) and drop it into the embedded jre.
# See awtxawt_stub.c for why. Usage: ./build-libawt_xawt.sh
set -euo pipefail
cd "$(dirname "$0")"

OUT=libawt_xawt.dylib
JRE_LIB=../jre/lib

# §6.1: re-export libawt_headless (keeps its REAL Font/FontDescriptor/PlatformFont initIDs) and add
# our no-op headful component initIDs stubs (xawt_fake.c). libawt_headless's install_name is
# @rpath/libawt_headless.dylib, so we add -rpath @loader_path: at runtime @rpath resolves to the
# sibling file in jre/lib. -L paths let the static linker resolve libawt_headless's own deps
# (libawt/libjava/libjvm) while reading it for the reexport. See xawt_fake.c for the symbol policy.
HEADLESS="$JRE_LIB/libawt_headless.dylib"
if [ ! -f "$HEADLESS" ]; then echo "!! $HEADLESS not found — need the embedded jre present"; exit 1; fi

xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=17.0 -dynamiclib \
  -install_name @rpath/libawt_xawt.dylib \
  -Wl,-reexport_library,"$HEADLESS" \
  -Wl,-rpath,@loader_path \
  -L"$JRE_LIB" -L"$JRE_LIB/server" -Wl,-undefined,dynamic_lookup \
  -o "$OUT" xawt_fake.c

echo "built:"; file "$OUT"
echo "reexport of libawt_headless present?"; otool -l "$OUT" | grep -A2 REEXPORT_DYLIB | grep -i headless || echo "  !! NO reexport recorded"
echo "headful stub symbols (sample):"; nm -gU "$OUT" | grep -E '_Java_java_awt_(Component|Container|Window|AWTEvent)_initIDs' || true
echo "Font.initIDs visible via reexport?"; nm -gm "$OUT" 2>/dev/null | grep -i 'Font_initIDs' | head -1 || true

if [ -d "$JRE_LIB" ]; then
  cp "$OUT" "$JRE_LIB/$OUT"
  echo "installed -> $JRE_LIB/$OUT (the Xcode resign-jre phase will sign it)"
else
  echo "NOTE: $JRE_LIB not found — copy $OUT into the jre's lib/ manually."
fi
