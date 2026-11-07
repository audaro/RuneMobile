#!/usr/bin/env bash
# RLHD shader matrix: host gate for the 117HD shaders as a port compiles them. For each config variant below,
# RlhdShaderDump assembles every program the zone renderer builds (through the real HdPlugin.getShaderIncludes(), with
# that config), then downport_check.py applies that port's runtime downport and validates each stage with glslang.
# The shaders are the port's overlay from the working tree laid over its pristine rlhd-src/ resources, as the staged
# jar has them; the classes come from the port's stage work dir. Run after any change to an overlay, to a runtime
# downport (RouteCBridge.m on iOS, librlawt.cpp on Android) or to the RLHD pin.
#
#   tools/shader-matrix/run-matrix.sh ios            # all variants, iOS (ES 3.0 driver)
#   tools/shader-matrix/run-matrix.sh android pcss   # the variants whose name starts with "pcss", Android (ES 3.2)
# Needs the port's stage work dir from a prior stager run (the script names it), and glslangValidator.
# Output goes to <work>/shader-matrix/<variant>/ (assembled stages, chk-*.glsl as validated, report.txt).
# Verdict: SHADER_MATRIX_GREEN when every stage of every variant validates.
#
# glslang is the fast filter, not the authority: the drivers that matter are the phones' (iOS sim-gate.sh boots
# 117HD in the simulator, whose GL is Apple's software renderer).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/tools/shader-matrix"
PORT="${1:-}"; shift || true
case "$PORT" in
	ios)
		BASE="$ROOT/ios/dev-tools/gpu-zone"; WORK="$BASE/stage-zone-work"; OVERLAY="$BASE/ios-overrides"
		BRIDGE="$ROOT/ios/dev-tools/gpu-routec/app/RouteCBridge.m"; STAGER="ios/dev-tools/gpu-zone/stage-ios-zone-jar.sh" ;;
	android)
		BASE="$ROOT/android/dev-tools/gpu"; WORK="$BASE/stage-rlhd-work"; OVERLAY="$BASE/shader-overlay/rs117/hd"
		BRIDGE="$ROOT/android/app/src/main/cpp/librlawt.cpp"; STAGER="android/dev-tools/gpu/stage-rlhd-zone-jar.sh" ;;
	*) echo "usage: $0 ios|android [variant-prefix]" >&2; exit 2 ;;
esac

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21}"
command -v glslangValidator >/dev/null || { echo "!! glslangValidator not found (brew install glslang)" >&2; exit 1; }
for d in rlhd_out facade_out cp; do
	[ -d "$WORK/$d" ] || { echo "!! $WORK/$d missing - run $STAGER first" >&2; exit 1; }
done
RES="$BASE/rlhd-src/src/main/resources"
[ -d "$RES/rs117/hd" ] || { echo "!! $RES missing - the stager fetches rlhd-src" >&2; exit 1; }
[ -d "$OVERLAY" ] || { echo "!! overlay $OVERLAY missing" >&2; exit 1; }
OUT="$WORK/shader-matrix"
rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/overrides/rs117"
ln -s "$OVERLAY" "$OUT/overrides/rs117/hd"
CP="$OUT/overrides:$RES:$WORK/rlhd_out:$WORK/facade_out:$WORK/cp"
"$JAVA_HOME/bin/javac" -nowarn -d "$OUT/classes" -cp "$CP" "$HERE/RlhdShaderDump.java" || { echo "!! RlhdShaderDump did not compile" >&2; exit 1; }

# The MAT_ constants the shaders reference (HdPlugin's MATERIAL_CONSTANTS include defines one per MATERIAL_MAP entry).
MATS=$(grep -rhoE '\bMAT_[A-Z0-9_]+' "$RES/rs117/hd" "$OVERLAY" | sed 's/^MAT_//' | sort -u | paste -sd, -)

# name|config overrides (HdPluginConfig method=value; enums by constant name). Between them the variants give each
# config-driven define in getShaderIncludes() every value it can take at least once (each value, not each
# combination); "default" is HdPluginConfig's defaults. A new config-driven define on an RLHD bump needs a variant.
VARIANTS=(
	"default|"
	"alloff|daylightCycle=OFF shadowMode=OFF dynamicLights=NONE parallaxOcclusionMapping=false normalMapping=false windDisplacement=false characterDisplacement=false terrainShadows=false shadowTransparency=false starMode=OFF enableNebulae=false pointSprites=OFF waterSpecularReflections=false"
	"pcss|shadowFiltering=PCSS shadowMode=FAST tiledLighting=OFF dynamicLights=MANY glareIntensity=50 colorBlindness=PROTANOPE flatShading=true vanillaColorBanding=true legacyGreyColors=true shadingMode=VANILLA centroidQualifier=ON uiScalingMode=XBR starMode=ARTISTIC pointSprites=ON @colorFilter=SEPIA"
	"pcss-detailed|shadowFiltering=PCSS shadowMode=DETAILED shadowTransparency=false uiScalingMode=NEAREST colorBlindness=DEUTERANOPE shadingMode=NONE starMode=STATIC daylightCycle=NIGHT"
	"nearest|shadowFiltering=NEAREST uiScalingMode=LINEAR shadingMode=UNLIT colorBlindness=TRITANOPE dynamicLights=FEW tiledLighting=ON"
	"smoothlow|shadowFiltering=SMOOTH_LOW uiScalingMode=MITCHELL terrainShadows=false"
	"ditherlow|shadowFiltering=DITHERED_LOW uiScalingMode=CATMULL_ROM"
	"ditherhigh|shadowFiltering=DITHERED_HIGH shadowMode=FAST"
	"pixelated|shadowFiltering=PIXELATED centroidQualifier=OFF pointSprites=ON"
	"misc|wireframe=true windowsHdrCorrection=true legacyBoatSilhouettes=true normalMapping=false waterSpecularReflections=false enableNebulae=false"
	"iosdefaults|tiledLighting=OFF dynamicLights=FEW shadowMode=FAST shadowTransparency=false shadowFiltering=SMOOTH_HIGH parallaxOcclusionMapping=false windDisplacement=false characterDisplacement=false daylightCycle=OFF"
	"pomonly|parallaxOcclusionMapping=true normalMapping=false windDisplacement=false characterDisplacement=true shadowMode=FAST daylightCycle=OFF"
)

fail=0; ran=0
for v in "${VARIANTS[@]}"; do
	name=${v%%|*}; args=${v#*|}
	[ -n "${1:-}" ] && [[ "$name" != "$1"* ]] && continue
	ran=$((ran + 1))
	dir="$OUT/$name"
	# shellcheck disable=SC2086 # args is a space-separated list of key=value overrides
	dump=$("$JAVA_HOME/bin/java" -cp "$OUT/classes:$CP" RlhdShaderDump "$dir/assembled" "@mats=$MATS" $args 2>&1)
	if ! printf '%s\n' "$dump" | grep -q '^assembled [0-9]* stages'; then
		echo "$name: !! assembly failed"; printf '%s\n' "$dump" | grep -v '^\s*at ' | tail -5; fail=1; continue
	fi
	/usr/bin/python3 "$HERE/downport_check.py" "$PORT" "$BRIDGE" "$dir/assembled" "$dir" > "$dir/report.txt" 2>&1
	rc=$?
	echo "$name: $(grep -m1 '^TOTAL' "$dir/report.txt" || echo '!! no TOTAL line')"
	if [ $rc -ne 0 ]; then fail=1; sed -n '/^TOTAL/,$p' "$dir/report.txt" | sed 1d | head -40; fi
done
[ $ran -gt 0 ] || { echo "!! no variant matches '${1:-}'" >&2; exit 1; }
if [ $fail -eq 0 ]; then echo "SHADER_MATRIX_GREEN ($PORT, $ran variants)"; else echo "SHADER_MATRIX_RED ($PORT)"; exit 1; fi
