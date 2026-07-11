/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

// Controlled iOS GLES depth-precision repro: does writing the reverse-Z depth via gl_FragDepth
// (window_z = NDC.z = 100/viewZ directly) resolve the z-fighting that the default (NDC.z+1)/2
// half-range mapping causes at distance, on Apple's GLES-over-Metal? Runs entirely offscreen.
@interface DepthProbe : NSObject
+ (void)runWithLog:(void (^)(NSString *))log;
@end
