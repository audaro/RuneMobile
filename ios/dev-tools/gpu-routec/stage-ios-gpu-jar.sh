#!/usr/bin/env bash
# GPU Route C step 2A — stage the iOS-variant gpu jar (jar surgery).
#
# Reads the PRISTINE desktop shaded jar (build/libs, left untouched — desktop + Android keep using it) and writes
# an iOS variant into the app bundle staging dir (jvm-resources). In the variant, every `org.lwjgl.*`,
# `net.runelite.rlawt.AWTContext` and `net.runelite.client.plugins.gpu.*` class is provided ONLY by our native
# facade (`facade-native/`, GL/AWTContext methods turned `native`) + a recompile of the unmodified plugin against
# it; LWJGL and librlawt are physically stripped. So at runtime there is exactly one provider of each of those
# symbols, all bridge-backed — no macOS dylib `dlopen` is attempted on device.
#
# Deterministic + md5-gateable. Pass an expected md5 of the staged jar's sorted class manifest as $1 to gate.
set -euo pipefail
cd "$(dirname "$0")"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$JAVA_HOME/bin/jar"
# QA-P1-15: derive the version from gradle.properties (full version, e.g. 1.12.29-SNAPSHOT) so the SOURCE jar
# read here always tracks an upstream bump instead of a hardcoded literal that silently diverges. The staged
# OUT name is deliberately version-AGNOSTIC (client-shaded.jar): project.yml and JVMLauncher.m reference it as
# a fixed string, so an upstream version bump can't break the bundle. Mirrors the gpu-zone staging script.
VERSION="$(sed -n 's/^project\.build\.version=//p' ../../../gradle.properties)"
[ -n "$VERSION" ] || { echo "!! could not read project.build.version from gradle.properties" >&2; exit 1; }
SRC="${SRC:-../../../runelite-client/build/libs/client-${VERSION}-shaded.jar}"
OUT="${OUT:-../../app/jvm-resources/client-shaded.jar}"
DL="${DL:-../../../runelite-client/build/generated/sources/delombok/java/main/net/runelite/client/plugins/gpu}"
EXPECT_MD5="${1:-}"

[ -f "$SRC" ] || { echo "!! pristine shaded jar missing: $SRC (run ./gradlew :client:assemble)" >&2; exit 1; }
# Refresh the delombok'd sources every stage: the output is a gitignored build artifact (absent on a fresh
# CI workspace, and silently STALE in a persistent one after an upstream merge). Gradle's up-to-date check
# makes the no-change case cheap; skip only when the caller pinned DL to a custom tree.
if [ "$DL" = "../../../runelite-client/build/generated/sources/delombok/java/main/net/runelite/client/plugins/gpu" ]; then
  ( cd ../../.. && JAVA_HOME="$JAVA_HOME" ./gradlew --no-daemon -q :client:delombok )
fi
[ -d "$DL" ]  || { echo "!! delombok gpu sources missing: $DL (run ./gradlew :client:delombok)" >&2; exit 1; }

# Absolutize — SRC/DL are used inside `(cd "$WORK/..." && ...)` subshells where a relative path would misresolve.
SRC=$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")
DL=$(cd "$DL" && pwd)
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac

# Refuse a non-pristine source (already stripped) — guards against accidentally feeding the iOS variant back in.
# (grep -c consumes all input, so it doesn't SIGPIPE unzip under `set -o pipefail` the way grep -q would.)
SRC_LWJGL=$(unzip -l "$SRC" | grep -c 'org/lwjgl/.*[.]class' || true)
[ "$SRC_LWJGL" -gt 0 ] || { echo "!! SRC has no org/lwjgl classes — not a pristine shaded jar: $SRC" >&2; exit 1; }

WORK="$(pwd)/stage-work"
rm -rf "$WORK"; mkdir -p "$WORK/facade_out" "$WORK/gpu_out" "$WORK/jar"

# 1) facade compiles (the GL/AWTContext surface the plugin references, methods `native`). DEFAULT = the GROWN RLHD
#    superset (../gpu-zone/facade) so the single in-jar facade covers BOTH base gpu + RLHD/117HD. This MUST be the
#    default: the device app boots 117HD (RLHDStarter), and RLHD needs the superset's org.lwjgl.system.* (Platform,
#    MemoryUtil, …) — stage with the base-only facade-native and HdPlugin.<clinit> dies with
#    NoClassDefFoundError: org/lwjgl/system/Platform, the plugin loads 0 classes, and 117HD silently never activates.
#    The base plugin compiles+runs fine against the superset (host- + device-verified; the extra facade classes are
#    pure-Java or stay unbound+uncalled in base mode). Override FACADE_SRC=facade-native only for a base-gpu-only jar.
FACADE_SRC="${FACADE_SRC:-../gpu-zone/facade}"
[ -d "$FACADE_SRC" ] || { echo "!! FACADE_SRC dir missing: $FACADE_SRC" >&2; exit 1; }
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -d "$WORK/facade_out" $(find "$FACADE_SRC" -name '*.java')
FACADE_LWJGL_CLASSES=$(cd "$WORK/facade_out" && find org/lwjgl -name '*.class' | wc -l | tr -d ' ')
echo "facade source dir    : $FACADE_SRC"

# 2) explode the pristine jar; strip lwjgl + rlawt + the gpu package's CLASSES (the only LWJGL/rlawt users in
#    the tree). For the gpu package we delete ONLY the real-build .class files (recompiled below) and KEEP its
#    non-class RESOURCES — regions/regions.txt (read by RegionManager's ctor) and the GLSL shaders
#    (vert/frag/vertui/fragui/hsl_to_rgb/colorblind + scale/*.glsl, loaded via getResourceAsStream at runtime,
#    then downported 330->ES300 at glShaderSource time). A blanket `rm -rf` of the package would drop them and
#    the plugin would NPE on the null resource stream before startUp ever runs.
(cd "$WORK/jar" && unzip -q "$SRC")
rm -rf "$WORK/jar/org/lwjgl" "$WORK/jar/net/runelite/rlawt"
find "$WORK/jar/net/runelite/client/plugins/gpu" -name '*.class' -delete

# 3) recompile the unmodified delombok'd gpu sources against [facade-native : stripped-jar]. Recompiling (not
#    reusing the real-build bytecode) guarantees every reference resolves against facade classes we control.
set +e
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -nowarn -proc:none -cp "$WORK/facade_out:$WORK/jar" -d "$WORK/gpu_out" $(find "$DL" -name '*.java') 2>"$WORK/err.txt"
RC=$?
set -e
if [ "$RC" != 0 ]; then echo "!! gpu recompile FAILED ($(grep -c 'error:' "$WORK/err.txt") errors):" >&2; cat "$WORK/err.txt" >&2; exit 2; fi

# 4) repackage: drop the facade + recompiled gpu classes into the stripped tree.
cp -R "$WORK/facade_out/." "$WORK/jar/"
cp -R "$WORK/gpu_out/." "$WORK/jar/"

# 5) asserts — exactly one (facade) provider of each stripped namespace, no stale service providers.
SURV=$(cd "$WORK/jar" && find org/lwjgl -name '*.class' 2>/dev/null | wc -l | tr -d ' ')
RLAWT_SURV=$(find "$WORK/jar/net/runelite/rlawt" -name '*.class' 2>/dev/null | wc -l | tr -d ' ')
GPU_CLASSES=$(cd "$WORK/jar" && find net/runelite/client/plugins/gpu -name '*.class' 2>/dev/null | wc -l | tr -d ' ')
SVC_LEAK=$( { grep -rIlE 'org\.lwjgl|net\.runelite\.rlawt' "$WORK/jar/META-INF/services" 2>/dev/null || true; } | wc -l | tr -d ' ')
# gpu-package resources the plugin loads at runtime MUST survive the class strip: regions.txt + the 6 base GLSL
# shaders (vert/frag/vertui/fragui/hsl_to_rgb/colorblind). A missing regions.txt NPEs RegionManager before startUp.
GPU_GLSL=$(cd "$WORK/jar" && find net/runelite/client/plugins/gpu -maxdepth 1 -name '*.glsl' 2>/dev/null | wc -l | tr -d ' ')
GPU_REGIONS=$([ -f "$WORK/jar/net/runelite/client/plugins/gpu/regions/regions.txt" ] && echo 1 || echo 0)

# 6) rezip (keep the on-disk MANIFEST; -M = don't synthesize one).
NEW="$WORK/staged.jar"
"$JAR" --create --no-manifest --file "$NEW" -C "$WORK/jar" .
STAGED_MD5=$(cd "$WORK/jar" && find . -name '*.class' | sort | xargs cat | { md5 -q 2>/dev/null || md5sum | awk '{print $1}'; })

echo "facade lwjgl classes : $FACADE_LWJGL_CLASSES"
echo "org/lwjgl survivors  : $SURV   (must == facade lwjgl classes; all bridge-backed)"
echo "rlawt survivors      : $RLAWT_SURV   (facade AWTContext only)"
echo "gpu classes          : $GPU_CLASSES   (recompiled against facade-native; 21 sources + inner)"
echo "gpu base glsl shaders: $GPU_GLSL   (must be >=6: vert/frag/vertui/fragui/hsl_to_rgb/colorblind)"
echo "gpu regions.txt      : $GPU_REGIONS   (must be 1; RegionManager ctor reads it)"
echo "stale svc providers  : $SVC_LEAK   (must be 0)"
echo "staged class md5     : $STAGED_MD5${EXPECT_MD5:+  (expected $EXPECT_MD5)}"

OK=yes
[ "$SURV" = "$FACADE_LWJGL_CLASSES" ] || OK=no
[ "$RLAWT_SURV" -ge 1 ] || OK=no
[ "$GPU_CLASSES" -ge 21 ] || OK=no
[ "$GPU_GLSL" -ge 6 ] || OK=no
[ "$GPU_REGIONS" = 1 ] || OK=no
[ "$SVC_LEAK" = 0 ] || OK=no
if [ -n "$EXPECT_MD5" ] && [ "$STAGED_MD5" != "$EXPECT_MD5" ]; then OK=no; fi

if [ "$OK" != yes ]; then echo "MEGAVERDICT = ROUTEC_STAGE_NOT_GREEN" >&2; exit 3; fi

mv "$NEW" "$OUT"
echo "staged iOS gpu jar   : $OUT"
echo "MEGAVERDICT = ROUTEC_STAGE_GREEN"
