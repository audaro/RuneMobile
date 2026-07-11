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
#include <uniforms/global.glsl>

#include <utils/constants.glsl>
#include <utils/misc.glsl>

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
#define sampleShadowMap(fragPos, distortion, lightDotNormals) 0
#endif
