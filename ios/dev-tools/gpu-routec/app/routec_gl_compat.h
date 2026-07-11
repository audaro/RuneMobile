/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ----------------------------------------------------------------------------------------------------------------
 * Route C backend compat shim — selects the GL backend at BUILD time via RC_BACKEND_ANGLE:
 *
 *   RC_BACKEND_ANGLE defined  -> MetalANGLE: EGL window/pbuffer surfaces + ANGLE's <GLES3/gl32.h> (libEGL/libGLESv2,
 *                                vendored from the Amethyst IPA). Gives a REAL EXT_clip_control (root-cause depth
 *                                z-fight fix) + GL_MAX_SAMPLES=8 MSAA. This is Phase A1's backend.
 *   RC_BACKEND_ANGLE undefined-> native EAGL ES3 (Apple's OpenGLES.framework) — the prior backend, kept for the A/B
 *                                baseline and the blueprint §12 "perf bad -> keep EAGL" fallback.
 *
 * Why a hard build-time switch (not a runtime toggle): Apple's OpenGLES.framework and ANGLE's libGLESv2 BOTH export
 * glXxx, so they can't be linked together (two-level-namespace binds each glXxx to ONE provider). The active backend
 * is whatever project.yml links + this macro selects. To A/B: flip the macro + the framework deps + xcodegen.
 *
 * Header hygiene: in the ANGLE build, the GLES3 headers type-conflict with Apple's OpenGLES module, so any TU that
 * includes this MUST NOT also import UIKit / <QuartzCore/QuartzCore.h> / CoreVideo (they pull the OpenGLES module).
 * That is why RouteCBridge.h is GL-header-free and the on-screen layer is passed around as an opaque void*.
 * ----------------------------------------------------------------------------------------------------------------
 */
#ifndef ROUTEC_GL_COMPAT_H
#define ROUTEC_GL_COMPAT_H

#include <stdint.h>
#include <time.h>

#if defined(RC_BACKEND_ANGLE)

#import <EGL/egl.h>
#import <EGL/eglext.h>
#import <GLES3/gl32.h>

// EGL ANGLE platform selectors (define if the vendored eglext.h predates them) — mirror AngleProbe.m.
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_OPENGL_ES3_BIT
#define EGL_OPENGL_ES3_BIT 0x00000040
#endif
#ifndef EGL_CONTEXT_MAJOR_VERSION
#define EGL_CONTEXT_MAJOR_VERSION 0x3098
#endif
#ifndef EGL_CONTEXT_MINOR_VERSION
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
#endif

// EXT_clip_control enums + entry point (exported by ANGLE's libGLESv2). This is what turns the no-op clip-control
// shim into a real glClipControlEXT(LOWER_LEFT, ZERO_TO_ONE) -> reverse-Z at full window-depth precision.
#ifndef GL_LOWER_LEFT_EXT
#define GL_LOWER_LEFT_EXT 0x8CA1
#endif
#ifndef GL_ZERO_TO_ONE_EXT
#define GL_ZERO_TO_ONE_EXT 0x935F
#endif
#ifndef GL_NEGATIVE_ONE_TO_ONE_EXT
#define GL_NEGATIVE_ONE_TO_ONE_EXT 0x935E
#endif
extern void glClipControlEXT(GLenum origin, GLenum depth);

// EXT_texture_filter_anisotropic enum (in gl2ext.h, not the core gl32.h the vendored ANGLE headers ship) —
// used by the water-shimmer anisotropy fix. The extension is advertised + honoured by ANGLE on Metal.
#ifndef GL_TEXTURE_MAX_ANISOTROPY_EXT
#define GL_TEXTURE_MAX_ANISOTROPY_EXT 0x84FE
#endif
#ifndef GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT
#define GL_MAX_TEXTURE_MAX_ANISOTROPY_EXT 0x84FF
#endif

// The base gpu plugin uploads the interface texture as GL_BGRA + GL_UNSIGNED_INT_8_8_8_8_REV (desktop/EAGL formats).
// Neither is ES-3.0 core, so ANGLE rejects them (GL_INVALID_OPERATION) and the UI texture upload silently fails ->
// the UI quad paints opaque over the scene (black screen). The texture shims translate these to GL_RGBA +
// GL_UNSIGNED_BYTE for ANGLE; these are the incoming LWJGL constant VALUES the plugin passes.
#ifndef GL_BGRA
#define GL_BGRA 0x80E1
#endif
#ifndef GL_UNSIGNED_INT_8_8_8_8_REV
#define GL_UNSIGNED_INT_8_8_8_8_REV 0x8367
#endif

#else  /* EAGL */

#define GLES_SILENCE_DEPRECATION 1   // OpenGLES is deprecated-since-iOS-12 but works on iOS 26 (no Metal-GL bridge)
#import <OpenGLES/EAGL.h>            // EAGLContext (the EAGL backend's context)
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <QuartzCore/QuartzCore.h>    // CAEAGLLayer (EAGL direct present). Safe here — no GLES3 headers in this branch.

#endif

// Monotonic seconds, framework-free (CACurrentMediaTime lives in QuartzCore, which we cannot import alongside the
// ANGLE GLES3 headers). Same clock domain as CACurrentMediaTime (mach monotonic) for the perf counters.
static inline double rc_now_seconds(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double) ts.tv_sec + (double) ts.tv_nsec * 1e-9;
}

#endif /* ROUTEC_GL_COMPAT_H */
