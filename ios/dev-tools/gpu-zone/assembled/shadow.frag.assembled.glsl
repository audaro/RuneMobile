#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
precision highp sampler2DArray;
precision highp isampler2D;
precision highp isampler2DArray;
precision highp usampler2D;
precision highp usampler2DArray;
precision highp sampler2DShadow;
/*
 * Copyright (c) 2018, Adam <Adam@sigterm.info>
 * Copyright (c) 2023, Hooder <ahooder@protonmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone B0.5, shadow program). Verbatim copy of rs117/hd/shadow_frag.glsl @ RLHD
 * 7dded59 EXCEPT every int-in-float-context is made explicit (blueprint #13): GLSL ES 3.00 does NO implicit
 * int<->float conversions that GLSL 330 allows. The zone renderer compiles BOTH shadow programs
 * (fastShadowProgram = SHADOW_MODE_FAST, detailedShadowProgram = SHADOW_MODE_DETAILED) UNCONDITIONALLY, even
 * when shadows are disabled, so the DETAILED + SHADOW_TRANSPARENCY branches — never reached by the Z0 probe
 * (which assembled shadow at SHADOW_MODE=0 / transparency off) — must also be ES-clean. Sites:
 *   - `float opacity = 1.0;`                -> `1.0`
 *   - `fUvw.z != -1` / `uvw.z != -1` / `uvw.w != -1`   (float != int)   -> `-1.0`
 *   - `clamp(uvw.x, 0, .984375)`          (int 0)       -> `0.0`
 *   - the SHADOW_TRANSPARENCY depth packing: `1 - opacity` -> `1.0 - opacity`, the int<<|int packed value is
 *     wrapped in `float(...)` before the `/ float(SHADOW_COMBINED_MAX)` divide, and SHADOW_ALPHA_MAX /
 *     SHADOW_DEPTH_MAX (int #defines) are float()-cast at their float uses.
 * Logic identical. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */

// #pragma once: first include

// #pragma once: first include

#define EPS 1.0e-10
#define PI 3.14159265 // max 32-bit float precision
#define HALF_PI (.5*PI)
#define TAU (2*PI)

#define SHORT_MAX 32767 // 2^15 - 1

#define VERTEX_SHADER 35633
#define FRAGMENT_SHADER 35632
#define GEOMETRY_SHADER 36313
#define COMPUTE_SHADER 37305
#define SHADER_TYPE 35632
#define LEGACY_RENDERER 0
#define ZONE_RENDERER 1

// Any changes here may need to be reflected in OpenCL's constants.cl
// They are kept separate to avoid accidentally breaking OpenCL compatibility
#define MATERIAL_INDEX_SHIFT 21
#define MATERIAL_INDEX_MASK ((1 << (32 - MATERIAL_INDEX_SHIFT)) - 1)
#define MATERIAL_SHADOW_OPACITY_THRESHOLD_SHIFT 15
#define MATERIAL_FLAG_WIND_MODIFIER 12
#define MATERIAL_FLAG_WIND_SWAYING 9
#define MATERIAL_FLAG_INVERT_DISPLACEMENT_STRENGTH 8
#define MATERIAL_FLAG_UNDO_VANILLA_SHADING 7
#define MATERIAL_FLAG_TERRAIN_VERTEX_SNAPPING 6
#define MATERIAL_FLAG_DISABLE_SHADOW_RECEIVING 5
#define MATERIAL_FLAG_UPWARDS_NORMALS 4
#define MATERIAL_FLAG_FLAT_NORMALS 3
#define MATERIAL_FLAG_WORLD_UVS 2
#define MATERIAL_FLAG_VANILLA_UVS 1
#define MATERIAL_FLAG_IS_OVERLAY 0

#define SHADOW_MODE 2
#define SHADOW_MODE_OFF 0
#define SHADOW_MODE_FAST 1
#define SHADOW_MODE_DETAILED 2

#define SHADOW_TRANSPARENCY_BIAS 0.006
#define SHADOW_DEPTH_BITS 16
#define SHADOW_ALPHA_BITS 8
#define SHADOW_COMBINED_BITS (SHADOW_DEPTH_BITS + SHADOW_ALPHA_BITS)
#define SHADOW_DEPTH_MAX ((1 << SHADOW_DEPTH_BITS) - 1)
#define SHADOW_ALPHA_MAX ((1 << SHADOW_ALPHA_BITS) - 1)
#define SHADOW_COMBINED_MAX ((1 << SHADOW_COMBINED_BITS) - 1)

#define SHADOW_RESOLUTION 2048

#define SHADOW_FILTERING 0
#define SHADOW_FILTERING_PCF 0
#define SHADOW_FILTERING_DITHER 1
#define SHADOW_FILTERING_AVERAGE 2

#define SHADOW_TRANSPARENCY 1
#if SHADOW_TRANSPARENCY
    #define SHADOW_DEFAULT_OPACITY_THRESHOLD 0.01 // Remove shadows from clickboxes
#else
    #define SHADOW_DEFAULT_OPACITY_THRESHOLD 0.71 // Lowest while keeping Prifddinas glass walkways transparent
#endif

#define VANILLA_COLOR_BANDING 0
#define UNDO_VANILLA_SHADING 0
#define LEGACY_GREY_COLORS 0
#define DISABLE_DIRECTIONAL_SHADING 0
#define FLAT_SHADING 0
#define APPLY_COLOR_FILTER 0
#define WIREFRAME 0
#define WIND_DISPLACEMENT 0
#define WIND_DISPLACEMENT_NOISE_RESOLUTION 128
#define CHARACTER_DISPLACEMENT 0
#define DYNAMIC_LIGHTS 1
#define MAX_LIGHT_COUNT 480
#define TILED_LIGHTING 1
#define TILED_LIGHTING_LAYER_COUNT 8
#define TILED_LIGHTING_TILE_SIZE 16
#define TILED_LIGHTING_MAX_TILE_LIGHT_COUNT (TILED_LIGHTING_LAYER_COUNT * 4 * 2)
#define WINDOWS_HDR_CORRECTION 0


layout(std140) uniform UBOGlobal {
    int expandedMapLoadingChunks;
    float drawDistance;

    float colorBlindnessIntensity;
    float gammaCorrection;
    float saturation;
	float contrast;
    int colorFilterPrevious;
    int colorFilter;
    float colorFilterFade;

    ivec2 sceneResolution;
    ivec2 tiledLightingResolution;

    vec3 ambientColor;
    float ambientStrength;
    vec3 lightColor;
    float lightStrength;
    vec3 underglowColor;
    float underglowStrength;

    int useFog;
    float fogDepth;
    vec3 fogColor;
    float groundFogStart;
    float groundFogEnd;
    float groundFogOpacity;

    vec3 waterColorLight;
    vec3 waterColorMid;
    vec3 waterColorDark;

    bool underwaterEnvironment;
    bool underwaterCaustics;
    vec3 underwaterCausticsColor;
    float underwaterCausticsStrength;

    vec3 lightDir;

    int pointLightsCount;

    vec3 cameraPos;
    mat4 viewMatrix;
    mat4 projectionMatrix;
    mat4 invProjectionMatrix;
    mat4 lightProjectionMatrix;

    float lightningBrightness;
    float elapsedTime;
};


// #pragma once: already included

/*
 * Color utility functions
 * Written in 2023 by Hooder <ahooder@protonmail.com>
 * To the extent possible under law, the author(s) have dedicated all copyright and related and neighboring rights
 * to this software to the public domain worldwide. This software is distributed without any warranty.
 * You should have received a copy of the CC0 Public Domain Dedication along with this software.
 * If not, see <http://creativecommons.org/publicdomain/zero/1.0/>.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone Z0). Verbatim copy of rs117/hd/utils/color_utils.glsl @ RLHD 7dded59 EXCEPT
 * every int-literal-in-float-context and int->float assignment is made explicit (GLSL ES 3.00 does no implicit
 * int<->float conversion, blueprint #13). This file is pervasively cast-heavy, so it gets a hand-maintained
 * override (the assembler resolves ios-overrides/ before rlhd-src/) rather than dozens of brittle downporter
 * string rules. RE-MERGE this against upstream when the pinned RLHD rev is bumped. Only numeric-literal types
 * changed; logic is identical.
 * ===========================================================================================================
 */
// #pragma once: first include

// #pragma once: already included


/**
 * Row-major transformation matrices for conversion between RGB and XYZ color spaces.
 */
const mat3 RGB_TO_XYZ_MATRIX = mat3(
    .49, .1769, .0,
    .31, .8124, .0099,
    .2,  .0107, .9901
);
const mat3 XYZ_TO_RGB_MATRIX = mat3(
    2.36449,  -.514935,  0.00514883,
    -.896553, 1.42633,   -.0142619,
    -.467937,  .0886025, 1.00911
);

vec3 XYZtoRGB(vec3 XYZ) {
    return XYZ_TO_RGB_MATRIX * XYZ;
}

vec3 RGBtoXYZ(vec3 RGB) {
    return RGB_TO_XYZ_MATRIX * RGB;
}

vec3 colorTemperatureToLinearRgb(float kelvin) {
    // UV coordinates in CIE 1960 UCS color space
    vec2 uv = vec2(
        (0.860117757 + 1.54118254e-4 * kelvin + 1.28641212e-7 * kelvin * kelvin)
            / (1.0 + 8.42420235e-4 * kelvin + 7.08145163e-7 * kelvin * kelvin),
        (0.317398726 + 4.22806245e-5 * kelvin + 4.20481691e-8 * kelvin * kelvin)
            / (1.0 - 2.89741816e-5 * kelvin + 1.61456053e-7 * kelvin * kelvin)
    );

    // xy coordinates in CIES 1931 xyY space
    vec2 xy = vec2(3.0 * uv.x, 2.0 * uv.y) / (2.0 * uv.x - 8.0 * uv.y + 4.0);

    // CIE XYZ space
    const float Y = 1.0;
    vec3 XYZ = Y * vec3(xy.x / xy.y, 1.0, (1.0 - xy.x - xy.y) / xy.y);

    vec3 linearRgb = XYZtoRGB(XYZ);
    float m = max(linearRgb.x, max(linearRgb.y, linearRgb.z));
    linearRgb = linearRgb / m;
    return linearRgb;
}

vec3 srgbToLinear(vec3 srgb) {
  return mix(
    srgb / 12.92,
    pow((srgb + vec3(0.055)) / vec3(1.055), vec3(2.4)),
    step(vec3(0.04045), srgb));
}

vec3 linearToSrgb(vec3 rgb) {
  return mix(
    rgb * 12.92,
    1.055 * pow(rgb, vec3(1.0 / 2.4)) - 0.055,
    step(vec3(0.0031308), rgb));
}

float srgbToLinear(float srgb) {
  return mix(
    srgb / 12.92,
    pow((srgb + float(0.055)) / float(1.055), float(2.4)),
    step(float(0.04045), srgb));
}

float linearToSrgb(float rgb) {
  return mix(
    rgb * 12.92,
    1.055 * pow(rgb, 1.0 / 2.4) - 0.055,
    step(0.0031308, rgb));
}

// https://web.archive.org/web/20230619214343/https://en.wikipedia.org/wiki/HSL_and_HSV#Color_conversion_formulae
vec3 srgbToHsl(vec3 srgb) {
    float V = max(max(srgb.r, srgb.g), srgb.b);
    float X_min = min(min(srgb.r, srgb.g), srgb.b);
    float C = V - X_min;

    float H = 0.0;
    if (C > 0.0) {
        if (V == srgb.r) {
            H = mod((srgb.g - srgb.b) / C, 6.0);
        } else if (V == srgb.g) {
            H = (srgb.b - srgb.r) / C + 2.0;
        } else {
            H = (srgb.r - srgb.g) / C + 4.0;
        }
    }

    float L = (V + X_min) / 2.0;
    float divisor = 1.0 - abs(2.0 * L - 1.0);
    float S_L = abs(divisor) < EPS ? 0.0 : C / divisor;
    return vec3(H / 6.0, S_L, L);
}

vec3 hslToSrgb(vec3 hsl) {
    float C = (1.0 - abs(2.0 * hsl[2] - 1.0)) * hsl[1];
    float H_prime = fract(hsl[0]) * 6.0;
    float m = hsl[2] - C / 2.0;

    float r = clamp(abs(H_prime - 3.0) - 1.0, 0.0, 1.0);
    float g = clamp(2.0 - abs(H_prime - 2.0), 0.0, 1.0);
    float b = clamp(2.0 - abs(H_prime - 4.0), 0.0, 1.0);
    return vec3(r, g, b) * C + m;
}

vec3 hslToHsv(vec3 hsl) {
    float v = hsl[2] + hsl[1] * min(hsl[2], 1.0 - hsl[2]);
    return vec3(hsl[0], abs(v) < EPS ? 0.0 : 2.0 * (1.0 - hsl[2] / v), v);
}

vec3 hsvToHsl(vec3 hsv) {
    float l = hsv[2] * (1.0 - hsv[1] / 2.0);
    float divisor = min(l, 1.0 - l);
    return vec3(hsv[0], abs(divisor) < EPS ? 0.0 : (hsv[2] - l) / divisor, l);
}

vec3 srgbToHsv(vec3 rgb) {
    return hslToHsv(srgbToHsl(rgb));
}

vec3 hsvToSrgb(vec3 hsv) {
    return hslToSrgb(hsvToHsl(hsv));
}

// Pack HSL int Jagex format
int packRawHsl(ivec3 hsl) {
    int H = clamp(hsl[0], 0, 63);
    int S = clamp(hsl[1], 0, 7);
    int L = clamp(hsl[2], 0, 127);
    return H << 10 | S << 7 | L;
}

// Pack HSL int Jagex format
int packHsl(vec3 hsl) {
    ivec3 rawHsl = ivec3(
        round((hsl[0] - .0078125) * 64.0),
        round((hsl[1] - .0625) * 8.0),
        round(hsl[2] * 128.0)
    );
    return packRawHsl(rawHsl);
}

// Unpack HSL from Jagex format
vec3 unpackRawHsl(int hsl) {
    // 6-bit hue | 3-bit saturation | 7-bit lightness
    float H = float(hsl >> 10 & 63);
    float S = float(hsl >> 7 & 7);
    float L = float(hsl & 127);
    return vec3(H, S, L);
}

// Unpack HSL from Jagex format
vec3 convertHsl(vec3 HSL) {
    // 6-bit hue | 3-bit saturation | 7-bit lightness
    float H = HSL[0] / 64. + .0078125;
    float S = HSL[1] / 8. + .0625;
    float L = HSL[2] / 128.;
    return vec3(H, S, L);
}

int srgbToPackedHsl(vec3 srgb) {
    return packHsl(srgbToHsl(srgb));
}

vec3 packedHslToSrgb(int hsl) {
    return hslToSrgb(convertHsl(unpackRawHsl(hsl)));
}


#if SHADOW_MODE == SHADOW_MODE_DETAILED
    uniform sampler2DArray textureArray;
    in vec4 fUvw;
    flat in int fMaterialData;
#endif

#if SHADOW_TRANSPARENCY
    in float fOpacity;
#endif

void main() {
    float opacity = 1.0;
    #if SHADOW_TRANSPARENCY
        opacity = fOpacity;
    #endif

    #if SHADOW_MODE == SHADOW_MODE_DETAILED
        if (fUvw.z != -1.0) {
            vec4 uvw = fUvw;

            // Vanilla tree textures rely on UVs being clamped horizontally,
            // which HD doesn't do, so we instead opt to hide these fragments
            if ((fMaterialData >> MATERIAL_FLAG_VANILLA_UVS & 1) == 1)
                uvw.x = clamp(uvw.x, 0.0, .984375);

            if (uvw.z != -1.0)
                opacity *= texture(textureArray, uvw.xyz).a;
            if (uvw.w != -1.0)
                opacity *= linearToSrgb(texture(textureArray, uvw.xyw).r);

            #if !SHADOW_TRANSPARENCY
                if (opacity < SHADOW_DEFAULT_OPACITY_THRESHOLD)
                    discard;
            #endif
        }
    #endif

    #if SHADOW_TRANSPARENCY
        // We pack the transparency and depth of each fragment into the upper and lower bits
        // of the output depth respectively, such that less-transparent fragments overwrite
        // more-transparent fragments first, and equally transparent fragments second, based on depth.
        // Unfortunately, the exact handling of floats is implementation dependant, so this may not work
        // the same across all GPUs.
        float depth = gl_FragCoord.z;
        gl_FragDepth = float(
            int((1.0 - opacity) * float(SHADOW_ALPHA_MAX)) << SHADOW_DEPTH_BITS |
            int(depth * float(SHADOW_DEPTH_MAX))
        ) / float(SHADOW_COMBINED_MAX);
    #endif
}
