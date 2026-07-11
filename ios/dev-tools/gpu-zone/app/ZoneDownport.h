/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

// GLSL (desktop, post-assembly) -> GLSL ES 3.00 downporter for the RLHD zone shaders. A superset of the base-gpu
// B1 downporter (ios/dev-tools/gpu-b1/app/B1Downport.m): the same lexical rules PLUS the two RLHD-specific blockers
// that the base plugin never hit — `#version 420/430` headers and the `isamplerBuffer textureFaces` texture-buffer
// (repacked to a 2D `isampler2D`, gpu-tbo2d). Operates on the ASSEMBLED shader string (all `#include`/`#define`
// already resolved), exactly like glShaderSource sees it on desktop.
@interface ZoneDownport : NSObject
+ (NSString *)downport:(NSString *)src fragment:(BOOL)fragment;
@end
