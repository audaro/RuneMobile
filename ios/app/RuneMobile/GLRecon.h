/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met (see the project headers).
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// W3 GPU track — B0 reconnaissance (hard go/no-go gate). Pure-native (no JVM/JIT): queries the device's GPU/GL
/// capabilities so we know whether RuneLite's GPU plugins are even reachable on iOS before investing in the port.
/// Probes: Metal device + GPU family (the real GPU + the ANGLE-over-Metal target), native OpenGL ES (EAGL) tier
/// (version/renderer/GLSL), compute availability, key limits, and an offscreen FBO render+readback (the int[] blit
/// path). Logs each finding via the sink (also to Documents/hello-shell.log for retrieval). Diagnostic-only.
@interface GLRecon : NSObject
+ (void)runWithLog:(void (^)(NSString *line))log;
@end

NS_ASSUME_NONNULL_END
