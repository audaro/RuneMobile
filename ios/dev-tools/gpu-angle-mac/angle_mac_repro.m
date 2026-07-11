/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ----------------------------------------------------------------------------------------------------------------
 * OFF-DEVICE ANGLE-Metal reproduction harness (macOS). The on-device iOS render shows giant white degenerate-triangle
 * "wedges" the EAGL build never had. The leading hypothesis is that ANGLE-on-Metal clips the base gpu plugin's unusual
 * reverse-Z projection (constant clip.z = 2*near, clip.w = viewZ) differently at the near/camera plane than desktop
 * GL/EAGL, so triangles crossing the camera plane go degenerate. macOS ANGLE (from Google Chrome) shares ANGLE's
 * Metal backend, so it should reproduce a clip/projection bug here — with a fast Mac iteration loop, no device.
 *
 * This probe: brings up ANGLE/Metal EGL + an ES3 offscreen FBO, forces clip_control(ZERO_TO_ONE) like the bridge,
 * and renders triangles with the plugin's reverse-Z gl_Position = vec4(ndc.xy*w, CLIP_Z, w):
 *   GREEN  — a normal triangle entirely in front of the camera (all w > 0): the control.
 *   RED    — a triangle with one vertex BEHIND the camera (w < 0): the prime wedge candidate (w-clipping).
 *   BLUE   — a triangle that straddles the near/camera plane (w from large -> ~0): near-plane clip candidate.
 * Dumps the readback to a PNG (via CoreGraphics). If RED/BLUE smear into huge wedges across the frame, the wedge is
 * reproduced off-device and the fix can be iterated here. CAVEAT: macOS ANGLE-Metal != iOS ANGLE-Metal bit-for-bit
 * (different GPU + ANGLE build) — final confirmation still needs one device run (same caveat as the gpu-b1 proxy).
 * ----------------------------------------------------------------------------------------------------------------
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <EGL/egl.h>
#import <EGL/eglext.h>
#import <GLES3/gl32.h>

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

static const int W = 512, H = 512;
static const float CLIP_Z = 100.0f;   // the plugin's reverse-Z constant clip.z = 2*near

static void logln(NSString *s) { fprintf(stderr, "%s\n", s.UTF8String); }

static GLuint compile(GLenum t, const char *src)
{
	GLuint sh = glCreateShader(t); glShaderSource(sh, 1, &src, NULL); glCompileShader(sh);
	GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
	if (!ok) { char b[2048]; glGetShaderInfoLog(sh, sizeof(b), NULL, b); logln([NSString stringWithFormat:@"COMPILE FAIL: %s", b]); }
	return sh;
}

static void writePNG(const uint8_t *rgba, int w, int h, NSString *path)
{
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate((void *)rgba, w, h, 8, w * 4, cs,
		kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
	CGImageRef img = CGBitmapContextCreateImage(ctx);
	CFURLRef url = CFURLCreateWithFileSystemPath(NULL, (CFStringRef)path, kCFURLPOSIXPathStyle, false);
	CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
	CGImageDestinationAddImage(dst, img, NULL);
	CGImageDestinationFinalize(dst);
	CFRelease(dst); CFRelease(url); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
}

// Render the test scene under the given clip-control mode; read back + return mean RGB + write PNG.
static void renderPass(GLuint prog, GLuint vao, GLenum clipMode, NSString *pngPath)
{
	glClipControlEXT(GL_LOWER_LEFT_EXT, clipMode);
	glViewport(0, 0, W, H);
	glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GEQUAL); glDepthMask(GL_TRUE);
	glClearDepthf(0.0f); glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glUseProgram(prog);
	glUniform1f(glGetUniformLocation(prog, "uClipZ"), CLIP_Z);
	glBindVertexArray(vao);
	glDrawArrays(GL_TRIANGLES, 0, 9);   // 3 triangles

	uint8_t *px = malloc((size_t)W * H * 4);
	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	// stats: fraction of red/blue/white pixels (wedge detection)
	long red = 0, blue = 0, white = 0, lit = 0;
	for (int i = 0; i < W * H; i++) {
		uint8_t r = px[i*4], g = px[i*4+1], b = px[i*4+2];
		if (r + g + b > 30) lit++;
		if (r > 150 && g < 90 && b < 90) red++;
		if (b > 150 && r < 90 && g < 90) blue++;
		if (r > 200 && g > 200 && b > 200) white++;
	}
	// flip vertically for PNG (GL bottom-left -> image top-left)
	uint8_t *flip = malloc((size_t)W * H * 4);
	for (int y = 0; y < H; y++) memcpy(flip + (size_t)y*W*4, px + (size_t)(H-1-y)*W*4, (size_t)W*4);
	writePNG(flip, W, H, pngPath);
	free(px); free(flip);
	logln([NSString stringWithFormat:@"  clip=%@ -> lit=%.1f%% red=%.1f%% blue=%.1f%% white=%.1f%%  glErr=0x%x  png=%@",
		clipMode == GL_ZERO_TO_ONE_EXT ? @"ZERO_TO_ONE" : @"NEG_ONE_TO_ONE",
		100.0*lit/(W*H), 100.0*red/(W*H), 100.0*blue/(W*H), 100.0*white/(W*H), glGetError(), pngPath.lastPathComponent]);
}

int main(int argc, char **argv)
{
	@autoreleasepool
	{
		EGLDisplay dpy = EGL_NO_DISPLAY;
		PFNEGLGETPLATFORMDISPLAYEXTPROC getPD = (PFNEGLGETPLATFORMDISPLAYEXTPROC) eglGetProcAddress("eglGetPlatformDisplayEXT");
		if (getPD) {
			EGLint da[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
			dpy = getPD(EGL_PLATFORM_ANGLE_ANGLE, (void *) EGL_DEFAULT_DISPLAY, da);
		}
		if (dpy == EGL_NO_DISPLAY) dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
		if (dpy == EGL_NO_DISPLAY) { logln(@"EGL_NO_DISPLAY -> NO-GO"); return 1; }
		EGLint vmaj = 0, vmin = 0;
		if (!eglInitialize(dpy, &vmaj, &vmin)) { logln([NSString stringWithFormat:@"eglInitialize FAILED 0x%x", eglGetError()]); return 1; }
		logln([NSString stringWithFormat:@"EGL %d.%d vendor=%s", vmaj, vmin, eglQueryString(dpy, EGL_VENDOR)]);
		eglBindAPI(EGL_OPENGL_ES_API);
		EGLint cfgAttr[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
			EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8, EGL_DEPTH_SIZE,24, EGL_NONE };
		EGLConfig cfg; EGLint nc = 0;
		if (!eglChooseConfig(dpy, cfgAttr, &cfg, 1, &nc) || nc < 1) { logln(@"eglChooseConfig FAILED"); return 1; }
		EGLint pb[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
		EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pb);
		EGLint ctxAttr[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE };
		EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttr);
		if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, surf, surf, ctx)) { logln(@"context/makeCurrent FAILED"); return 1; }
		logln([NSString stringWithFormat:@"GL_RENDERER = %s", (const char *) glGetString(GL_RENDERER)]);
		logln([NSString stringWithFormat:@"GL_VERSION  = %s", (const char *) glGetString(GL_VERSION)]);

		// offscreen FBO (RGBA8 + depth24)
		GLuint colorTex = 0, depthRb = 0, fbo = 0;
		glGenTextures(1, &colorTex); glBindTexture(GL_TEXTURE_2D, colorTex);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
		glGenRenderbuffers(1, &depthRb); glBindRenderbuffer(GL_RENDERBUFFER, depthRb);
		glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, W, H);
		glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTex, 0);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRb);
		if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { logln(@"FBO incomplete"); return 1; }

		const char *vs =
			"#version 300 es\nprecision highp float;\n"
			"layout(location=0) in vec2 aNdc;\nlayout(location=1) in float aViewZ;\nlayout(location=2) in vec3 aCol;\n"
			"uniform float uClipZ;\nout vec3 vCol;\n"
			"void main(){ gl_Position = vec4(aNdc * aViewZ, uClipZ, aViewZ); vCol = aCol; }\n";   // plugin reverse-Z
		const char *fs =
			"#version 300 es\nprecision highp float;\nin vec3 vCol;\nout vec4 o;\nvoid main(){ o = vec4(vCol, 1.0); }\n";
		GLuint prog = glCreateProgram();
		glAttachShader(prog, compile(GL_VERTEX_SHADER, vs)); glAttachShader(prog, compile(GL_FRAGMENT_SHADER, fs));
		glLinkProgram(prog);
		GLint ok = 0; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
		if (!ok) { char b[2048]; glGetProgramInfoLog(prog, sizeof(b), NULL, b); logln([NSString stringWithFormat:@"LINK FAIL: %s", b]); return 1; }

		// 3 triangles. Per-vertex: ndc.x, ndc.y, viewZ (=clip.w), r,g,b.
		// T1 GREEN: all in front (w>0) — control, should render a normal triangle.
		// T2 RED: one vertex BEHIND the camera (w<0) — w-clip candidate (the wedge suspect).
		// T3 BLUE: straddles the near/camera plane (w from big -> ~0) — near-plane clip candidate.
		const float verts[] = {
			// aNdc.x aNdc.y  viewZ      r g b
			-0.8f, -0.8f,   500.0f,   0,1,0,
			-0.2f, -0.8f,   500.0f,   0,1,0,
			-0.5f,  0.6f,   500.0f,   0,1,0,

			 0.1f, -0.8f,   500.0f,   1,0,0,
			 0.8f, -0.8f,   500.0f,   1,0,0,
			 0.5f,  0.6f,  -200.0f,   1,0,0,   // <-- behind camera (w < 0)

			-0.4f, -0.2f,   500.0f,   0,0,1,
			 0.4f, -0.2f,   500.0f,   0,0,1,
			 0.0f,  0.9f,     0.5f,   0,0,1,   // <-- straddles near plane (w -> ~0)
		};
		GLuint vao = 0, vbo = 0;
		glGenVertexArrays(1, &vao); glBindVertexArray(vao);
		glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
		glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 6*sizeof(float), (void*)0);
		glEnableVertexAttribArray(1); glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 6*sizeof(float), (void*)(2*sizeof(float)));
		glEnableVertexAttribArray(2); glVertexAttribPointer(2, 3, GL_FLOAT, GL_FALSE, 6*sizeof(float), (void*)(3*sizeof(float)));

		NSString *dir = [[NSFileManager defaultManager] currentDirectoryPath];
		logln(@"--- ANGLE reverse-Z near/behind-plane wedge repro ---");
		renderPass(prog, vao, GL_ZERO_TO_ONE_EXT,      [dir stringByAppendingPathComponent:@"repro-clip-on.png"]);
		renderPass(prog, vao, GL_NEGATIVE_ONE_TO_ONE_EXT, [dir stringByAppendingPathComponent:@"repro-clip-off.png"]);
		logln(@"done. Inspect repro-clip-on.png / repro-clip-off.png. A huge red/blue smear = the wedge reproduced.");

		eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
		eglDestroyContext(dpy, ctx); eglDestroySurface(dpy, surf); eglTerminate(dpy);
		return 0;
	}
}
