#!/usr/bin/env bash
# B0.5 shadow program — host gate covering the configs the MAIN probe can't.
#
# The Z0 probe (ZoneShaderAssemble buildConfig) assembles shadow at SHADOW_MODE=0 / SHADOW_TRANSPARENCY=false,
# because scene/ui must see SHADOW_MODE=0 (the runtime compiles scene with config=OFF). But the zone renderer
# compiles the shadow PROGRAMS at SHADOW_MODE_FAST(1) and SHADOW_MODE_DETAILED(2) UNCONDITIONALLY, with
# SHADOW_TRANSPARENCY=config (default true). Those branches were never gated → the device hit an int/float
# compile error in shadow_frag's transparency block ("'-' does not operate on 'int' and 'float'").
#
# This gate assembles shadow_vert/shadow_frag at all four {FAST,DETAILED} x {transparency on,off} combos and
# runs glslangValidator (bumped to 310 es to dodge glslang's interface-block false-positives — same trick as
# glslang-check.sh; Apple's EAGL accepts the 300 es interface blocks). GREEN = no int/float operand errors in
# any combo. glslang works for shadow (unlike scene), so this is a real host check; the device app run is the
# integration gate. Verdict: ALL_SHADOW_CONFIGS_CLEAN.
set -euo pipefail
cd "$(dirname "$0")"

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
GV="${GV:-/opt/homebrew/bin/glslangValidator}"
[ -x "$GV" ] || { echo "!! glslangValidator not found at $GV" >&2; exit 1; }

SRC=assemble/ZoneShaderAssemble.java
BAK="$(mktemp)"; cp "$SRC" "$BAK"
trap 'cp "$BAK" "$SRC"; rm -f "$BAK"; ( cd assemble && "$JAVA_HOME/bin/javac" ZoneShaderAssemble.java >/dev/null 2>&1 && "$JAVA_HOME/bin/java" ZoneShaderAssemble >/dev/null 2>&1 ) || true' EXIT

fail=0
for MODE in 1 2; do for TR in true false; do
  cp "$BAK" "$SRC"
  sed -i '' "s/define(\"SHADOW_MODE\", [0-9]*)/define(\"SHADOW_MODE\", $MODE)/; s/define(\"SHADOW_TRANSPARENCY\", [a-z]*)/define(\"SHADOW_TRANSPARENCY\", $TR)/" "$SRC"
  ( cd assemble && "$JAVA_HOME/bin/javac" ZoneShaderAssemble.java >/dev/null 2>&1 && "$JAVA_HOME/bin/java" ZoneShaderAssemble >/dev/null 2>&1 )
  for s in vert frag; do
    tmp="$(mktemp).${s}"
    sed 's/#version 300 es/#version 310 es/' "assembled/shadow.$s.assembled.glsl" > "$tmp"
    out=$("$GV" "$tmp" 2>&1 | grep -iE "does not operate|wrong operand|cannot convert|Incompatible" || true)
    rm -f "$tmp"
    if [ -n "$out" ]; then
      echo "FAIL  SHADOW_MODE=$MODE TRANSPARENCY=$TR  shadow.$s"; echo "$out" | head -3; fail=1
    else
      echo "ok    SHADOW_MODE=$MODE TRANSPARENCY=$TR  shadow.$s"
    fi
  done
done; done

echo
[ "$fail" = 0 ] && echo "MEGAVERDICT = ALL_SHADOW_CONFIGS_CLEAN" || { echo "MEGAVERDICT = SHADOW_CONFIGS_HAVE_INT_FLOAT_SITES" >&2; exit 2; }
