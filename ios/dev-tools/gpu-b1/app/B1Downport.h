/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

/*
 * Downports a desktop GLSL 330 source string (as emitted by RuneLite's Template for the base `gpu` plugin) to
 * GLSL ES 3.00 — the only tier iOS native EAGL exposes (B0: GL_SLVERSION = "OpenGL ES GLSL ES 3.00"). This is the
 * exact transform an in-process iOS shim would apply at glShaderSource() time. Purely mechanical:
 *   1. `#version 330[ core]` -> `#version 300 es`, then inject precision qualifiers.
 *   2. drop `noperspective` (desktop-only interpolation qualifier; absent from ES 3.00 — `centroid`/`flat` stay).
 *   3. strip `f`/`F` float-literal suffixes (`1.0f`, `255.f`, `0.f`) — illegal in ES 3.00 (hex `0xff` is safe:
 *      the suffix strip requires a decimal point).
 */
@interface B1Downport : NSObject
+ (NSString *)downport:(NSString *)src fragment:(BOOL)fragment;
@end
