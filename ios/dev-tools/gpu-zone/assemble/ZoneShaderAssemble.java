/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */

// Standalone, dependency-free host-JVM assembler for the RLHD zone shaders. Replicates the resolution algorithm of
// RLHD's rs117.hd.opengl.shader.ShaderIncludes.parse() (vendored under ../rlhd-src/java for reference) WITHOUT its
// lwjgl/ResourcePath/UniformBuffer dependencies: the UBO std140 blocks are hand-written in uniforms/*.glsl (plain
// #include), and the #define identifiers (ZONE_RENDERER, UI_SCALING_MODE, MATERIAL_GETTER, ...) arrive as
// `#include IDENTIFIER` directives resolved from the same fixed define map HdPlugin.getShaderIncludes() builds.
//
// Produces ../assembled/<name>.<stage>.assembled.glsl (flat GLSL, all #include/#define resolved, still desktop
// #version 330) — the input the iOS ZoneDownport then rewrites to ES 3.00 and the Z0 probe compiles on EAGL.
//
// Config = a MINIMAL flat-scene set (ZONE_RENDERER on; shadows/tiled/dynamic-lights/displacement OFF) — the B0
// bring-up target. Grow the config (and re-run) as later B-phases turn features on. Unknown `#include IDENTIFIER`
// or missing files are reported (not silently stubbed) so the define map's gaps are explicit.
//
// Build+run:  javac ZoneShaderAssemble.java && java ZoneShaderAssemble

import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;

public class ZoneShaderAssemble {
	static final Path SHADER_ROOT = Paths.get("..", "rlhd-src", "shaders", "hd").toAbsolutePath().normalize();
	// Hand-maintained iOS ES-3.0 shader overrides, resolved BEFORE rlhd-src for `<...>` includes. Used only for
	// pervasively cast-heavy files (e.g. utils/color_utils.glsl) where a verbatim-with-casts copy beats dozens of
	// brittle downporter string rules (blueprint policy). Mirrors the rlhd-src/shaders/hd tree layout.
	static final Path OVERRIDE_ROOT = Paths.get("..", "ios-overrides").toAbsolutePath().normalize();
	static final Path OUT_DIR = Paths.get("..", "assembled").toAbsolutePath().normalize();

	// GL shader-type constants (for the SHADER_TYPE define block, mirroring ShaderTemplate).
	static final int GL_VERTEX_SHADER = 35633, GL_FRAGMENT_SHADER = 35632, GL_GEOMETRY_SHADER = 36313, GL_COMPUTE_SHADER = 37305;

	// The zone-path program entry shaders to assemble: name -> (file, glStage[, TILED_LIGHTING_LAYER]). geometry/
	// compute are NOT ported. The optional 4th column is the per-program TILED_LIGHTING_LAYER value for the tiled-
	// lighting culling pass (set into the include map before assembling that target; ignored otherwise). HdPlugin
	// compiles DynamicLights.MAX_LAYERS_PER_TILE (12) of these, one per layer; layer 0 takes the `#if
	// TILED_LIGHTING_LAYER > 0` FALSE branch (no array read) and layers >0 the TRUE branch (read prior layers), so
	// the gate validates BOTH (layer 0 + layer 1) — layers 2..11 are structurally identical to layer 1.
	static final String[][] TARGETS = {
		{ "scene",  "scene_vert.glsl",  "V" },
		{ "scene",  "scene_frag.glsl",  "F" },
		{ "shadow", "shadow_vert.glsl", "V" },
		{ "shadow", "shadow_frag.glsl", "F" },
		{ "ui",     "ui_vert.glsl",     "V" },
		{ "ui",     "ui_frag.glsl",     "F" },
		{ "tiled_l0", "tiled_lighting_vert.glsl", "V", "0" },
		{ "tiled_l0", "tiled_lighting_frag.glsl", "F", "0" },
		{ "tiled_l1", "tiled_lighting_vert.glsl", "V", "1" },
		{ "tiled_l1", "tiled_lighting_frag.glsl", "F", "1" },
	};

	final Map<String, String> includeMap = new HashMap<>();   // identifier -> replacement text
	final List<String> missing = new ArrayList<>();           // unresolved identifier includes (reported)
	final Deque<Path> fileStack = new ArrayDeque<>();
	final Set<String> pragmaOnce = new HashSet<>();

	// --- the fixed define map (HdPlugin.getShaderIncludes @ 7dded59, minimal flat-scene config) ---
	void define(String id, String val) { includeMap.put(id, "#define " + id + " " + val); }
	void define(String id, boolean b)  { define(id, b ? "1" : "0"); }
	void define(String id, int v)      { define(id, Integer.toString(v)); }

	void buildConfig() {
		define("UI_SCALING_MODE", 0);
		define("COLOR_BLINDNESS", 0);
		define("APPLY_COLOR_FILTER", false);
		// MATERIAL_COUNT at the REAL runtime size (device-observed: 595 materials x 96 B std140 = 57120 B).
		// Z0 originally used 1, which is why the gate passed while the runtime UBOMaterials block blew Apple's
		// 16384-byte uniform-block cap at glLinkProgram. With ios-overrides/uniforms/materials.glsl present the
		// block is replaced by the RGBA32I material-store texture and the count no longer sizes anything; with
		// the override absent, 595 reproduces the device link failure (negative control for the gate).
		define("MATERIAL_COUNT", 595);
		define("WATER_TYPE_COUNT", 1);
		// B1 dynamic lights + TILED lighting: DYNAMIC_LIGHTS on, TILED on. Tiled lets the WHOLE scene light up (vs the
		// ~50 nearest non-tiled lights): a per-tile culling pass writes the active light indices into the
		// tiledLightingArray (RGBA16UI 2D array, one layer per culling pass), and scene_frag's calculateLighting reads
		// the tile's indices instead of looping all lights. When TILED is on, HdPlugin sizes MAX_LIGHT_COUNT =
		// UBOLights.MAX_LIGHTS (java-override = 480): UBOLights 480*32=15360 B + UBOLightsCulling 480*16=7680 B, both
		// under Apple's 16384 B uniform-block cap, so NO texture-backed store is needed (unlike UBOMaterials). 480 =
		// ~10x the non-tiled 50, covers all but pathologically dense scenes. TILED_LIGHTING_LAYER_COUNT = dynamicLights
		// SOME.getTiledLightingLayers() = 8. ios-overrides: tiled_lighting_{vert,frag}.glsl + utils/lights.glsl TILED branch.
		define("DYNAMIC_LIGHTS", true);
		define("TILED_LIGHTING", true);
		define("TILED_LIGHTING_LAYER_COUNT", 8);
		define("TILED_LIGHTING_TILE_SIZE", 16);
		define("MAX_LIGHT_COUNT", 480);
		define("NORMAL_MAPPING", true); // B1: normal mapping ON — swaps sampleNormalMap stub for the real normals.glsl body
		define("PARALLAX_OCCLUSION_MAPPING", true);   // B1 POM: validate the displacement raymarch path compiles (ios-overrides/utils/displacement.glsl)
		// B1 shadows: SHADOW_MODE_DETAILED=2 (FAST=1, OFF=0). DETAILED samples the caster's texture alpha in
		// shadow_frag so foliage casts DAPPLED shadows (light through leaf gaps); transparency packs depth+alpha
		// (16+8=24 bits) into gl_FragDepth so the shadow FBO stays depth-only (DEPTH_COMPONENT24). The scene shader
		// only cares SHADOW_MODE!=OFF + SHADOW_TRANSPARENCY; shadow_frag's DETAILED+TRANSPARENCY paths were ES3-ported
		// in the round-2 shadow_frag override. SHADOW_FILTERING_PCF=0. SHADOW_RESOLUTION is the bias ORDINAL (>=4).
		define("SHADOW_MODE", 2);
		define("SHADOW_TRANSPARENCY", true);
		define("SHADOW_FILTERING", 0);
		define("SHADOW_RESOLUTION", 2048);
		define("VANILLA_COLOR_BANDING", false);
		define("UNDO_VANILLA_SHADING", false);
		define("LEGACY_GREY_COLORS", false);
		define("DISABLE_DIRECTIONAL_SHADING", false);
		define("FLAT_SHADING", false);
		define("WIND_DISPLACEMENT", false);
		define("WIND_DISPLACEMENT_NOISE_RESOLUTION", 128);
		define("CHARACTER_DISPLACEMENT", false);
		define("MAX_CHARACTER_POSITION_COUNT", 1);
		define("WIREFRAME", false);
		define("WINDOWS_HDR_CORRECTION", false);
		define("LEGACY_RENDERER", false);
		define("ZONE_RENDERER", true);
		// ZoneRenderer.addShaderIncludes() overrides these two for the zone path (HdPlugin's base values are 0/"",
		// which size WorldViewArray[0] = illegal). We don't vendor ZoneRenderer, so replicate its override: a real
		// world-view count (>=1) + the array getter. (Compile gate needs >=1; bump to the renderer's true max for
		// correctness when ZoneRenderer is staged in B0.1.)
		define("MAX_SIMULTANEOUS_WORLD_VIEWS", 1);
		includeMap.put("WORLD_VIEW_GETTER", "#define getWorldView(i) WorldViewArray[i]");
		// VERSION_HEADER: compute-only in the zone path (comp*.glsl), but define it harmlessly in case.
		includeMap.put("VERSION_HEADER", "#version 330");
		// Dynamic getters: the simple (non-Intel-workaround) form RLHD emits when dynamic indexing works.
		// NOTE: unused once ios-overrides/uniforms/materials.glsl is present (the override drops the
		// `#include MATERIAL_GETTER` line and defines a texelFetch-based getMaterial instead).
		includeMap.put("MATERIAL_GETTER", "#define getMaterial(i) MaterialArray[i]");
		includeMap.put("WATER_TYPE_GETTER", "#define getWaterType(i) WaterTypeArray[i]");
		// MATERIAL_CONSTANTS: per-material `#define MAT_<NAME> getMaterial(idx)`. The scene shaders reference a few
		// named materials in always-compiled (water/caustics) code; define them to index 0 for the compile gate
		// (B0/B1 wires the real MaterialManager.MATERIAL_MAP indices). MATERIAL_COUNT=1 so index 0 is in-bounds.
		includeMap.put("MATERIAL_CONSTANTS",
			"#define MAT_CAUSTICS_MAP getMaterial(0)\n" +
			"#define MAT_WATER_FLOW_MAP getMaterial(0)\n" +
			"#define MAT_WATER_FOAM getMaterial(0)\n");
		// SHADER_TYPE block (mirrors ShaderTemplate.SHADER_TYPE_DEFINE); the per-target SHADER_TYPE value is set in run().
	}

	// --- GLSL 330 -> ES 3.00 downport (single source of truth; mirrors the rule set documented in
	//     app/ZoneDownport.m). Applied at assemble time so the emitted shader IS the exact ES300 the device compiles
	//     and glslangValidator can validate it offline. Keeps the int<->float (#13) cast map in one place. ---
	static final String[][] CASTS = {
		// scaling/bicubic.glsl — `t` is float, the bicubic-window bounds are int literals (Mitchell + Catmull fns).
		{ "if (t < 1)", "if (t < 1.0)" },
		{ "if (t < 2)", "if (t < 2.0)" },
		// scaling/bicubic.glsl textureCubic — textureSize() returns ivec2.
		{ "vec2 texSize = textureSize(sampler, 0);", "vec2 texSize = vec2(textureSize(sampler, 0));" },
		// scaling/hybrid.glsl — sourceDimensions/targetDimensions are ivec2; `1 - texelUv` mixes int with a vec2.
		{ "uv *= sourceDimensions;", "uv *= vec2(sourceDimensions);" },
		{ "(1 - texelUv)", "(vec2(1.0) - texelUv)" },
		// uniforms/world_views.glsl — orthographic-projection test, float matrix element vs int 0.
		{ "projectionMatrix[2][3] != 0)", "projectionMatrix[2][3] != 0.0)" },
		// utils/uvs.glsl — world-UV scale, int 128 vs float scale.
		{ "-IN.position.xz / (128 * scale)", "-IN.position.xz / (128.0 * scale)" },
		// scene_vert.glsl — depth-bias offset, int depthBias / float.
		{ "clipPosition.z += depthBias / 128.0;", "clipPosition.z += float(depthBias) / 128.0;" },
		// utils/shadows.glsl — with SHADOW_MODE off, the `sampleShadowMap` stub macro expands to int `0`, so every
		// `float x = sampleShadowMap(...)` call site breaks. Fix the macro definition once (→ float `0.0`) instead of
		// wrapping each call. (When shadows are enabled the real function returns float, so this stub is unused.)
		{ "#define sampleShadowMap(fragPos, distortion, lightDotNormals) 0", "#define sampleShadowMap(fragPos, distortion, lightDotNormals) 0.0" },
		// utils/fog.glsl — fog-depth guard and the camera-to-vertex midpoint.
		{ "if (fogDepth == 0)", "if (fogDepth == 0.0)" },
		{ "(position.y + cameraPos.y) / 2,", "(position.y + cameraPos.y) / 2.0," },
		// utils/normals.glsl — unpack normal map from [0,1] to [-1,1].
		{ "n.xy = n.xy * 2 - 1;", "n.xy = n.xy * 2.0 - 1.0;" },
		// scene_frag.glsl — water-depth blend: packed int depths times float texBlend weights.
		{ "waterDepth1 * IN.texBlend.x", "float(waterDepth1) * IN.texBlend.x" },
		{ "waterDepth2 * IN.texBlend.y", "float(waterDepth2) * IN.texBlend.y" },
		{ "waterDepth3 * IN.texBlend.z", "float(waterDepth3) * IN.texBlend.z" },
		{ "bool isUnderwater = waterDepth != 0;", "bool isUnderwater = waterDepth != 0.0;" },
		// scene_frag.glsl body — float locals initialized from int literals.
		{ "float mipBias = 0;", "float mipBias = 0.0;" },
		{ "float selfShadowing = 0;", "float selfShadowing = 0.0;" },
		{ "float overlayMix = 0;", "float overlayMix = 0.0;" },
		{ "float shadow = 0;", "float shadow = 0.0;" },
		{ "float closeFadeDistance = 1500;", "float closeFadeDistance = 1500.0;" },
		// scene_frag.glsl body — clamp/max ranges with int literal args (some also fold in int * / - sites).
		{ "clamp(blendedUv.x, 0, .984375)", "clamp(blendedUv.x, 0.0, .984375)" },
		{ "clamp(blendedUv.y, 0, .984375)", "clamp(blendedUv.y, 0.0, .984375)" },
		{ "clamp(underlayBlend, 0, 1)", "clamp(underlayBlend, 0.0, 1.0)" },
		{ "clamp(overlayBlend, 0, 1)", "clamp(overlayBlend, 0.0, 1.0)" },
		{ "clamp(result * 2 - 1, 0, 1)", "clamp(result * 2.0 - 1.0, 0.0, 1.0)" },
		{ "clamp((1 - baseColor1.a) * 2, 0, 1)", "clamp((1.0 - baseColor1.a) * 2.0, 0.0, 1.0)" },
		{ "clamp((1 - baseColor2.a) * 2, 0, 1)", "clamp((1.0 - baseColor2.a) * 2.0, 0.0, 1.0)" },
		{ "clamp((1 - baseColor3.a) * 2, 0, 1)", "clamp((1.0 - baseColor3.a) * 2.0, 0.0, 1.0)" },
		{ "max(normals.y, 0)", "max(normals.y, 0.0)" },
		{ "clamp(outputColor.rgb, 0, 1)", "clamp(outputColor.rgb, 0.0, 1.0)" },
		// scene_frag.glsl body — PARALLAX_OCCLUSION_MAPPING block: average the per-material displacement (vec3/float
		// divided by int 3) + clamp the displaced depth (max int 0). displacement.glsl itself = ios-overrides ES3 port.
		{ "fragDelta /= 3;", "fragDelta /= 3.0;" },
		{ "selfShadowing /= 3;", "selfShadowing /= 3.0;" },
		{ "fragDelta.z = max(0, fragDelta.z);", "fragDelta.z = max(0.0, fragDelta.z);" },
		// scene_frag.glsl body — water-scroll periods + caustics animationFrame() int args (fn takes float).
		{ "10 * waterType.duration", "10.0 * waterType.duration" },
		{ "animationFrame(231)", "animationFrame(231.0)" },
		{ "animationFrame(19)", "animationFrame(19.0)" },
		{ "animationFrame(37)", "animationFrame(37.0)" },
		// scene_frag.glsl body — entity-tint HSL blend: tint is ivec4 (.xyz ivec3, .w int), hsl* are vec3.
		{ "hsl1 += ((tint.xyz - hsl1) * tint.w) / 128;", "hsl1 += ((vec3(tint.xyz) - hsl1) * float(tint.w)) / 128.0;" },
		{ "hsl2 += ((tint.xyz - hsl2) * tint.w) / 128;", "hsl2 += ((vec3(tint.xyz) - hsl2) * float(tint.w)) / 128.0;" },
		{ "hsl3 += ((tint.xyz - hsl3) * tint.w) / 128;", "hsl3 += ((vec3(tint.xyz) - hsl3) * float(tint.w)) / 128.0;" },
		// scene_frag.glsl body — per-face base alpha from the packed alpha byte: int 1 minus the float ratio.
		{ "1 - float(fAlphaBiasHsl[0] >> 24 & 0xff) / 255.", "1.0 - float(fAlphaBiasHsl[0] >> 24 & 0xff) / 255." },
		{ "1 - float(fAlphaBiasHsl[1] >> 24 & 0xff) / 255.", "1.0 - float(fAlphaBiasHsl[1] >> 24 & 0xff) / 255." },
		{ "1 - float(fAlphaBiasHsl[2] >> 24 & 0xff) / 255.", "1.0 - float(fAlphaBiasHsl[2] >> 24 & 0xff) / 255." },
		// scene_frag.glsl body — underlay/overlay masks are ivec3; texBlend is vec3.
		{ "vec3 underlayBlend = IN.texBlend * isUnderlay;", "vec3 underlayBlend = IN.texBlend * vec3(isUnderlay);" },
		{ "vec3 overlayBlend = IN.texBlend * isOverlay;", "vec3 overlayBlend = IN.texBlend * vec3(isOverlay);" },
		{ "float result = dot(IN.texBlend, isPrimary);", "float result = dot(IN.texBlend, vec3(isPrimary));" },
		{ "result = 1 - result;", "result = 1.0 - result;" },
		{ "float inverseShadow = 1 - shadow;", "float inverseShadow = 1.0 - shadow;" },
		// scene_frag.glsl body — material-map "no map" ternaries (roughness + ambientOcclusion): int `1` default vs
		// the float texture branch. One rule covers all 6 (3 materials x 2 maps).
		{ "Map == -1 ? 1 :", "Map == -1 ? 1.0 :" },
		// scene_frag.glsl body — caustics flow: ivec2 direction/drift mixed with vec2 animationFrame(); vec3 * int.
		{ "const ivec2 direction = ivec2(1, -1);", "const vec2 direction = vec2(1.0, -1.0);" },
		{ "* ivec2(1, -2)", "* vec2(1.0, -2.0)" },
		{ "sampleCaustics(flow1, flow2) * 2;", "sampleCaustics(flow1, flow2) * 2.0;" },
		// scene_frag.glsl body — tile-distance wireframe/grid: vec2 xz / int tile size.
		{ "floor(IN.position.xz / 128)", "floor(IN.position.xz / 128.0)" },
		{ "floor(cameraPos.xz / 128)", "floor(cameraPos.xz / 128.0)" },
		{ "outputColor.a *= -256;", "outputColor.a *= -256.0;" },
		// scene_frag.glsl body — post-process saturation/contrast guards (float uniforms vs int 1).
		{ "if (saturation != 1 || contrast != 1)", "if (saturation != 1.0 || contrast != 1.0)" },
		{ "float combinedFog = 1 - (1 - fogAmount) * (1 - groundFog);", "float combinedFog = 1.0 - (1.0 - fogAmount) * (1.0 - groundFog);" },
		{ "outputColor.a * (1 - combinedFog);", "outputColor.a * (1.0 - combinedFog);" },
		// shadow_vert.glsl — alpha from packed bytes: int `1`, and an int/float division (packed byte / float).
		{ "float opacity = 1 - (alphaBiasHsl >> 24 & 0xFF) / float(0xFF)", "float opacity = 1.0 - float(alphaBiasHsl >> 24 & 0xFF) / float(0xFF)" },
		// shadow_vert.glsl — opacity threshold from packed 6-bit field divided by int 0x3F.
		{ "MATERIAL_SHADOW_OPACITY_THRESHOLD_SHIFT & 0x3F) / 0x3F;", "MATERIAL_SHADOW_OPACITY_THRESHOLD_SHIFT & 0x3F) / float(0x3F);" },
		{ "if (opacityThreshold == 0)", "if (opacityThreshold == 0.0)" },
		// shadow_frag.glsl — default opacity literal.
		{ "float opacity = 1;", "float opacity = 1.0;" },
		// utils/misc.glsl — animation-duration guard, float vs int 0.
		{ "if (animationDuration == 0)", "if (animationDuration == 0.0)" },
		// utils/misc.glsl — vanilla-shading lightness adjustment (applyVanillaLighting): float vs int throughout.
		{ "if (vanillaLightDotNormals > 0)", "if (vanillaLightDotNormals > 0.0)" },
		{ "float lighten = max(0, lightness - IGNORE_LOW_LIGHTNESS);", "float lighten = float(max(0, lightness - IGNORE_LOW_LIGHTNESS));" },
		{ "int(127 - 72 * pow(saturation / 7., .05))", "int(127.0 - 72.0 * pow(float(saturation) / 7., .05))" },
		{ "(lighten * LIGHTNESS_MULTIPLIER + BASE_LIGHTEN - lightness) * vanillaLightDotNormals", "(lighten * float(LIGHTNESS_MULTIPLIER) + float(BASE_LIGHTEN) - float(lightness)) * vanillaLightDotNormals" },
		// utils/color_utils.glsl is pervasively cast-heavy → handled by ios-overrides/utils/color_utils.glsl (a
		// hand-maintained ES3 copy), NOT rules here — so no color-temp / sRGB / HSL cast rules in this map.
	};

	String downport(String src, boolean fragment) {
		String s = src;
		// 1+2) #version + precision. ES/ANGLE require #version as the ABSOLUTE first bytes — only comments/whitespace
		//      may precede it, and ANGLE/glslang reject even the license-comment block the RLHD shaders open with
		//      (Apple's EAGL tolerates it, but that's a latent device/ANGLE bug — the base-gpu B1 downport hit this).
		//      So STRIP every `#version ...` line wherever it sits and PREPEND `#version 300 es` + precision as the
		//      very first bytes (the displaced license comment becomes a normal post-version comment, which is legal).
		s = s.replaceAll("(?m)^\\s*#version\\s+\\d+(\\s+core)?\\s*$", "");
		String prec = fragment
			? "precision highp float;\nprecision highp int;\nprecision highp sampler2D;\nprecision highp sampler2DArray;\nprecision highp isampler2D;\nprecision highp isampler2DArray;\nprecision highp usampler2D;\nprecision highp usampler2DArray;\nprecision highp sampler2DShadow;\n"
			: "precision highp float;\nprecision highp int;\nprecision highp sampler2D;\nprecision highp sampler2DArray;\nprecision highp isampler2D;\nprecision highp isampler2DArray;\nprecision highp usampler2D;\nprecision highp usampler2DArray;\n";
		s = "#version 300 es\n" + prec + s;
		// 3) drop noperspective.
		s = s.replaceAll("\\bnoperspective\\s+", "");
		// 4) strip float-literal f/F suffix (needs a decimal point; hex/ints untouched). The trailing (?![A-Za-z0-9_])
		//    is REQUIRED: without it, `material1.flowMap` matches `1.f` (digit-dot-<zero digits>-f) and the `f` of an
		//    identifier like flowMap/flags gets stripped -> `material1.lowMap` (silent corruption). Only strip when
		//    the f/F is a real literal suffix, i.e. not followed by an identifier character.
		s = s.replaceAll("(\\d*\\.\\d+|\\d+\\.\\d*)[fF](?![A-Za-z0-9_])", "$1");
		// 5) textureFaces isamplerBuffer -> 2D isampler2D repack (gpu-tbo2d), only where declared.
		if (s.contains("textureFaces")) {
			s = s.replaceAll("uniform\\s+isamplerBuffer\\s+textureFaces\\s*;", "uniform highp isampler2D textureFaces;");
			int m = s.indexOf("void main()");
			if (m >= 0) { int br = s.indexOf('{', m); if (br >= 0) s = s.substring(0, br + 1) + "\n  int tfW = textureSize(textureFaces, 0).x;" + s.substring(br + 1); }
			s = s.replaceAll("texelFetch\\(\\s*textureFaces\\s*,\\s*([^(),]+?)\\s*\\)", "texelFetch(textureFaces, ivec2(($1)%tfW,($1)/tfW), 0)");
		}
		// 6) explicit int<->float casts (#13) — targeted; cast-heavy files use ios-overrides instead.
		for (String[] c : CASTS) s = s.replace(c[0], c[1]);
		return s;
	}

	String shaderTypeBlock(int type) {
		return "#define VERTEX_SHADER " + GL_VERTEX_SHADER + "\n"
			+ "#define FRAGMENT_SHADER " + GL_FRAGMENT_SHADER + "\n"
			+ "#define GEOMETRY_SHADER " + GL_GEOMETRY_SHADER + "\n"
			+ "#define COMPUTE_SHADER " + GL_COMPUTE_SHADER + "\n"
			+ "#define SHADER_TYPE " + type;
	}

	static final Pattern IDENT = Pattern.compile("^[A-Za-z_]\\w*");

	String loadFile(Path file) throws IOException {
		Path norm = file.toAbsolutePath().normalize();
		fileStack.push(norm);
		String out = parse(Files.readString(norm), norm.getParent());
		fileStack.pop();
		return out;
	}

	String parse(String source, Path curDir) throws IOException {
		StringBuilder sb = new StringBuilder();
		for (String line : source.split("\r?\n")) {
			String t = line.stripLeading();
			if (t.startsWith("#include ")) {
				String expr = t.substring(9).stripLeading();
				if (expr.isEmpty()) { sb.append("// empty include\n"); continue; }
				char c = expr.charAt(0);
				if (c == '"' || c == '<') {
					char end = (c == '<') ? '>' : '"';
					int e = expr.indexOf(end, 1);
					String inc = expr.substring(1, e);
					// `<...>` resolves from ios-overrides first, then the shader root; `"..."` relative to the file's dir.
					Path target;
					if (c == '<') {
						Path ov = OVERRIDE_ROOT.resolve(inc).normalize();
						target = Files.exists(ov) ? ov : SHADER_ROOT.resolve(inc).normalize();
					} else {
						target = curDir.resolve(inc).normalize();
					}
					if (!Files.exists(target)) { missing.add("FILE " + inc + " (from " + fileStack.peek() + ")"); sb.append("// MISSING FILE: ").append(inc).append('\n'); continue; }
					sb.append(loadFile(target)).append('\n');
				} else {
					Matcher m = IDENT.matcher(expr);
					if (m.find()) {
						String id = m.group();
						String rep = includeMap.get(id);
						if (rep == null) { missing.add("IDENT " + id + " (from " + fileStack.peek() + ")"); sb.append("// MISSING IDENT: ").append(id).append('\n'); }
						else sb.append(rep).append('\n');
					} else sb.append("// unparsed include: ").append(expr).append('\n');
				}
			} else if (t.startsWith("#pragma once")) {
				String f = fileStack.peek().toString();
				if (!pragmaOnce.add(f)) { sb.append("// #pragma once: already included\n"); break; }
				sb.append("// #pragma once: first include\n");
			} else {
				sb.append(line).append('\n');
			}
		}
		return sb.toString();
	}

	void run() throws IOException {
		buildConfig();
		Files.createDirectories(OUT_DIR);
		// clear stale assembled outputs (keep .gitkeep)
		try (var s = Files.list(OUT_DIR)) {
			for (Path p : (Iterable<Path>) s::iterator)
				if (p.getFileName().toString().endsWith(".assembled.glsl")) Files.delete(p);
		}

		int ok = 0;
		for (String[] tgt : TARGETS) {
			String name = tgt[0], file = tgt[1]; boolean vert = tgt[2].equals("V");
			pragmaOnce.clear(); fileStack.clear();
			missing.clear();
			includeMap.put("SHADER_TYPE", shaderTypeBlock(vert ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER));
			// Tiled-lighting targets carry a TILED_LIGHTING_LAYER (4th column) consumed by tiled_lighting_frag's
			// `#include TILED_LIGHTING_LAYER` / `#include TILED_IMAGE_STORE` directives. TILED_IMAGE_STORE is always 0
			// on iOS (GLES 3.0 has no image load/store -> the per-layer `out uvec4 TiledData` path). The other targets
			// don't reference these identifiers, so the entries are harmless when set.
			if (tgt.length > 3) {
				includeMap.put("TILED_LIGHTING_LAYER", "#define TILED_LIGHTING_LAYER " + tgt[3]);
				includeMap.put("TILED_IMAGE_STORE", "#define TILED_IMAGE_STORE 0");
			}
			// Top-level target file resolves from ios-overrides first (same as `<...>` includes), so a
			// hand-ported ES3 copy of a top-level shader (e.g. shadow_frag.glsl) is picked up by the gate.
			Path ovTop = OVERRIDE_ROOT.resolve(file).normalize();
			Path topTarget = Files.exists(ovTop) ? ovTop : SHADER_ROOT.resolve(file);
			String assembled = downport(loadFile(topTarget), !vert);
			String stage = vert ? "vert" : "frag";
			Path outPath = OUT_DIR.resolve(name + "." + stage + ".assembled.glsl");
			Files.writeString(outPath, assembled);
			int lines = assembled.split("\n").length;
			if (missing.isEmpty()) { ok++; System.out.printf("OK   %-22s -> %s (%d lines)%n", file, outPath.getFileName(), lines); }
			else {
				System.out.printf("WARN %-22s -> %s (%d lines) — %d unresolved:%n", file, outPath.getFileName(), lines, missing.size());
				for (String mm : new LinkedHashSet<>(missing)) System.out.println("       - " + mm);
			}
		}
		System.out.printf("%nASSEMBLE SUMMARY: %d/%d clean%n", ok, TARGETS.length);
		System.out.println(ok == TARGETS.length ? "VERDICT = ALL_TARGETS_ASSEMBLE_CLEAN" : "VERDICT = ASSEMBLE_HAS_UNRESOLVED");
	}

	public static void main(String[] args) throws IOException { new ZoneShaderAssemble().run(); }
}
