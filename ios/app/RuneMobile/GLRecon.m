/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met (see the project headers).
 */
#import "GLRecon.h"
#if !defined(RC_BACKEND_ANGLE)   // EAGL recon — compiled out of the MetalANGLE build (OpenGLES.framework not linked).
#import <Metal/Metal.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>

// GLES 3.1 compute enum (absent from the iOS ES3 headers since native EAGL caps at 3.0). Querying it is the
// decisive "does this GL tier have compute?" probe — on ES 3.0 it returns GL_INVALID_ENUM.
#ifndef GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS
#define GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS 0x90EB
#endif
#ifndef GL_MAX_ARRAY_TEXTURE_LAYERS
#define GL_MAX_ARRAY_TEXTURE_LAYERS 0x88FF
#endif

@implementation GLRecon

+ (void)runWithLog:(void (^)(NSString *))log
{
	log(@"[glrecon] ===== B0: GPU / GL tier recon =====");

	// ---- Metal: the real GPU, and the target an ANGLE/gl4es GL->Metal layer would translate onto ----
	id<MTLDevice> mtl = MTLCreateSystemDefaultDevice();
	if (mtl)
	{
		log([NSString stringWithFormat:@"[glrecon] Metal.device = %@", mtl.name]);
		NSString *fam = @"<Apple6 or unknown";
		if (@available(iOS 13.0, *))
		{
			if ([mtl supportsFamily:MTLGPUFamilyApple9]) fam = @"Apple9";
			else if ([mtl supportsFamily:MTLGPUFamilyApple8]) fam = @"Apple8";
			else if ([mtl supportsFamily:MTLGPUFamilyApple7]) fam = @"Apple7";
			else if ([mtl supportsFamily:MTLGPUFamilyApple6]) fam = @"Apple6";
		}
		log([NSString stringWithFormat:@"[glrecon] Metal.gpuFamily = %@  (Metal always has compute + GLES3.1-equiv features)", fam]);
		log([NSString stringWithFormat:@"[glrecon] Metal.maxBufferLength = %lu MB", (unsigned long)(mtl.maxBufferLength / (1024 * 1024))]);
	}
	else
	{
		log(@"[glrecon] Metal.device = NULL (!)");
	}

	// ---- Native OpenGL ES (EAGL): the GL tier iOS exposes WITHOUT a translation layer ----
	NSString *api = @"ES3";
	EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
	if (!ctx) { ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2]; api = @"ES2"; }
	if (!ctx)
	{
		log(@"[glrecon] EAGL context creation FAILED — no native OpenGL ES on this OS");
		log(@"[glrecon] ===== B0 done (native GL unavailable; GPU track would need ANGLE-over-Metal) =====");
		return;
	}
	[EAGLContext setCurrentContext:ctx];

	log([NSString stringWithFormat:@"[glrecon] EAGL.api      = %@", api]);
	log([NSString stringWithFormat:@"[glrecon] GL_VERSION    = %s", (const char *) glGetString(GL_VERSION)]);
	log([NSString stringWithFormat:@"[glrecon] GL_RENDERER   = %s", (const char *) glGetString(GL_RENDERER)]);
	log([NSString stringWithFormat:@"[glrecon] GL_VENDOR     = %s", (const char *) glGetString(GL_VENDOR)]);
	log([NSString stringWithFormat:@"[glrecon] GL_SLVERSION  = %s", (const char *) glGetString(GL_SHADING_LANGUAGE_VERSION)]);

	GLint v = 0;
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &v);          log([NSString stringWithFormat:@"[glrecon] MAX_TEXTURE_SIZE        = %d", v]);
	glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &v);   log([NSString stringWithFormat:@"[glrecon] MAX_TEXTURE_IMAGE_UNITS = %d", v]);
	v = 0; glGetIntegerv(GL_MAX_ARRAY_TEXTURE_LAYERS, &v); log([NSString stringWithFormat:@"[glrecon] MAX_ARRAY_TEXTURE_LAYERS= %d (117HD uses texture arrays)", v]);
	GLint next = 0; glGetIntegerv(GL_NUM_EXTENSIONS, &next); log([NSString stringWithFormat:@"[glrecon] GL_NUM_EXTENSIONS      = %d", next]);

	// Decisive compute probe: valid only on GLES 3.1+. On native ES3.0 this returns GL_INVALID_ENUM (0x0500).
	while (glGetError() != GL_NO_ERROR) { /* drain */ }
	GLint comp = -1;
	glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &comp);
	GLenum cerr = glGetError();
	if (cerr == GL_NO_ERROR)
	{
		log([NSString stringWithFormat:@"[glrecon] COMPUTE = SUPPORTED (MAX_COMPUTE_WORK_GROUP_INVOCATIONS=%d) -> 117HD reachable", comp]);
	}
	else
	{
		log([NSString stringWithFormat:@"[glrecon] COMPUTE = UNSUPPORTED (err=0x%04x) -> 117HD NOT reachable on native GLES (needs ANGLE-over-Metal)", cerr]);
	}

	// Offscreen FBO render + readback (Claim B: render to FBO -> int[] blit). Clear to (51,102,153) and read it
	// back; a match proves windowless GPU rendering + glReadPixels works on this device.
	GLuint tex = 0, fbo = 0;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	GLenum fbs = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	glViewport(0, 0, 64, 64);
	glClearColor(0.2f, 0.4f, 0.6f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glFinish();
	unsigned char px[4] = {0, 0, 0, 0};
	glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
	BOOL ok = (fbs == GL_FRAMEBUFFER_COMPLETE) && px[0] > 40 && px[0] < 62 && px[2] > 140 && px[2] < 165;
	log([NSString stringWithFormat:@"[glrecon] offscreen FBO: status=0x%04x readback=(%d,%d,%d,%d) expect~(51,102,153,255) -> %@",
		fbs, px[0], px[1], px[2], px[3], ok ? @"WORKS (offscreen GPU + readback OK)" : @"FAILED"]);

	glDeleteFramebuffers(1, &fbo);
	glDeleteTextures(1, &tex);
	[EAGLContext setCurrentContext:nil];
	log(@"[glrecon] ===== B0 done =====");
}

@end

#else   // MetalANGLE build: OpenGLES.framework (EAGL) is not linked, so this EAGL recon is compiled out. The stub
        // keeps the GLRecon symbol present. ANGLE GPU caps are proven by the gpu-angle / gpu-present probes instead.
@implementation GLRecon
+ (void)runWithLog:(void (^)(NSString *line))log
{
	if (log) log(@"[glrecon] EAGL recon disabled in the MetalANGLE build (see gpu-angle / gpu-present probes)");
}
@end
#endif
