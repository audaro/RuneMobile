/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

// On-device evaluation of MetalANGLE (ANGLE-over-Metal, extracted from the Amethyst IPA) as a possible GPU backend.
// Answers, in one run: is it really ANGLE/Metal + which GLES version; does EXT_clip_control WORK (the root-cause
// depth-precision fix the native-EAGL path can't do); do compute shaders + SSBOs WORK (the 117HD enabler); MSAA.
@interface AngleProbe : NSObject
+ (void)runWithLog:(void (^)(NSString *))log;
@end
