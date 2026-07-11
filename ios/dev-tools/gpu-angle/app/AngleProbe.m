/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ----------------------------------------------------------------------------------------------------------------
 * MetalANGLE on-device capability probe. ANGLE (libEGL + libGLESv2, the Metal backend) is linked + embedded from the
 * Amethyst IPA. We create an EGL pbuffer context on the ANGLE/Metal display and answer three go/no-go questions:
 *
 *   A) EXT_clip_control — does it WORK?  This is the root-cause fix for the river depth z-fight: native iOS EAGL GLES
 *      has no glClipControl, so reverse-Z depth is squeezed into window_z = (NDC.z+1)/2 (low precision at distance).
 *      Metal's NDC depth is natively [0,1]; if ANGLE honors glClipControl(ZERO_TO_ONE), window_z = NDC.z directly
 *      (desktop-equivalent full precision). We render a flat quad with the plugin's reverse-Z (clip.z=100, viewZ=6000
 *      -> NDC.z=100/6000=0.016667) into a DEPTH_COMPONENT32F texture, sample it into an R32F target, and read the
 *      stored window_z back as a float, with clip_control OFF vs ON. OFF should read ~0.5083; ON should read ~0.0167.
 *
 *   B) Compute shaders + SSBO — do they WORK?  This is 117HD's hard requirement (GL 4.3 / GLES 3.1 compute), which
 *      native iOS GLES 3.0 cannot provide. We compile a trivial compute shader that writes data[i]=i*2 to an SSBO,
 *      dispatch it, and read the buffer back.
 *
 *   C) MSAA — GL_MAX_SAMPLES + a multisampled FBO completeness check (the lever for the distant aliasing).
 * ----------------------------------------------------------------------------------------------------------------
 */
#import "AngleProbe.h"
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
#ifndef GL_NEGATIVE_ONE_TO_ONE_EXT
#define GL_NEGATIVE_ONE_TO_ONE_EXT 0x935E
#endif
#ifndef GL_ZERO_TO_ONE_EXT
#define GL_ZERO_TO_ONE_EXT 0x935F
#endif
extern void glClipControlEXT(GLenum origin, GLenum depth);   // EXT_clip_control (exported by this libGLESv2)

@implementation AngleProbe

static const float CLIP_Z = 100.0f;   // plugin reverse-Z: clip.z = 2*near (Mat4.projection(w,h,50))

// ----- shader helpers -----
static GLuint compile(GLenum type, const char *src, NSString *label, void (^log)(NSString *))
{
	GLuint sh = glCreateShader(type);
	glShaderSource(sh, 1, &src, NULL);
	glCompileShader(sh);
	GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
	if (!ok)
	{
		GLint n = 0; glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &n);
		char *b = n > 1 ? malloc(n) : NULL; if (b) glGetShaderInfoLog(sh, n, NULL, b);
		log([NSString stringWithFormat:@"[ga] COMPILE %@ FAIL: %s", label, b ? b : "(no log)"]);
		free(b); glDeleteShader(sh); return 0;
	}
	return sh;
}
static GLuint link2(GLuint a, GLuint b, NSString *label, void (^log)(NSString *))
{
	GLuint p = glCreateProgram(); glAttachShader(p, a); if (b) glAttachShader(p, b); glLinkProgram(p);
	GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
	if (!ok)
	{
		GLint n = 0; glGetProgramiv(p, GL_INFO_LOG_LENGTH, &n);
		char *bb = n > 1 ? malloc(n) : NULL; if (bb) glGetProgramInfoLog(p, n, NULL, bb);
		log([NSString stringWithFormat:@"[ga] LINK %@ FAIL: %s", label, bb ? bb : "(no log)"]);
		free(bb); glDeleteProgram(p); return 0;
	}
	return p;
}

static BOOL hasExtension(const char *name)
{
	GLint n = 0; glGetIntegerv(GL_NUM_EXTENSIONS, &n);
	for (GLint i = 0; i < n; i++)
	{
		const char *e = (const char *) glGetStringi(GL_EXTENSIONS, i);
		if (e && strcmp(e, name) == 0) return YES;
	}
	return NO;
}

static GLuint sQuadVao = 0, sQuadVbo = 0, sEmptyVao = 0;

// ===== TEST A: clip_control reverse-Z depth precision (stored window_z, OFF vs ON) =====
// returns the stored window_z for viewZ, under the given clip-control depth mode.
static float storedDepth(GLuint progFlat, GLuint progRead, GLuint fboDepth, GLuint depthTex,
	GLuint fboFloat, GLenum clipDepthMode, float viewZ)
{
	glClipControlEXT(GL_LOWER_LEFT_EXT, clipDepthMode);

	// pass 1: render flat full-screen quad at the reverse-Z, writing depth.
	glBindFramebuffer(GL_FRAMEBUFFER, fboDepth);
	glViewport(0, 0, 16, 16);
	glEnable(GL_DEPTH_TEST); glDepthFunc(GL_ALWAYS); glDepthMask(GL_TRUE);
	glClearDepthf(0.f); glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glUseProgram(progFlat);
	glUniform1f(glGetUniformLocation(progFlat, "uViewZ"), viewZ);
	glUniform1f(glGetUniformLocation(progFlat, "uClipZ"), CLIP_Z);
	glBindVertexArray(sQuadVao);
	glDrawArrays(GL_TRIANGLES, 0, 6);

	// pass 2: sample the depth texture, output as float color, read it back.
	glBindFramebuffer(GL_FRAMEBUFFER, fboFloat);
	glViewport(0, 0, 16, 16);
	glDisable(GL_DEPTH_TEST);
	glClear(GL_COLOR_BUFFER_BIT);
	glUseProgram(progRead);
	glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, depthTex);
	glUniform1i(glGetUniformLocation(progRead, "uDepth"), 0);
	glBindVertexArray(sEmptyVao);
	glDrawArrays(GL_TRIANGLES, 0, 3);

	float px[4] = {0, 0, 0, 0};
	glReadPixels(8, 8, 1, 1, GL_RGBA, GL_FLOAT, px);
	return px[0];
}

static BOOL testClipControl(void (^log)(NSString *))
{
	log(@"[ga] ----- TEST A: EXT_clip_control reverse-Z depth precision -----");
	BOOL ext = hasExtension("GL_EXT_clip_control");
	log([NSString stringWithFormat:@"[ga]   GL_EXT_clip_control advertised = %@", ext ? @"YES" : @"NO"]);
	BOOL floatColor = hasExtension("GL_EXT_color_buffer_float") || hasExtension("GL_EXT_color_buffer_half_float");
	if (!floatColor)
	{
		log(@"[ga]   no float color buffer -> cannot read stored depth precisely; CLIP_CONTROL_WORKS = UNKNOWN");
		return NO;
	}

	const char *vsFlat =
		"#version 300 es\nprecision highp float;\n"
		"layout(location=0) in vec2 aNdc;\nuniform float uViewZ;\nuniform float uClipZ;\n"
		"void main(){ gl_Position = vec4(aNdc*uViewZ, uClipZ, uViewZ); }\n";
	const char *fsWhite =
		"#version 300 es\nprecision highp float;\nout vec4 o;\nvoid main(){ o = vec4(1.0); }\n";
	const char *vsFs =
		"#version 300 es\nprecision highp float;\nout vec2 vUv;\n"
		"const vec2 P[3]=vec2[3](vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));\n"
		"void main(){ vec2 p=P[gl_VertexID]; gl_Position=vec4(p,0.,1.); vUv=p*0.5+0.5; }\n";
	const char *fsRead =
		"#version 300 es\nprecision highp float;\nuniform highp sampler2D uDepth;\nin vec2 vUv;\nout vec4 o;\n"
		"void main(){ o = vec4(texture(uDepth, vUv).r, 0.0, 0.0, 1.0); }\n";

	GLuint progFlat = link2(compile(GL_VERTEX_SHADER, vsFlat, @"flat.vs", log),
		compile(GL_FRAGMENT_SHADER, fsWhite, @"white.fs", log), @"FLAT", log);
	GLuint progRead = link2(compile(GL_VERTEX_SHADER, vsFs, @"fs.vs", log),
		compile(GL_FRAGMENT_SHADER, fsRead, @"read.fs", log), @"READ", log);
	if (!progFlat || !progRead) { log(@"[ga]   programs failed -> CLIP_CONTROL_WORKS = NO"); return NO; }

	// fbo with depth32F texture + rgba8 color
	GLuint depthTex = 0, colorTex = 0, fboDepth = 0;
	glGenTextures(1, &depthTex); glBindTexture(GL_TEXTURE_2D, depthTex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT32F, 16, 16, 0, GL_DEPTH_COMPONENT, GL_FLOAT, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
	glGenTextures(1, &colorTex); glBindTexture(GL_TEXTURE_2D, colorTex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenFramebuffers(1, &fboDepth); glBindFramebuffer(GL_FRAMEBUFFER, fboDepth);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTex, 0);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depthTex, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
	{ log(@"[ga]   depth fbo incomplete -> CLIP_CONTROL_WORKS = NO"); return NO; }

	// fbo with rgba32f color (for float readback of the sampled depth)
	GLuint floatTex = 0, fboFloat = 0;
	glGenTextures(1, &floatTex); glBindTexture(GL_TEXTURE_2D, floatTex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, 16, 16, 0, GL_RGBA, GL_FLOAT, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenFramebuffers(1, &fboFloat); glBindFramebuffer(GL_FRAMEBUFFER, fboFloat);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, floatTex, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
	{ log(@"[ga]   float fbo incomplete -> CLIP_CONTROL_WORKS = NO"); return NO; }

	const float viewZ = 6000.f;   // far plane (~max OSRS draw distance)
	float off = storedDepth(progFlat, progRead, fboDepth, depthTex, fboFloat, GL_NEGATIVE_ONE_TO_ONE_EXT, viewZ);
	float on  = storedDepth(progFlat, progRead, fboDepth, depthTex, fboFloat, GL_ZERO_TO_ONE_EXT, viewZ);
	const float expectOff = (CLIP_Z / viewZ + 1.f) * 0.5f;   // ~0.50833
	const float expectOn  = (CLIP_Z / viewZ);                // ~0.01667
	log([NSString stringWithFormat:@"[ga]   stored window_z @ viewZ=%.0f: clip OFF=%.6f (expect ~%.6f)  clip ON=%.6f (expect ~%.6f)",
		viewZ, off, expectOff, on, expectOn]);

	// WORKS iff ON moves the far-plane depth down to ~NDC.z (full precision) and OFF stays in the squeezed ~0.5 band.
	BOOL works = ext && (off > 0.45f) && (on < 0.05f);
	GLenum err = glGetError();
	log([NSString stringWithFormat:@"[ga]   CLIP_CONTROL_WORKS = %@ (glerr=0x%04x)", works ? @"YES" : @"NO", err]);
	return works;
}

// ===== TEST B: compute shader + SSBO =====
static BOOL testCompute(BOOL es31, void (^log)(NSString *))
{
	log(@"[ga] ----- TEST B: compute shader + SSBO (117HD's hard requirement) -----");
	if (!es31) { log(@"[ga]   context is not ES 3.1 -> no compute; COMPUTE_WORKS = NO"); return NO; }

	const char *cs =
		"#version 310 es\n"
		"layout(local_size_x = 64) in;\n"
		"layout(std430, binding = 0) buffer Buf { uint data[]; };\n"
		"void main(){ uint i = gl_GlobalInvocationID.x; data[i] = i * 2u; }\n";
	GLuint sh = compile(GL_COMPUTE_SHADER, cs, @"compute", log);
	if (!sh) { log(@"[ga]   compute shader did not compile -> COMPUTE_WORKS = NO"); return NO; }
	GLuint prog = link2(sh, 0, @"COMPUTE", log);
	if (!prog) { log(@"[ga]   compute program did not link -> COMPUTE_WORKS = NO"); return NO; }

	const int N = 64;
	GLuint ssbo = 0; glGenBuffers(1, &ssbo);
	glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
	glBufferData(GL_SHADER_STORAGE_BUFFER, N * sizeof(GLuint), NULL, GL_DYNAMIC_DRAW);
	glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);

	glUseProgram(prog);
	glDispatchCompute(1, 1, 1);
	glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT | GL_BUFFER_UPDATE_BARRIER_BIT);

	GLuint *data = (GLuint *) glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, N * sizeof(GLuint), GL_MAP_READ_BIT);
	BOOL correct = (data != NULL);
	int bad = -1;
	if (data)
	{
		for (int i = 0; i < N; i++) { if (data[i] != (GLuint)(i * 2)) { correct = NO; bad = i; break; } }
		glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
	}
	GLenum err = glGetError();
	if (correct)
	{
		log([NSString stringWithFormat:@"[ga]   dispatched 64 invocations; SSBO readback correct (data[i]==i*2); glerr=0x%04x", err]);
	}
	else
	{
		log([NSString stringWithFormat:@"[ga]   SSBO readback WRONG (firstBad=%d, mapped=%@); glerr=0x%04x", bad, data ? @"yes" : @"no", err]);
	}
	log([NSString stringWithFormat:@"[ga]   COMPUTE_WORKS = %@", correct ? @"YES" : @"NO"]);
	return correct;
}

// ===== TEST C: MSAA =====
static void testMsaa(void (^log)(NSString *))
{
	log(@"[ga] ----- TEST C: MSAA -----");
	GLint maxSamples = 0; glGetIntegerv(GL_MAX_SAMPLES, &maxSamples);
	GLuint rb = 0, fbo = 0;
	glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb);
	GLint s = maxSamples >= 4 ? 4 : maxSamples;
	glRenderbufferStorageMultisample(GL_RENDERBUFFER, s, GL_RGBA8, 64, 64);
	glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
	BOOL complete = (glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
	log([NSString stringWithFormat:@"[ga]   GL_MAX_SAMPLES=%d  %dx-MSAA fbo complete=%@", maxSamples, s, complete ? @"YES" : @"NO"]);
}

+ (void)runWithLog:(void (^)(NSString *))log
{
	log(@"[ga] ===== gpu-angle: MetalANGLE capability probe (EGL pbuffer on ANGLE/Metal) =====");

	// ---- EGL: bring up an ANGLE/Metal display + ES 3.1 (fallback 3.0) pbuffer context ----
	EGLDisplay dpy = EGL_NO_DISPLAY;
	PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC) eglGetProcAddress("eglGetPlatformDisplayEXT");
	if (getPlatformDisplay)
	{
		EGLint da[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
		dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, (void *) EGL_DEFAULT_DISPLAY, da);
		log(@"[ga] requested ANGLE platform = Metal (eglGetPlatformDisplayEXT)");
	}
	if (dpy == EGL_NO_DISPLAY) { dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY); log(@"[ga] fell back to eglGetDisplay(DEFAULT)"); }
	if (dpy == EGL_NO_DISPLAY) { log(@"[ga] EGL_NO_DISPLAY -> NO-GO"); return; }

	EGLint vmaj = 0, vmin = 0;
	if (!eglInitialize(dpy, &vmaj, &vmin)) { log([NSString stringWithFormat:@"[ga] eglInitialize FAILED (0x%04x) -> NO-GO", eglGetError()]); return; }
	log([NSString stringWithFormat:@"[ga] EGL %d.%d  vendor=%s", vmaj, vmin, eglQueryString(dpy, EGL_VENDOR)]);
	log([NSString stringWithFormat:@"[ga] EGL_VERSION = %s", eglQueryString(dpy, EGL_VERSION)]);
	eglBindAPI(EGL_OPENGL_ES_API);

	EGLint cfgAttr[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_NONE };
	EGLConfig cfg; EGLint nc = 0;
	if (!eglChooseConfig(dpy, cfgAttr, &cfg, 1, &nc) || nc < 1) { log(@"[ga] eglChooseConfig FAILED -> NO-GO"); return; }
	EGLint pbAttr[] = { EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE };
	EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pbAttr);
	if (surf == EGL_NO_SURFACE) { log(@"[ga] eglCreatePbufferSurface FAILED -> NO-GO"); return; }

	BOOL es31 = YES;
	EGLint ctx31[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 1, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx31);
	if (ctx == EGL_NO_CONTEXT)
	{
		es31 = NO;
		EGLint ctx30[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE };
		ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx30);
		log(@"[ga] ES 3.1 context unavailable; fell back to ES 3.0");
	}
	if (ctx == EGL_NO_CONTEXT) { log(@"[ga] eglCreateContext FAILED -> NO-GO"); return; }
	if (!eglMakeCurrent(dpy, surf, surf, ctx)) { log(@"[ga] eglMakeCurrent FAILED -> NO-GO"); return; }

	// ---- who are we? ----
	log([NSString stringWithFormat:@"[ga] GL_RENDERER = %s", (const char *) glGetString(GL_RENDERER)]);
	log([NSString stringWithFormat:@"[ga] GL_VERSION = %s", (const char *) glGetString(GL_VERSION)]);
	log([NSString stringWithFormat:@"[ga] GL_SLVERSION = %s", (const char *) glGetString(GL_SHADING_LANGUAGE_VERSION)]);
	log([NSString stringWithFormat:@"[ga] GL_VENDOR = %s", (const char *) glGetString(GL_VENDOR)]);
	GLint glMaj = 0, glMin = 0; glGetIntegerv(GL_MAJOR_VERSION, &glMaj); glGetIntegerv(GL_MINOR_VERSION, &glMin);
	es31 = es31 && (glMaj > 3 || (glMaj == 3 && glMin >= 1));
	log([NSString stringWithFormat:@"[ga] ES_VERSION = %d.%d  (es31=%@)", glMaj, glMin, es31 ? @"YES" : @"NO"]);

	glGenVertexArrays(1, &sEmptyVao);
	glGenVertexArrays(1, &sQuadVao); glBindVertexArray(sQuadVao);
	glGenBuffers(1, &sQuadVbo); glBindBuffer(GL_ARRAY_BUFFER, sQuadVbo);
	const float quad[] = { -1,-1, 1,-1, 1,1, -1,-1, 1,1, -1,1 };
	glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), (void *) 0);

	BOOL clip = testClipControl(log);
	BOOL compute = testCompute(es31, log);
	testMsaa(log);

	const char *rnd = (const char *) glGetString(GL_RENDERER);
	BOOL isMetal = rnd && (strstr(rnd, "Metal") || strstr(rnd, "ANGLE"));
	log([NSString stringWithFormat:@"[ga] ANGLE_METAL = %@", isMetal ? @"YES" : @"NO"]);
	log([NSString stringWithFormat:@"[ga] VERDICT angle_metal=%@ es31=%@ clip_control=%@ compute=%@",
		isMetal ? @"YES" : @"NO", es31 ? @"YES" : @"NO", clip ? @"YES" : @"NO", compute ? @"YES" : @"NO"]);
	log(@"[ga] ===== gpu-angle done =====");

	eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(dpy, ctx);
	eglDestroySurface(dpy, surf);
	eglTerminate(dpy);
}

@end
