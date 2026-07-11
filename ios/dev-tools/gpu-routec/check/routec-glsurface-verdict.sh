#!/usr/bin/env bash
# GPU Route C step 3a — GL surface existence verdict (anti-fabrication).
#
# GREEN = every GLES 3.0 target symbol the base `gpu` plugin needs (LWJGL convenience/desktop names already mapped
# to GLES symbols; the 5 census shims represented by their targets) is DECLARED in the iOS device GLES 3.0 headers
# AND RESOLVES against OpenGLES.framework for iOS arm64. Proves the core GL surface is reachable on iOS — the last
# static unknown before the (device-only) JNI wiring. Pins the symbol list + check source by md5.
set -euo pipefail
cd "$(dirname "$0")"

EXPECT_TARGETS_MD5="${1:-}"
N_EXPECT="${2:-81}"

[ -f gl-targets.txt ] || { echo "!! gl-targets.txt missing" >&2; exit 1; }
[ -f gl_surface_check.c ] || { echo "!! gl_surface_check.c missing" >&2; exit 1; }

TARGETS_MD5="$(md5 -q gl-targets.txt 2>/dev/null || md5sum gl-targets.txt | awk '{print $1}')"
NSYM=$(grep -c 'fnptr)&' gl_surface_check.c)
NTARGETS=$(grep -c . gl-targets.txt)

rm -f gl_surface_check.o libglsurf.dylib
set +e
xcrun -sdk iphoneos clang -arch arm64 -DGLES_SILENCE_DEPRECATION -Wno-deprecated-declarations \
	-c gl_surface_check.c -o gl_surface_check.o 2>cc.err
CC=$?
xcrun -sdk iphoneos clang -arch arm64 -DGLES_SILENCE_DEPRECATION -Wno-deprecated-declarations \
	-dynamiclib gl_surface_check.o -framework OpenGLES -o libglsurf.dylib 2>ld.err
LD=$?
set -e

ARCH=$(file libglsurf.dylib 2>/dev/null | grep -c "arm64" || true)
OGL=$(otool -L libglsurf.dylib 2>/dev/null | grep -ic "OpenGLES.framework/OpenGLES" || true)
RESOLVED=$(nm -u libglsurf.dylib 2>/dev/null | grep -c '_gl' || true)

echo "gl-targets.txt md5 : $TARGETS_MD5${EXPECT_TARGETS_MD5:+  (expected $EXPECT_TARGETS_MD5)}"
echo "targets / refs     : $NTARGETS / $NSYM (expect $N_EXPECT)"
echo "compile exit       : $CC"
echo "link exit          : $LD"
echo "dylib arm64        : $ARCH   OpenGLES-linked: $OGL   resolved _gl syms: $RESOLVED"

OK=yes
[ "$CC" = 0 ] || OK=no
[ "$LD" = 0 ] || OK=no
[ "$ARCH" -ge 1 ] || OK=no
[ "$OGL" -ge 1 ] || OK=no
[ "$NSYM" = "$N_EXPECT" ] || OK=no
[ "$RESOLVED" -ge "$N_EXPECT" ] || OK=no
if [ -n "$EXPECT_TARGETS_MD5" ] && [ "$TARGETS_MD5" != "$EXPECT_TARGETS_MD5" ]; then OK=no; fi

if [ "$OK" = yes ]; then
	echo "MEGAVERDICT = ROUTEC_GLSURFACE_GREEN_AS_EXPECTED"
	exit 0
else
	echo "MEGAVERDICT = ROUTEC_GLSURFACE_NOT_GREEN"
	cat cc.err ld.err 2>/dev/null | head -20
	exit 2
fi
