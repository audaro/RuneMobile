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
 * Copyright (c) 2021, 117 <https://twitter.com/117scape>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ===========================================================================================================
 * iOS ES-3.0 OVERRIDE (gpu-zone B1, tiled lighting). Verbatim copy of rs117/hd/tiled_lighting_frag.glsl @ RLHD
 * 7dded59 EXCEPT every int-in-float-context is made explicit (blueprint #13) so the per-layer tiled-lighting
 * culling program compiles on GLES 3.00. This whole pass is gated off at Z0, so it was never compiled before.
 * The TILED_IMAGE_STORE branch (image load/store) stays #if'd OUT on iOS (GLES 3.0 has no image load/store; the
 * caps gate picks the !TILED_IMAGE_STORE per-layer path that writes `out uvec4 TiledData`). Changes:
 *   - sceneResolution / tiledLightingResolution are ivec2 (global UBO) -> vec2(...) before float math
 *   - int(ceil(pointLightsCount / 32.0)) -> float(pointLightsCount)
 *   - TiledData = uvec4(0.0) -> uvec4(0u)
 * Logic identical. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */

#define TILED_LIGHTING_LAYER 1
#define TILED_IMAGE_STORE 0

#if TILED_IMAGE_STORE
    #extension GL_EXT_shader_image_load_store : enable
    #extension GL_ARB_shader_image_load_store : enable
    layout(rgba16ui) coherent uniform uimage2DArray tiledLightingImage;
#else
    uniform usampler2DArray tiledLightingArray;
    out uvec4 TiledData;
#endif

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


in vec2 fUv;

#if TILED_IMAGE_STORE
    #define SORTING_BIN_SIZE TILED_LIGHTING_MAX_TILE_LIGHT_COUNT
#else
    #define SORTING_BIN_SIZE 8
#endif

struct SortedLight {
    int lightIdx;
    float score;
};

#define USE_LIGHTS_MASK !TILED_IMAGE_STORE

uint packLightIndices(in SortedLight bin[SORTING_BIN_SIZE], in int binSize, inout int binIdx) {
    if (binIdx >= binSize) return 0u;

    int idx0 = bin[binIdx].lightIdx;
    if (idx0 < 0) return 0u;

    idx0 += 1;
    binIdx += 1;

    if (binIdx < binSize) {
        int idx1 = bin[binIdx].lightIdx;
        if (idx1 >= 0) {
            idx1 += 1;
            // Try dual-pack: idx0 = 7 bits, idx1 = 8 bits
            if (idx0 <= 127 && idx1 <= 255) {
                binIdx += 1;
                return 0x8000u | (uint(idx1 & 0xFF) << 7) | uint(idx0 & 0x7F); // MSB = 1
            } else if (idx1 <= 127 && idx0 <= 255) {
                binIdx += 1;
                return 0x8000u | (uint(idx0 & 0xFF) << 7) | uint(idx1 & 0x7F); // MSB = 1
            }
        }
    }

    // Fallback: single 15-bit index
    return (idx0 <= 32767) ? uint(idx0 & 0x7FFF) : 0u;
}

void main() {
    ivec2 pixelCoord = ivec2(fUv * vec2(tiledLightingResolution));

#if USE_LIGHTS_MASK
    int LightMaskSize = int(ceil(float(pointLightsCount) / 32.0));
    uint LightsMask[32]; // 32 Words = 1024 Lights
    for (int i = 0; i < LightMaskSize; i++)
        LightsMask[i] = 0u;

    #if TILED_LIGHTING_LAYER > 0
        int LayerCount = TILED_LIGHTING_LAYER - 1;
        for (int l = LayerCount; l >= 0; l--) {
            uvec4 layerData = texelFetch(tiledLightingArray, ivec3(pixelCoord, l), 0);
            for (int c = 3; c >= 0; c--) {
                ivec2 unpacked = decodePackedLight(layerData[c]);
                for (int i = 0; i < (isDualPacked(layerData[c]) ? 2 : 1); i++) {
                    int encodedLightIdx = unpacked[i];

                    if (encodedLightIdx < 0) {
                        TiledData = uvec4(0u);
                        return; // No more lights are overlapping with cell since the previous layer didn't encode
                    }

                    uint word = uint(encodedLightIdx) >> 5u;
                    uint mask = 1u << (uint(encodedLightIdx) & 31u);
                    LightsMask[word] |= mask;
                }
            }
        }
    #endif
#endif

    const vec2 tileSize = vec2(TILED_LIGHTING_TILE_SIZE);
    vec2 screenUV = fUv * vec2(sceneResolution);
    vec2 tileOrigin = floor(screenUV / tileSize) * tileSize;

    vec2 tl = tileOrigin + vec2(0.0, tileSize.y); // top-left
    vec2 tr = tileOrigin + tileSize;              // top-right
    vec2 bl = tileOrigin;                         // bottom-left
    vec2 br = tileOrigin + vec2(tileSize.x, 0.0); // bottom-right

    vec2 ndcTL = (tl / vec2(sceneResolution)) * 2.0 - 1.0;
    vec2 ndcTR = (tr / vec2(sceneResolution)) * 2.0 - 1.0;
    vec2 ndcBL = (bl / vec2(sceneResolution)) * 2.0 - 1.0;
    vec2 ndcBR = (br / vec2(sceneResolution)) * 2.0 - 1.0;

    const float eps = 1e-10;

    vec4 pTL = invProjectionMatrix * vec4(ndcTL, eps, 1.0);
    vec4 pTR = invProjectionMatrix * vec4(ndcTR, eps, 1.0);
    vec4 pBL = invProjectionMatrix * vec4(ndcBL, eps, 1.0);
    vec4 pBR = invProjectionMatrix * vec4(ndcBR, eps, 1.0);

    vec3 rTL = normalize((viewMatrix * vec4((pTL.xyz / pTL.w) - cameraPos, 1.0)).xyz);
    vec3 rTR = normalize((viewMatrix * vec4((pTR.xyz / pTR.w) - cameraPos, 1.0)).xyz);
    vec3 rBL = normalize((viewMatrix * vec4((pBL.xyz / pBL.w) - cameraPos, 1.0)).xyz);
    vec3 rBR = normalize((viewMatrix * vec4((pBR.xyz / pBR.w) - cameraPos, 1.0)).xyz);

    vec3 tileCenterVec = normalize(rTL + rTR + rBL + rBR);
    float tileCos = min(min(dot(tileCenterVec, rTL), dot(tileCenterVec, rTR)), min(dot(tileCenterVec, rBL), dot(tileCenterVec, rBR)));
    float tileSin = sqrt(max(0.0, 1.0 - tileCos * tileCos));

    SortedLight sortingBin[SORTING_BIN_SIZE];
    int sortingBinSize = 0;

    for (int lightIdx = 0; lightIdx < pointLightsCount; lightIdx++) {
        vec4 lightData = PointLightPositionsArray[lightIdx];
        vec3 lightViewPos = lightData.xyz;
        float lightRadiusSqr = lightData.w;

        float lightDistSqr = dot(lightViewPos, lightViewPos);

        vec3 lightCenterVec = (lightDistSqr > 0.0) ? lightViewPos / sqrt(lightDistSqr) : vec3(0.0);

        float lightSinSqr = clamp(lightRadiusSqr / max(lightDistSqr, 1e-6), 0.0, 1.0);
        float lightCos = sqrt(0.999 - lightSinSqr);
        float lightTileCos = dot(lightCenterVec, tileCenterVec);

        float sumCos = (lightRadiusSqr > lightDistSqr) ? -1.0 : (tileCos * lightCos - tileSin * sqrt(lightSinSqr));
        if (lightTileCos < sumCos)
            continue;

        #if USE_LIGHTS_MASK
            uint word = uint(lightIdx) >> 5u;
            uint mask = 1u << (uint(lightIdx) & 31u);
            if ((LightsMask[word] & mask) != 0u)
                continue;
        #endif

        const float PROXIMITY_WEIGHT = 0.75;
        float distanceScore = clamp(1.0 - sqrt(lightDistSqr) / (sqrt(lightRadiusSqr) + 1e-6), 0.0, 1.0);
        float combinedScore = (lightTileCos * PROXIMITY_WEIGHT) + distanceScore * (1.0 - PROXIMITY_WEIGHT);

        int idx = 0;
        for (; idx < sortingBinSize; idx++) {
            if (combinedScore > sortingBin[idx].score) {
                for (int j = sortingBinSize; j > idx; j--)
                    sortingBin[j] = sortingBin[j - 1];
                break;
            }
        }

        sortingBin[idx].score = combinedScore;
        sortingBin[idx].lightIdx = lightIdx;
        if (sortingBinSize < SORTING_BIN_SIZE)
            sortingBinSize++;
    }

#if TILED_IMAGE_STORE
    uvec4 outputTileData = uvec4(0);
    for (int layer = 0, binIdx = 0; layer < TILED_LIGHTING_LAYER_COUNT; layer++) {
        for (int c = 0; c < 4; c++)
            outputTileData[c] = packLightIndices(sortingBin, sortingBinSize, binIdx);
        imageStore(tiledLightingImage, ivec3(pixelCoord, layer), outputTileData);
    }
    discard;
#else
    uvec4 outputTileData = uvec4(0);
    for (int c = 0, binIdx = 0; c < 4 && binIdx < sortingBinSize; c++)
        outputTileData[c] = packLightIndices(sortingBin, sortingBinSize, binIdx);
    TiledData = outputTileData;
#endif
}
