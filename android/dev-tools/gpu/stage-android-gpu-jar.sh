#!/usr/bin/env bash
# Track G AG2-P3 — stage the Android-variant gpu jar (jar surgery). The Android mirror of the iOS
# stage-ios-gpu-jar.sh (gpu branch): reads the PRISTINE shaded client jar and writes a GPU variant in which every
# org.lwjgl.*, net.runelite.rlawt.AWTContext and net.runelite.client.plugins.gpu.* class is provided ONLY by our
# native facade (facade-src/, GL/AWTContext methods turned `native`, backed by librlawt's RegisterNatives) + a
# recompile of the UNMODIFIED plugin against it. LWJGL is physically stripped (it has no natives-android
# classifier anyway), so at runtime there is exactly one provider of each symbol, all bridge-backed.
#
# The variant is a SEPARATE jar (client-<ver>-gpu.jar, NOT *-shaded.jar) so the normal CPU boot — which globs
# client-*-shaded.jar — never picks it up; only the GPU launch path loads it explicitly.
#
# Deterministic + md5-gateable. Pass an expected md5 of the staged jar's sorted class manifest as $1 to gate.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../../.. && pwd)"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$JAVA_HOME/bin/jar"
VERSION="$(sed -n 's/^project\.build\.version=//p' "$ROOT/gradle.properties")"
[ -n "$VERSION" ] || { echo "!! could not read project.build.version from gradle.properties" >&2; exit 1; }

FACADE="$(pwd)/facade-src"
SRC="${SRC:-$ROOT/runelite-client/build/libs/client-${VERSION}-shaded.jar}"
OUT="${OUT:-$ROOT/android/app/src/main/assets/jvm/client-${VERSION}-gpu.jar}"
DL="${DL:-$ROOT/runelite-client/build/generated/sources/delombok/java/main/net/runelite/client/plugins/gpu}"
EXPECT_MD5="${1:-}"

[ -f "$SRC" ]  || { echo "!! pristine shaded jar missing: $SRC (run ./gradlew :client:shadowJar)" >&2; exit 1; }
# Refresh the delombok'd sources every stage: the output is a gitignored build artifact (absent on a fresh
# CI workspace, and silently STALE in a persistent one after an upstream merge). Gradle's up-to-date check
# makes the no-change case cheap; skip only when the caller pinned DL to a custom tree.
if [ "$DL" = "$ROOT/runelite-client/build/generated/sources/delombok/java/main/net/runelite/client/plugins/gpu" ]; then
  ( cd "$ROOT" && JAVA_HOME="$JAVA_HOME" ./gradlew --no-daemon -q :client:delombok )
fi
[ -d "$DL" ]   || { echo "!! delombok gpu sources missing: $DL (run ./gradlew :client:delombok)" >&2; exit 1; }
[ -d "$FACADE" ] || { echo "!! facade-src missing: $FACADE" >&2; exit 1; }

# Refuse a non-pristine source (already stripped) — guards against feeding a GPU variant back in.
# (grep -c consumes all input, so it won't SIGPIPE unzip under `set -o pipefail` the way grep -q would.)
SRC_LWJGL=$(unzip -l "$SRC" | grep -c 'org/lwjgl/.*[.]class' || true)
[ "$SRC_LWJGL" -gt 0 ] || { echo "!! SRC has no org/lwjgl classes — not a pristine shaded jar: $SRC" >&2; exit 1; }

WORK="$(pwd)/stage-work"
rm -rf "$WORK"; mkdir -p "$WORK/facade_out" "$WORK/gpu_out" "$WORK/jar"

# 1) facade compiles (the GL/AWTContext surface the plugin references, methods `native`).
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -nowarn -d "$WORK/facade_out" $(find "$FACADE" -name '*.java')
FACADE_LWJGL_CLASSES=$(cd "$WORK/facade_out" && find org/lwjgl -name '*.class' | wc -l | tr -d ' ')

# 2) explode the pristine jar; strip lwjgl + rlawt + the gpu package's CLASSES. For the gpu package delete ONLY
#    the real-build .class files (recompiled below) and KEEP its non-class RESOURCES — regions/regions.txt (read
#    by RegionManager's ctor) and the GLSL shaders (vert/frag/vertui/fragui/hsl_to_rgb/colorblind + scale/*.glsl,
#    loaded via getResourceAsStream at runtime then downported 330->ES in librlawt's glShaderSource). A blanket
#    rm of the package would drop them and the plugin would NPE on the null resource stream before startUp runs.
(cd "$WORK/jar" && unzip -q "$SRC")
rm -rf "$WORK/jar/org/lwjgl" "$WORK/jar/net/runelite/rlawt"
find "$WORK/jar/net/runelite/client/plugins/gpu" -name '*.class' -delete

# 3) recompile the unmodified delombok'd gpu sources against [facade : stripped-jar]. Recompiling (not reusing
#    the real-build bytecode) guarantees every reference resolves against facade classes we control.
set +e
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -nowarn -proc:none -cp "$WORK/facade_out:$WORK/jar" -d "$WORK/gpu_out" $(find "$DL" -name '*.java') 2>"$WORK/err.txt"
RC=$?
set -e
if [ "$RC" != 0 ]; then echo "!! gpu recompile FAILED ($(grep -c 'error:' "$WORK/err.txt") errors):" >&2; cat "$WORK/err.txt" >&2; exit 2; fi

# 4) repackage: drop the facade + recompiled gpu classes into the stripped tree.
cp -R "$WORK/facade_out/." "$WORK/jar/"
cp -R "$WORK/gpu_out/." "$WORK/jar/"

# 5) asserts — exactly one (facade) provider of each stripped namespace, no stale service providers, resources kept.
SURV=$(cd "$WORK/jar" && find org/lwjgl -name '*.class' 2>/dev/null | wc -l | tr -d ' ')
RLAWT_SURV=$(find "$WORK/jar/net/runelite/rlawt" -name '*.class' 2>/dev/null | wc -l | tr -d ' ')
GPU_CLASSES=$(cd "$WORK/jar" && find net/runelite/client/plugins/gpu -name '*.class' 2>/dev/null | wc -l | tr -d ' ')
SVC_LEAK=$( { grep -rIlE 'org\.lwjgl|net\.runelite\.rlawt' "$WORK/jar/META-INF/services" 2>/dev/null || true; } | wc -l | tr -d ' ')
GPU_GLSL=$(cd "$WORK/jar" && find net/runelite/client/plugins/gpu -maxdepth 1 -name '*.glsl' 2>/dev/null | wc -l | tr -d ' ')
GPU_REGIONS=$([ -f "$WORK/jar/net/runelite/client/plugins/gpu/regions/regions.txt" ] && echo 1 || echo 0)

# 6) rezip (keep the on-disk MANIFEST; --no-manifest = don't synthesize one).
NEW="$WORK/staged.jar"
"$JAR" --create --no-manifest --file "$NEW" -C "$WORK/jar" .
STAGED_MD5=$(cd "$WORK/jar" && find . -name '*.class' | sort | xargs cat | { md5 -q 2>/dev/null || md5sum | awk '{print $1}'; })

echo "facade lwjgl classes : $FACADE_LWJGL_CLASSES"
echo "org/lwjgl survivors  : $SURV   (must == facade lwjgl classes; all bridge-backed)"
echo "rlawt survivors      : $RLAWT_SURV   (facade AWTContext only)"
echo "gpu classes          : $GPU_CLASSES   (recompiled against facade; 21 sources + inner)"
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

if [ "$OK" != yes ]; then echo "MEGAVERDICT = ANDROID_GPU_STAGE_NOT_GREEN" >&2; exit 3; fi

mkdir -p "$(dirname "$OUT")"
mv "$NEW" "$OUT"
# Prune other-version leftovers: assets/jvm persists across version bumps (dev tree + CI runner workspace),
# and a second client-*-gpu.jar matching the runtime glob would ship in the APK alongside the fresh one.
find "$(dirname "$OUT")" -maxdepth 1 -name 'client-*-gpu.jar' ! -name "$(basename "$OUT")" -delete
echo "staged Android gpu jar: $OUT"
echo "MEGAVERDICT = ANDROID_GPU_STAGE_GREEN"
