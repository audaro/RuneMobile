/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

// Controlled iOS GLES depth A/B of THREE reverse-Z depth strategies for the Route C river z-fight, all on the
// SAME geometry + metrics so they can be compared directly:
//   BASELINE  — fixed-function window_z = (NDC.z+1)/2 (what native EAGL does without glClipControl): the z-fight.
//   FRAGDEPTH — gl_FragDepth = clip.z/clip.w = NDC.z (full precision, but DISABLES Apple TBDR early-Z/HSR).
//   CLIPREMAP — vertex remap gl_Position.z = 2*clip.z - clip.w (keeps early-Z; precision is the open question,
//               because it routes the far plane back through the (z+1)/2 windowing's catastrophic cancellation).
// Answers, off-device on the Simulator's software GLES: does CLIPREMAP recover FRAGDEPTH's precision (making it the
// preferred early-Z-friendly fix) or only BASELINE's (making it useless for the z-fight)?  Runs fully offscreen.
@interface ClipRemapProbe : NSObject
+ (void)runWithLog:(void (^)(NSString *))log;
@end
