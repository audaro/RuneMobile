/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

// 117HD-on-iOS blocker #1, de-risked off-device, RLHD-FAITHFUL. RLHD's Zone path feeds per-face data to its VERTEX
// shaders via a GL_TEXTURE_BUFFER: `uniform isamplerBuffer textureFaces` (GL_RGB32I = 3xint32/texel), where each face
// is 3 CONSECUTIVE texels fetched as texelFetch(textureFaces, vTextureFaceIdx{,+1,+2}).xyz / [vertex]. iOS EAGL
// GLES 3.0 (and ANGLE-on-Metal ES 3.0) have NO texture-buffer object (it is ES 3.2 core). The repack: upload the same
// RGB32I bytes as a 2D integer texture and rewrite the fetch to texelFetch(tex2d, ivec2(idx % W, idx / W), 0). This
// probe proves the repack is byte-exact on iOS GLES 3.0 using RLHD's REAL format + fetch idiom: RGB32I is sampleable
// (so zero host transform), the idx/idx+1/idx+2 fetches with .xyz AND dynamic [vertex] indexing are exact across row-
// straddling spans and at texel counts a 1D texture could not hold, in BOTH the fragment AND the vertex stage. Integer
// 2D textures + texelFetch + vertex texture fetch are ES 3.0 CORE, so a Simulator GREEN is high-confidence for the
// device GPU. Runs fully offscreen.
@interface Tbo2dProbe : NSObject
+ (void)runWithLog:(void (^)(NSString *))log;
@end
