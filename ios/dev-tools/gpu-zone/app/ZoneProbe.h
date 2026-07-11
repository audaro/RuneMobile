/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

// Z0 conformance probe: for every bundled `*.assembled.glsl` (RLHD zone shader, already #include/#define-resolved),
// downport to ES 3.00 (ZoneDownport) and glCompileShader it on a real EAGL ES3 context. Fail-closed: any shader that
// fails to compile is logged with its infolog + numbered source. Writes a pullable verdict log.
@interface ZoneProbe : NSObject
+ (void)runWithLog:(void (^)(NSString *))log;
@end
