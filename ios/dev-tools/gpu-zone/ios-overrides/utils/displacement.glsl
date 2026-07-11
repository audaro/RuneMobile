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
#include PARALLAX_OCCLUSION_MAPPING

#include <uniforms/global.glsl>
#include <uniforms/materials.glsl>

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
