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
 *   - `float opacity = 1;`                -> `1.0`
 *   - `fUvw.z != -1` / `uvw.z != -1` / `uvw.w != -1`   (float != int)   -> `-1.0`
 *   - `clamp(uvw.x, 0, .984375)`          (int 0)       -> `0.0`
 *   - the SHADOW_TRANSPARENCY depth packing: `1 - opacity` -> `1.0 - opacity`, the int<<|int packed value is
 *     wrapped in `float(...)` before the `/ float(SHADOW_COMBINED_MAX)` divide, and SHADOW_ALPHA_MAX /
 *     SHADOW_DEPTH_MAX (int #defines) are float()-cast at their float uses.
 * Logic identical. RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
#version 330

#include <uniforms/global.glsl>

#include <utils/constants.glsl>
#include <utils/color_utils.glsl>

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
