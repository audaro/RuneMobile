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


// #pragma once: already included

/*
 * Copyright (c) 2023, Adam <Adam@sigterm.info>
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
// #pragma once: already included

// #pragma once: already included


// #pragma once: already included


void computeUvs(const int materialData, const int worldViewIndex, const vec3 pos[3], inout vec3 uvw[3]) {
    if ((materialData >> MATERIAL_FLAG_WORLD_UVS & 1) == 1) {
        // Treat the input uvw as a normal vector for a plane that goes through origo,
        // and find the distance from the point to the plane
        float scale = 1. / length(uvw[0]);

        vec3 N = uvw[0] * scale;
        vec3 C1 = cross(vec3(0, 0, 1), N);
        vec3 C2 = cross(vec3(0, 1, 0), N);
        vec3 T = normalize(length(C1) > length(C2) ? C1 : C2);
        vec3 B = cross(N, T);
        mat3 TBN = mat3(T, B, N);

        for (int i = 0; i < 3; i++)
            uvw[i].xy = (TBN * pos[i]).xy / 128. * scale;
    } else if ((materialData >> MATERIAL_FLAG_VANILLA_UVS & 1) == 1) {
        #if ZONE_RENDERER
            // Vanilla UVs are relative to vertex positions
            for (int i = 0; i < 3; i++)
                uvw[i] = pos[i] + mat3(getWorldViewProjection(worldViewIndex)) * uvw[i];
        #endif

        vec3 v1 = uvw[0];
        vec3 v2 = uvw[1] - v1;
        vec3 v3 = uvw[2] - v1;

        vec3 uvNormal = cross(v2, v3);
        vec3 perpv2 = cross(v2, uvNormal);
        vec3 perpv3 = cross(v3, uvNormal);
        float du = 1.0 / dot(perpv3, v2);
        float dv = 1.0 / dot(perpv2, v3);

        for (int i = 0; i < 3; i++) {
            vec3 p = pos[i];
            #ifdef USE_VANILLA_UV_PROJECTION
                // Project vertex positions onto a plane going through the texture triangle
                vec3 vertexToCamera = cameraPos - p;
                p += vertexToCamera * dot(uvw[i] - p, uvNormal) / dot(vertexToCamera, uvNormal);
            #endif

            // uvw[i].x = (v4's distance along perpv3) / (v2's distance along perpv3)
            // uvw[i].y = (v4's distance along perpv2) / (v3's distance along perpv2)
            vec3 v = p - v1;
            uvw[i].xy = vec2(
                dot(perpv3, v) * du,
                dot(perpv2, v) * dv
            );
        }
    }
}

vec2 computeVertexUvs(int materialData, const vec3 pos, const vec3 uvw) {
    if ((materialData >> MATERIAL_FLAG_WORLD_UVS & 1) == 1) {
        // Treat the input uvw as a normal vector for a plane that goes through origo,
        // and find the distance from the point to the plane
        float scale = 1. / length(uvw);

        vec3 N = uvw * scale;
        vec3 C1 = cross(vec3(0, 0, 1), N);
        vec3 C2 = cross(vec3(0, 1, 0), N);
        vec3 T = normalize(length(C1) > length(C2) ? C1 : C2);
        vec3 B = cross(N, T);
        mat3 TBN = mat3(T, B, N);

        return (TBN * pos).xy / 128. * scale;
    }

    return uvw.xy;
}


layout (location = 0) in vec3 vPosition;

#if ZONE_RENDERER
    layout (location = 1) in vec4 vUv;
    layout (location = 2) in vec4 vNormal;
    layout (location = 3) in int vTextureFaceIdx;
    layout (location = 6) in int vWorldViewId;
    layout (location = 7) in ivec2 vSceneBase;

    uniform highp isampler2D textureFaces;
#else
    layout (location = 1) in vec3 vUv;
    layout (location = 2) in vec3 vNormal;
    layout (location = 3) in int vAlphaBiasHsl;
    layout (location = 4) in int vMaterialData;
    layout (location = 5) in int vTerrainData;
#endif

#if ZONE_RENDERER
    flat out int fWorldViewId;
    flat out ivec3 fAlphaBiasHsl;
    flat out ivec3 fMaterialData;
    flat out ivec3 fTerrainData;

    #if FLAT_SHADING
        flat out vec3 fFlatNormal;
    #endif

    out FragmentData {
        vec3 position;
        vec2 uv;
        vec3 normal;
        vec3 texBlend;
    } OUT;

    void main() {
  int tfW = textureSize(textureFaces, 0).x;
        int vertex = gl_VertexID % 3;
        bool isProvoking = vertex == 2;
        int materialData = 0;
        int alphaBiasHsl = 0;

        if (isProvoking) {
            // Only the Provoking vertex needs to fetch the face data
            fAlphaBiasHsl = texelFetch(textureFaces, ivec2((vTextureFaceIdx)%tfW,(vTextureFaceIdx)/tfW), 0).xyz;
            fMaterialData = texelFetch(textureFaces, ivec2((vTextureFaceIdx + 1)%tfW,(vTextureFaceIdx + 1)/tfW), 0).xyz;
            fTerrainData = texelFetch(textureFaces, ivec2((vTextureFaceIdx + 2)%tfW,(vTextureFaceIdx + 2)/tfW), 0).xyz;
            fWorldViewId = vWorldViewId;
            alphaBiasHsl = fAlphaBiasHsl[vertex];
            materialData = fMaterialData[vertex];
        } else {
            // All outputs must be written to for macOS compatibility
            fAlphaBiasHsl = ivec3(0);
            fMaterialData = ivec3(0);
            fTerrainData  = ivec3(0);
            fWorldViewId  = 0;
            alphaBiasHsl = texelFetch(textureFaces, ivec2((vTextureFaceIdx)%tfW,(vTextureFaceIdx)/tfW), 0)[vertex];
            materialData = texelFetch(textureFaces, ivec2((vTextureFaceIdx + 1)%tfW,(vTextureFaceIdx + 1)/tfW), 0)[vertex];
        }

        vec3 sceneOffset = vec3(vSceneBase.x, 0, vSceneBase.y);
        vec3 worldNormal = vNormal.xyz;
        vec3 worldPosition = sceneOffset + vPosition;
        if (vWorldViewId != -1) {
            mat4x3 worldViewProjection = mat4x3(getWorldViewProjection(vWorldViewId));
            worldPosition = worldViewProjection * vec4(worldPosition, 1.0);
            worldNormal = mat3(worldViewProjection) * worldNormal;
        }

        OUT.position = worldPosition;
        OUT.uv = computeVertexUvs(materialData, worldPosition, vUv.xyz);
        OUT.normal = worldNormal;
        OUT.texBlend = vec3(0);
        OUT.texBlend[vertex] = 1.0;

        #if FLAT_SHADING
            fFlatNormal = worldNormal;
        #endif

        vec4 clipPosition = projectionMatrix * vec4(worldPosition, 1.0);
        int depthBias = (alphaBiasHsl >> 16) & 0xff;
        if (projectionMatrix[2][3] != 0.0) // Disable depth bias for orthographic projection
            clipPosition.z += float(depthBias) / 128.0;

        gl_Position = clipPosition;
    }
#else
    out vec3 gPosition;
    out vec3 gUv;
    out vec3 gNormal;
    out int gAlphaBiasHsl;
    out int gMaterialData;
    out int gTerrainData;

    void main() {
        gPosition = vPosition;
        gUv = vUv.xyz;
        gNormal = vNormal.xyz;
        gAlphaBiasHsl = vAlphaBiasHsl;
        gMaterialData = vMaterialData;
        gTerrainData = vTerrainData;
    }
#endif
