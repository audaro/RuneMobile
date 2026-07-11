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
#pragma once

#include <utils/constants.glsl>

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
        round((hsl[0] - .0078125f) * 64.0),
        round((hsl[1] - .0625f) * 8.0),
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
    float H = HSL[0] / 64.f + .0078125f;
    float S = HSL[1] / 8.f + .0625f;
    float L = HSL[2] / 128.f;
    return vec3(H, S, L);
}

int srgbToPackedHsl(vec3 srgb) {
    return packHsl(srgbToHsl(srgb));
}

vec3 packedHslToSrgb(int hsl) {
    return hslToSrgb(convertHsl(unpackRawHsl(hsl)));
}
