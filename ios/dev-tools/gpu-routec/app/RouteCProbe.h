/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>

// GPU Route C step 2 — exercises the native bridge core (RouteCBridge) on a real GLES 3.0 driver and settles the
// one open render decision from the GL-surface census: does the plugin's reverse-Z depth ordering survive on GLES
// 3.0 WITHOUT glClipControl (which iOS lacks)? Also exercises the glMultiDrawArrays->loop and glClearDepth->f shims
// and the EAGL depth FBO. Logs structured [rc2] lines a bash verdict script md5-gates.
@interface RouteCProbe : NSObject
+ (void)runWithLog:(void (^)(NSString *))log;
@end
