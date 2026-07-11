/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ----------------------------------------------------------------------------------------------------------------
 * gpu-tbo2d — 117HD-on-iOS blocker #1 (texture-buffer -> 2D integer texture repack), RLHD-FAITHFUL, on iOS GLES.
 *
 * RLHD's Zone renderer feeds per-face data to its VERTEX shaders (scene_vert/shadow_vert) via a GL_TEXTURE_BUFFER.
 * REAL schema, read from rlhd-src (rev 7dded59):
 *   - GLTextureBuffer.java: glTexBuffer(target, GL_RGB32I, id)  -> the buffer is RGB32I, i.e. 3 x int32 per texel.
 *   - scene_vert.glsl:43 / shadow_vert.glsl:42:  uniform isamplerBuffer textureFaces;
 *   - the fetch idiom (scene_vert :77-90, shadow_vert :54-57): each FACE occupies 3 CONSECUTIVE texels at a base
 *     index vTextureFaceIdx (a per-vertex `int` attribute):
 *         texelFetch(textureFaces, vTextureFaceIdx    ).xyz   // alphaBiasHsl   (flat / provoking-vertex path)
 *         texelFetch(textureFaces, vTextureFaceIdx + 1).xyz   // materialData
 *         texelFetch(textureFaces, vTextureFaceIdx + 2).xyz   // terrainData
 *         texelFetch(textureFaces, vTextureFaceIdx    )[vertex]   // per-vertex DYNAMIC component, vertex=gl_VertexID%3
 *
 * iOS EAGL GLES 3.0 (and ANGLE-on-Metal ES 3.0) have NO texture-buffer object (isamplerBuffer / GL_TEXTURE_BUFFER
 * is ES 3.2 core). THE DOWNPORTER TRANSFORM this probe validates (a mechanical 3-rule rewrite — see README):
 *   1.  uniform isamplerBuffer textureFaces;  ->  uniform highp isampler2D textureFaces;
 *   2.  inject at top of main():  int tfW = textureSize(textureFaces, 0).x;
 *   3.  texelFetch(textureFaces, EXPR)  ->  texelFetch(textureFaces, ivec2((EXPR) % tfW, (EXPR) / tfW), 0)
 * (the .xyz / [vertex] swizzles are UNCHANGED — texelFetch on isampler2D still returns ivec4.)  Host side: upload
 * the same RGB32I bytes as a W x ceil(N/W) 2D texture instead of a buffer.
 *
 * This probe proves, on the real RLHD format + fetch idiom, that the repack is BYTE-EXACT on iOS GLES 3.0:
 *   PHASE A — format support matrix: is GL_RGB32I (the real format) usable as a 2D texImage2D + isampler2D source on
 *             iOS? (3-component integer textures are the classic driver-flaky case.) RGBA32I tested as the fallback.
 *   PHASE B — RLHD-faithful FRAGMENT fetch: 16000 faces x 3 texels (48000 texels > GL_MAX_TEXTURE_SIZE, so a 1D
 *             layout is impossible). Per face: fetch idx/idx+1/idx+2 via the repack, with .xyz AND dynamic [v]
 *             indexing; faces' 3-texel spans STRADDLE row boundaries. All verified vs a CPU reference.
 *   PHASE C — same in the VERTEX stage (gl_VertexID-driven) — the exact stage RLHD fetches in.
 *
 * CAVEAT: GL_RENDERER is the Simulator SOFTWARE renderer, not the device Metal GPU. But integer 2D textures +
 * texelFetch + vertex texture fetch are ES 3.0 CORE, so a pass is high-confidence for the device GPU. (Format
 * support in PHASE A is the one part a device could still differ on — it is reported explicitly.)
 * ----------------------------------------------------------------------------------------------------------------
 */
#import "Tbo2dProbe.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>

@implementation Tbo2dProbe

// RLHD-faithful geometry: each face = 3 consecutive RGB32I texels. faceCount * 3 deliberately > GL_MAX_TEXTURE_SIZE.
static const int kFaceCount = 16000;        // 16000 * 3 = 48000 texels
static const int kTexelsPerFace = 3;
static const int kW = 2048;                 // texel-texture width -> 48000/2048 = ~24 rows
static const int kOutW = 2048;              // verify-target width -> 16000/2048 = 8 rows

// Deterministic per-TEXEL RGB32I record (3 signed ints; mixes large/bitwise/negative to surface format/sign bugs).
static void expectedTexelC(int t, int *out /*[3]*/)
{
	out[0] = t * 7 + 1;
	out[1] = (t ^ 0x5a5a) & 0x7fffffff;
	out[2] = -(t * 3 + 1);
}
// the same in GLSL, returning ivec3 (matches RLHD's .xyz usage).
static NSString *const kExpectedGLSL =
	@"ivec3 expected(int t){ return ivec3(t*7+1, (t ^ 0x5a5a) & 0x7fffffff, -(t*3+1)); }\n";

// ---- GL helpers ----
static GLuint compileShader(GLenum type, NSString *src, NSString *label, void (^log)(NSString *))
{
	GLuint sh = glCreateShader(type);
	const char *cstr = [src UTF8String];
	glShaderSource(sh, 1, &cstr, NULL); glCompileShader(sh);
	GLint status = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &status);
	if (status != GL_TRUE) {
		GLint ll = 0; glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &ll);
		char *b = ll > 1 ? malloc(ll) : NULL; if (b) glGetShaderInfoLog(sh, ll, NULL, b);
		log([NSString stringWithFormat:@"[tbo] COMPILE %@ = FAIL: %s", label, b ? b : "(no log)"]);
		free(b); glDeleteShader(sh); return 0;
	}
	return sh;
}
static GLuint linkProgram(NSString *vsrc, NSString *fsrc, NSString *label, void (^log)(NSString *))
{
	GLuint vs = compileShader(GL_VERTEX_SHADER, vsrc, [label stringByAppendingString:@".vert"], log);
	GLuint fs = compileShader(GL_FRAGMENT_SHADER, fsrc, [label stringByAppendingString:@".frag"], log);
	if (!vs || !fs) return 0;
	GLuint p = glCreateProgram(); glAttachShader(p, vs); glAttachShader(p, fs); glLinkProgram(p);
	glDeleteShader(vs); glDeleteShader(fs);
	GLint linked = 0; glGetProgramiv(p, GL_LINK_STATUS, &linked);
	if (!linked) {
		GLint ll = 0; glGetProgramiv(p, GL_INFO_LOG_LENGTH, &ll);
		char *b = ll > 1 ? malloc(ll) : NULL; if (b) glGetProgramInfoLog(p, ll, NULL, b);
		log([NSString stringWithFormat:@"[tbo] LINK %@ = FAIL: %s", label, b ? b : "(no log)"]);
		free(b); glDeleteProgram(p); return 0;
	}
	log([NSString stringWithFormat:@"[tbo] PROGRAM %@ = OK", label]);
	return p;
}
static const char *glErrStr(GLenum e) {
	switch (e) { case GL_NO_ERROR: return "NONE"; case GL_INVALID_ENUM: return "INVALID_ENUM";
		case GL_INVALID_VALUE: return "INVALID_VALUE"; case GL_INVALID_OPERATION: return "INVALID_OPERATION";
		case GL_INVALID_FRAMEBUFFER_OPERATION: return "INVALID_FRAMEBUFFER_OP"; case GL_OUT_OF_MEMORY: return "OOM";
		default: return "?"; }
}
static BOOL makeRGBA8Fbo(int W, int H, GLuint *fboOut, GLuint *colOut, void (^log)(NSString *)) {
	GLuint col = 0, fbo = 0;
	glGenTextures(1, &col); glBindTexture(GL_TEXTURE_2D, col);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, col, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		log(@"[tbo] FBO INCOMPLETE -> SKIP"); glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &col); return NO; }
	*fboOut = fbo; *colOut = col; return YES;
}

// Build the per-texel 2D integer texture (W x H, row-major by texel index; padding zeroed). `rgba`=YES expands each
// RGB32I record to RGBA32I (4th int = 0) — the host fallback when RGB32I 2D is unsupported.
static GLuint buildTexelTexture(BOOL rgba, int numTexels, int W, int *Hout, void (^log)(NSString *))
{
	const int H = (numTexels + W - 1) / W;
	*Hout = H;
	const int comp = rgba ? 4 : 3;
	int32_t *data = calloc((size_t)W * H * comp, sizeof(int32_t));
	for (int t = 0; t < numTexels; t++) { int v[3]; expectedTexelC(t, v); memcpy(&data[(size_t)t * comp], v, sizeof(v)); }
	GLuint tex = 0; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glTexImage2D(GL_TEXTURE_2D, 0, rgba ? GL_RGBA32I : GL_RGB32I, W, H, 0,
		rgba ? GL_RGBA_INTEGER : GL_RGB_INTEGER, GL_INT, data);
	GLenum e = glGetError();
	free(data);
	log([NSString stringWithFormat:@"[tbo]   %@ %dx%d (%d texels) upload glErr=%s",
		rgba ? @"RGBA32I" : @"RGB32I", W, H, numTexels, glErrStr(e)]);
	if (e != GL_NO_ERROR) { glDeleteTextures(1, &tex); return 0; }
	return tex;
}

// PHASE A — format support matrix: upload a tiny texture in each format, sample one known texel via texelFetch in a
// 1x1 fragment render, verify exact. Returns whether each format works.
static void runPhaseA(BOOL *rgb32iOk, BOOL *rgba32iOk, void (^log)(NSString *))
{
	log(@"[tbo] ===== PHASE A: integer-texture format support (RGB32I = RLHD's real format; RGBA32I = fallback) =====");
	NSString *vsrc =
		@"#version 300 es\nprecision highp float;\n"
		 "void main(){ gl_Position = vec4(0.,0.,0.,1.); gl_PointSize = 1.0; }\n";
	NSString *fsrc = [NSString stringWithFormat:
		@"#version 300 es\nprecision highp float; precision highp int; precision highp isampler2D;\n"
		 "uniform highp isampler2D uTex; uniform int uIdx;\n"
		 "out vec4 FragColor;\n%@"
		 "void main(){ ivec3 got = texelFetch(uTex, ivec2(uIdx, 0), 0).xyz;\n"
		 "  FragColor = (got == expected(uIdx)) ? vec4(0.,1.,0.,1.) : vec4(1.,0.,0.,1.); }\n", kExpectedGLSL];
	GLuint prog = linkProgram(vsrc, fsrc, @"P_FORMAT", log);
	if (!prog) { *rgb32iOk = NO; *rgba32iOk = NO; return; }
	GLuint fbo = 0, col = 0;
	if (!makeRGBA8Fbo(1, 1, &fbo, &col, log)) { glDeleteProgram(prog); *rgb32iOk = NO; *rgba32iOk = NO; return; }

	for (int pass = 0; pass < 2; pass++) {
		const BOOL rgba = (pass == 1);
		int H = 0; GLuint tex = buildTexelTexture(rgba, 8, 8, &H, log);   // 8 texels in one row
		BOOL ok = NO;
		if (tex) {
			glBindFramebuffer(GL_FRAMEBUFFER, fbo); glViewport(0, 0, 1, 1);
			glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
			glUseProgram(prog);
			glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
			glUniform1i(glGetUniformLocation(prog, "uTex"), 0);
			glUniform1i(glGetUniformLocation(prog, "uIdx"), 5);          // sample texel 5
			GLuint vao = 0; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
			glDrawArrays(GL_POINTS, 0, 1);
			unsigned char px[4] = {0}; glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
			ok = (px[1] > 200 && px[0] < 80);
			glDeleteVertexArrays(1, &vao); glDeleteTextures(1, &tex);
		}
		if (rgba) *rgba32iOk = ok; else *rgb32iOk = ok;
		log([NSString stringWithFormat:@"[tbo] A_%@_SAMPLEABLE = %@", rgba ? @"RGBA32I" : @"RGB32I", ok ? @"YES" : @"NO"]);
	}
	glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &col); glDeleteProgram(prog);
}

// The downporter-rewritten RLHD fetch idiom, shared by PHASE B (fragment) and PHASE C (vertex). Verifies, for a face:
//   - texelFetch(textureFaces, idx+k).xyz  (k=0,1,2) == expected(idx+k)        [the flat/provoking path]
//   - texelFetch(textureFaces, idx)[v]     (v=0,1,2) == expected(idx)[v]       [the per-vertex DYNAMIC-index path]
// with the 2D repack ivec2((EXPR) % tfW, (EXPR) / tfW) — faces' 3-texel spans straddle rows.
// NOTE: this is a plain NSString literal inserted via %@ (NOT a format string), so single % is correct here.
static NSString *kVerifyBodyGLSL =
	@"  int tfW = textureSize(uFaces, 0).x;\n"                                  // downporter rule 2
	 "  int idx = faceId * 3;\n"
	 "  ivec3 a = texelFetch(uFaces, ivec2((idx)   % tfW, (idx)   / tfW), 0).xyz;\n"   // rule 3, vTextureFaceIdx
	 "  ivec3 b = texelFetch(uFaces, ivec2((idx+1) % tfW, (idx+1) / tfW), 0).xyz;\n"   //         + 1
	 "  ivec3 c = texelFetch(uFaces, ivec2((idx+2) % tfW, (idx+2) / tfW), 0).xyz;\n"   //         + 2
	 "  bool ok = (a == expected(idx)) && (b == expected(idx+1)) && (c == expected(idx+2));\n"
	 "  for (int v = 0; v < 3; v++) {\n"
	 "    int comp = texelFetch(uFaces, ivec2((idx) % tfW, (idx) / tfW), 0)[v];\n"     // the [vertex] idiom
	 "    if (comp != expected(idx)[v]) ok = false;\n"
	 "  }\n";

static BOOL countGreen(int W, int H, int wantGreen, int wantOther, BOOL otherIsBlue, const char *phaseTag, void (^log)(NSString *))
{
	unsigned char *px = malloc((size_t)W * H * 4);
	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	int green = 0, red = 0, other = 0;
	for (size_t i = 0; i < (size_t)W * H; i++) {
		const unsigned char *p = px + i * 4;
		if (p[1] > 200 && p[0] < 80) green++;
		else if (p[0] > 200 && p[1] < 80) red++;
		else other++;
	}
	free(px);
	const BOOL ok = (green == wantGreen) && (red == 0) && (other == wantOther);
	log([NSString stringWithFormat:@"[tbo] PHASE %s: green=%d (want %d) red=%d (want 0) %s=%d (want %d) -> %@",
		phaseTag, green, wantGreen, red, otherIsBlue ? "blue/pad" : "black/undrawn", other, wantOther, ok ? @"YES" : @"NO"]);
	return ok;
}

static BOOL runPhaseB(GLuint faceTex, int outW, int outH, int numFaces, void (^log)(NSString *))
{
	NSString *vsrc =
		@"#version 300 es\nprecision highp float;\n"
		 "const vec2 P[4] = vec2[4](vec2(-1.,-1.), vec2(1.,-1.), vec2(-1.,1.), vec2(1.,1.));\n"
		 "void main(){ gl_Position = vec4(P[gl_VertexID], 0., 1.); }\n";
	NSString *fsrc = [NSString stringWithFormat:
		@"#version 300 es\nprecision highp float; precision highp int; precision highp isampler2D;\n"
		 "uniform highp isampler2D uFaces; uniform int uOutW; uniform int uNumFaces;\n"
		 "out vec4 FragColor;\n%@"
		 "void main(){\n"
		 "  int faceId = int(gl_FragCoord.y) * uOutW + int(gl_FragCoord.x);\n"
		 "  if (faceId >= uNumFaces) { FragColor = vec4(0.,0.,1.,1.); return; }\n"
		 "%@"
		 "  FragColor = ok ? vec4(0.,1.,0.,1.) : vec4(1.,0.,0.,1.);\n}\n", kExpectedGLSL, kVerifyBodyGLSL];
	GLuint prog = linkProgram(vsrc, fsrc, @"P_FRAG", log);
	if (!prog) return NO;
	GLuint fbo = 0, col = 0;
	if (!makeRGBA8Fbo(outW, outH, &fbo, &col, log)) { glDeleteProgram(prog); return NO; }
	glBindFramebuffer(GL_FRAMEBUFFER, fbo); glViewport(0, 0, outW, outH); glDisable(GL_DEPTH_TEST);
	glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
	glUseProgram(prog);
	glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, faceTex);
	glUniform1i(glGetUniformLocation(prog, "uFaces"), 0);
	glUniform1i(glGetUniformLocation(prog, "uOutW"), outW);
	glUniform1i(glGetUniformLocation(prog, "uNumFaces"), numFaces);
	GLuint vao = 0; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	const int padding = outW * outH - numFaces;
	BOOL ok = countGreen(outW, outH, numFaces, padding, YES, "B (fragment, RLHD fetch idiom)", log);
	glDeleteVertexArrays(1, &vao); glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &col); glDeleteProgram(prog);
	log([NSString stringWithFormat:@"[tbo] B_FRAG_EXACT = %@", ok ? @"YES" : @"NO"]);
	return ok;
}

static BOOL runPhaseC(GLuint faceTex, int outW, int outH, int numFaces, void (^log)(NSString *))
{
	NSString *vsrc = [NSString stringWithFormat:
		@"#version 300 es\nprecision highp float; precision highp int; precision highp isampler2D;\n"
		 "uniform highp isampler2D uFaces; uniform int uOutW; uniform int uOutH;\n"
		 "flat out int vOk;\n%@"
		 "void main(){\n"
		 "  int faceId = gl_VertexID;\n"
		 "%@"
		 "  vOk = ok ? 1 : 0;\n"
		 "  int px = faceId %% uOutW; int py = faceId / uOutW;\n"
		 "  float nx = (float(px)+0.5)/float(uOutW)*2.0 - 1.0;\n"
		 "  float ny = (float(py)+0.5)/float(uOutH)*2.0 - 1.0;\n"
		 "  gl_Position = vec4(nx, ny, 0.0, 1.0); gl_PointSize = 1.0;\n}\n", kExpectedGLSL, kVerifyBodyGLSL];
	NSString *fsrc =
		@"#version 300 es\nprecision highp float;\nflat in int vOk;\nout vec4 FragColor;\n"
		 "void main(){ FragColor = (vOk == 1) ? vec4(0.,1.,0.,1.) : vec4(1.,0.,0.,1.); }\n";
	GLuint prog = linkProgram(vsrc, fsrc, @"P_VERT", log);
	if (!prog) return NO;
	GLuint fbo = 0, col = 0;
	if (!makeRGBA8Fbo(outW, outH, &fbo, &col, log)) { glDeleteProgram(prog); return NO; }
	glBindFramebuffer(GL_FRAMEBUFFER, fbo); glViewport(0, 0, outW, outH); glDisable(GL_DEPTH_TEST);
	glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
	glUseProgram(prog);
	glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, faceTex);
	glUniform1i(glGetUniformLocation(prog, "uFaces"), 0);
	glUniform1i(glGetUniformLocation(prog, "uOutW"), outW);
	glUniform1i(glGetUniformLocation(prog, "uOutH"), outH);
	GLuint vao = 0; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
	glDrawArrays(GL_POINTS, 0, numFaces);
	const int padding = outW * outH - numFaces;
	BOOL ok = countGreen(outW, outH, numFaces, padding, NO, "C (vertex stage, gl_VertexID, RLHD pathway)", log);
	glDeleteVertexArrays(1, &vao); glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &col); glDeleteProgram(prog);
	log([NSString stringWithFormat:@"[tbo] C_VERT_EXACT = %@", ok ? @"YES" : @"NO"]);
	return ok;
}

+ (void)runWithLog:(void (^)(NSString *))log
{
	log(@"[tbo] ===== gpu-tbo2d: RLHD textureFaces (GL_RGB32I texture-buffer) -> 2D integer-texture repack on iOS GLES =====");
	EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
	if (!ctx) { log(@"[tbo] EAGL ES3 context creation FAILED -> NO-GO"); return; }
	[EAGLContext setCurrentContext:ctx];
	const char *renderer = (const char *) glGetString(GL_RENDERER);
	log([NSString stringWithFormat:@"[tbo] GL_VERSION = %s", (const char *) glGetString(GL_VERSION)]);
	log([NSString stringWithFormat:@"[tbo] GL_SLVERSION = %s", (const char *) glGetString(GL_SHADING_LANGUAGE_VERSION)]);
	log([NSString stringWithFormat:@"[tbo] GL_RENDERER = %s", renderer]);
	GLint maxTex = 0, maxVtxTex = 0;
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTex);
	glGetIntegerv(GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS, &maxVtxTex);
	const int numTexels = kFaceCount * kTexelsPerFace;
	log([NSString stringWithFormat:@"[tbo] GL_MAX_TEXTURE_SIZE=%d  GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS=%d", maxTex, maxVtxTex]);
	log([NSString stringWithFormat:@"[tbo] %d faces x %d texels = %d texels; a 1D layout needs width %d > GL_MAX_TEXTURE_SIZE=%d -> %@",
		kFaceCount, kTexelsPerFace, numTexels, numTexels, maxTex, (numTexels > maxTex) ? @"2D REQUIRED" : @"would-fit-1D-but-2D-for-bigger-scenes"]);
	if (renderer && strstr(renderer, "Software"))
		log(@"[tbo] NOTE: software renderer; integer-2D-texture + texelFetch + vertex texture fetch are ES 3.0 CORE -> high device confidence (PHASE A format support is the one device-checkable item).");

	BOOL rgb32iOk = NO, rgba32iOk = NO;
	runPhaseA(&rgb32iOk, &rgba32iOk, log);

	// Choose the repack format: prefer RGB32I (exact match to RLHD's buffer, zero host data transform); else pad to RGBA32I.
	const BOOL useRgba = !rgb32iOk;
	log([NSString stringWithFormat:@"[tbo] REPACK_FORMAT = %@  (RGB32I sampleable=%@; %@)",
		useRgba ? @"RGBA32I (host pads RGB->RGBA)" : @"RGB32I (exact, no host transform)",
		rgb32iOk ? @"YES" : @"NO", useRgba ? @"falling back to RGBA32I" : @"using RLHD's native RGB32I"]);

	int texH = 0;
	GLuint faceTex = buildTexelTexture(useRgba, numTexels, kW, &texH, log);
	log([NSString stringWithFormat:@"[tbo] face texture: %@ %dx%d", useRgba ? @"RGBA32I" : @"RGB32I", kW, texH]);

	BOOL b = NO, c = NO;
	const int outH = (kFaceCount + kOutW - 1) / kOutW;
	if (faceTex) {
		b = runPhaseB(faceTex, kOutW, outH, kFaceCount, log);
		c = runPhaseC(faceTex, kOutW, outH, kFaceCount, log);
		glDeleteTextures(1, &faceTex);
	} else { log(@"[tbo] face texture build FAILED -> PHASE B/C SKIP"); }

	const BOOL green = (faceTex != 0) && b && c && (rgb32iOk || rgba32iOk);
	log([NSString stringWithFormat:@"[tbo] VERDICT tbo2d_repack_exact = %@  (rgb32i=%@ frag=%@ vert=%@)",
		green ? @"YES" : @"NO", rgb32iOk ? @"YES" : @"NO", b ? @"YES" : @"NO", c ? @"YES" : @"NO"]);
	log(@"[tbo] ===== gpu-tbo2d done =====");
	[EAGLContext setCurrentContext:nil];
}

@end
