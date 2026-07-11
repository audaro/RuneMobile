/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

// GPU B1 — the real gate. Compiles RuneLite's ACTUAL base-`gpu`-plugin shaders (assembled by the real Template,
// then downported to GLSL ES 3.00) against the native EAGL GLES 3.0 context, links + validates both programs
// (scene vert/frag + UI vertui/fragui), and renders each into an offscreen FBO -> glReadPixels to prove they
// produce non-blank, shader-shaped output. Logs structured [b1] lines a bash verdict script md5-gates.
@interface B1Probe : NSObject
+ (void)runWithLog:(void (^)(NSString *))log;
@end
