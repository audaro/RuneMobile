#version 300 es
precision highp float;
precision highp int;
precision highp sampler2D;
precision highp sampler2DArray;
precision highp isampler2D;
precision highp isampler2DArray;
precision highp usampler2D;
precision highp usampler2DArray;
/*
 * Copyright (c) 2018, Adam <Adam@sigterm.info>
 * Copyright (c) 2023, Hooder <ahooder@protonmail.com>
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
#define SHADER_TYPE 35633
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


// #pragma once: already included


layout (location = 0) in vec3 vPosition;

#if ZONE_RENDERER
    layout (location = 1) in vec4 vUv;
    layout (location = 3) in int vTextureFaceIdx;
    layout (location = 6) in int vWorldViewId;
    layout (location = 7) in ivec2 vSceneBase;

    uniform highp isampler2D textureFaces;

    #if SHADOW_MODE == SHADOW_MODE_DETAILED
        out vec4 fUvw;
        flat out int fMaterialData;
    #endif

    #if SHADOW_TRANSPARENCY
        out float fOpacity;
    #endif

    void main() {
  int tfW = textureSize(textureFaces, 0).x;
        int vertex = gl_VertexID % 3;
        int alphaBiasHsl = texelFetch(textureFaces, ivec2((vTextureFaceIdx)%tfW,(vTextureFaceIdx)/tfW), 0)[vertex];
        int materialData = texelFetch(textureFaces, ivec2((vTextureFaceIdx + 1)%tfW,(vTextureFaceIdx + 1)/tfW), 0)[vertex];
        int terrainData = texelFetch(textureFaces, ivec2((vTextureFaceIdx + 2)%tfW,(vTextureFaceIdx + 2)/tfW), 0)[vertex];

        int waterTypeIndex = terrainData >> 3 & 0xFF;
        float opacity = 1.0 - float(alphaBiasHsl >> 24 & 0xFF) / float(0xFF);

        float opacityThreshold = float(materialData >> MATERIAL_SHADOW_OPACITY_THRESHOLD_SHIFT & 0x3F) / float(0x3F);
        if (opacityThreshold == 0.0)
            opacityThreshold = SHADOW_DEFAULT_OPACITY_THRESHOLD;

        bool isTransparent = opacity <= opacityThreshold;
        bool isGroundPlaneTile = (terrainData & 0xF) == 1; // plane == 0 && isTerrain
        bool isWaterSurfaceOrUnderwaterTile = waterTypeIndex > 0;

        bool isShadowDisabled =
            isGroundPlaneTile ||
            isWaterSurfaceOrUnderwaterTile ||
            isTransparent;

        if (!isShadowDisabled && vWorldViewId > 0) {
            ivec4 tint = getWorldViewTint(vWorldViewId);
            isShadowDisabled = tint.w > 0;
        }

        Material material = getMaterial(materialData >> MATERIAL_INDEX_SHIFT & MATERIAL_INDEX_MASK);
        #if SHADOW_MODE == SHADOW_MODE_DETAILED
            if (!isShadowDisabled) {
                fUvw = vec4(vUv.xy, material.colorMap, material.shadowAlphaMap);
                // Scroll UVs
                fUvw.xy += material.scrollDuration * elapsedTime;
                // Scale from the center
                fUvw.xy = .5 + (fUvw.xy - .5) * material.textureScale.xy;
            } else {
                // All outputs must be written for Mac compatibility, even if unused
                fUvw = vec4(0);
            }
            fMaterialData = materialData;
        #endif

        int shouldCastShadow = isShadowDisabled ? 0 : 1;

        vec3 sceneOffset = vec3(vSceneBase.x, 0, vSceneBase.y);
        vec3 worldPosition = sceneOffset + vPosition;
        if (vWorldViewId != -1) {
            mat4x3 worldViewProjection = mat4x3(getWorldViewProjection(vWorldViewId));
            worldPosition = worldViewProjection * vec4(worldPosition, 1.0);;
        }

        #if SHADOW_TRANSPARENCY
            fOpacity = opacity;
        #endif

        vec4 clipPosition = lightProjectionMatrix * vec4(worldPosition, shouldCastShadow);
        if (getMaterialHasTransparency(material)) // bias face if it has transparency to avoid self-shadowing
            clipPosition.z += SHADOW_TRANSPARENCY_BIAS;
        gl_Position = clipPosition;
    }
#else
    layout (location = 1) in vec3 vUv;
    layout (location = 3) in int vAlphaBiasHsl;
    layout (location = 4) in int vMaterialData;
    layout (location = 5) in int vTerrainData;

    #if SHADOW_MODE == SHADOW_MODE_DETAILED
        // Pass to geometry shader
        flat out vec3 gPosition;
        flat out vec3 gUv;
        flat out int gMaterialData;
        flat out int gCastShadow;
        flat out int gWorldViewId;
        #if SHADOW_TRANSPARENCY
            flat out float gOpacity;
        #endif
    #else
        #if SHADOW_TRANSPARENCY
            // Pass to fragment shader
            out float fOpacity;
        #endif
    #endif

    void main() {
        int waterTypeIndex = vTerrainData >> 3 & 0xFF;
        float opacity = 1 - (vAlphaBiasHsl >> 24 & 0xFF) / float(0xFF);

        float opacityThreshold = float(vMaterialData >> MATERIAL_SHADOW_OPACITY_THRESHOLD_SHIFT & 0x3F) / float(0x3F);
        if (opacityThreshold == 0.0)
            opacityThreshold = SHADOW_DEFAULT_OPACITY_THRESHOLD;

        bool isTransparent = opacity <= opacityThreshold;
        bool isGroundPlaneTile = (vTerrainData & 0xF) == 1; // plane == 0 && isTerrain
        bool isWaterSurfaceOrUnderwaterTile = waterTypeIndex > 0;

        bool isShadowDisabled =
            isGroundPlaneTile ||
            isWaterSurfaceOrUnderwaterTile ||
            isTransparent;

        int shouldCastShadow = isShadowDisabled ? 0 : 1;

        #if SHADOW_MODE == SHADOW_MODE_DETAILED
            gPosition = vPosition;
            gUv = vUv.xyz;
            gMaterialData = vMaterialData;
            gCastShadow = shouldCastShadow;
            #if SHADOW_TRANSPARENCY
                gOpacity = opacity;
            #endif
        #else
            gl_Position = lightProjectionMatrix * vec4(vPosition, shouldCastShadow);
            #if SHADOW_TRANSPARENCY
                fOpacity = opacity;
            #endif
        #endif
    }
#endif
