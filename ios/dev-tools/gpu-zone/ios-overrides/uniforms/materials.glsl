#pragma once
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
#include MATERIAL_COUNT

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
