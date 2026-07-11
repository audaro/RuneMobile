#!/usr/bin/env bash
# Track G AG2.5-b — stage the Android-variant 117HD (RLHD) Zone jar. Sibling of stage-android-gpu-jar.sh.
#
# RLHD is an EXTERNAL hub plugin (vendored, gitignored, at rlhd-src/, rev 7dded59, targets RuneLite 1.12.+), so
# unlike the base gpu plugin it is NOT inside the client jar. This script compiles the UNMODIFIED RLHD source
# against [facade-src + a lwjgl-STRIPPED client jar] — i.e. our pure-Java org.lwjgl.{opengl,opencl,system} +
# net.runelite.rlawt.AWTContext facade is the SOLE provider of every LWJGL symbol RLHD references. Stripping
# real lwjgl from the compile classpath is deliberate: if the facade is missing any GL/CL/system symbol RLHD
# uses, javac fails here rather than NoClassDefFound-ing at runtime. lombok runs as an annotation processor
# (equivalent to delombok). The OpenCL surface is a symbols-only stub (Zone never creates a CL context, so no cl*
# call ever runs); it exists purely so the class-load graph (HdPlugin -> UBOCompute -> UniformBuffer ->
# SharedGLBuffer -> OpenCLManager, and ZoneRenderer -> UniformBuffer) resolves.
#
# Output: client-<ver>-rlhd.jar = rs117/** classes (facade-backed) + RLHD resources (shaders/JSON/textures). It
# carries NO org.lwjgl/rlawt — the facade ships in the base-gpu client-<ver>-gpu.jar, which must be on the
# classpath alongside this jar at runtime. Deterministic + md5-gateable: pass an expected class-manifest md5 as $1.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../../.. && pwd)"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
JAVAC="$JAVA_HOME/bin/javac"
JAR="$JAVA_HOME/bin/jar"
VERSION="$(sed -n 's/^project\.build\.version=//p' "$ROOT/gradle.properties")"
[ -n "$VERSION" ] || { echo "!! could not read project.build.version from gradle.properties" >&2; exit 1; }

# Use the PROJECT-PINNED lombok (libs.versions.toml: `lombok = "x.y.z"`) — the exact jar the real build uses.
# An arbitrary cached 1.18.x could be an unrelated/incompatible version, and an old one crashes JDK 21 javac
# (NoSuchFieldError JCTree$JCImport.qualid). shadowJar (which runs before staging) pulls the pinned jar into
# the cache. Fall back to newest-cached only if the pin is unreadable.
LOMBOK_VER="$(sed -n 's/^lombok[[:space:]]*=[[:space:]]*"\([0-9.]*\)".*/\1/p' "$ROOT/libs.versions.toml" | head -1)"
if [ -z "${LOMBOK:-}" ] && [ -n "$LOMBOK_VER" ]; then
  LOMBOK="$(find "$HOME/.gradle/caches" -name "lombok-${LOMBOK_VER}.jar" 2>/dev/null | grep -vE 'sources|javadoc|plugin' | head -1)"
fi
LOMBOK="${LOMBOK:-$(find "$HOME/.gradle/caches" -name 'lombok-1.18.*.jar' 2>/dev/null | grep -vE 'sources|javadoc|plugin' | sort -V | tail -1)}"
FACADE="$(pwd)/facade-src"
RLHD="$(pwd)/rlhd-src"
SRC="${SRC:-$ROOT/runelite-client/build/libs/client-${VERSION}-shaded.jar}"
OUT="${OUT:-$ROOT/android/app/src/main/assets/jvm/client-${VERSION}-rlhd.jar}"
EXPECT_MD5="${1:-}"

[ -f "$SRC" ]    || { echo "!! pristine shaded jar missing: $SRC (run ./gradlew :client:shadowJar)" >&2; exit 1; }
[ -d "$FACADE" ] || { echo "!! facade-src missing: $FACADE" >&2; exit 1; }
# rlhd-src is the vendored 117HD/RLHD tree (gitignored) — self-provision on a fresh workspace (CI) by fetching
# the pinned rev; the commit SHA is the integrity pin (same rev the HD blueprint audited). Re-provision when
# the tree is ABSENT or its checked-out HEAD != the pin (RLHD_REV bumped, or a persistent runner/dev workspace
# still holds old sources, or a hand-vendored tree with no .git) so a rev bump can't silently compile against
# stale sources. It's a full git checkout here, so `git rev-parse HEAD` is the actual-vs-pinned check.
RLHD_REV=7dded591a21d4c17c2d8c077c8ac0ecfbbd7313f
if [ ! -d "$RLHD/src/main/java" ] || [ "$(git -C "$RLHD" rev-parse HEAD 2>/dev/null)" != "$RLHD_REV" ]; then
  echo "== rlhd-src absent or != pinned rev — (re)fetching 117HD/RLHD @ $RLHD_REV =="
  rm -rf "$RLHD"; mkdir -p "$RLHD"
  git -C "$RLHD" init -q
  git -C "$RLHD" fetch -q --depth 1 https://github.com/117HD/RLHD.git "$RLHD_REV"
  git -C "$RLHD" checkout -q FETCH_HEAD
fi
[ -d "$RLHD/src/main/java" ] || { echo "!! rlhd-src missing: $RLHD (vendored, gitignored)" >&2; exit 1; }
[ -n "$LOMBOK" ] && [ -f "$LOMBOK" ] || { echo "!! lombok jar not found in ~/.gradle/caches" >&2; exit 1; }

WORK="$(pwd)/stage-rlhd-work"
rm -rf "$WORK"; mkdir -p "$WORK/facade_out" "$WORK/rlhd_out" "$WORK/cp" "$WORK/jar"

# 1) facade compiles (the GL/CL/system/AWTContext surface RLHD references).
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -nowarn -d "$WORK/facade_out" $(find "$FACADE" -name '*.java')
FACADE_LWJGL_CLASSES=$(cd "$WORK/facade_out" && find org/lwjgl -name '*.class' | wc -l | tr -d ' ')

# 2) explode the pristine client jar and STRIP real lwjgl + rlawt -> the facade becomes the sole LWJGL provider
#    on the compile classpath (so a missing facade symbol is a javac error, not a runtime NoClassDefFound).
(cd "$WORK/cp" && unzip -q "$SRC")
rm -rf "$WORK/cp/org/lwjgl" "$WORK/cp/net/runelite/rlawt"

# 2b) stage RLHD java sources into a work tree, then layer our tracked java-overlay/ on top — overlay files
#     replace the same-path rlhd-src files (e.g. the JAU14->JAU11 camera-angle fix in StaticAlphaSortingJob),
#     so our Java fixes are committed + reproducible while rlhd-src stays pristine (as shader-overlay does for GLSL).
JSRC="$WORK/rlhd_java"; mkdir -p "$JSRC"; cp -R "$RLHD/src/main/java/." "$JSRC/"
# Lombok config lives at the rlhd-src ROOT (lombok.accessors.chain=true → setters return `this`); carry it into
# the work tree so chained-setter sources (e.g. Environment.java) still compile when built from $JSRC, not rlhd-src.
[ -f "$RLHD/lombok.config" ] && cp "$RLHD/lombok.config" "$JSRC/lombok.config"
JOVERLAY="$(pwd)/java-overlay"
if [ -d "$JOVERLAY" ]; then
	cp -R "$JOVERLAY/." "$JSRC/"
	JOVR=$(cd "$JOVERLAY" && find . -name '*.java' | wc -l | tr -d ' ')
	echo "java overlay applied  : $JOVR file(s)"
fi

# 3) compile the RLHD sources (rlhd-src + java-overlay) against [facade : stripped-client], lombok as annotation processor.
set +e
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -nowarn -proc:full -cp "$WORK/facade_out:$WORK/cp:$LOMBOK" -processorpath "$LOMBOK" \
	-d "$WORK/rlhd_out" $(find "$JSRC" -name '*.java') 2>"$WORK/err.txt"
RC=$?
set -e
# On failure show javac 'error:' lines, or the raw head when there are none (e.g. an annotation-processor
# crash) — a bare no-match grep would die under pipefail BEFORE printing anything or reaching exit 2.
if [ "$RC" != 0 ]; then
  echo "!! RLHD recompile FAILED:" >&2
  { grep 'error:' "$WORK/err.txt" || head -40 "$WORK/err.txt"; } | head -40 >&2
  exit 2
fi

# 3b) compile the AG2.5-b class-load + loader-data probe (RLHDProbe) against [facade : stripped-client] (it needs
#     only Gson + the facade Configuration; it reaches the RLHD classes via Class.forName at runtime).
if [ -f "$(pwd)/RLHDProbe.java" ]; then
	"$JAVAC" -nowarn -cp "$WORK/facade_out:$WORK/cp" -d "$WORK/rlhd_out" "$(pwd)/RLHDProbe.java"
fi

# 4) package: rs117/** classes + RLHDProbe + ALL RLHD resources (shaders/JSON/textures). NO org.lwjgl/rlawt
#    (facade is in the base-gpu jar). Keep the resource tree exactly as RLHD loads it via getResourceAsStream.
cp -R "$WORK/rlhd_out/." "$WORK/jar/"
[ -d "$RLHD/src/main/resources" ] && cp -R "$RLHD/src/main/resources/." "$WORK/jar/"
# AG3-c shader overlay: our GLSL-ES ports of the Zone shaders (RLHD's #version 330 shaders use int literals in
# float contexts that strict GLSL ES rejects). The overlay holds full fixed copies that replace the pristine
# rlhd-src ones — committed + reproducible, keeping rlhd-src untouched. (rc_downport still handles version/
# precision/noperspective at load; the overlay handles the int->float typing the downport can't do safely.)
OVERLAY="$(pwd)/shader-overlay"
if [ -d "$OVERLAY" ]; then
	cp -R "$OVERLAY/." "$WORK/jar/"
	OVR=$(cd "$OVERLAY" && find . -name '*.glsl' | wc -l | tr -d ' ')
	echo "shader overlay applied : $OVR file(s)"
fi

# 5) asserts.
RLHD_CLASSES=$(cd "$WORK/jar" && { find rs117 -name '*.class' 2>/dev/null || true; } | wc -l | tr -d ' ')
LWJGL_LEAK=$(cd "$WORK/jar" && { find org/lwjgl net/runelite/rlawt -name '*.class' 2>/dev/null || true; } | wc -l | tr -d ' ')
GLSL=$(cd "$WORK/jar" && find . -name '*.glsl' 2>/dev/null | wc -l | tr -d ' ')
JSON=$(cd "$WORK/jar" && find . -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
ZONE=$([ -f "$WORK/jar/rs117/hd/renderer/zone/ZoneRenderer.class" ] && echo 1 || echo 0)
OCL=$([ -f "$WORK/jar/rs117/hd/opengl/compute/OpenCLManager.class" ] && echo 1 || echo 0)

# 6) rezip + class-manifest md5 (deterministic).
NEW="$WORK/staged.jar"
"$JAR" --create --no-manifest --file "$NEW" -C "$WORK/jar" .
STAGED_MD5=$(cd "$WORK/jar" && find . -name '*.class' | sort | xargs cat | { md5 -q 2>/dev/null || md5sum | awk '{print $1}'; })

echo "facade lwjgl classes : $FACADE_LWJGL_CLASSES"
echo "rlhd classes         : $RLHD_CLASSES   (facade-backed; must be >=290)"
echo "lwjgl/rlawt leak     : $LWJGL_LEAK   (must be 0; facade ships in the gpu jar)"
echo "glsl shaders         : $GLSL   (must be >=40)"
echo "loader json          : $JSON   (must be >=6)"
echo "ZoneRenderer.class   : $ZONE   (must be 1)"
echo "OpenCLManager.class  : $OCL   (must be 1)"
echo "staged class md5     : $STAGED_MD5${EXPECT_MD5:+  (expected $EXPECT_MD5)}"

OK=yes
[ "$RLHD_CLASSES" -ge 290 ] || OK=no
[ "$LWJGL_LEAK" = 0 ] || OK=no
[ "$GLSL" -ge 40 ] || OK=no
[ "$JSON" -ge 6 ] || OK=no
[ "$ZONE" = 1 ] || OK=no
[ "$OCL" = 1 ] || OK=no
if [ -n "$EXPECT_MD5" ] && [ "$STAGED_MD5" != "$EXPECT_MD5" ]; then OK=no; fi

if [ "$OK" != yes ]; then echo "MEGAVERDICT = ANDROID_RLHD_STAGE_NOT_GREEN" >&2; exit 3; fi

mkdir -p "$(dirname "$OUT")"
mv "$NEW" "$OUT"
# Prune other-version leftovers (same rationale as stage-android-gpu-jar.sh).
find "$(dirname "$OUT")" -maxdepth 1 -name 'client-*-rlhd.jar' ! -name "$(basename "$OUT")" -delete
echo "staged Android rlhd jar: $OUT"
echo "MEGAVERDICT = ANDROID_RLHD_STAGE_GREEN"
