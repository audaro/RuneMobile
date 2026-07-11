#!/usr/bin/env bash
# GPU Route C — facade-compile smoke verdict (anti-fabrication).
#
# GREEN = the REAL, UNMODIFIED base `gpu` plugin source (all 15 delombok'd files) compiles against our local
# org.lwjgl.opengl / net.runelite.rlawt facade with LWJGL + librlawt PHYSICALLY ABSENT from the classpath — so
# the facade is provably the only provider of those symbols. This validates the "unmodified plugin source" leg
# of Route C and pins the generated GLALL spec (real GL enum values + reflected method signatures) by md5.
set -euo pipefail
cd "$(dirname "$0")"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVAC="$JAVA_HOME/bin/javac"
# QA-P1-15: derive the version from gradle.properties (mirrors stage-ios-gpu-jar.sh) instead of a hardcoded
# literal that silently diverges on the next upstream bump. Same name today (1.12.29-SNAPSHOT).
VERSION="$(sed -n 's/^project\.build\.version=//p' ../../../gradle.properties)"
[ -n "$VERSION" ] || { echo "!! could not read project.build.version from gradle.properties" >&2; exit 1; }
SHADED="${SHADED:-../../app/jvm-resources/client-shaded.jar}"
DL="${DL:-../../../runelite-client/build/generated/sources/delombok/java/main/net/runelite/client/plugins/gpu}"
EXPECT_GLALL_MD5="${1:-}"

[ -f "$SHADED" ] || { echo "!! shaded jar missing: $SHADED" >&2; exit 1; }
[ -d "$DL" ] || { echo "!! delombok'd gpu sources missing: $DL (run ./gradlew :client:delombok)" >&2; exit 1; }

rm -rf facade_out deps plugin_out
mkdir -p facade_out plugin_out

# 1) facade compiles
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -d facade_out $(find facade -name "*.java")
FACADE_CLASSES=$(find facade_out -name '*.class' | wc -l | tr -d ' ')

# 2) deps = shaded jar with lwjgl + rlawt STRIPPED (force the facade to be the only provider)
mkdir -p deps && (cd deps && unzip -q "../$SHADED" && rm -rf org/lwjgl net/runelite/rlawt)
LWJGL_LEAK=$([ -d deps/org/lwjgl ] && echo LEAK || echo none)
RLAWT_LEAK=$([ -d deps/net/runelite/rlawt ] && echo LEAK || echo none)

# 3) the real plugin package compiles against [facade : shaded-minus-lwjgl]
set +e
"$JAVAC" -nowarn -proc:none -cp "facade_out:deps" -d plugin_out "$DL"/*.java 2>err.txt
RC=$?
set -e
ERRORS=$(grep -c 'error:' err.txt || true)
PLUGIN_CLASSES=$(find plugin_out -name '*.class' | wc -l | tr -d ' ')

# 4) provenance: GpuPlugin references the FACADE lwjgl/rlawt
PROV=$("$JAVA_HOME/bin/javap" -c -p -classpath plugin_out net.runelite.client.plugins.gpu.GpuPlugin 2>/dev/null \
	| grep -cE "org/lwjgl/opengl/(GL|GL33C|GLCapabilities)|net/runelite/rlawt/AWTContext" || true)

GLALL_MD5=$(md5 -q facade/org/lwjgl/opengl/GLALL.java 2>/dev/null || md5sum facade/org/lwjgl/opengl/GLALL.java | awk '{print $1}')

echo "facade classes      : $FACADE_CLASSES"
echo "deps lwjgl leak     : $LWJGL_LEAK   rlawt leak: $RLAWT_LEAK"
echo "plugin javac exit   : $RC   errors: $ERRORS   classes: $PLUGIN_CLASSES"
echo "GpuPlugin->facade   : $PROV refs"
echo "GLALL.java md5      : $GLALL_MD5${EXPECT_GLALL_MD5:+  (expected $EXPECT_GLALL_MD5)}"

OK=yes
[ "$RC" = 0 ] || OK=no
[ "$ERRORS" = 0 ] || OK=no
[ "$LWJGL_LEAK" = none ] || OK=no
[ "$RLAWT_LEAK" = none ] || OK=no
[ "$PLUGIN_CLASSES" -ge 15 ] || OK=no
[ "$PROV" -ge 1 ] || OK=no
if [ -n "$EXPECT_GLALL_MD5" ] && [ "$GLALL_MD5" != "$EXPECT_GLALL_MD5" ]; then OK=no; fi

if [ "$OK" = yes ]; then
	echo "MEGAVERDICT = ROUTEC_FACADE_GREEN_AS_EXPECTED"
	exit 0
else
	echo "MEGAVERDICT = ROUTEC_FACADE_NOT_GREEN"
	exit 2
fi
