/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>   // Foundation ONLY — importing UIKit/QuartzCore here would pull Apple's OpenGLES
                                     // module into a TU that also includes ANGLE's <GLES3/gl32.h> (type redefinition
                                     // conflict). The UIKit side (main.m) owns the CAMetalLayer + CADisplayLink and
                                     // hands this probe the layer as a void* (an EGLNativeWindowType). Mirrors gpu-angle.

// Phase A1 present-path de-risk: prove an EGL-on-ANGLE WINDOW surface (the ANGLE analogue of EAGL's
// renderbufferStorage:fromDrawable: direct present) actually scans out to the screen on this device, before we swap
// the Route C renderer backend. Pure GLES via ANGLE — no JVM, no UIKit/QuartzCore in this TU.
@interface PresentProbe : NSObject
// Bring up ANGLE/Metal EGL + an ES3 WINDOW surface on `metalLayer` (a CAMetalLayer*, passed as void*), run the
// one-shot self-checks, and log via `log`. Returns NO on a NO-GO (EGL/window bring-up failed).
- (BOOL)startWithLayer:(void *)metalLayer log:(void (^)(NSString *))log;
// Render one frame (colour bars + sweeping stripe) into the window default framebuffer and eglSwapBuffers.
// Driven from the UIKit side's CADisplayLink.
- (void)renderFrame;
@end
