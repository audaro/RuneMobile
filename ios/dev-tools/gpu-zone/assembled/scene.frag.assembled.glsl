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
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#define DISPLAY_BASE_COLOR 0
#define DISPLAY_UV 0
#define DISPLAY_NORMAL 0
#define DISPLAY_TANGENT 0
#define DISPLAY_SHADOWS 0
#define DISPLAY_LIGHTING 0

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

// #pragma once: first include

// #pragma once: already included


#if ZONE_RENDERER
#define MAX_SIMULTANEOUS_WORLD_VIEWS 1

    struct WorldView {
        mat4 projectionMatrix;
        ivec4 tint;
    };

    layout(std140) uniform UBOWorldViews {
        WorldView WorldViewArray[MAX_SIMULTANEOUS_WORLD_VIEWS];
    };

#define getWorldView(i) WorldViewArray[i]

    mat4 getWorldViewProjection(int worldViewIndex) {
        if (worldViewIndex <= 0)
            return mat4(1);
        return getWorldView(worldViewIndex - 1).projectionMatrix;
    }

    ivec4 getWorldViewTint(int worldViewIndex) {
        if (worldViewIndex <= 0)
            return ivec4(0);
        return getWorldView(worldViewIndex - 1).tint;
    }
#else
    #define getWorldViewProjection(worldViewIndex) mat4(1)
    #define getWorldViewTint(worldViewIndex) ivec4(0)
#endif

// #pragma once: first include
// ^ must stay the FIRST line: on repeat inclusion the expanders (assembler + runtime ShaderIncludes) emit
//   everything BEFORE the pragma, so a banner above it would be duplicated per include site.
/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone B0.5, materials subsystem). Apple's GLES-on-Metal caps a uniform block at
 * 16384 bytes; the real material set is ~595 materials x 96 B std140 = ~57 KB, so the UBOMaterials block
 * fails glLinkProgram on device ("UBOMaterials too large"). This override replaces the std140 block with an
 * RGBA32I texture holding the SAME bytes the Java UBO writer serializes (UniformBuffer std140 layout,
 * 96-byte stride = 6 RGBA32I texels per material), fetched row-per-material:
 *     texel x = scalar slot group (0..5), texel y = material index.
 * The Java side uploads the UBO ByteBuffer verbatim into the texture (java-overrides MaterialManager
 * .uploadMaterialStore(), texture unit TEXTURE_UNIT_MATERIAL_STORE) — so the decode below MUST match the
 * UniformBuffer.PropertyType std140 packing: 8 ints @0..28, 5 floats @32..48, pad @52, vec2 @56, vec2 @64,
 * pad @72, vec3 @80, struct pad to 96. The struct, field order and the flags helpers are verbatim RLHD
 * @7dded59. getMaterial(i) becomes a real function (replaces the generated MATERIAL_GETTER include — the
 * MAT_* constants from MATERIAL_CONSTANTS expand to getMaterial(N) and keep working unchanged). The UBO
 * block is gone entirely, so the 16 KB cap no longer applies; the Java-side glBindBufferBase of the dead
 * block is harmless (ShaderProgram skips absent blocks). RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
#define MATERIAL_COUNT 595

struct Material {
    int colorMap;
    int normalMap;
    int displacementMap;
    int roughnessMap;
    int ambientOcclusionMap;
    int flowMap;
    int shadowAlphaMap;
    int flags; // overrideBaseColor << 2 | unlit << 1 | hasTransparency
    float brightness;
    float displacementScale;
    float specularStrength;
    float specularGloss;
    float flowMapStrength;
    vec2 flowMapDuration;
    vec2 scrollDuration;
    vec3 textureScale;
};

uniform highp isampler2D materialStore;

Material getMaterial(int i) {
    ivec4 t0 = texelFetch(materialStore, ivec2(0, i), 0);
    ivec4 t1 = texelFetch(materialStore, ivec2(1, i), 0);
    ivec4 t2 = texelFetch(materialStore, ivec2(2, i), 0);
    ivec4 t3 = texelFetch(materialStore, ivec2(3, i), 0);
    ivec4 t4 = texelFetch(materialStore, ivec2(4, i), 0);
    ivec4 t5 = texelFetch(materialStore, ivec2(5, i), 0);
    Material m;
    m.colorMap = t0.x;
    m.normalMap = t0.y;
    m.displacementMap = t0.z;
    m.roughnessMap = t0.w;
    m.ambientOcclusionMap = t1.x;
    m.flowMap = t1.y;
    m.shadowAlphaMap = t1.z;
    m.flags = t1.w;
    m.brightness = intBitsToFloat(t2.x);
    m.displacementScale = intBitsToFloat(t2.y);
    m.specularStrength = intBitsToFloat(t2.z);
    m.specularGloss = intBitsToFloat(t2.w);
    m.flowMapStrength = intBitsToFloat(t3.x);
    // t3.y = std140 pad (vec2 aligns to 8 bytes)
    m.flowMapDuration = vec2(intBitsToFloat(t3.z), intBitsToFloat(t3.w));
    m.scrollDuration = vec2(intBitsToFloat(t4.x), intBitsToFloat(t4.y));
    // t4.zw = std140 pad (vec3 aligns to 16 bytes)
    m.textureScale = vec3(intBitsToFloat(t5.x), intBitsToFloat(t5.y), intBitsToFloat(t5.z));
    return m;
}

bool getMaterialShouldOverrideBaseColor(const Material material) {
    return (material.flags >> 2 & 1) == 1;
}

int getMaterialIsUnlit(const Material material) {
    return material.flags >> 1 & 1;
}

bool getMaterialHasTransparency(const Material material) {
    return (material.flags & 1) == 1;
}

// #pragma once: first include

#define WATER_TYPE_COUNT 1

struct WaterType {
    bool isFlat;
    float specularStrength;
    float specularGloss;
    float normalStrength;
    float baseOpacity;
    int hasFoam;
    float duration;
    float fresnelAmount;
    vec3 surfaceColor;
    vec3 foamColor;
    vec3 depthColor;
    int normalMap;
};

layout(std140) uniform UBOWaterTypes {
    WaterType WaterTypeArray[WATER_TYPE_COUNT];
};

#define getWaterType(i) WaterTypeArray[i]


#define MAT_CAUSTICS_MAP getMaterial(0)
#define MAT_WATER_FLOW_MAP getMaterial(0)
#define MAT_WATER_FOAM getMaterial(0)


uniform sampler2DArray textureArray;
uniform sampler2D shadowMap;
uniform usampler2DArray tiledLightingArray;

// general HD settings

flat in int fWorldViewId;
flat in ivec3 fAlphaBiasHsl;
flat in ivec3 fMaterialData;
flat in ivec3 fTerrainData;

#if FLAT_SHADING && ZONE_RENDERER
    flat in vec3 fFlatNormal;
#endif

in FragmentData {
    vec3 position;
    vec2 uv;
    vec3 normal;
    vec3 texBlend;
} IN;

out vec4 FragColor;

vec2 worldUvs(float scale) {
    return -IN.position.xz / (128.0 * scale);
}

// #pragma once: already included

/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
// #pragma once: first include

// #pragma once: already included


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


// translates a value from a custom range into 0-1
float translateRange(float rangeStart, float rangeEnd, float value) {
    return (value - rangeStart) / (rangeEnd - rangeStart);
}

// returns a value between 0-1 representing a frame of animation
// based on the length of the animation
float animationFrame(float animationDuration) {
    if (animationDuration == 0.0)
        return 0.0;
    return mod(elapsedTime, animationDuration) / animationDuration;
}

vec2 animationFrame(vec2 animationDuration) {
    if (animationDuration == vec2(0))
        return vec2(0);
    return mod(vec2(elapsedTime), vec2(animationDuration)) / animationDuration;
}

vec3 windowsHdrCorrection(vec3 c) {
    // SDR monitors *usually* apply a gamma 2.2 curve, instead of the piece-wise sRGB curve, leading to the following
    // technically incorrect operation for *most* SDR monitors, producing our *expected* final result (first line).
    // In Windows' SDR-in-HDR implementation however, the piece-wise sRGB EOTF is used, leading to technically correct
    // linear colors before transformation to HDR, but this is *not* the *expected* output. To counteract this, we can
    // transform our output from linear to sRGB, then from gamma 2.2 to linear, effectively replacing Windows' HDR sRGB
    // conversion with our expected gamma 2.2 conversion for SDR content, to within rounding error of the output format.
    // sRGB ----------------------------------> SDR screen gammaToLinear --> expected (although technically incorrect)
    // sRGB ----------------------------------> Windows' HDR srgbToLinear -> linear (technically correct, not expected)
    // sRGB -> linearToSrgb -> gammaToLinear -> Windows' HDR srgbToLinear -> expected (same as the SDR case)
    // https://github.com/clshortfuse/renodx (MIT license)
    return pow(linearToSrgb(c), vec3(2.2));
}

void undoVanillaShading(inout int hsl, vec3 unrotatedNormal) {
    const vec3 LIGHT_DIR_MODEL = vec3(0.57735026, 0.57735026, 0.57735026);
    // subtracts the X lowest lightness levels from the formula.
    // helps keep darker colors appropriately dark
    const int IGNORE_LOW_LIGHTNESS = 3;
    // multiplier applied to vertex' lightness value.
    // results in greater lightening of lighter colors
    const float LIGHTNESS_MULTIPLIER = 3.;
    // the minimum amount by which each color will be lightened
    const int BASE_LIGHTEN = 10;

    int saturation = hsl >> 7 & 0x7;
    int lightness = hsl & 0x7F;
    float vanillaLightDotNormals = dot(LIGHT_DIR_MODEL, unrotatedNormal);
    if (vanillaLightDotNormals > 0.0) {
        vanillaLightDotNormals /= length(unrotatedNormal);
        float lighten = float(max(0, lightness - IGNORE_LOW_LIGHTNESS));
        lightness += int((lighten * float(LIGHTNESS_MULTIPLIER) + float(BASE_LIGHTEN) - float(lightness)) * vanillaLightDotNormals);
    }
    int maxLightness;
    #if LEGACY_GREY_COLORS
        maxLightness = 55;
    #else
        maxLightness = int(127.0 - 72.0 * pow(float(saturation) / 7., .05));
    #endif
    lightness = min(lightness, maxLightness);
    hsl &= ~0x7F;
    hsl |= lightness;
}

#if SHADER_TYPE == FRAGMENT_SHADER
    mat3 cotangent_frame(vec3 N, vec3 p, vec2 uv) {
        // get edge vectors of the pixel triangle
        vec3 dpdx = dFdx(p);
        vec3 dpdy = dFdy(p);
        vec2 duvdx = dFdx(uv);
        vec2 duvdy = dFdy(uv);

        // solve the linear system
        vec3 a = cross(dpdy, N);
        vec3 b = cross(N, dpdx);
        vec3 T = a * duvdx.x + b * duvdy.x;
        vec3 B = a * duvdx.y + b * duvdy.y;

        // construct a scale-invariant frame
        float invmax = inversesqrt(max(dot(T, T), dot(B, B)));
        return mat3(T * invmax, B * invmax, N);
    }
#endif

// 2D Random
float hash(in vec2 st) {
    return fract(sin(dot(st.xy, vec2(12.9898, 78.233))) * 43758.5453123);
}

// 3D Random
float hash(in vec3 st) {
	return fract(sin(dot(st, vec3(12.9898, 78.233, 45.164))) * 43758.5453123);
}

// 4D Random
float hash(in vec4 st) {
	return fract(sin(dot(st, vec4(12.9898, 78.233, 45.164, 94.673))) * 43758.5453123);
}

// 2D Noise based on Morgan McGuire @morgan3d, under the BSD license
// https://www.shadertoy.com/view/4dS3Wd
float noise(in vec2 st) {
    vec2 i = floor(st);
    vec2 f = fract(st);

    // Four corners in 2D of a tile
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));

    // Smooth interpolation
    vec2 u = smoothstep(0., 1., f);

    // Mix 4 corner percentages
    return mix(a, b, u.x) +
        (c - a) * u.y * (1.0 - u.x) +
        (d - b) * u.x * u.y;
}

vec3 snap(vec3 position, float gridSpacing) {
    position /= gridSpacing;
    position = round(position);
    position *= gridSpacing;
    return position;
}

vec2 snap(vec2 position, float gridSpacing) {
    return snap(vec3(position.x, 0.0, position.y), gridSpacing).xz;
}

float smooth_step(float edge0, float edge1, float x) {
    float p = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    float v = p * p * (3.0 - 2.0 * p); // smoothstep formula
    return v;
}

vec3 safe_normalize(vec3 v) {
    vec3 r = normalize(v);
    r.x = isnan(r.x) ? 0.0 : r.x;
    r.y = isnan(r.y) ? 0.0 : r.y;
    r.z = isnan(r.z) ? 0.0 : r.z;
    return r;
}

float saturate(float value) {
    return clamp(value, 0.0, 1.0);
}

vec2 saturate(vec2 value) {
    return clamp(value, vec2(0.0), vec2(1.0));
}

vec3 saturate(vec3 value) {
    return clamp(value, vec3(0.0), vec3(1.0));
}

vec4 saturate(vec4 value) {
    return clamp(value, vec4(0.0), vec4(1.0));
}

#define POISSON_DISK_LENGTH 16
vec2 getPoissonDisk(int idx) {
    switch(idx) {
        case  0: return vec2(-0.94201624,  -0.39906216);
        case  1: return vec2( 0.94558609,  -0.76890725);
        case  2: return vec2(-0.094184101, -0.92938870);
        case  3: return vec2( 0.34495938,   0.29387760);
        case  4: return vec2(-0.91588581,   0.45771432);
        case  5: return vec2(-0.81544232,  -0.87912464);
        case  6: return vec2(-0.38277543,   0.27676845);
        case  7: return vec2( 0.97484398,   0.75648379);
        case  8: return vec2( 0.44323325,  -0.97511554);
        case  9: return vec2( 0.53742981,  -0.47373420);
        case 10: return vec2(-0.26496911,  -0.41893023);
        case 11: return vec2( 0.79197514,   0.19090188);
        case 12: return vec2(-0.24188840,   0.99706507);
        case 13: return vec2(-0.81409955,   0.91437590);
        case 14: return vec2( 0.19984126,   0.78641367);
        default: return vec2( 0.14383161,  -0.14100790);
    }
}

//
// Algorithm from "Analysis of Color Blindness" by Onur Fidaner, Poliang Lin and Nevran Ozguven.
// https://web.archive.org/web/20090731011248/http://scien.stanford.edu/class/psych221/projects/05/ofidaner/project_report.pdf
//

#define COLOR_BLINDNESS 0

#define NONE 0
#define PROTAN 1
#define DEUTERAN 2
#define TRITAN 3

const mat3 rgb2lms = mat3(
  vec3(17.8824, 43.5161, 4.11935),
  vec3(3.45565, 27.1554, 3.86714),
  vec3(0.0299566, 0.184309, 1.46709)
);

const mat3 lms2lmsp = mat3(
  vec3(0.0, 2.02344, -2.52581),
  vec3(0.0, 1.0, 0.0),
  vec3(0.0, 0.0, 1.0)
);

const mat3 lms2lmsd = mat3(
  vec3(1.0, 0.0, 0.0),
  vec3(0.494207, 0.0, 1.24827),
  vec3(0.0, 0.0, 1.0)
);

const mat3 lms2lmst = mat3(
  vec3(1.0, 0.0, 0.0),
  vec3(0.0, 1.0, 0.0),
  vec3(-0.395913, 0.801109, 0.0)
);

const mat3 protanopiaDaltonization = mat3(
  vec3(0.0, 0.0, 0.0),
  vec3(0.7, 1.0, 0.0),
  vec3(0.7, 0.0, 1.0)
);

#if COLOR_BLINDNESS != NONE
vec3 colorBlindnessCompensation(vec3 color)
{
  vec3 LMS = color * rgb2lms;

  #if COLOR_BLINDNESS == PROTAN
  vec3 lms = LMS * lms2lmsp; // red deficiency
  #elif COLOR_BLINDNESS == DEUTERAN
  vec3 lms = LMS * lms2lmsd; // green deficiency
  #elif COLOR_BLINDNESS == TRITAN
  vec3 lms = LMS * lms2lmst; // blue deficiency
  #endif

  // LMS to RGB matrix conversion
  mat3 lms2rgb = inverse(rgb2lms);
  vec3 error = lms * lms2rgb;

  // Isolate invisible colors to color vision deficiency (calculate error matrix)
  error = (color - error);

  // Shift colors towards visible spectrum (apply error modifications)
  vec3 compensation = error * protanopiaDaltonization;

  // Add compensation to original values
  compensation = color + compensation * colorBlindnessIntensity;

  return compensation;
}
#else
#define colorBlindnessCompensation(color) color
#endif

/*
 * Copyright (c) 2022, Hooder <ahooder@protonmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
// #pragma once: already included


float sampleCausticsChannel(const vec2 flow1, const vec2 flow2) {
    return min(
        texture(textureArray, vec3(flow1, MAT_CAUSTICS_MAP.colorMap)).r,
        texture(textureArray, vec3(flow2, MAT_CAUSTICS_MAP.colorMap)).r
    );
}

float sampleCausticsChannel(const vec2 flow1, const vec2 flow2, const vec2 aberration) {
    return sampleCausticsChannel(flow1 + aberration, flow2 + aberration);
}

vec3 sampleCaustics(const vec2 flow1, const vec2 flow2, const float aberration) {
    float r = sampleCausticsChannel(flow1, flow2, aberration * vec2( 1,  1));
    float g = sampleCausticsChannel(flow1, flow2, aberration * vec2( 1, -1));
    float b = sampleCausticsChannel(flow1, flow2, aberration * vec2(-1, -1));
    return vec3(r, g, b);
}

vec3 sampleCaustics(const vec2 flow1, const vec2 flow2) {
    return vec3(sampleCausticsChannel(flow1, flow2));
}

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
// #pragma once: already included

/*
 * Copyright (c) 2022, Hooder <ahooder@protonmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#define NORMAL_MAPPING 1

// #pragma once: already included


#if NORMAL_MAPPING
vec3 sampleNormalMap(const Material material, const vec2 uv, const mat3 TBN) {
    if (material.normalMap == -1)
        return TBN[2];

    // Sample normal map texture, swapping Y and Z to match the coordinate system in OSRS
    vec3 n = texture(textureArray, vec3(uv, material.normalMap)).xyz;
    // Undo automatic sRGB to linear conversion, since we want the raw values
    n = linearToSrgb(n);
    // Scale and shift normal so it can point in both directions
    n.xy = n.xy * 2.0 - 1.0;
    // Flip normals when UVs are flipped
    n.xy *= sign(material.textureScale.xy);
    // Scale the normal map's Z-component to adjust strength
    n.z *= material.textureScale.z;
    // Transform the normal from tangent space to world space
    n = TBN * n;
    // Assume the normal is already normalized
    return n;
}
#else
#define sampleNormalMap(material, uv, TBN) TBN[2]
#endif

/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
// #pragma once: first include

float specular(vec3 texBlend, vec3 viewDir, vec3 reflectDir, vec3 specularGloss, vec3 specularStrength) {
    float vDotR = clamp(dot(viewDir, reflectDir), 1e-10, 1.);
    vec3 spec = pow(vec3(vDotR), specularGloss) * specularStrength;
    return dot(spec, texBlend);
}

/*
 * Copyright (c) 2023, Hooder <ahooder@protonmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone B1, parallax occlusion mapping). Verbatim copy of rs117/hd/utils/displacement.glsl
 * @ RLHD 7dded59 EXCEPT every int-in-float-context is made explicit (blueprint #13) so the POM raymarch compiles
 * on GLES 3.00 when PARALLAX_OCCLUSION_MAPPING != 0 — this whole file is a no-op macro at POM off, so Z0 never
 * compiled it. config.parallaxOcclusionMapping() is a boolean, so the define is 0/1; the `#if >= 2` self-shadowing
 * block is never reached at runtime (kept ES3-ported for completeness). Casts: minLayers/maxLayers/height/layer
 * int literals -> float; `1 - clamp(...,0,1)` -> 1.0/0.0/1.0; `layer >= 0` -> 0.0; vec3(uv, displacementMap) wraps
 * the int array index in float(). Logic identical. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
#define PARALLAX_OCCLUSION_MAPPING 1

// #pragma once: already included

// #pragma once: already included


#if PARALLAX_OCCLUSION_MAPPING

float sampleHeight(const Material material, const vec2 uv) {
    return linearToSrgb(texture(textureArray, vec3(uv, float(material.displacementMap))).r);
}

void sampleDisplacementMap(
    const Material material,
    const vec3 tsViewDir,
    const vec3 tsLightDir,
    inout vec2 uv,
    inout vec3 fragDelta,
    inout float selfShadowing
) {
    if (material.displacementMap == -1)
        return;

    float scale = material.displacementScale;

    // TODO: consider anti-aliasing to fit more nicely with MSAA
    // TODO: improve close-up accuracy
    const float minLayers = 1.0;
    const float maxLayers = 16.0;
    float cosView = normalize(tsViewDir).z;
    float numLayers = mix(minLayers, maxLayers, 1.0 - clamp(cosView * cosView, 0.0, 1.0));
    float heightPerLayer = 1. / numLayers;

    vec2 deltaXyPerZ = tsViewDir.xy / tsViewDir.z * scale;

    // Shift UVs so half displacement is the same height as the surface
    // This avoids some shadowing artifacts from the surface casting a shadow onto itself
    uv += deltaXyPerZ * .5;
    fragDelta -= vec3(deltaXyPerZ, scale) * .5;

    float height = 0.0;
    float prevHeight = 0.0;
    float layer = 1.0;
    float prevLayer = 1.0;
    for (; layer >= 0.0 && height <= layer; layer -= heightPerLayer) {
        prevLayer = layer;
        prevHeight = height;
        height = sampleHeight(material, uv - deltaXyPerZ * layer);
    }

    float overshoot = height - layer;
    float undershoot = (layer + heightPerLayer) - prevHeight;
    height = mix(height, prevHeight, overshoot / (overshoot + undershoot));

    vec3 tsDelta = vec3(deltaXyPerZ, scale) * height;
    uv -= tsDelta.xy;
    fragDelta += tsDelta;

    // TODO: fix self-shadowing at steep angles
//    #undef PARALLAX_OCCLUSION_MAPPING
//    #define PARALLAX_OCCLUSION_MAPPING 2
    #if PARALLAX_OCCLUSION_MAPPING >= 2 // self-shadowing (never reached: the config define maxes at 1)
        float cosLight = normalize(tsLightDir).z;
        float shadowBias = max(.0001, pow(1.0 - cosLight, 5.) * scale);

        // Prepare for shadow steps
        deltaXyPerZ = tsLightDir.xy / tsLightDir.z * scale;
        layer = height;

        #if PARALLAX_OCCLUSION_MAPPING == 2 // hard shadows
            for (; layer <= 1.0 && height <= layer; layer += heightPerLayer)
                height = sampleHeight(material, uv - deltaXyPerZ * layer) - shadowBias;

            if (layer <= 1.0)
                selfShadowing++;
        #else // PCF 3x3 soft shadows
            float shadow = 0.0;
            float texelSize = 1. / float(textureSize(textureArray, 0).x);
            for (int x = -1; x <= 1; x++) {
                for (int y = -1; y <= 1; y++) {
                    vec2 sUv = uv + (vec2(x, y) - .5) * texelSize;

                    float sLayer = layer;
                    float sHeight = height;
                    for (; sLayer <= 1.0 && sHeight <= sLayer; sLayer += heightPerLayer)
                        sHeight = sampleHeight(material, sUv - deltaXyPerZ * sLayer);

                    if (sLayer <= 1.0)
                        shadow++;
                }
            }
            selfShadowing += shadow / 9.0;
        #endif
    #endif
}
#else
#define sampleDisplacementMap(mat, viewDir, lightDir, fragDelta, selfShadowing) uv
#endif

/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * Copyright (c) 2024, Hooder <ahooder@protonmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone B1, shadows). Verbatim copy of rs117/hd/utils/shadows.glsl @ RLHD 7dded59
 * EXCEPT every int-in-float-context is made explicit (blueprint #13) so the SCENE program compiles on GLES 3.00
 * when SHADOW_MODE != OFF — this whole file is #if'd out (stub macro) at SHADOW_MODE_OFF, so Z0 never compiled it.
 * Changes are purely numeric-type explicitness; logic identical:
 *   - int literals in float context -> float literals (0->0.0, 1->1.0, 2->2.0)
 *   - SHADOW_* / POISSON_DISK_LENGTH (#define ints) cast to float at each float use
 *   - shadowPos.xy *= vec2(shadowRes)  (shadowRes is ivec2 from textureSize; vec2 *= ivec2 is illegal in ES)
 *   - clamp/max int args -> float; kernelSize/2 int wrapped float() before the vec2 subtraction
 * RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
// #pragma once: already included


// #pragma once: already included

/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
// #pragma once: already included


#if SHADOW_RESOLUTION == 0
    #define MIN_SHADOW_BIAS -0.00125
#elif SHADOW_RESOLUTION == 1
    #define MIN_SHADOW_BIAS -0.0007
#elif SHADOW_RESOLUTION == 2
    #define MIN_SHADOW_BIAS -0.00035
#elif SHADOW_RESOLUTION == 3
    #define MIN_SHADOW_BIAS -0.0003
#elif SHADOW_RESOLUTION >= 4
    #define MIN_SHADOW_BIAS -0.00025
#endif

#ifndef TILE_SIZE
    #define TILE_SIZE 128
#endif

#if SHADOW_MODE != SHADOW_MODE_OFF
float fetchShadowTexel(ivec2 pixelCoord, float fragDepth, vec3 fragPos, int i) {
    #if SHADOW_FILTERING == SHADOW_FILTERING_DITHER
        int index = int(hash(vec4(floor(fragPos.xyz), i)) * float(POISSON_DISK_LENGTH)) % POISSON_DISK_LENGTH;
        pixelCoord += ivec2(getPoissonDisk(index) * 1.25);
    #endif

    #if SHADOW_TRANSPARENCY
        int alphaDepth = int(texelFetch(shadowMap, pixelCoord, 0).r * float(SHADOW_COMBINED_MAX));
        float depth = float(alphaDepth & SHADOW_DEPTH_MAX) / float(SHADOW_DEPTH_MAX);
        float alpha = 1.0 - float(alphaDepth >> SHADOW_DEPTH_BITS) / float(SHADOW_ALPHA_MAX);
        return depth < fragDepth ? alpha : 0.0;
    #else
        return texelFetch(shadowMap, pixelCoord, 0).r < fragDepth ? 1.0 : 0.0;
    #endif
}

float sampleShadowMap(vec3 fragPos, vec2 distortion, float lightDotNormals) {
    if (lightStrength <= 0.0)
        return 0.0;

    vec4 shadowPos = lightProjectionMatrix * vec4(fragPos, 1.0);
    shadowPos.xyz /= shadowPos.w;

    // Fade out shadows near the shadow map edges
    #if ZONE_RENDERER
        // TODO: Make this configurable if we make the Shadow Distance Variable
        const float fadeStart = 55.0 * float(TILE_SIZE);
        const float fadeEnd   = 65.0 * float(TILE_SIZE);
        float fadeOut = smoothstep(fadeStart, fadeEnd, length(fragPos - cameraPos));
    #else
        float fadeOut = smoothstep(.75, 1., dot(shadowPos.xy, shadowPos.xy));
    #endif
    if (fadeOut >= 1.0)
        return 0.0;

    // NDC to texture space
    ivec2 shadowRes = textureSize(shadowMap, 0);
    shadowPos.xyz += 1.0;
    shadowPos.xyz /= 2.0;
    shadowPos.xy += distortion;
    shadowPos.xy = clamp(shadowPos.xy, 0.0, 1.0);
    shadowPos.xy *= vec2(shadowRes);
    shadowPos.xy += .5; // Shift to texel center

    float shadowBias = MIN_SHADOW_BIAS * max(1.0, 1.0 - lightDotNormals);
    float fragDepth = shadowPos.z + shadowBias;

    const int kernelSize = 3;
    ivec2 kernelOffset = ivec2(shadowPos.xy - float(kernelSize / 2));
    #if SHADOW_FILTERING == SHADOW_FILTERING_AVERAGE
        const float kernelAreaReciprocal = 1.0 / float(kernelSize * kernelSize);
    #else
        const float kernelAreaReciprocal = .25; // This is effectively a 2x2 kernel
        vec2 lerp = fract(shadowPos.xy);
        vec3 lerpX = vec3(1.0 - lerp.x, 1.0, lerp.x);
        vec3 lerpY = vec3(1.0 - lerp.y, 1.0, lerp.y);
    #endif

    // Sample 4 corners first
    float c00 = fetchShadowTexel(kernelOffset + ivec2(0, 0), fragDepth, fragPos, 0);
    float c02 = fetchShadowTexel(kernelOffset + ivec2(0, kernelSize - 1), fragDepth, fragPos, 1);
    float c20 = fetchShadowTexel(kernelOffset + ivec2(kernelSize - 1, 0), fragDepth, fragPos, 2);
    float c22 = fetchShadowTexel(kernelOffset + ivec2(kernelSize - 1, kernelSize - 1), fragDepth, fragPos, 3);

    // Early exit if all corners are the same (fully shadowed or fully lit)
    bool allShadowed = (c00 == 0.0 && c02 == 0.0 && c20 == 0.0 && c22 == 0.0);
    bool allLit      = (c00 == 1.0 && c02 == 1.0 && c20 == 1.0 && c22 == 1.0);

    float shadow = 0.0;
    if (allShadowed || allLit) {
        shadow = (c00 + c02 + c20 + c22) * 0.25;
    } else {
        // Finish sampling the reset of the kernal
        float s01 = fetchShadowTexel(kernelOffset + ivec2(0, 1), fragDepth, fragPos, 4);
        float s10 = fetchShadowTexel(kernelOffset + ivec2(1, 0), fragDepth, fragPos, 5);
        float s11 = fetchShadowTexel(kernelOffset + ivec2(1, 1), fragDepth, fragPos, 6);
        float s12 = fetchShadowTexel(kernelOffset + ivec2(1, 2), fragDepth, fragPos, 7);
        float s21 = fetchShadowTexel(kernelOffset + ivec2(2, 1), fragDepth, fragPos, 8);

        #if SHADOW_FILTERING == SHADOW_FILTERING_AVERAGE
            shadow =
                c00 + s01 + c02 +
                s10 + s11 + s12 +
                c20 + s21 + c22;
        #else
            shadow =
                c00 * lerpX[0] * lerpY[0] +
                s01 * lerpX[0] * lerpY[1] +
                c02 * lerpX[0] * lerpY[2] +
                s10 * lerpX[1] * lerpY[0] +
                s11 * lerpX[1] * lerpY[1] +
                s12 * lerpX[1] * lerpY[2] +
                c20 * lerpX[2] * lerpY[0] +
                s21 * lerpX[2] * lerpY[1] +
                c22 * lerpX[2] * lerpY[2];
        #endif
        shadow *= kernelAreaReciprocal;
    }

    return shadow * (1.0 - fadeOut);
}
#else
#define sampleShadowMap(fragPos, distortion, lightDotNormals) 0.0
#endif

/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone Z0). Verbatim copy of rs117/hd/utils/water.glsl @ RLHD 7dded59 EXCEPT every
 * int-literal-in-float-context is made explicit (GLSL ES 3.00 does no implicit int<->float conversion,
 * blueprint #13). Pervasively cast-heavy, so a hand-maintained override beats ~25 brittle downporter rules.
 * RE-MERGE against upstream when the pinned RLHD rev is bumped (water rendering evolves more than color_utils).
 * Only numeric-literal types changed; logic is identical.
 * ===========================================================================================================
 */
// #pragma once: already included

// #pragma once: already included

// #pragma once: already included


/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone B1, dynamic lights). Verbatim copy of rs117/hd/utils/lights.glsl @ RLHD 7dded59
 * EXCEPT the two int-in-float-context sites in calculateLight are made explicit (blueprint #13) so the SCENE
 * program compiles on GLES 3.00 when DYNAMIC_LIGHTS != NONE — this whole file is a no-op macro at DYNAMIC_LIGHTS
 * off, so Z0 never compiled it:
 *   line 19: 1 - sqrt(...)            -> 1.0 - sqrt(...)
 *   line 25: max(dot(...), 0)         -> max(dot(...), 0.0)
 * The UBO blocks (uniforms/lights.glsl) are sized at MAX_LIGHT_COUNT (<=100 for dynamic, NOT the 1000 tiled cap),
 * so they fit Apple's 16 KB uniform-block limit -> no texture-backed store needed (unlike UBOMaterials); the tiled
 * path caps lights at MAX_LIGHTS=480 (java-overrides/UBOLights.java) so the 480-entry UBO stays under the cap. B1
 * tiled lighting also ports the TILED_LIGHTING branch's tileXY (sceneResolution/tiledLightingResolution are ivec2
 * -> vec2()). Logic identical. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
// #pragma once: first include

// #pragma once: first include

// #pragma once: already included


#if DYNAMIC_LIGHTS
struct PointLight {
    vec4 position;
    vec4 color;
};

layout(std140) uniform UBOLights {
    PointLight PointLightArray[MAX_LIGHT_COUNT];
};

layout(std140) uniform UBOLightsCulling {
    vec4 PointLightPositionsArray[MAX_LIGHT_COUNT];
};

bool isDualPacked(uint packedValue) {
    return (packedValue & 0x8000u) != 0u;
}

ivec2 decodePackedLight(uint packedValue) {
    if (isDualPacked(packedValue)) {
        int idx0 = int(packedValue & 0x7Fu) - 1;
        int idx1 = int((packedValue >> 7) & 0xFFu) - 1;
        return ivec2(idx0, idx1);
    } else {
        return ivec2(int(packedValue & 0x7FFFu) - 1, -1);
    }
}
#endif


// #pragma once: already included

/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
// #pragma once: already included


#if DYNAMIC_LIGHTS
void calculateLight(
    int lightIdx, vec3 position, vec3 normals, vec3 viewDir,
    vec3 texBlend, vec3 specularGloss, vec3 specularStrength,
    inout vec3 pointLightsOut, inout vec3 pointLightsSpecularOut
) {
    PointLight light = PointLightArray[lightIdx];
    vec3 lightToFrag = light.position.xyz - position;
    float distanceSquared = dot(lightToFrag, lightToFrag);
    float radiusSquared = light.position.w;
    if (distanceSquared <= radiusSquared) {
        float attenuation = 1.0 - sqrt(distanceSquared / radiusSquared);
        attenuation *= attenuation;

        vec3 pointLightColor = light.color.rgb * attenuation;
        vec3 pointLightDir = normalize(lightToFrag);

        float pointLightDotNormals = max(dot(normals, pointLightDir), 0.0);
        pointLightsOut += pointLightColor * pointLightDotNormals;

        vec3 pointLightReflectDir = reflect(-pointLightDir, normals);
        pointLightsSpecularOut += pointLightColor * specular(texBlend, viewDir, pointLightReflectDir, specularGloss, specularStrength);
    }
}

void calculateLighting(
    vec3 position, vec3 normals, vec3 viewDir,
    vec3 texBlend, vec3 specularGloss, vec3 specularStrength,
    inout vec3 pointLightsOut, inout vec3 pointLightsSpecularOut
) {
    #if TILED_LIGHTING
        // iOS: sceneResolution / tiledLightingResolution are ivec2 (global UBO) -> vec2() before the float math.
        ivec2 tileXY = ivec2(gl_FragCoord.xy / vec2(sceneResolution) * vec2(tiledLightingResolution));

        for (int tileLayer = 0; tileLayer < TILED_LIGHTING_LAYER_COUNT; tileLayer++) {
            uvec4 tileLayerData = texelFetch(tiledLightingArray, ivec3(tileXY, tileLayer), 0);
            ivec2 unpackedData = ivec2(0);

            #define PROCESS_TILED_LIGHT_COMPONENT(c)                 \
                if (tileLayerData[c] <= 0u)                          \
                    break;                                           \
                unpackedData = decodePackedLight(tileLayerData[c]);  \
                                                                     \
                if (unpackedData[0] >= 0)                            \
                    calculateLight(unpackedData[0],                  \
                        position, normals, viewDir,                  \
                        texBlend, specularGloss, specularStrength,   \
                        pointLightsOut, pointLightsSpecularOut);     \
                                                                     \
                if (unpackedData[1] >= 0)                            \
                    calculateLight(unpackedData[1],                  \
                        position, normals, viewDir,                  \
                        texBlend, specularGloss, specularStrength,   \
                        pointLightsOut, pointLightsSpecularOut);

            PROCESS_TILED_LIGHT_COMPONENT(0);
            PROCESS_TILED_LIGHT_COMPONENT(1);
            PROCESS_TILED_LIGHT_COMPONENT(2);
            PROCESS_TILED_LIGHT_COMPONENT(3);
        }
    #else
        for (int lightIdx = 0; lightIdx < pointLightsCount; lightIdx++)
            calculateLight(lightIdx, position, normals, viewDir,
                texBlend, specularGloss, specularStrength,
                pointLightsOut, pointLightsSpecularOut);
    #endif
}
#else
#define calculateLighting(position, normals, viewDir, texBlend, specularGloss, specularStrength, pointLightsOut,  pointLightsSpecularOut)
#endif

/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
// #pragma once: already included


vec4 sampleWater(int waterTypeIndex, vec3 viewDir) {
    WaterType waterType = getWaterType(waterTypeIndex);

    vec2 uv1 = worldUvs(3.0).yx - animationFrame(28.0 * waterType.duration);
    vec2 uv2 = worldUvs(3.0) + animationFrame(24.0 * waterType.duration);
    vec2 uv3 = IN.uv;

    vec2 flowMapUv = worldUvs(15.0) + animationFrame(50.0 * waterType.duration);
    float flowMapStrength = 0.025;

    vec2 uvFlow = texture(textureArray, vec3(flowMapUv, MAT_WATER_FLOW_MAP.colorMap)).xy;
    uv1 += uvFlow * flowMapStrength;
    uv2 += uvFlow * flowMapStrength;
    uv3 += uvFlow * flowMapStrength;

    // get diffuse textures
    vec3 n1 = linearToSrgb(texture(textureArray, vec3(uv1, waterType.normalMap)).xyz);
    vec3 n2 = linearToSrgb(texture(textureArray, vec3(uv2, waterType.normalMap)).xyz);
    float foamMask = texture(textureArray, vec3(uv3, MAT_WATER_FOAM.colorMap)).r;

    // normals
    n1 = -vec3((n1.x * 2.0 - 1.0) * waterType.normalStrength, n1.z, (n1.y * 2.0 - 1.0) * waterType.normalStrength);
    n2 = -vec3((n2.x * 2.0 - 1.0) * waterType.normalStrength, n2.z, (n2.y * 2.0 - 1.0) * waterType.normalStrength);
    vec3 normals = normalize(n1 + n2);

    float lightDotNormals = dot(normals, lightDir);
    float downDotNormals = -normals.y;
    float viewDotNormals = dot(viewDir, normals);

    vec2 distortion = uvFlow * .00075;
    float shadow = sampleShadowMap(IN.position, distortion, lightDotNormals);
    float inverseShadow = 1.0 - shadow;

    vec3 vSpecularStrength = vec3(waterType.specularStrength);
    vec3 vSpecularGloss = vec3(waterType.specularGloss);
    float combinedSpecularStrength = waterType.specularStrength;

    // calculate lighting

    // ambient light
    vec3 ambientLightOut = ambientColor * ambientStrength;

    // directional light
    vec3 dirLightColor = lightColor * lightStrength;

    // apply shadows
    dirLightColor *= inverseShadow;

    vec3 lightColor = dirLightColor;
    vec3 lightOut = max(lightDotNormals, 0.0) * lightColor;

    // directional light specular
    vec3 lightReflectDir = reflect(-lightDir, normals);
    vec3 lightSpecularOut = lightColor * specular(IN.texBlend, viewDir, lightReflectDir, vSpecularGloss, vSpecularStrength);

    // point lights
    vec3 pointLightsOut = vec3(0);
    vec3 pointLightsSpecularOut = vec3(0);
    calculateLighting(IN.position, normals, viewDir, IN.texBlend, vSpecularGloss, vSpecularStrength, pointLightsOut, pointLightsSpecularOut);

    // sky light
    vec3 skyLightColor = fogColor.rgb;
    float skyLightStrength = 0.5;
    float skyDotNormals = downDotNormals;
    vec3 skyLightOut = max(skyDotNormals, 0.0) * skyLightColor * skyLightStrength;


    // lightning
    vec3 lightningColor = vec3(1.0, 1.0, 1.0);
    float lightningStrength = lightningBrightness;
    float lightningDotNormals = downDotNormals;
    vec3 lightningOut = max(lightningDotNormals, 0.0) * lightningColor * lightningStrength;


    // underglow
    vec3 underglowOut = underglowColor * max(normals.y, 0.0) * underglowStrength;


    // fresnel reflection
    float baseOpacity = 0.4;
    float fresnel = 1.0 - clamp(viewDotNormals, 0.0, 1.0);
    float finalFresnel = clamp(mix(baseOpacity, 1.0, fresnel * 1.2), 0.0, 1.0);
    vec3 surfaceColor = vec3(0);

    // add sky gradient
    if (finalFresnel < 0.5) {
        surfaceColor = mix(waterColorDark, waterColorMid, finalFresnel * 2.0);
    } else {
        surfaceColor = mix(waterColorMid, waterColorLight, (finalFresnel - 0.5) * 2.0);
    }

    vec3 surfaceColorOut = surfaceColor * max(combinedSpecularStrength, 0.2);


    // apply lighting
    vec3 compositeLight = ambientLightOut + lightOut + lightSpecularOut + skyLightOut + lightningOut +
    underglowOut + pointLightsOut + pointLightsSpecularOut + surfaceColorOut;

    vec3 baseColor = waterType.surfaceColor * compositeLight;
    baseColor = mix(baseColor, surfaceColor, waterType.fresnelAmount);
    if (waterType.fresnelAmount == 0.85)
        baseColor *= .75; // Sailing hack
    float shoreLineMask = 1.0 - dot(IN.texBlend, vec3(fAlphaBiasHsl & 127) / 127.);
    float maxFoamAmount = 0.8;
    float foamAmount = min(shoreLineMask, maxFoamAmount);
    float foamDistance = 0.7;
    vec3 foamColor = waterType.foamColor;
    foamColor = foamColor * foamMask * compositeLight;
    foamAmount = clamp(pow(1.0 - ((1.0 - foamAmount) / foamDistance), 3.0), 0.0, 1.0) * float(waterType.hasFoam);
    foamAmount *= foamColor.r;
    baseColor = mix(baseColor, foamColor, foamAmount);
    vec3 specularComposite = mix(lightSpecularOut, vec3(0.0), foamAmount);
    float flatFresnel = (1.0 - dot(viewDir, vec3(0, -1, 0))) * 1.0;
    finalFresnel = max(finalFresnel, flatFresnel);
    finalFresnel -= finalFresnel * shadow * 0.2;
    baseColor += pointLightsSpecularOut + lightSpecularOut / 3.0;

    float alpha = max(waterType.baseOpacity, max(foamAmount, max(finalFresnel, length(specularComposite / 3.0))));

    if (waterType.isFlat) {
        baseColor = mix(waterType.depthColor, baseColor, alpha);
        alpha = 1.0;
    }

    return vec4(baseColor, alpha);
}

void sampleUnderwater(inout vec3 outputColor, WaterType waterType, float depth, float lightDotNormals) {
    // underwater terrain
    float lowestColorLevel = 500.0;
    float midColorLevel = 150.0;
    float surfaceLevel = IN.position.y - depth; // e.g. -1600

    if (depth < midColorLevel) {
        outputColor *= mix(vec3(1), waterType.depthColor, translateRange(0.0, midColorLevel, depth));
    } else if (depth < lowestColorLevel) {
        outputColor *= mix(waterType.depthColor, vec3(0), translateRange(midColorLevel, lowestColorLevel, depth));
    } else {
        outputColor = vec3(0);
    }

    if (underwaterCaustics) {
        const float scale = 1.75;
        const float maxCausticsDepth = 128.0 * 4.0;

        vec2 causticsUv = worldUvs(scale);

        float depthMultiplier = (IN.position.y - surfaceLevel - maxCausticsDepth) / -maxCausticsDepth;
        depthMultiplier *= depthMultiplier;

        causticsUv *= .75;

        const vec2 direction = vec2(1.0, -2.0);   // ES3: vec2 (was ivec2) so animationFrame()*direction is vec2*vec2
        vec2 flow1 = causticsUv + animationFrame(17.0) * direction;
        vec2 flow2 = causticsUv * 1.5 + animationFrame(23.0) * -direction;
        vec3 caustics = sampleCaustics(flow1, flow2, .005);

        vec3 causticsColor = underwaterCausticsColor * underwaterCausticsStrength;
        outputColor.rgb *= 1.0 + caustics * causticsColor * depthMultiplier * lightDotNormals * lightStrength;
    }
}

// #pragma once: first include

#if APPLY_COLOR_FILTER

// #pragma once: already included


// #pragma once: already included


#define COLOR_FILTER_NONE 0
#define COLOR_FILTER_GREYSCALE 1
#define COLOR_FILTER_SEPIA 2
#define COLOR_FILTER_HIGH_CONTRAST 3
#define COLOR_FILTER_CARTOON 4
#define COLOR_FILTER_INVERT 5
#define COLOR_FILTER_BLACK_AND_WHITE 6
#define COLOR_FILTER_CEL_SHADING 7

vec3 applySingleColorFilter(int filterIndex, vec3 color) {
    switch (filterIndex) {
        case COLOR_FILTER_GREYSCALE:
            return vec3(dot(color, vec3(0.2126, 0.7152, 0.0722)));
        case COLOR_FILTER_SEPIA:
            return color * mat3(
                0.393, 0.769, 0.189,
                0.349, 0.686, 0.168,
                0.272, 0.534, 0.131
            );
        case COLOR_FILTER_HIGH_CONTRAST: {
            float intensity = dot(color, vec3(0.2126, 0.7152, 0.0722));
            float modifier = 2.2;
            return vec3(
                intensity + (color.r - intensity) * modifier,
                intensity + (color.g - intensity) * modifier,
                intensity + (color.b - intensity) * modifier
            );
        }
        case COLOR_FILTER_CARTOON: {
            float quantizationLevels = 7.0;
            vec3 quantizedColor = floor(color * quantizationLevels) / quantizationLevels;
            return quantizedColor;
        }
        case COLOR_FILTER_INVERT:
            return 1 - color;
        case COLOR_FILTER_BLACK_AND_WHITE:
            return dot(color, vec3(0.2126, 0.7152, 0.0722)) > 0.4 ? vec3(1) : vec3(0);
        case COLOR_FILTER_CEL_SHADING: {
            float intensity = dot(color, vec3(0.299, 0.587, 0.114));
            float quantizationLevels = 8.0;
            float quantizedIntensity = floor(intensity * quantizationLevels) / quantizationLevels;
            return color * quantizedIntensity / intensity;
        }
        default:
            return color;
    }
}

vec3 applyColorFilter(vec3 color) {
    vec3 previous = applySingleColorFilter(colorFilterPrevious, color);
    vec3 current = applySingleColorFilter(colorFilter, color);
    // Fade smoothly between the previous and current filters
    return mix(previous, current, smoothstep(0, 1, colorFilterFade));
}
#endif

/*
 * Copyright (c) 2018, Adam <Adam@sigterm.info>
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone Z0). Verbatim copy of rs117/hd/utils/fog.glsl @ RLHD 7dded59 EXCEPT every
 * int-in-float-context is made explicit (blueprint #13): TILE_SIZE (a `#define 128`) is cast to float at each
 * float use, the FOG_SCENE_EDGE_* macros are made float, the integer `useFog` uniform is cast, and int literal
 * args to clamp/max/fogFactorLinear are floats. Logic identical. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
// #pragma once: already included


#define TILE_SIZE 128
#define FOG_SCENE_EDGE_MIN (float((    - expandedMapLoadingChunks * 8 + 1) * TILE_SIZE))
#define FOG_SCENE_EDGE_MAX (float((104 + expandedMapLoadingChunks * 8 - 1) * TILE_SIZE))
#define FOG_CORNER_ROUNDING 1.5
#define FOG_CORNER_ROUNDING_SQUARED FOG_CORNER_ROUNDING * FOG_CORNER_ROUNDING

float fogFactorLinear(const float dist, const float start, const float end) {
    return 1.0 - clamp((dist - start) / (end - start), 0.0, 1.0);
}

float calculateFogAmount(vec3 position) {
    if (fogDepth == 0.0)
        return 0.;

    float drawDistance2 = drawDistance * float(TILE_SIZE);

    // the client draws one less tile to the north and east than it does to the south
    // and west, so subtract a tile's width from the north and east edges.
    float fogWest = max(FOG_SCENE_EDGE_MIN, cameraPos.x - drawDistance2);
    float fogEast = min(FOG_SCENE_EDGE_MAX, cameraPos.x + drawDistance2 - float(TILE_SIZE));
    float fogSouth = max(FOG_SCENE_EDGE_MIN, cameraPos.z - drawDistance2);
    float fogNorth = min(FOG_SCENE_EDGE_MAX, cameraPos.z + drawDistance2 - float(TILE_SIZE));

    // Calculate distance from the scene edge
    float xDist = min(position.x - fogWest, fogEast - position.x);
    float zDist = min(position.z - fogSouth, fogNorth - position.z);
    float nearestEdgeDistance = min(xDist, zDist);
    float secondNearestEdgeDistance = max(xDist, zDist);
    float fogDistance = nearestEdgeDistance
        - FOG_CORNER_ROUNDING * float(TILE_SIZE) * max(0.0,
            (nearestEdgeDistance + FOG_CORNER_ROUNDING_SQUARED)
            / (secondNearestEdgeDistance + FOG_CORNER_ROUNDING_SQUARED)
        );

    // This is different from the GPU plugin, and seems to have worked this way from the start
    float edgeFogAmount = fogFactorLinear(fogDistance, 0.0, 5.0 * float(TILE_SIZE)) * float(useFog);

    // Use a combination of two different methods of calculating distance fog.
    // The is super arbitrary and is only eyeballed to provide a similar overall
    // appearance between equal fog depths at different draw distances.

    float fogStart1 = drawDistance2 * 0.85;
    float distance1 = length(cameraPos.xz - position.xz);
    float distanceFogAmount1 = clamp((distance1 - fogStart1) / (drawDistance2 * .15), 0.0, 1.0);

    float minFogStart = 0.0;
    float maxFogStart = 0.3;
    drawDistance2 = min(drawDistance, 90.0) * float(TILE_SIZE);
    float fogDepthMultiplier = clamp(fogDepth, 0.0, 1000.0) / 1000.0;
    float fogStart2 = (maxFogStart - (fogDepthMultiplier * (maxFogStart - minFogStart))) * drawDistance2;
    float camToVertex = length(cameraPos - vec3(position.x, (position.y + cameraPos.y) / 2.0, position.z));
    float distance2 = max(camToVertex - fogStart2, 0.0) / max(drawDistance2 - fogStart2, 1.0);
    float density = fogDepth / 100.0;
    float distanceFogAmount2 = 1.0 - clamp(exp(-distance2 * density), 0.0, 1.0);

    // Combine distance fogs
    float distanceFogAmount = max(distanceFogAmount1, distanceFogAmount2);

    // Combine distance fog with edge fog
    return max(distanceFogAmount, edgeFogAmount);
}

/*
 * Copyright (c) 2024, nucleon <noelcun@protonmail.com>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
// #pragma once: first include

#if WIREFRAME
float wireframeMask() {
    const float wireframeWidth = 0.8;
    vec3 d = smoothstep(vec3(0.0), fwidth(IN.texBlend) * wireframeWidth, IN.texBlend);
    return min(min(d.x, d.y), d.z);
}
#endif

/*
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone B1, dynamic lights). Verbatim copy of rs117/hd/utils/lights.glsl @ RLHD 7dded59
 * EXCEPT the two int-in-float-context sites in calculateLight are made explicit (blueprint #13) so the SCENE
 * program compiles on GLES 3.00 when DYNAMIC_LIGHTS != NONE — this whole file is a no-op macro at DYNAMIC_LIGHTS
 * off, so Z0 never compiled it:
 *   line 19: 1 - sqrt(...)            -> 1.0 - sqrt(...)
 *   line 25: max(dot(...), 0)         -> max(dot(...), 0.0)
 * The UBO blocks (uniforms/lights.glsl) are sized at MAX_LIGHT_COUNT (<=100 for dynamic, NOT the 1000 tiled cap),
 * so they fit Apple's 16 KB uniform-block limit -> no texture-backed store needed (unlike UBOMaterials); the tiled
 * path caps lights at MAX_LIGHTS=480 (java-overrides/UBOLights.java) so the 480-entry UBO stays under the cap. B1
 * tiled lighting also ports the TILED_LIGHTING branch's tileXY (sceneResolution/tiledLightingResolution are ivec2
 * -> vec2()). Logic identical. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
// #pragma once: already included


void main() {
    vec3 downDir = vec3(0, -1, 0);
    // View & light directions are from the fragment to the camera/light
    vec3 viewDir = normalize(cameraPos - IN.position);

    Material material1 = getMaterial(fMaterialData[0] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);
    Material material2 = getMaterial(fMaterialData[1] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);
    Material material3 = getMaterial(fMaterialData[2] >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);

    // Water data
    bool isTerrain = (fTerrainData[0] & 1) != 0; // 1 = 0b1
    int waterDepth1 = fTerrainData[0] >> 11 & 0xFFF;
    int waterDepth2 = fTerrainData[1] >> 11 & 0xFFF;
    int waterDepth3 = fTerrainData[2] >> 11 & 0xFFF;
    float waterDepth =
        float(waterDepth1) * IN.texBlend.x +
        float(waterDepth2) * IN.texBlend.y +
        float(waterDepth3) * IN.texBlend.z;
    int waterTypeIndex = isTerrain ? fTerrainData[0] >> 3 & 0xFF : 0;
    WaterType waterType = getWaterType(waterTypeIndex);

    // set initial texture map ids
    int colorMap1 = material1.colorMap;
    int colorMap2 = material2.colorMap;
    int colorMap3 = material3.colorMap;

    // only use one flowMap map
    int flowMap = material1.flowMap;

    bool isUnderwater = waterDepth != 0.0;
    bool isWater = waterTypeIndex > 0 && !isUnderwater;

    vec4 outputColor = vec4(1);

    if (isWater) {
        outputColor = sampleWater(waterTypeIndex, viewDir);
    } else {
        vec2 blendedUv = IN.uv;

        float mipBias = 0.0;
        // Vanilla tree textures rely on UVs being clamped horizontally, which HD doesn't do at the texture level.
        // Instead we manually clamp vanilla textures with transparency here. Including the transparency check
        // allows texture wrapping to work correctly for the mirror shield.
        if ((fMaterialData[0] >> MATERIAL_FLAG_VANILLA_UVS & 1) == 1 && getMaterialHasTransparency(material1))
            blendedUv.x = clamp(blendedUv.x, 0.0, .984375);

        vec2 uv1 = blendedUv;
        vec2 uv2 = blendedUv;
        vec2 uv3 = blendedUv;

        // Scroll UVs
        uv1 += material1.scrollDuration * elapsedTime;
        uv2 += material2.scrollDuration * elapsedTime;
        uv3 += material3.scrollDuration * elapsedTime;

        // Scale from the center
        uv1 = (uv1 - .5) * material1.textureScale.xy + .5;
        uv2 = (uv2 - .5) * material2.textureScale.xy + .5;
        uv3 = (uv3 - .5) * material3.textureScale.xy + .5;

        // get flowMap map
        vec2 flowMapUv = uv1 - animationFrame(material1.flowMapDuration);
        float flowMapStrength = material1.flowMapStrength;
        if (isUnderwater)
        {
            // Distort underwater textures
            flowMapUv = worldUvs(1.5) + animationFrame(10.0 * waterType.duration) * vec2(1, -1);
            flowMapStrength = 0.075;
        }

        vec2 uvFlow = texture(textureArray, vec3(flowMapUv, flowMap)).xy;
        uv1 += uvFlow * flowMapStrength;
        uv2 += uvFlow * flowMapStrength;
        uv3 += uvFlow * flowMapStrength;

        // Set up tangent-space transformation matrix

        vec3 N;
        #if FLAT_SHADING && ZONE_RENDERER
            N = normalize(fFlatNormal);
        #else
            N = normalize(IN.normal);
        #endif
        mat3 TBN = cotangent_frame(N, IN.position, IN.uv * -1.0);

        #if DISPLAY_UV
            FragColor = vec4(fract(uv1 * IN.texBlend.x + uv2 * IN.texBlend.y + uv3 * IN.texBlend.z), 0.0, 1.0);
            if (DISPLAY_UV == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        #if DISPLAY_NORMAL
            FragColor = vec4(N * 0.5 + 0.5, 1.0);
            if (DISPLAY_NORMAL == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        #if DISPLAY_TANGENT
            FragColor = vec4(TBN[0] * 0.5 + 0.5, 1.0);
            if (DISPLAY_TANGENT == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        float selfShadowing = 0.0;
        vec3 fragPos = IN.position;
        #if PARALLAX_OCCLUSION_MAPPING
            mat3 invTBN = inverse(TBN);
            vec3 tsViewDir = invTBN * viewDir;
            vec3 tsLightDir = invTBN * -lightDir;

            vec3 fragDelta = vec3(0);

            sampleDisplacementMap(material1, tsViewDir, tsLightDir, uv1, fragDelta, selfShadowing);
            sampleDisplacementMap(material2, tsViewDir, tsLightDir, uv2, fragDelta, selfShadowing);
            sampleDisplacementMap(material3, tsViewDir, tsLightDir, uv3, fragDelta, selfShadowing);

            // Average
            fragDelta /= 3.0;
            selfShadowing /= 3.0;

            // Prevent displaced surfaces from casting flat shadows onto themselves
            fragDelta.z = max(0.0, fragDelta.z);

            fragPos += TBN * fragDelta;
        #endif

        vec3 hsl1 = unpackRawHsl(fAlphaBiasHsl[0]);
        vec3 hsl2 = unpackRawHsl(fAlphaBiasHsl[1]);
        vec3 hsl3 = unpackRawHsl(fAlphaBiasHsl[2]);

        // Apply entity tint to HSL
        ivec4 tint = getWorldViewTint(fWorldViewId);
        if (tint.w > 0) {
            hsl1 += ((vec3(tint.xyz) - hsl1) * float(tint.w)) / 128.0;
            hsl2 += ((vec3(tint.xyz) - hsl2) * float(tint.w)) / 128.0;
            hsl3 += ((vec3(tint.xyz) - hsl3) * float(tint.w)) / 128.0;
        }

        // get vertex colors
        vec4 baseColor1 = vec4(convertHsl(hsl1), 1.0 - float(fAlphaBiasHsl[0] >> 24 & 0xff) / 255.);
        vec4 baseColor2 = vec4(convertHsl(hsl2), 1.0 - float(fAlphaBiasHsl[1] >> 24 & 0xff) / 255.);
        vec4 baseColor3 = vec4(convertHsl(hsl3), 1.0 - float(fAlphaBiasHsl[2] >> 24 & 0xff) / 255.);

        // Convert to linear RGB
        baseColor1.rgb = srgbToLinear(hslToSrgb(baseColor1.xyz));
        baseColor2.rgb = srgbToLinear(hslToSrgb(baseColor2.xyz));
        baseColor3.rgb = srgbToLinear(hslToSrgb(baseColor3.xyz));

        #if DISPLAY_BASE_COLOR
        if (DISPLAY_BASE_COLOR == 1) { // Redundant, used for syntax highlighting in IntelliJ
            outputColor = baseColor1 * IN.texBlend.x + baseColor2 * IN.texBlend.y + baseColor3 * IN.texBlend.z;
            outputColor.rgb = linearToSrgb(outputColor.rgb);
            FragColor = outputColor;
            return;
        }
        #endif

        // get diffuse textures
        vec4 texColor1 = colorMap1 == -1 ? vec4(1) : texture(textureArray, vec3(uv1, colorMap1), mipBias);
        vec4 texColor2 = colorMap2 == -1 ? vec4(1) : texture(textureArray, vec3(uv2, colorMap2), mipBias);
        vec4 texColor3 = colorMap3 == -1 ? vec4(1) : texture(textureArray, vec3(uv3, colorMap3), mipBias);
        texColor1.rgb *= material1.brightness;
        texColor2.rgb *= material2.brightness;
        texColor3.rgb *= material3.brightness;

        ivec3 isOverlay = ivec3(
            fMaterialData[0] >> MATERIAL_FLAG_IS_OVERLAY & 1,
            fMaterialData[1] >> MATERIAL_FLAG_IS_OVERLAY & 1,
            fMaterialData[2] >> MATERIAL_FLAG_IS_OVERLAY & 1
        );
        int overlayCount = isOverlay[0] + isOverlay[1] + isOverlay[2];
        ivec3 isUnderlay = ivec3(1) - isOverlay;
        int underlayCount = isUnderlay[0] + isUnderlay[1] + isUnderlay[2];

        // calculate blend amounts for overlay and underlay vertices
        vec3 underlayBlend = IN.texBlend * vec3(isUnderlay);
        vec3 overlayBlend = IN.texBlend * vec3(isOverlay);

        if (underlayCount == 0 || overlayCount == 0)
        {
            // if a tile has all overlay or underlay vertices,
            // use the default blend

            underlayBlend = IN.texBlend;
            overlayBlend = IN.texBlend;
        }
        else
        {
            // if there's a mix of overlay and underlay vertices,
            // calculate custom blends for each 'layer'

            float underlayBlendMultiplier = 1.0 / (underlayBlend[0] + underlayBlend[1] + underlayBlend[2]);
            // adjust back to 1.0 total
            underlayBlend *= underlayBlendMultiplier;
            underlayBlend = clamp(underlayBlend, 0.0, 1.0);

            float overlayBlendMultiplier = 1.0 / (overlayBlend[0] + overlayBlend[1] + overlayBlend[2]);
            // adjust back to 1.0 total
            overlayBlend *= overlayBlendMultiplier;
            overlayBlend = clamp(overlayBlend, 0.0, 1.0);
        }


        // get fragment colors by combining vertex colors and texture samples
        vec4 texA = getMaterialShouldOverrideBaseColor(material1) ? texColor1 : vec4(texColor1.rgb * baseColor1.rgb, min(texColor1.a, baseColor1.a));
        vec4 texB = getMaterialShouldOverrideBaseColor(material2) ? texColor2 : vec4(texColor2.rgb * baseColor2.rgb, min(texColor2.a, baseColor2.a));
        vec4 texC = getMaterialShouldOverrideBaseColor(material3) ? texColor3 : vec4(texColor3.rgb * baseColor3.rgb, min(texColor3.a, baseColor3.a));

        // combine fragment colors based on each blend, creating
        // one color for each overlay/underlay 'layer'
        vec4 underlayColor = texA * underlayBlend.x + texB * underlayBlend.y + texC * underlayBlend.z;
        vec4 overlayColor = texA * overlayBlend.x + texB * overlayBlend.y + texC * overlayBlend.z;

        float overlayMix = 0.0;

        if (overlayCount > 0 && underlayCount > 0)
        {
            ivec3 isPrimary = isUnderlay;
            bool invert = true;
            if (overlayCount == 1) {
                isPrimary = isOverlay;
                invert = false;
            }

            float result = dot(IN.texBlend, vec3(isPrimary));
            if (invert)
                result = 1.0 - result;

            result = clamp(result * 2.0 - 1.0, 0.0, 1.0);
            overlayMix = result;
        }

        outputColor = mix(underlayColor, overlayColor, overlayMix);

        // normals
        vec3 normals;
        if ((fMaterialData[0] >> MATERIAL_FLAG_UPWARDS_NORMALS & 1) == 1) {
            normals = vec3(0, -1, 0);
        } else {
            vec3 n1 = sampleNormalMap(material1, uv1, TBN);
            vec3 n2 = sampleNormalMap(material2, uv2, TBN);
            vec3 n3 = sampleNormalMap(material3, uv3, TBN);
            normals = normalize(n1 * IN.texBlend.x + n2 * IN.texBlend.y + n3 * IN.texBlend.z);
        }

        float lightDotNormals = dot(normals, lightDir);
        float downDotNormals = dot(downDir, normals);
        float viewDotNormals = dot(viewDir, normals);

        #if DISABLE_DIRECTIONAL_SHADING
            lightDotNormals = .7;
        #endif

        float shadow = 0.0;
        if ((fMaterialData[0] >> MATERIAL_FLAG_DISABLE_SHADOW_RECEIVING & 1) == 0)
            shadow = sampleShadowMap(fragPos, vec2(0), lightDotNormals);
        shadow = max(shadow, selfShadowing);
        float inverseShadow = 1.0 - shadow;

        #if DISPLAY_SHADOWS
            FragColor = vec4(inverseShadow, inverseShadow, inverseShadow, 1.0);
            if (DISPLAY_SHADOWS == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        // specular
        vec3 vSpecularGloss = vec3(material1.specularGloss, material2.specularGloss, material3.specularGloss);
        vec3 vSpecularStrength = vec3(material1.specularStrength, material2.specularStrength, material3.specularStrength);
        vSpecularStrength *= vec3(
            material1.roughnessMap == -1 ? 1.0 : linearToSrgb(texture(textureArray, vec3(uv1, material1.roughnessMap)).r),
            material2.roughnessMap == -1 ? 1.0 : linearToSrgb(texture(textureArray, vec3(uv2, material2.roughnessMap)).r),
            material3.roughnessMap == -1 ? 1.0 : linearToSrgb(texture(textureArray, vec3(uv3, material3.roughnessMap)).r)
        );

        // apply specular highlights to anything semi-transparent
        // this isn't always desirable but adds subtle light reflections to windows, etc.
        if (baseColor1.a + baseColor2.a + baseColor3.a < 2.99)
        {
            vSpecularGloss = vec3(30);
            vSpecularStrength = vec3(
                clamp((1.0 - baseColor1.a) * 2.0, 0.0, 1.0),
                clamp((1.0 - baseColor2.a) * 2.0, 0.0, 1.0),
                clamp((1.0 - baseColor3.a) * 2.0, 0.0, 1.0)
            );
        }
        float combinedSpecularStrength = dot(vSpecularStrength, IN.texBlend);


        // calculate lighting

        // ambient light
        vec3 ambientLightOut = ambientColor * ambientStrength;

        float aoFactor =
            IN.texBlend.x * (material1.ambientOcclusionMap == -1 ? 1.0 : texture(textureArray, vec3(uv1, material1.ambientOcclusionMap)).r) +
            IN.texBlend.y * (material2.ambientOcclusionMap == -1 ? 1.0 : texture(textureArray, vec3(uv2, material2.ambientOcclusionMap)).r) +
            IN.texBlend.z * (material3.ambientOcclusionMap == -1 ? 1.0 : texture(textureArray, vec3(uv3, material3.ambientOcclusionMap)).r);
        ambientLightOut *= aoFactor;

        // directional light
        vec3 dirLightColor = lightColor * lightStrength;

        // underwater caustics based on directional light
        if (underwaterCaustics && underwaterEnvironment) {
            float scale = 12.8;
            vec2 causticsUv = worldUvs(scale);

            const vec2 direction = vec2(1.0, -1.0);
            const int driftSpeed = 231;
            vec2 drift = animationFrame(231.0) * vec2(1.0, -2.0);
            vec2 flow1 = causticsUv + animationFrame(19.0) * direction + drift;
            vec2 flow2 = causticsUv * 1.25 + animationFrame(37.0) * -direction + drift;

            vec3 caustics = sampleCaustics(flow1, flow2) * 2.0;

            vec3 causticsColor = underwaterCausticsColor * underwaterCausticsStrength;
            dirLightColor += caustics * causticsColor * lightDotNormals * pow(lightStrength, 1.5);
        }

        // apply shadows
        dirLightColor *= inverseShadow;

        vec3 lightColor = dirLightColor;
        vec3 lightOut = max(lightDotNormals, 0.0) * lightColor;

        // directional light specular
        vec3 lightReflectDir = reflect(-lightDir, normals);
        vec3 lightSpecularOut = lightColor * specular(IN.texBlend, viewDir, lightReflectDir, vSpecularGloss, vSpecularStrength);

        // point lights
        vec3 pointLightsOut = vec3(0);
        vec3 pointLightsSpecularOut = vec3(0);
        calculateLighting(IN.position, normals, viewDir, IN.texBlend, vSpecularGloss, vSpecularStrength, pointLightsOut, pointLightsSpecularOut);

        // sky light
        vec3 skyLightColor = fogColor;
        float skyLightStrength = 0.5;
        float skyDotNormals = downDotNormals;
        vec3 skyLightOut = max(skyDotNormals, 0.0) * skyLightColor * skyLightStrength;


        // lightning
        vec3 lightningColor = vec3(.25, .25, .25);
        float lightningStrength = lightningBrightness;
        float lightningDotNormals = downDotNormals;
        vec3 lightningOut = max(lightningDotNormals, 0.0) * lightningColor * lightningStrength;


        // underglow
        vec3 underglowOut = underglowColor * max(normals.y, 0.0) * underglowStrength;


        // fresnel reflection
        float baseOpacity = 0.4;
        float fresnel = 1.0 - clamp(viewDotNormals, 0.0, 1.0);
        float finalFresnel = clamp(mix(baseOpacity, 1.0, fresnel * 1.2), 0.0, 1.0);
        vec3 surfaceColor = vec3(0);
        vec3 surfaceColorOut = surfaceColor * max(combinedSpecularStrength, 0.2);


        // apply lighting
        vec3 compositeLight = ambientLightOut + lightOut + lightSpecularOut + skyLightOut + lightningOut +
        underglowOut + pointLightsOut + pointLightsSpecularOut + surfaceColorOut;

        #if DISPLAY_LIGHTING
            FragColor = vec4(compositeLight, 1.0);
            if (DISPLAY_LIGHTING == 1) return; // Redundant, for syntax highlighting in IntelliJ
        #endif

        float unlit = dot(IN.texBlend, vec3(
            getMaterialIsUnlit(material1),
            getMaterialIsUnlit(material2),
            getMaterialIsUnlit(material3)
        ));

        #if VANILLA_COLOR_BANDING
            outputColor.rgb = linearToSrgb(outputColor.rgb);
            outputColor.rgb = srgbToHsv(outputColor.rgb);
            outputColor.b = floor(outputColor.b * 127) / 127;
            outputColor.rgb = hsvToSrgb(outputColor.rgb);
            outputColor.rgb = srgbToLinear(outputColor.rgb);
        #endif

        if (tint.w > 0) {
            outputColor.rgb *= 1.0 + skyLightOut;
        } else {
            outputColor.rgb *= mix(compositeLight, vec3(1), unlit);
        }
        outputColor.rgb = linearToSrgb(outputColor.rgb);

        if (isUnderwater) {
            sampleUnderwater(outputColor.rgb, waterType, waterDepth, lightDotNormals);
        }
    }

    vec2 tiledist = abs(floor(IN.position.xz / 128.0) - floor(cameraPos.xz / 128.0));
    float maxDist = max(tiledist.x, tiledist.y);
    if (maxDist > drawDistance) {
        // Rapidly fade out any geometry that extends beyond the draw distance.
        // This is required if we always draw all underwater terrain.
        outputColor.a *= -256.0;
    }

    outputColor.rgb = clamp(outputColor.rgb, 0.0, 1.0);

    // Skip unnecessary color conversion if possible
    if (saturation != 1.0 || contrast != 1.0) {
        vec3 hsv = srgbToHsv(outputColor.rgb);

        // Apply saturation setting
        hsv.y *= saturation;

        // Apply contrast setting
        if (hsv.z > 0.5) {
            hsv.z = 0.5 + ((hsv.z - 0.5) * contrast);
        } else {
            hsv.z = 0.5 - ((0.5 - hsv.z) * contrast);
        }

        outputColor.rgb = hsvToSrgb(hsv);
    }

    outputColor.rgb = colorBlindnessCompensation(outputColor.rgb);

    #if APPLY_COLOR_FILTER
        outputColor.rgb = applyColorFilter(outputColor.rgb);
    #endif

    #if WIREFRAME
        outputColor.rgb *= wireframeMask();
    #endif

    // apply fog
    if (!isUnderwater) {
        // ground fog
        float distance = distance(IN.position, cameraPos);
        float closeFadeDistance = 1500.0;
        float groundFog = 1.0 - clamp((IN.position.y - groundFogStart) / (groundFogEnd - groundFogStart), 0.0, 1.0);
        groundFog = mix(0.0, groundFogOpacity, groundFog);
        groundFog *= clamp(distance / closeFadeDistance, 0.0, 1.0);

        // multiply the visibility of each fog
        float fogAmount = calculateFogAmount(IN.position);
        float combinedFog = 1.0 - (1.0 - fogAmount) * (1.0 - groundFog);

        if (isWater) {
            outputColor.a = combinedFog + outputColor.a * (1.0 - combinedFog);
        }

        outputColor.rgb = mix(outputColor.rgb, fogColor, combinedFog);
    }

    outputColor.rgb = pow(outputColor.rgb, vec3(gammaCorrection));

    #if WINDOWS_HDR_CORRECTION
        outputColor.rgb = windowsHdrCorrection(outputColor.rgb);
    #endif

    FragColor = outputColor;
}
