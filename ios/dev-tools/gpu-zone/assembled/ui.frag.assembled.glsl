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

layout(std140) uniform UBOUI {
    ivec2 sourceDimensions;
    ivec2 targetDimensions;
    vec4 alphaOverlay;
};

#define UI_SCALING_MODE 0
#define UI_SCALING_MODE_NEAREST 0
#define UI_SCALING_MODE_LINEAR 1
#define UI_SCALING_MODE_MITCHELL 2
#define UI_SCALING_MODE_CATROM 3
#define UI_SCALING_MODE_XBR 4
#define UI_SCALING_MODE_HYBRID 5


uniform sampler2D uiTexture;

/*
 * Copyright (c) 2019 logarrhythmic <https://github.com/logarrhythmic>
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

/* Bicubic sampling takes neighboring pixels into account using a cubic filter for pixel weights.
 *
 * A generalized cubic filter as described by Mitchell and Netravali is defined by the piecewise equation:
 * if abs(x) < 1
 *  y = 1/6 * ( (12 - 9b - 6c) * abs(x)^3 + (-18 + 12b + 6c) * abs(x)^2 + (6 - 2b) )
 * if abs(x) >= 1 and < 2
 *  y = 1/6 * ( (-1b - 6c) * abs(x)^3 + (6b + 30c) * abs(x)^2 + (-12b - 48c) * abs(x) + (8b + 24c) )
 * otherwise
 *  y = 0
 * This produces a bell curve centered on 0 with a width of 2.
 *
 * The 2 functions below are specific cases of the cubic filter with particular values of a and b.
 */

// Cubic filter with Catmull-Rom parameters
float catmull_rom(float x)
{
    /*
     * Generally favorable results in image upscaling are given by a cubic filter with the values b = 0 and c = 0.5.
     * This is known as the Catmull-Rom filter, and it closely approximates Jinc upscaling with Lanczos input values.
     * Placing these values into the piecewise equation gives us a more compact representation of:
     *  y = 1.5 * abs(x)^3 - 2.5 * abs(x)^2 + 1                 // abs(x) < 1
     *  y = -0.5 * abs(x)^3 + 2.5 * abs(x)^2 - 4 * abs(x) + 2   // 1 <= abs(x) < 2
     */

    float t = abs(x);
    float t2 = t * t;
    float t3 = t * t * t;

    if (t < 1.0)
        return 1.5 * t3 - 2.5 * t2 + 1.0;
    else if (t < 2.0)
        return -0.5 * t3 + 2.5 * t2 - 4.0 * t + 2.0;
    else
        return 0.0;
}

float mitchell(float x)
{
    /*
     * This is another cubic filter with less aggressive sharpening than Catmull-Rom, which some users may prefer.
     * B = 1/3, C = 1/3.
     */

    float t = abs(x);
    float t2 = t * t;
    float t3 = t * t * t;

    if (t < 1.0)
        return 7.0/6.0 * t3 + -2.0 * t2 + 8.0/9.0;
    else if (t < 2.0)
        return -7.0/18.0 * t3 + 2.0 * t2 - 10.0/3.0 * t + 16.0/9.0;
    else
        return 0.0;
}

#define CR_AR_STRENGTH 0.9

#define FLT_MAX 3.402823466e+38
#define FLT_MIN 1.175494351e-38

// Calculates the distance between two points
float d(vec2 pt1, vec2 pt2)
{
    vec2 v = pt2 - pt1;
    return sqrt(dot(v,v));
}

// Samples a texture using a 4x4 kernel.
vec4 textureCubic(sampler2D sampler, vec2 texCoords)
{
    vec2 texSize = vec2(textureSize(sampler, 0));
    vec2 texelSize = 1.0 / texSize;
    vec2 texelFCoords = texCoords * texSize;
    texelFCoords -= 0.5;

    vec4 nSum = vec4( 0.0, 0.0, 0.0, 0.0 );
    vec4 nDenom = vec4( 0.0, 0.0, 0.0, 0.0 );

    vec2 coordFract = fract(texelFCoords);
    texCoords -= coordFract * texelSize;

    vec4 c;

    #if UI_SCALING_MODE == UI_SCALING_MODE_CATROM
        // catrom benefits from anti-ringing, which requires knowledge of the minimum and maximum samples in the kernel
        vec4 min_sample = vec4(FLT_MAX);
        vec4 max_sample = vec4(FLT_MIN);
        for (int m = -1; m <= 2; m++)
        {
            for (int n = -1; n <= 2; n++)
            {
                // this would use texelFetch, but that would require manual implementation of texture wrapping
                vec4 vecData = texture(sampler, texCoords + vec2(m, n) * texelSize);

                // update min and max as we go
                min_sample = min(min_sample, vecData);
                max_sample = max(max_sample, vecData);

                // calculate weight based on distance of the current texel offset from the sub-texel position of the sampling location
                float w = catmull_rom( d(vec2(m, n), coordFract) );

                // build the weighted average
                nSum += vecData * w;
                nDenom += w;
            }
        }
        // calculate weighted average
        c = nSum / nDenom;

        // store value before anti-ringing
        vec4 aux = c;
        // anti-ringing: clamp the color value so that it cannot exceed values already present in the kernel area
        c = clamp(c, min_sample, max_sample);
        // mix according to anti-ringing strength
        c = mix(aux, c, CR_AR_STRENGTH);
    #elif UI_SCALING_MODE == UI_SCALING_MODE_MITCHELL
        for (int m = -1; m <= 2; m++)
        {
            for (int n = -1; n <= 2; n++)
            {
                // this would use texelFetch, but that would require manual implementation of texture wrapping
                vec4 vecData = texture(sampler, texCoords + vec2(m, n) * texelSize);

                // calculate weight based on distance of the current texel offset from the sub-texel position of the sampling location
                float w = mitchell( d(vec2(m, n), coordFract) );

                // build the weighted average
                nSum += vecData * w;
                nDenom += w;
            }
        }
        // calculate weighted average
        c = nSum / nDenom;
    #else
        c = vec4(1, 0, 1, 1); // magenta = error
    #endif

    // return the weighted average
    return c;
}

// #pragma once: already included

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


#if UI_SCALING_MODE == UI_SCALING_MODE_XBR
/*
   Hyllian's xBR-lv2 Shader

   Copyright (C) 2011-2016 Hyllian - sergiogdb@gmail.com

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
   THE SOFTWARE.

   Incorporates some of the ideas from SABR shader. Thanks to Joshua Street.
*/

//   PARAMETERS   //
// Uncomment just one of the four params below to choose the corner detection
//#define CORNER_A
//#define CORNER_B
#define CORNER_C
//#define CORNER_D

#define XBR_Y_WEIGHT 50.0           // involved in preserving small details if small_details = 1, otherwise unused
#define XBR_EQ_THRESHOLD 9.0        // equality threshold for comparisons
//#define XBR_LV1_COEFFICIENT 0.5   // unused, probably left over from a previous iteration
#define XBR_LV2_COEFFICIENT 2.0     // moves the step in a step function at one point during blending
#define small_details 1.0           // 0 or 1, switches logic in a few spots to help preserve small details
// END PARAMETERS //

#define mul(a,b) (b*a)
#define lv2_cf XBR_LV2_COEFFICIENT
#ifndef CORNER_A
#define SMOOTH_TIPS
#endif

//const float coef         = 2.0; // unused
const vec3 rgbw          = vec3(14.352, 28.176, 5.472);     // rgb weights
//const vec4 eq_threshold  = vec4(15.0, 15.0, 15.0, 15.0); // unused

const  vec4 Ao = vec4( 1.0, -1.0, -1.0, 1.0 );
const  vec4 Bo = vec4( 1.0,  1.0, -1.0,-1.0 );
const  vec4 Co = vec4( 1.5,  0.5, -0.5, 0.5 );
const  vec4 Ax = vec4( 1.0, -1.0, -1.0, 1.0 );
const  vec4 Bx = vec4( 0.5,  2.0, -0.5,-2.0 );
const  vec4 Cx = vec4( 1.0,  1.0, -0.5, 0.0 );
const  vec4 Ay = vec4( 1.0, -1.0, -1.0, 1.0 );
const  vec4 By = vec4( 2.0,  0.5, -2.0,-0.5 );
const  vec4 Cy = vec4( 2.0,  0.0, -1.0, 0.5 );
const  vec4 Ci = vec4(0.25, 0.25, 0.25, 0.25);

const vec3 Y = vec3(0.2126, 0.7152, 0.0722); // rec.709 luma weights

// Difference between vector components.
vec4 df(vec4 A, vec4 B)
{
    return vec4(abs(A-B));
}

// Compare two vectors and return their components are different.
vec4 diff(vec4 A, vec4 B)
{
    return vec4(notEqual(A, B));
}

// Determine if two vector components are equal based on a threshold.
vec4 eq(vec4 A, vec4 B)
{
    return (step(df(A, B), vec4(XBR_EQ_THRESHOLD)));
}

// Determine if two vector components are NOT equal based on a threshold.
vec4 neq(vec4 A, vec4 B)
{
    return (vec4(1.0, 1.0, 1.0, 1.0) - eq(A, B));
}

// Weighted distance.
vec4 wd(vec4 a, vec4 b, vec4 c, vec4 d, vec4 e, vec4 f, vec4 g, vec4 h)
{
    return (df(a,b) + df(a,c) + df(d,e) + df(d,f) + 4.0*df(g,h));
}

// This is a macro because a function behaves differently between Apple Silicon Macs vs other platforms.
#define weighted_distance(a,b,c,d,e,f,g,h,i,j,k,l) (df(a,b) + df(a,c) + df(d,e) + df(d,f) + df(i,j) + df(k,l) + 2.0*df(g,h))

float c_df(vec3 c1, vec3 c2)
{
    vec3 df = abs(c1 - c2);
    return df.r + df.g + df.b;
}

/*
   Hyllian's xBR-lv2 Shader

   Copyright (C) 2011-2016 Hyllian - sergiogdb@gmail.com

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
   THE SOFTWARE.

   Incorporates some of the ideas from SABR shader. Thanks to Joshua Street.
*/

struct XBRTable
{
    vec2 texCoord;
    vec4 t1;
    vec4 t2;
    vec4 t3;
    vec4 t4;
    vec4 t5;
    vec4 t6;
    vec4 t7;
};



// xBR-level2 upscaler. Level 2 means it detects edges in 2 directions, instead of just 1 in the most basic form of the algorithm.
// This improves quality by a good bit without adding too much complexity compared to available level-3 and level-4 algorithms.
vec4 textureXBR(sampler2D image, vec2 texCoord, XBRTable t, float scale)
{
    vec4 delta   = vec4(1.0/scale, 1.0/scale, 1.0/scale, 1.0/scale);
    vec4 delta_l = vec4(0.5/scale, 1.0/scale, 0.5/scale, 1.0/scale);
    vec4 delta_u = delta_l.yxwz;

    vec2 textureDimensions = textureSize(image, 0);

    vec4 edri, edr, edr_l, edr_u, px; // px = pixel, edr = edge detection rule
    vec4 irlv0, irlv1, irlv2l, irlv2u, block_3d;
    vec4 fx, fx_l, fx_u; // inequations of straight lines.

    vec2 fp = fract(texCoord*textureDimensions);

    //    A1 B1 C1
    // A0  A  B  C C4
    // D0  D  E  F F4
    // G0  G  H  I I4
    //    G5 H5 I5
    vec4 A1 = texture(image, t.t1.xw );
    vec4 B1 = texture(image, t.t1.yw );
    vec4 C1 = texture(image, t.t1.zw );
    vec4 A  = texture(image, t.t2.xw );
    vec4 B  = texture(image, t.t2.yw );
    vec4 C  = texture(image, t.t2.zw );
    vec4 D  = texture(image, t.t3.xw );
    vec4 E  = texture(image, t.t3.yw );
    vec4 F  = texture(image, t.t3.zw );
    vec4 G  = texture(image, t.t4.xw );
    vec4 H  = texture(image, t.t4.yw );
    vec4 I  = texture(image, t.t4.zw );
    vec4 G5 = texture(image, t.t5.xw );
    vec4 H5 = texture(image, t.t5.yw );
    vec4 I5 = texture(image, t.t5.zw );
    vec4 A0 = texture(image, t.t6.xy );
    vec4 D0 = texture(image, t.t6.xz );
    vec4 G0 = texture(image, t.t6.xw );
    vec4 C4 = texture(image, t.t7.xy );
    vec4 F4 = texture(image, t.t7.xz );
    vec4 I4 = texture(image, t.t7.xw );

    vec4 b  = vec4(dot(B.xyz ,rgbw), dot(D.xyz ,rgbw), dot(H.xyz ,rgbw), dot(F.xyz ,rgbw));
    vec4 c  = vec4(dot(C.xyz ,rgbw), dot(A.xyz ,rgbw), dot(G.xyz ,rgbw), dot(I.xyz ,rgbw));
    vec4 d  = b.yzwx;
    vec4 e  = vec4(dot(E.xyz,rgbw));
    vec4 f  = b.wxyz;
    vec4 g  = c.zwxy;
    vec4 h  = b.zwxy;
    vec4 i  = c.wxyz;

    vec4 i4, i5, h5, f4;

    float y_weight = XBR_Y_WEIGHT;

    if (small_details < 0.5)
    {
        i4 = vec4(dot(I4.xyz,rgbw), dot(C1.xyz,rgbw), dot(A0.xyz,rgbw), dot(G5.xyz,rgbw));
        i5 = vec4(dot(I5.xyz,rgbw), dot(C4.xyz,rgbw), dot(A1.xyz,rgbw), dot(G0.xyz,rgbw));
        h5 = vec4(dot(H5.xyz,rgbw), dot(F4.xyz,rgbw), dot(B1.xyz,rgbw), dot(D0.xyz,rgbw));
    }
    else
    {
        i4 = mul( mat4x3(I4.xyz, C1.xyz, A0.xyz, G5.xyz), y_weight * Y );
        i5 = mul( mat4x3(I5.xyz, C4.xyz, A1.xyz, G0.xyz), y_weight * Y );
        h5 = mul( mat4x3(H5.xyz, F4.xyz, B1.xyz, D0.xyz), y_weight * Y );
    }

    // These inequations define the line below which interpolation occurs.
    fx   = (Ao*fp.y+Bo*fp.x);
    fx_l = (Ax*fp.y+Bx*fp.x);
    fx_u = (Ay*fp.y+By*fp.x);

    // corner detection
    irlv1 = irlv0 = diff(e,f) * diff(e,h);
    #ifdef CORNER_B
    irlv1      = (irlv0 * ( neq(f,b) * neq(h,d) + eq(e,i) * neq(f,i4) * neq(h,i5) + eq(e,g) + eq(e,c) ) );
    #endif
    #ifdef CORNER_D
    vec4 c1 = i4.yzwx;
    vec4 g0 = i5.wxyz;
    irlv1     = (irlv0  *  ( neq(f,b) * neq(h,d) + eq(e,i) * neq(f,i4) * neq(h,i5) + eq(e,g) + eq(e,c) ) * (diff(f,f4) * diff(f,i) + diff(h,h5) * diff(h,i) + diff(h,g) + diff(f,c) + eq(b,c1) * eq(d,g0)));
    #endif
    #ifdef CORNER_C
    irlv1     = (irlv0  * ( neq(f,b) * neq(f,c) + neq(h,d) * neq(h,g) + eq(e,i) * (neq(f,f4) * neq(f,i4) + neq(h,h5) * neq(h,i5)) + eq(e,g) + eq(e,c)) );
    #endif

    // corner detection in the other direction
    irlv2l = diff(e,g) * diff(d,g);
    irlv2u = diff(e,c) * diff(b,c);

    vec4 fx45i = clamp((fx   + delta   -Co - Ci)/(2.0*delta  ), 0.0, 1.0);
    vec4 fx45  = clamp((fx   + delta   -Co     )/(2.0*delta  ), 0.0, 1.0);
    vec4 fx30  = clamp((fx_l + delta_l -Cx     )/(2.0*delta_l), 0.0, 1.0);
    vec4 fx60  = clamp((fx_u + delta_u -Cy     )/(2.0*delta_u), 0.0, 1.0);

    vec4 wd1, wd2;
    if (small_details < 0.5)
    {
        wd1 = wd( e, c,  g, i, h5, f4, h, f);
        wd2 = wd( h, d, i5, f, i4,  b, e, i);
    }
    else
    {
        wd1 = weighted_distance( e, c, g, i, f4, h5, h, f, b, d, i4, i5);
        wd2 = weighted_distance( h, d, i5, f, b, i4, e, i, g, h5, c, f4);
    }

    edri  = step(wd1, wd2) * irlv0;
    edr   = step(wd1 + vec4(0.1, 0.1, 0.1, 0.1), wd2) * step(vec4(0.5, 0.5, 0.5, 0.5), irlv1);
    edr_l = step( lv2_cf*df(f,g), df(h,c) ) * irlv2l * edr;
    edr_u = step( lv2_cf*df(h,c), df(f,g) ) * irlv2u * edr;

    fx45  = edr   * fx45;
    fx30  = edr_l * fx30;
    fx60  = edr_u * fx60;
    fx45i = edri  * fx45i;

    px = step(df(e,f), df(e,h));

    #ifdef SMOOTH_TIPS
    vec4 maximos = max(max(fx30, fx60), max(fx45, fx45i));
    #endif
    #ifndef SMOOTH_TIPS
    vec4 maximos = max(max(fx30, fx60), fx45);
    #endif

    vec4 res1 = E;
    res1 = mix(res1, mix(H, F, px.x), maximos.x);
    res1 = mix(res1, mix(B, D, px.z), maximos.z);

    vec4 res2 = E;
    res2 = mix(res2, mix(F, B, px.y), maximos.y);
    res2 = mix(res2, mix(D, H, px.w), maximos.w);

    vec4 res = mix(res1, res2, step(c_df(E.xyz, res1.xyz), c_df(E.xyz, res2.xyz)));

    return res;
}


    in XBRTable xbrTable;
#elif UI_SCALING_MODE == UI_SCALING_MODE_HYBRID
/*
 * Written in 2025 by Casey Zwicker <caseypzwicker@gmail.com>
 * To the extent possible under law, the author(s) have dedicated all copyright and related and neighboring rights
 * to this software to the public domain worldwide. This software is distributed without any warranty.
 * You should have received a copy of the CC0 Public Domain Dedication along with this software.
 * If not, see <http://creativecommons.org/publicdomain/zero/1.0/>.
 */

// Anti-aliased UI scaling that respects pixel sharpness
// Approach taken from https://colececil.dev/blog/2017/scaling-pixel-art-without-destroying-it/

vec4 textureHybrid(sampler2D tex, vec2 uv) {
    uv *= vec2(sourceDimensions);
    vec2 texelUv = fract(uv);
    vec2 pixelsPerTexel = vec2(targetDimensions) / vec2(sourceDimensions);
    vec2 interpolationAmount = min(texelUv * pixelsPerTexel, .5) - min((vec2(1.0) - texelUv) * pixelsPerTexel, .5);
    return texture(tex, (floor(uv) + .5 + interpolationAmount) / sourceDimensions);
}

#endif

in vec2 fUv;

out vec4 FragColor;

vec4 alphaBlend(vec4 src, vec4 dst) {
    return vec4(
        src.rgb + dst.rgb * (1.0 - src.a),
        src.a + dst.a * (1.0 - src.a)
    );
}

void main() {
    vec4 c;
    #if UI_SCALING_MODE == UI_SCALING_MODE_MITCHELL || UI_SCALING_MODE == UI_SCALING_MODE_CATROM
        c = textureCubic(uiTexture, fUv);
    #elif UI_SCALING_MODE == UI_SCALING_MODE_XBR
        c = textureXBR(uiTexture, fUv, xbrTable, ceil(1.0 * targetDimensions.x / sourceDimensions.x));
    #elif UI_SCALING_MODE == UI_SCALING_MODE_HYBRID
        c = textureHybrid(uiTexture, fUv);
    #else // NEAREST or LINEAR, which uses GL_TEXTURE_MIN_FILTER/GL_TEXTURE_MAG_FILTER to affect sampling
        c = texture(uiTexture, fUv);
    #endif

    c = alphaBlend(c, alphaOverlay);
    c.rgb = colorBlindnessCompensation(c.rgb);

    #if WINDOWS_HDR_CORRECTION
        c.rgb = windowsHdrCorrection(c.rgb);
    #endif

    FragColor = c;
}
