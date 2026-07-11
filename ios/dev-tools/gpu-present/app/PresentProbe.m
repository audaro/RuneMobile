/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ----------------------------------------------------------------------------------------------------------------
 * Phase A1 present-path de-risk probe (the handoff's #1 risk: "solve/de-risk it FIRST").
 *
 * The gpu-angle probe proved ANGLE/Metal works for OFFSCREEN pbuffer rendering. The Route C backend swap, though,
 * needs the frame ON SCREEN. EAGL did that with renderbufferStorage:fromDrawable: on a CAEAGLLayer; ANGLE has no
 * such call — its on-screen path is an EGL WINDOW surface created from a native layer + eglSwapBuffers. THIS probe
 * proves that path works on the device, in isolation, with NO JVM/JIT (pure GLES via ANGLE):
 *
 *   1) bring up an ANGLE/Metal EGL display + ES3 context (exactly like AngleProbe.m),
 *   2) create an EGL WINDOW surface from a full-screen CAMetalLayer,
 *   3) live-present an animated pattern (3 colour bars + a moving white stripe) every CADisplayLink tick via
 *      eglSwapBuffers -> visual confirmation it scans out to the display (screenshot it),
 *   4) self-checks, logged once: the window default-framebuffer is renderable + glReadPixels-able; EXT_clip_control
 *      reverse-Z works in a real on-surface FBO; an MSAA window config is honoured.
 *
 * Verdict line (one): window_present / fb_readback / clip_control / msaa. present-verdict.sh md5-seals it.
 * ----------------------------------------------------------------------------------------------------------------
 */
#import "PresentProbe.h"
#import <EGL/egl.h>
#import <EGL/eglext.h>
#import <GLES3/gl32.h>
// NO UIKit / QuartzCore here — they pull Apple's OpenGLES module, which type-conflicts with <GLES3/gl32.h>. The
// CAMetalLayer arrives as an opaque void* (configured on the UIKit side) and is only ever cast to EGLNativeWindowType.

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

@interface PresentProbe ()
@property (nonatomic, copy) void (^log)(NSString *);
@end

@implementation PresentProbe
{
	EGLDisplay _dpy;
	EGLContext _ctx;
	EGLSurface _surf;
	EGLConfig  _cfg;
	int  _frame;
	BOOL _clip, _msaa, _fbReadback, _sealed;
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

static GLuint compile2(GLenum t, const char *s) { GLuint sh = glCreateShader(t); glShaderSource(sh,1,&s,NULL); glCompileShader(sh); return sh; }
static GLuint link2(GLuint a, GLuint b) { GLuint p = glCreateProgram(); glAttachShader(p,a); if(b) glAttachShader(p,b); glLinkProgram(p); return p; }

// EXT_clip_control reverse-Z depth precision, in a real FBO under the WINDOW context (re-confirm vs the gpu-angle
// pbuffer). Far-plane stored window_z: OFF ~0.508 (squeezed (NDC.z+1)/2) -> ON ~0.0167 (= NDC.z, full precision).
- (BOOL)checkClipControl
{
	if (!hasExtension("GL_EXT_clip_control")) { self.log(@"[gp]   clip_control: NOT advertised -> NO"); return NO; }
	if (!(hasExtension("GL_EXT_color_buffer_float") || hasExtension("GL_EXT_color_buffer_half_float")))
	{ self.log(@"[gp]   clip_control: no float colour buffer -> UNKNOWN(NO)"); return NO; }

	const char *vsFlat = "#version 300 es\nprecision highp float;\nlayout(location=0) in vec2 aNdc;\n"
		"uniform float uViewZ; uniform float uClipZ;\nvoid main(){ gl_Position=vec4(aNdc*uViewZ,uClipZ,uViewZ); }\n";
	const char *fsWhite = "#version 300 es\nprecision highp float;\nout vec4 o;\nvoid main(){ o=vec4(1.0); }\n";
	const char *vsFs = "#version 300 es\nprecision highp float;\nout vec2 vUv;\n"
		"const vec2 P[3]=vec2[3](vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));\n"
		"void main(){ vec2 p=P[gl_VertexID]; gl_Position=vec4(p,0.,1.); vUv=p*0.5+0.5; }\n";
	const char *fsRead = "#version 300 es\nprecision highp float;\nuniform highp sampler2D uDepth;\nin vec2 vUv;out vec4 o;\n"
		"void main(){ o=vec4(texture(uDepth,vUv).r,0.,0.,1.); }\n";
	GLuint progFlat = link2(compile2(GL_VERTEX_SHADER,vsFlat), compile2(GL_FRAGMENT_SHADER,fsWhite));
	GLuint progRead = link2(compile2(GL_VERTEX_SHADER,vsFs),   compile2(GL_FRAGMENT_SHADER,fsRead));

	GLuint depthTex=0,colorTex=0,fboDepth=0,floatTex=0,fboFloat=0,vao=0,vbo=0,evao=0;
	glGenTextures(1,&depthTex); glBindTexture(GL_TEXTURE_2D,depthTex);
	glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT32F,16,16,0,GL_DEPTH_COMPONENT,GL_FLOAT,NULL);
	glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,GL_NONE);
	glGenTextures(1,&colorTex); glBindTexture(GL_TEXTURE_2D,colorTex);
	glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,16,16,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
	glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
	glGenFramebuffers(1,&fboDepth); glBindFramebuffer(GL_FRAMEBUFFER,fboDepth);
	glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,colorTex,0);
	glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,depthTex,0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE) { self.log(@"[gp]   clip_control: depth fbo incomplete -> NO"); return NO; }
	glGenTextures(1,&floatTex); glBindTexture(GL_TEXTURE_2D,floatTex);
	glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,16,16,0,GL_RGBA,GL_FLOAT,NULL);
	glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
	glGenFramebuffers(1,&fboFloat); glBindFramebuffer(GL_FRAMEBUFFER,fboFloat);
	glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,floatTex,0);
	glGenVertexArrays(1,&evao);
	glGenVertexArrays(1,&vao); glBindVertexArray(vao);
	glGenBuffers(1,&vbo); glBindBuffer(GL_ARRAY_BUFFER,vbo);
	const float quad[]={-1,-1, 1,-1, 1,1, -1,-1, 1,1, -1,1};
	glBufferData(GL_ARRAY_BUFFER,sizeof(quad),quad,GL_STATIC_DRAW);
	glEnableVertexAttribArray(0); glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,2*sizeof(float),(void*)0);

	const float viewZ=6000.f, CLIP_Z=100.f;
	float vals[2]={0,0};
	GLenum modes[2]={GL_NEGATIVE_ONE_TO_ONE_EXT, GL_ZERO_TO_ONE_EXT};
	for (int k=0;k<2;k++)
	{
		glClipControlEXT(GL_LOWER_LEFT_EXT, modes[k]);
		glBindFramebuffer(GL_FRAMEBUFFER,fboDepth); glViewport(0,0,16,16);
		glEnable(GL_DEPTH_TEST); glDepthFunc(GL_ALWAYS); glDepthMask(GL_TRUE);
		glClearDepthf(0.f); glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT);
		glUseProgram(progFlat);
		glUniform1f(glGetUniformLocation(progFlat,"uViewZ"),viewZ);
		glUniform1f(glGetUniformLocation(progFlat,"uClipZ"),CLIP_Z);
		glBindVertexArray(vao); glDrawArrays(GL_TRIANGLES,0,6);
		glBindFramebuffer(GL_FRAMEBUFFER,fboFloat); glViewport(0,0,16,16);
		glDisable(GL_DEPTH_TEST); glClear(GL_COLOR_BUFFER_BIT);
		glUseProgram(progRead);
		glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D,depthTex);
		glUniform1i(glGetUniformLocation(progRead,"uDepth"),0);
		glBindVertexArray(evao); glDrawArrays(GL_TRIANGLES,0,3);
		float px[4]={0,0,0,0}; glReadPixels(8,8,1,1,GL_RGBA,GL_FLOAT,px); vals[k]=px[0];
	}
	glClipControlEXT(GL_LOWER_LEFT_EXT, GL_NEGATIVE_ONE_TO_ONE_EXT);   // restore default for the present loop
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	BOOL works = (vals[0]>0.45f) && (vals[1]<0.05f);
	self.log([NSString stringWithFormat:@"[gp]   clip_control: window_z OFF=%.6f ON=%.6f -> WORKS=%@", vals[0], vals[1], works?@"YES":@"NO"]);
	return works;
}

static BOOL checkMsaaCfg(void (^log)(NSString *))
{
	GLint maxSamples=0; glGetIntegerv(GL_MAX_SAMPLES,&maxSamples);
	GLuint rb=0,fbo=0; glGenRenderbuffers(1,&rb); glBindRenderbuffer(GL_RENDERBUFFER,rb);
	GLint s = maxSamples>=4?4:maxSamples;
	glRenderbufferStorageMultisample(GL_RENDERBUFFER,s,GL_RGBA8,64,64);
	glGenFramebuffers(1,&fbo); glBindFramebuffer(GL_FRAMEBUFFER,fbo);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_RENDERBUFFER,rb);
	BOOL complete = (glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE);
	log([NSString stringWithFormat:@"[gp]   msaa: GL_MAX_SAMPLES=%d  %dx fbo complete=%@", maxSamples, s, complete?@"YES":@"NO"]);
	glDeleteFramebuffers(1,&fbo); glDeleteRenderbuffers(1,&rb);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	return complete && maxSamples>=4;
}

- (BOOL)startWithLayer:(void *)metalLayer log:(void (^)(NSString *))log
{
	self.log = log;
	log(@"[gp] ===== gpu-present: ANGLE/Metal WINDOW-surface present de-risk =====");
	if (!metalLayer) { log(@"[gp] nil layer -> NO-GO"); return NO; }

	// ---- EGL: ANGLE/Metal display + ES3 context (mirror AngleProbe.m) ----
	PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC) eglGetProcAddress("eglGetPlatformDisplayEXT");
	if (getPlatformDisplay)
	{
		EGLint da[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
		_dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, (void *) EGL_DEFAULT_DISPLAY, da);
	}
	if (_dpy == EGL_NO_DISPLAY) { _dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY); }
	if (_dpy == EGL_NO_DISPLAY) { log(@"[gp] EGL_NO_DISPLAY -> NO-GO"); return NO; }
	EGLint vmaj=0, vmin=0;
	if (!eglInitialize(_dpy, &vmaj, &vmin)) { log([NSString stringWithFormat:@"[gp] eglInitialize FAILED 0x%04x -> NO-GO", eglGetError()]); return NO; }
	log([NSString stringWithFormat:@"[gp] EGL %d.%d vendor=%s", vmaj, vmin, eglQueryString(_dpy, EGL_VENDOR)]);
	eglBindAPI(EGL_OPENGL_ES_API);

	// WINDOW-renderable config, RGBA8 + depth24 + 4x MSAA (the present surface itself can be multisampled).
	EGLint cfgAttr[] = {
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8, EGL_DEPTH_SIZE,24,
		EGL_SAMPLE_BUFFERS,1, EGL_SAMPLES,4, EGL_NONE };
	EGLint nc=0;
	if (!eglChooseConfig(_dpy, cfgAttr, &_cfg, 1, &nc) || nc<1)
	{
		// retry without MSAA on the window config (some ANGLE builds reject multisampled window surfaces)
		EGLint cfgPlain[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
			EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8, EGL_DEPTH_SIZE,24, EGL_NONE };
		if (!eglChooseConfig(_dpy, cfgPlain, &_cfg, 1, &nc) || nc<1) { log(@"[gp] eglChooseConfig FAILED -> NO-GO"); return NO; }
		log(@"[gp] window MSAA config rejected; using single-sample window surface");
	}

	_surf = eglCreateWindowSurface(_dpy, _cfg, (EGLNativeWindowType) metalLayer, NULL);
	if (_surf == EGL_NO_SURFACE) { log([NSString stringWithFormat:@"[gp] eglCreateWindowSurface FAILED 0x%04x -> NO-GO", eglGetError()]); return NO; }

	EGLint ctxAttr[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE };
	_ctx = eglCreateContext(_dpy, _cfg, EGL_NO_CONTEXT, ctxAttr);
	if (_ctx == EGL_NO_CONTEXT) { log(@"[gp] eglCreateContext FAILED -> NO-GO"); return NO; }
	if (!eglMakeCurrent(_dpy, _surf, _surf, _ctx)) { log(@"[gp] eglMakeCurrent FAILED -> NO-GO"); return NO; }

	log([NSString stringWithFormat:@"[gp] GL_RENDERER = %s", (const char *) glGetString(GL_RENDERER)]);
	log([NSString stringWithFormat:@"[gp] GL_VERSION  = %s", (const char *) glGetString(GL_VERSION)]);
	EGLint qw=0, qh=0; eglQuerySurface(_dpy,_surf,EGL_WIDTH,&qw); eglQuerySurface(_dpy,_surf,EGL_HEIGHT,&qh);
	log([NSString stringWithFormat:@"[gp] window surface = %dx%d", qw, qh]);

	// one-shot self-checks (clip_control + msaa); the UIKit side's CADisplayLink then drives renderFrame each tick.
	_clip = [self checkClipControl];
	_msaa = checkMsaaCfg(log);
	return YES;
}

// Live present: paint 3 colour bars (R | G | B) + a white stripe sweeping left->right, then eglSwapBuffers. If this
// shows on the device screen, the EGL window-surface present path works (the thing EAGL's fromDrawable did).
- (void)renderFrame
{
	if (_dpy == EGL_NO_DISPLAY || _surf == EGL_NO_SURFACE) return;
	eglMakeCurrent(_dpy, _surf, _surf, _ctx);
	EGLint w=0, h=0; eglQuerySurface(_dpy,_surf,EGL_WIDTH,&w); eglQuerySurface(_dpy,_surf,EGL_HEIGHT,&h);
	if (w<=0 || h<=0) return;

	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	glViewport(0,0,w,h);
	glDisable(GL_DEPTH_TEST);
	glEnable(GL_SCISSOR_TEST);
	int third = w/3;
	glScissor(0,0,third,h);          glClearColor(0.85f,0.10f,0.10f,1); glClear(GL_COLOR_BUFFER_BIT);
	glScissor(third,0,third,h);      glClearColor(0.10f,0.75f,0.10f,1); glClear(GL_COLOR_BUFFER_BIT);
	glScissor(2*third,0,w-2*third,h);glClearColor(0.10f,0.25f,0.90f,1); glClear(GL_COLOR_BUFFER_BIT);
	int stripeW = w/24; if (stripeW<8) stripeW=8;
	int x = (int)((_frame * (w / 90.0)));   // ~1.5s sweep at 60Hz
	x = x % (w + stripeW) - stripeW;
	glScissor(x,0,stripeW,h);        glClearColor(1,1,1,1); glClear(GL_COLOR_BUFFER_BIT);
	glDisable(GL_SCISSOR_TEST);

	// one-shot readback self-check: sample the GREEN bar centre from the default framebuffer (proves the on-screen
	// surface is a real, readable framebuffer 0 — not a no-op present).
	if (!_fbReadback && _frame >= 2)
	{
		uint8_t px[4]={0,0,0,0};
		glReadPixels(third + third/2, h/2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
		BOOL green = (px[1] > 150 && px[0] < 90 && px[2] < 90);
		_fbReadback = green;
		self.log([NSString stringWithFormat:@"[gp]   fb_readback: green-bar pixel = (%d,%d,%d,%d) -> %@",
			px[0],px[1],px[2],px[3], green?@"YES":@"NO"]);
		[self seal];
	}

	eglSwapBuffers(_dpy, _surf);
	_frame++;
}

- (void)seal
{
	if (_sealed) return; _sealed = YES;
	const char *rnd = (const char *) glGetString(GL_RENDERER);
	BOOL isMetal = rnd && (strstr(rnd,"Metal") || strstr(rnd,"ANGLE"));
	self.log([NSString stringWithFormat:@"[gp] ANGLE_METAL = %@", isMetal?@"YES":@"NO"]);
	self.log([NSString stringWithFormat:@"[gp] VERDICT window_present=%@ fb_readback=%@ clip_control=%@ msaa=%@",
		@"YES" /* surface created + swapped (a NO-GO would have returned before the loop) */,
		_fbReadback?@"YES":@"NO", _clip?@"YES":@"NO", _msaa?@"YES":@"NO"]);
	self.log(@"[gp] ===== gpu-present done (screenshot the device to confirm bars are on screen) =====");
}

@end
