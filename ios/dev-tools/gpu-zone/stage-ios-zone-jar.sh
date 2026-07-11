#!/usr/bin/env bash
# Phase B0.1 — stage the iOS-variant 117HD (RLHD) Zone jar. iOS analogue of the base-gpu
# `gpu-routec/stage-ios-gpu-jar.sh` and the Android `gpu/stage-rlhd-zone-jar.sh`.
#
# RLHD is an EXTERNAL hub plugin (vendored, gitignored, at rlhd-src/src/, rev 7dded59, targets RuneLite 1.12.+),
# so unlike the base gpu plugin it is NOT inside the client jar. This script compiles the RLHD source — pristine
# except the committed java-overrides/ files laid over it (step 2b; today = the materials subsystem, working
# around Apple's 16 KB uniform-block cap with an RGBA32I material-store texture) —
# against [facade/ + a lwjgl-STRIPPED client jar] — i.e. our pure-Java org.lwjgl.{opengl,opencl,system} +
# net.runelite.rlawt.AWTContext facade is the SOLE provider of every LWJGL symbol RLHD references. Stripping real
# lwjgl from the compile classpath is deliberate: a facade symbol RLHD uses but we don't declare becomes a javac
# error HERE, not a NoClassDefFound at runtime. lombok runs as an annotation processor (equivalent to delombok).
# The OpenCL surface is a symbols-only stub (the Zone path never creates a CL context, so no cl* call ever runs);
# it exists purely so the class-load graph (HdPlugin -> UBOCompute -> UniformBuffer -> OpenCLManager, and
# ZoneRenderer -> UniformBuffer) resolves.
#
# The facade methods are declared `native` (device-bound). At B0.1 (this script) we only prove COMPILE-green;
# the native RegisterNatives bindings in RouteCBridge.m are the separate B0.2/B0.3 work. The facade here is the
# spec for that delta — it enumerates every GL/CL/system symbol the iOS bridge must service.
#
# Output: client-rlhd.jar = rs117/** classes (facade-backed) + RLHD shader/JSON resources. It carries NO
# org.lwjgl/rlawt — at runtime the facade ships in the base-gpu client-shaded.jar staged alongside it.
# Deterministic + md5-gateable: pass an expected class-manifest md5 as $1.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../../.. && pwd)"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
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
FACADE="$(pwd)/facade"
RLHD="$(pwd)/rlhd-src"
SRC="${SRC:-$ROOT/runelite-client/build/libs/client-${VERSION}-shaded.jar}"
# Version-AGNOSTIC OUT name (client-rlhd.jar): project.yml and JVMLauncher.m reference it as a fixed string,
# so an upstream version bump can't break the bundle (the SOURCE jar above stays version-precise).
OUT="${OUT:-$ROOT/ios/app/jvm-resources/client-rlhd.jar}"
EXPECT_MD5="${1:-}"

[ -f "$SRC" ]    || { echo "!! pristine shaded jar missing: $SRC (run ./gradlew :client:shadowJar)" >&2; exit 1; }
[ -d "$FACADE" ] || { echo "!! facade missing: $FACADE" >&2; exit 1; }
# rlhd-src/src is the vendored 117HD/RLHD tree (gitignored) — self-provision on a fresh workspace (CI) by
# fetching the pinned rev per rlhd-src/PROVENANCE.md; the commit SHA is the integrity pin. A `.rev` stamp
# records what was fetched: re-provision when it's ABSENT (hand-vendored, or a fresh tree) or STALE (RLHD_REV
# was bumped but a persistent runner/dev workspace still holds the old sources) so a rev bump can't silently
# compile against stale sources. rlhd-src is pristine vendored state (overlays are layered in $WORK, never
# here), so re-fetching identical bytes is a safe no-op.
RLHD_REV=7dded591a21d4c17c2d8c077c8ac0ecfbbd7313f
if [ ! -d "$RLHD/src/main/java" ] || [ "$(cat "$RLHD/src/.rev" 2>/dev/null)" != "$RLHD_REV" ]; then
  echo "== rlhd-src/src absent or != pinned rev — (re)fetching 117HD/RLHD @ $RLHD_REV =="
  T="$(mktemp -d)"
  git -C "$T" init -q
  git -C "$T" fetch -q --depth 1 https://github.com/117HD/RLHD.git "$RLHD_REV"
  git -C "$T" checkout -q FETCH_HEAD
  rm -rf "$RLHD/src"; mkdir -p "$RLHD/src"
  cp -R "$T/src/main" "$RLHD/src/"
  cp "$T/lombok.config" "$RLHD/src/lombok.config"
  printf '%s\n' "$RLHD_REV" > "$RLHD/src/.rev"
  rm -rf "$T"
fi
[ -d "$RLHD/src/main/java" ] || { echo "!! rlhd-src/src missing: $RLHD/src (vendored, gitignored — re-fetch per rlhd-src/PROVENANCE.md)" >&2; exit 1; }
[ -n "$LOMBOK" ] && [ -f "$LOMBOK" ] || { echo "!! lombok jar not found in ~/.gradle/caches" >&2; exit 1; }

# Refuse a non-pristine source (already stripped) — guards against feeding an iOS variant back in.
SRC_LWJGL=$(unzip -l "$SRC" | grep -c 'org/lwjgl/.*[.]class' || true)
[ "$SRC_LWJGL" -gt 0 ] || { echo "!! SRC has no org/lwjgl classes — not a pristine shaded jar: $SRC" >&2; exit 1; }

WORK="$(pwd)/stage-zone-work"
rm -rf "$WORK"; mkdir -p "$WORK/facade_out" "$WORK/rlhd_out" "$WORK/cp" "$WORK/jar" "$WORK/rlhd_src"

# 1) facade compiles (the GL/CL/system/AWTContext surface RLHD references; methods `native`).
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -nowarn -d "$WORK/facade_out" $(find "$FACADE" -name '*.java')
FACADE_LWJGL_CLASSES=$(cd "$WORK/facade_out" && find org/lwjgl -name '*.class' | wc -l | tr -d ' ')

# 2) explode the pristine client jar and STRIP real lwjgl + rlawt -> the facade is the sole LWJGL provider on the
#    compile classpath (so a missing facade symbol is a javac error, not a runtime NoClassDefFound).
(cd "$WORK/cp" && unzip -q "$SRC")
rm -rf "$WORK/cp/org/lwjgl" "$WORK/cp/net/runelite/rlawt"

# 2b) iOS Java overlay: copy the pristine RLHD source tree (the whole src/ level — lombok.config lives at
#     rlhd-src/src/lombok.config and lombok resolves it by bubbling up from each source dir), then lay the
#     committed java-overrides/ files over it. Same pattern as the ios-overrides GLSL overlay: keeps rlhd-src
#     untouched (reproducible from PROVENANCE.md) while the iOS-only deltas live in a committable dir.
#     Today's delta = the materials subsystem (UBOMaterials 57 KB > Apple's 16 KB uniform-block cap -> the
#     shaders read an RGBA32I material-store texture instead; MaterialManager uploads it, the scene/shadow
#     programs wire the sampler).
cp -R "$RLHD/src/." "$WORK/rlhd_src/"
JOVERLAY="$(pwd)/java-overrides"
if [ -d "$JOVERLAY" ]; then
	cp -R "$JOVERLAY/." "$WORK/rlhd_src/main/java/"
	JOVR=$(cd "$JOVERLAY" && find . -name '*.java' | wc -l | tr -d ' ')
	echo "java overlay applied   : $JOVR java-override(s) -> rlhd_src/main/java/"
fi

# 3) compile the (overlaid) RLHD sources against [facade : stripped-client], lombok as annotation processor.
set +e
# shellcheck disable=SC2046  # intentional: word-split the .java file list into separate javac args (paths have no spaces)
"$JAVAC" -nowarn -proc:full -cp "$WORK/facade_out:$WORK/cp:$LOMBOK" -processorpath "$LOMBOK" \
	-d "$WORK/rlhd_out" $(find "$WORK/rlhd_src/main/java" -name '*.java') 2>"$WORK/err.txt"
RC=$?
set -e
# On failure show javac 'error:' lines, or the raw head when there are none (e.g. an annotation-processor
# crash) — a bare no-match grep would die under pipefail BEFORE printing anything or reaching exit 2.
if [ "$RC" != 0 ]; then
  echo "!! RLHD recompile FAILED:" >&2
  { grep 'error:' "$WORK/err.txt" || head -40 "$WORK/err.txt"; } | head -40 >&2
  exit 2
fi

# 4) package: rs117/** classes + ALL RLHD resources (shaders/JSON). NO org.lwjgl/rlawt (facade ships in the gpu
#    jar). Keep the resource tree exactly as RLHD loads it via getResourceAsStream. The shaders ship pristine
#    (#version 330/420); the iOS downporter rewrites them to ES 3.00 at glShaderSource time (same seam as base gpu).
cp -R "$WORK/rlhd_out/." "$WORK/jar/"
[ -d "$RLHD/src/main/resources" ] && cp -R "$RLHD/src/main/resources/." "$WORK/jar/"

# 4b) iOS ES-3.0 shader overlay: the Z0-proven hand-ported copies of the pervasively cast-heavy includes
#     (utils/{color_utils,water,fog}.glsl) that the load-time string downport can't safely transform. RLHD's own
#     #include resolves these from rs117/hd/** at runtime, so dropping the ports there makes the runtime-assembled
#     scene/shadow shaders match the Z0 assembled ES300 (which compiled+linked on device). The targeted per-site
#     casts + textureFaces TBO repack are applied at glShaderSource time by RouteCBridge downportShaderSource.
#     ios-overrides/utils/foo.glsl -> rs117/hd/utils/foo.glsl. Keeps rlhd-src untouched (committed + reproducible).
OVERLAY="$(pwd)/ios-overrides"
if [ -d "$OVERLAY" ]; then
	mkdir -p "$WORK/jar/rs117/hd"
	cp -R "$OVERLAY/." "$WORK/jar/rs117/hd/"
	OVR=$(cd "$OVERLAY" && find . -name '*.glsl' | wc -l | tr -d ' ')
	echo "shader overlay applied : $OVR ios-override(s) -> rs117/hd/"
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

if [ "$OK" != yes ]; then echo "MEGAVERDICT = IOS_RLHD_STAGE_NOT_GREEN" >&2; exit 3; fi

mkdir -p "$(dirname "$OUT")"
mv "$NEW" "$OUT"
echo "staged iOS rlhd jar  : $OUT"
echo "MEGAVERDICT = IOS_RLHD_STAGE_GREEN"
