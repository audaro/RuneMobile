/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ----------------------------------------------------------------------------------------------------------------
 * gpu-clipremap — three-way A/B of reverse-Z depth strategies on iOS GLES (Simulator), for the Route C river z-fight.
 *
 * The base gpu plugin uses a REVERSE-Z projection (Mat4.projection): clip.z = 2*near = 100 (CONSTANT), clip.w = viewZ,
 * so NDC.z = clip.z/clip.w = 100/viewZ in (0,1] (near=1, far->0), paired with glDepthFunc(GL_GREATER) +
 * glClearDepthf(0). On DESKTOP the plugin also calls glClipControl(ZERO_TO_ONE), so the depth buffer stores
 * window_z = NDC.z = 100/viewZ directly -> full float32 precision at the far plane.
 *
 * Native iOS EAGL has NO glClipControl, so the fixed-function viewport transform applies window_z = (NDC.z+1)/2,
 * which crushes the far plane into [0.5, ~0.51] (a low-precision region of float32). That collapse IS the z-fight.
 *
 * THREE candidate fixes, tested head-to-head here on identical geometry so the numbers compare directly:
 *
 *   (A) BASELINE  — no fix. Fixed-function window_z = (NDC.z+1)/2. The control / the bug.
 *
 *   (B) FRAGDEPTH — write the depth in the fragment shader: gl_FragDepth = clip.z/clip.w = NDC.z (the desktop
 *       ZERO_TO_ONE value), bypassing the lossy windowing. Validated GREEN by gpu-depthsim. BUT writing gl_FragDepth
 *       DISABLES Apple's TBDR Hidden Surface Removal / early-Z (Apple's own docs) -> a real perf cost at OSRS
 *       overdraw with 117HD's heavy fragment shaders. That perf cost is DEVICE-only (a software renderer is not a
 *       TBDR); this probe measures only the CORRECTNESS/PRECISION, not the perf.
 *
 *   (C) CLIPREMAP — emulate glClipControl(ZERO_TO_ONE) in the VERTEX shader: gl_Position.z = 2*clip.z - clip.w.
 *       After perspective divide NDC.z' = 2*NDC.z - 1, and the fixed (NDC.z'+1)/2 windowing returns window_z = NDC.z.
 *       It writes depth in the VERTEX stage, so early-Z/HSR stays ON (no perf cost) -- attractive IF it is precise.
 *       THE CATCH this probe exists to settle: CLIPREMAP routes the far plane back through NDC.z' ~= -0.967 and the
 *       (z+1)/2 add -- the exact catastrophic cancellation glClipControl was invented to avoid. So it may produce
 *       the correct MEAN depth but only BASELINE-grade precision. Phase 1 decides it numerically.
 *
 * Phases (mirrors gpu-depthsim, extended to 3 configs + a per-VERTEX bias test the original skipped):
 *   PHASE 1 — float32 precision at distance (CPU; models the device's confirmed-32F depth buffer). Distinct stored
 *             depth values per config over a far-plane viewZ window. The decisive test for CLIPREMAP.
 *   PHASE 2 — a real z-fight on DEPTH_COMPONENT32F (two near-coplanar intersecting planes at distance); contamination
 *             per config at NEAR/FAR/VERYFAR on the actual GLES pipeline.
 *   PHASE 3 — coplanar bias layering with the bias delivered as a PER-VERTEX ATTRIBUTE (the plugin's real pathway:
 *             screenPos.z += bias/128), not a per-draw uniform (the gap the depthsim verifier flagged). Each config
 *             must keep decorations on top of floors.
 * ----------------------------------------------------------------------------------------------------------------
 */
#import "ClipRemapProbe.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <math.h>

@implementation ClipRemapProbe

// the plugin's reverse-Z constant: clip.z = 2 * near, near = 50 (Mat4.projection(w,h,50)).
static const float CLIP_Z = 100.0f;

// =================================================================================================================
//  PHASE 1 depth models, in genuine float32 (the precision a true-32F depth buffer -- what the DEVICE has -- stores).
//  `volatile` forces each step to round to float32 (no double promotion / FMA contraction), faithfully modelling the
//  per-op rounding of the GPU's highp float depth path. Each function returns the STORED window depth for one config.
// =================================================================================================================
static float winBaseline(float viewZ, float clipZ)    // fixed-function window_z = (NDC.z+1)/2
{
	volatile float ndcz = clipZ / viewZ;              // 100/viewZ
	volatile float win  = ndcz * 0.5f + 0.5f;         // the precision-killing add-to-1.0, then halve
	return win;
}
static float winFragdepth(float viewZ, float clipZ)   // gl_FragDepth = clip.z/clip.w = NDC.z directly (no windowing)
{
	volatile float ndcz = clipZ / viewZ;
	return ndcz;
}
static float winClipremap(float viewZ, float clipZ)   // vertex remap: clip.z' = 2*clip.z - clip.w, then windowed
{
	volatile float cz   = 2.0f * clipZ - viewZ;       // remapped clip.z'
	volatile float ndcz = cz / viewZ;                 // NDC.z' = 2*NDC.z - 1  (~ -0.967 at far -> cancellation here)
	volatile float win  = ndcz * 0.5f + 0.5f;         // (NDC.z'+1)/2 -> mathematically == NDC.z, float32 differs
	return win;
}

// =================================================================================================================
//  shaders (GLSL ES 3.00). A per-vertex aBias attribute carries the plugin's coplanar layer offset (clip.z += bias/128),
//  so Phase 3 exercises the PER-VERTEX bias pathway. Three program variants share the fragment-color path; they differ
//  only in how the depth is produced (fixed-function / gl_FragDepth / vertex clip.z remap).
// =================================================================================================================

// BASELINE + FRAGDEPTH share this vertex shader (plain reverse-Z clip coords). vClipDepth carries the per-vertex clip.z
// for FRAGDEPTH's fragment write; it is `flat` (the plugin's bias is per-face-uniform, so the provoking vertex's value
// is the face's clip.z) -- Phase 3 delivers a uniform-per-quad bias via the attribute stream so flat is faithful.
static NSString *const kVertPlain =
	@"#version 300 es\n"
	 "precision highp float;\n"
	 "layout(location = 0) in vec2 aNdc;\n"      // target NDC xy in [-1,1]
	 "layout(location = 1) in float aViewZ;\n"   // per-vertex clip.w (the depth)
	 "layout(location = 2) in float aBias;\n"    // per-vertex raw bias (0..255); plugin adds bias/128 to clip.z
	 "uniform float uClipZ;\n"                   // clip.z = 2*near (constant base)
	 "flat out float vClipDepth;\n"
	 "void main() {\n"
	 "  float clipZ = uClipZ + aBias / 128.0;\n" // == screenPos.z += float(bias)/128.0
	 "  gl_Position = vec4(aNdc * aViewZ, clipZ, aViewZ);\n"
	 "  vClipDepth = clipZ;\n"
	 "}\n";

// CLIPREMAP vertex shader: identical except the emulated-ZERO_TO_ONE remap gl_Position.z = 2*clipZ - viewZ.
static NSString *const kVertClipremap =
	@"#version 300 es\n"
	 "precision highp float;\n"
	 "layout(location = 0) in vec2 aNdc;\n"
	 "layout(location = 1) in float aViewZ;\n"
	 "layout(location = 2) in float aBias;\n"
	 "uniform float uClipZ;\n"
	 "flat out float vClipDepth;\n"
	 "void main() {\n"
	 "  float clipZ = uClipZ + aBias / 128.0;\n"
	 "  gl_Position = vec4(aNdc * aViewZ, 2.0 * clipZ - aViewZ, aViewZ);\n"  // emulate glClipControl(ZERO_TO_ONE)
	 "  vClipDepth = clipZ;\n"
	 "}\n";

// BASELINE + CLIPREMAP fragment: solid colour, default depth (fixed-function). early-Z stays ON.
static NSString *const kFragSolid =
	@"#version 300 es\n"
	 "precision highp float;\n"
	 "uniform vec3 uColor;\n"
	 "out vec4 FragColor;\n"
	 "void main() { FragColor = vec4(uColor, 1.0); }\n";

// FRAGDEPTH fragment: solid colour + gl_FragDepth = clip.z/clip.w = NDC.z. DISABLES early-Z on a TBDR (device-only cost).
static NSString *const kFragDepthWrite =
	@"#version 300 es\n"
	 "precision highp float;\n"
	 "uniform vec3 uColor;\n"
	 "flat in float vClipDepth;\n"
	 "out vec4 FragColor;\n"
	 "void main() { FragColor = vec4(uColor, 1.0); gl_FragDepth = vClipDepth * gl_FragCoord.w; }\n";

// the three configs, indexed CFG_*.
enum { CFG_BASELINE = 0, CFG_FRAGDEPTH = 1, CFG_CLIPREMAP = 2, CFG_COUNT = 3 };
static NSString *const kCfgName[CFG_COUNT] = { @"baseline", @"fragdepth", @"clipremap" };

// ----- GL helpers -----

static GLuint compileShader(GLenum type, NSString *src, NSString *label, void (^log)(NSString *))
{
	GLuint sh = glCreateShader(type);
	const char *cstr = [src UTF8String];
	glShaderSource(sh, 1, &cstr, NULL);
	glCompileShader(sh);
	GLint status = 0;
	glGetShaderiv(sh, GL_COMPILE_STATUS, &status);
	if (status != GL_TRUE)
	{
		GLint logLen = 0; glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &logLen);
		char *b = logLen > 1 ? malloc(logLen) : NULL;
		if (b) { glGetShaderInfoLog(sh, logLen, NULL, b); }
		log([NSString stringWithFormat:@"[cr] COMPILE %@ = FAIL: %s", label, b ? b : "(no log)"]);
		free(b); glDeleteShader(sh); return 0;
	}
	return sh;
}

static GLuint linkProgram(NSString *vsrc, NSString *fsrc, NSString *label, void (^log)(NSString *))
{
	GLuint vs = compileShader(GL_VERTEX_SHADER, vsrc, [label stringByAppendingString:@".vert"], log);
	GLuint fs = compileShader(GL_FRAGMENT_SHADER, fsrc, [label stringByAppendingString:@".frag"], log);
	if (!vs || !fs) { return 0; }
	GLuint prog = glCreateProgram();
	glAttachShader(prog, vs); glAttachShader(prog, fs);
	glLinkProgram(prog);
	glDeleteShader(vs); glDeleteShader(fs);
	GLint linked = 0; glGetProgramiv(prog, GL_LINK_STATUS, &linked);
	if (!linked)
	{
		GLint ll = 0; glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &ll);
		char *b = ll > 1 ? malloc(ll) : NULL;
		if (b) { glGetProgramInfoLog(prog, ll, NULL, b); }
		log([NSString stringWithFormat:@"[cr] LINK %@ = FAIL: %s", label, b ? b : "(no log)"]);
		free(b); glDeleteProgram(prog); return 0;
	}
	log([NSString stringWithFormat:@"[cr] PROGRAM %@ = OK", label]);
	return prog;
}

// a screen-covering quad (2 tris). Each corner carries (viewZ, bias). Layout: BL, BR, TR, TL; BL = NDC(-1,-1) = readback row 0.
static GLuint sVao = 0, sVbo = 0;
static void drawCoveringQuad(float vzBL, float vzBR, float vzTR, float vzTL, float bias)
{
	const float v[] = {
		// aNdc.x aNdc.y  aViewZ  aBias
		-1.f, -1.f, vzBL, bias,   1.f, -1.f, vzBR, bias,   1.f, 1.f, vzTR, bias,   // tri 1: BL BR TR
		-1.f, -1.f, vzBL, bias,   1.f,  1.f, vzTR, bias,  -1.f, 1.f, vzTL, bias,   // tri 2: BL TR TL
	};
	glBindVertexArray(sVao);
	glBindBuffer(GL_ARRAY_BUFFER, sVbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STREAM_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)0);
	glEnableVertexAttribArray(1);
	glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)(2 * sizeof(float)));
	glEnableVertexAttribArray(2);
	glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void *)(3 * sizeof(float)));
	glDrawArrays(GL_TRIANGLES, 0, 6);
}

// =================================================================================================================
//  PHASE 1 — float32 precision at distance, per config. Walk float32 viewZ one ULP at a time over a window at the far
//  plane; count DISTINCT stored window-depth values each config yields. More distinct = finer = less collapse. The
//  decisive CLIPREMAP test: does it land near FRAGDEPTH (full precision) or near BASELINE (no help)?
// =================================================================================================================
static int sP1Distinct[CFG_COUNT];
static BOOL runPhase1Cpu(void (^log)(NSString *))
{
	log(@"[cr] ===== PHASE 1: float32 depth precision at distance (CPU; models the device's confirmed-32F buffer) =====");
	log(@"[cr]   (software renderer has no EXT_color_buffer_float; precision is pure float32 arithmetic, computed here.)");

	const float clipZ = CLIP_Z;   // bias 0 for the precision sweep
	const float sweep[] = {200.f, 1000.f, 2000.f, 6000.f, 9000.f};
	for (size_t i = 0; i < sizeof(sweep)/sizeof(sweep[0]); i++)
	{
		const float vz = sweep[i];
		log([NSString stringWithFormat:@"[cr]   viewZ=%6.0f  baseline=%.9g  fragdepth=%.9g  clipremap=%.9g",
			vz, winBaseline(vz, clipZ), winFragdepth(vz, clipZ), winClipremap(vz, clipZ)]);
	}

	const float Zfar = 6000.f;
	const int N = 100000;
	float zb = Zfar, zf = Zfar, zc = Zfar;          // independent walkers (same sequence) keep prev-tracking simple
	float pb = winBaseline(Zfar, clipZ), pf = winFragdepth(Zfar, clipZ), pc = winClipremap(Zfar, clipZ);
	int db = 1, df = 1, dc = 1;
	float zEnd = Zfar;
	for (int i = 1; i < N; i++)
	{
		const float z = nextafterf(zEnd, INFINITY);
		zEnd = z; zb = z; zf = z; zc = z;
		const float b = winBaseline(z, clipZ), f = winFragdepth(z, clipZ), c = winClipremap(z, clipZ);
		if (b != pb) { db++; pb = b; }
		if (f != pf) { df++; pf = f; }
		if (c != pc) { dc++; pc = c; }
	}
	const float covered = zEnd - Zfar;
	sP1Distinct[CFG_BASELINE] = db; sP1Distinct[CFG_FRAGDEPTH] = df; sP1Distinct[CFG_CLIPREMAP] = dc;
	log([NSString stringWithFormat:@"[cr] PHASE 1 over %.4g viewZ units at Zfar=%.0f (%d float32 samples):", covered, Zfar, N]);
	log([NSString stringWithFormat:@"[cr]   baseline  distinct depths = %d", db]);
	log([NSString stringWithFormat:@"[cr]   fragdepth distinct depths = %d  (%.1fx baseline)", df, (float)df/(float)db]);
	log([NSString stringWithFormat:@"[cr]   clipremap distinct depths = %d  (%.1fx baseline)", dc, (float)dc/(float)db]);

	// CLIPREMAP "recovers precision" iff it is within 2x of FRAGDEPTH (i.e. lands with the full-precision camp, not baseline).
	const BOOL clipremapRecovers = (dc * 2 >= df) && (dc > db * 4);
	log([NSString stringWithFormat:@"[cr] P1_CLIPREMAP_RECOVERS_PRECISION = %@  (clipremap=%d vs fragdepth=%d vs baseline=%d)",
		clipremapRecovers ? @"YES" : @"NO", dc, df, db]);
	const BOOL fragdepthFiner = df > db * 4;
	log([NSString stringWithFormat:@"[cr] P1_FRAGDEPTH_FINER = %@", fragdepthFiner ? @"YES" : @"NO"]);
	return fragdepthFiner;
}

// =================================================================================================================
//  PHASE 2 — a real z-fight on DEPTH_COMPONENT32F: two screen-covering planes at distance that coincide at screen
//  center and separate linearly. Contamination = wrong-colour pixels in each half. Run per config at NEAR/FAR/VERYFAR.
// =================================================================================================================
static int sP2Far[CFG_COUNT];
static int runPhase2Config(int cfg, GLuint prog, float Zfar, float slope, int W, int H, unsigned char *px, void (^log)(NSString *), NSString *tag)
{
	GLint locClipZ = glGetUniformLocation(prog, "uClipZ");
	GLint locColor = glGetUniformLocation(prog, "uColor");
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_GREATER);           // reverse-Z: nearer = larger depth
	glDepthMask(GL_TRUE);
	glClearDepthf(0.f);
	glViewport(0, 0, W, H);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glUseProgram(prog);
	glUniform1f(locClipZ, CLIP_Z);

	glUniform3f(locColor, 0.f, 0.f, 1.f);                                  // A — blue, flat at Zfar
	drawCoveringQuad(Zfar, Zfar, Zfar, Zfar, 0.f);
	glUniform3f(locColor, 1.f, 0.f, 0.f);                                  // B — red, tilted, coincident at center
	drawCoveringQuad(Zfar - slope, Zfar - slope, Zfar + slope, Zfar + slope, 0.f);

	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	int bottomBlue = 0, topRed = 0;                                        // row 0 = ndc.y=-1, B should win (red)
	for (int y = 0; y < H; y++)
	{
		const BOOL bottom = (y < H/2);
		for (int x = 0; x < W; x++)
		{
			const unsigned char *p = px + ((size_t)y*W + x)*4;
			if (bottom && p[2] > p[0]) { bottomBlue++; }
			if (!bottom && p[0] > p[2]) { topRed++; }
		}
	}
	const int contamination = bottomBlue + topRed;
	log([NSString stringWithFormat:@"[cr]   cfg=%@ %@ Zfar=%.0f contamination=%d (bottomBlue=%d topRed=%d of %d)",
		kCfgName[cfg], tag, Zfar, contamination, bottomBlue, topRed, W*H]);
	return contamination;
}

static void runPhase2(GLuint progs[CFG_COUNT], void (^log)(NSString *))
{
	log(@"[cr] ===== PHASE 2: real z-fight on DEPTH_COMPONENT32F (two near-coplanar intersecting planes) =====");
	const int W = 512, H = 512;
	GLuint color = 0, depth = 0, fbo = 0;
	glGenTextures(1, &color); glBindTexture(GL_TEXTURE_2D, color);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenTextures(1, &depth); glBindTexture(GL_TEXTURE_2D, depth);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT32F, W, H, 0, GL_DEPTH_COMPONENT, GL_FLOAT, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth, 0);
	GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	GLint depthBits = -1;
	glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE, &depthBits);
	log([NSString stringWithFormat:@"[cr] PHASE 2 fbo status=0x%04x depth_attach_bits=%d (requested DEPTH_COMPONENT32F)", st, depthBits]);
	if (st != GL_FRAMEBUFFER_COMPLETE)
	{
		log(@"[cr] PHASE 2 fbo INCOMPLETE -> SKIP");
		glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &color); glDeleteTextures(1, &depth);
		return;
	}
	unsigned char *px = malloc((size_t)W*H*4);
	const float slope = 0.5f;
	for (int cfg = 0; cfg < CFG_COUNT; cfg++)
	{
		runPhase2Config(cfg, progs[cfg], 600.f, slope, W, H, px, log, @"NEAR");
		sP2Far[cfg] = runPhase2Config(cfg, progs[cfg], 6000.f, slope, W, H, px, log, @"FAR");
		runPhase2Config(cfg, progs[cfg], 9000.f, slope, W, H, px, log, @"VERYFAR");
	}
	free(px);
	glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &color); glDeleteTextures(1, &depth);
	log([NSString stringWithFormat:@"[cr] PHASE 2 FAR contamination: baseline=%d fragdepth=%d clipremap=%d",
		sP2Far[CFG_BASELINE], sP2Far[CFG_FRAGDEPTH], sP2Far[CFG_CLIPREMAP]]);
}

// =================================================================================================================
//  PHASE 3 — coplanar bias layering with a PER-VERTEX bias attribute (the plugin's real pathway, not a per-draw
//  uniform). floor (blue, bias 0) then decoration (red, bias 4) fully coplanar at the far plane; the decoration's
//  larger clip.z must keep it on top. floor_bleed (blue showing through) = layering broken. Per config.
// =================================================================================================================
static int sP3Bleed[CFG_COUNT];
static void runPhase3(GLuint progs[CFG_COUNT], void (^log)(NSString *))
{
	log(@"[cr] ===== PHASE 3: coplanar bias layering via a PER-VERTEX bias attribute (decorations-on-floors) =====");
	const int W = 512, H = 512;
	GLuint color = 0, depth = 0, fbo = 0;
	glGenTextures(1, &color); glBindTexture(GL_TEXTURE_2D, color);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenTextures(1, &depth); glBindTexture(GL_TEXTURE_2D, depth);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT32F, W, H, 0, GL_DEPTH_COMPONENT, GL_FLOAT, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth, 0);
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
	{
		log(@"[cr] PHASE 3 fbo INCOMPLETE -> SKIP");
		glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &color); glDeleteTextures(1, &depth);
		return;
	}
	unsigned char *px = malloc((size_t)W*H*4);
	const float Zfar = 6000.f;
	for (int cfg = 0; cfg < CFG_COUNT; cfg++)
	{
		GLuint prog = progs[cfg];
		GLint locClipZ = glGetUniformLocation(prog, "uClipZ");
		GLint locColor = glGetUniformLocation(prog, "uColor");
		glEnable(GL_DEPTH_TEST); glDepthFunc(GL_GREATER); glDepthMask(GL_TRUE); glClearDepthf(0.f);
		glViewport(0, 0, W, H);
		glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glUseProgram(prog); glUniform1f(locClipZ, CLIP_Z);
		glUniform3f(locColor, 0.f, 0.f, 1.f);                          // floor, bias 0
		drawCoveringQuad(Zfar, Zfar, Zfar, Zfar, 0.f);
		glUniform3f(locColor, 1.f, 0.f, 0.f);                          // decoration, per-vertex bias 4
		drawCoveringQuad(Zfar, Zfar, Zfar, Zfar, 4.f);
		glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
		int bleed = 0;
		for (int i = 0; i < W*H; i++) { const unsigned char *p = px + (size_t)i*4; if (p[2] > p[0]) bleed++; }
		sP3Bleed[cfg] = bleed;
		log([NSString stringWithFormat:@"[cr]   cfg=%@ bias=4/128 Zfar=%.0f floor_bleed=%d of %d (0 = layering intact)",
			kCfgName[cfg], Zfar, bleed, W*H]);
	}
	free(px);
	glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &color); glDeleteTextures(1, &depth);
}

+ (void)runWithLog:(void (^)(NSString *))log
{
	log(@"[cr] ===== gpu-clipremap: baseline vs fragdepth vs clipremap reverse-Z depth, on iOS Simulator GLES =====");

	EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
	if (!ctx) { log(@"[cr] EAGL ES3 context creation FAILED -> NO-GO"); return; }
	[EAGLContext setCurrentContext:ctx];
	const char *renderer = (const char *) glGetString(GL_RENDERER);
	log([NSString stringWithFormat:@"[cr] GL_VERSION = %s", (const char *) glGetString(GL_VERSION)]);
	log([NSString stringWithFormat:@"[cr] GL_SLVERSION = %s", (const char *) glGetString(GL_SHADING_LANGUAGE_VERSION)]);
	log([NSString stringWithFormat:@"[cr] GL_RENDERER = %s", renderer]);
	const char *exts = (const char *) glGetString(GL_EXTENSIONS);
	BOOL software = renderer && strstr(renderer, "Software");
	log([NSString stringWithFormat:@"[cr] EXT_color_buffer_float = %@", (exts && strstr(exts, "EXT_color_buffer_float")) ? @"YES" : @"NO"]);
	if (software)
	{
		log(@"[cr] NOTE: Simulator GLES is a SOFTWARE renderer (not a TBDR Metal GPU). It validates depth MECHANISM +");
		log(@"[cr]       PRECISION + layering, but CANNOT measure the early-Z/HSR perf cost of fragdepth (device-only),");
		log(@"[cr]       and Phase 2 magnitudes are indicative, not device-exact. Phase 1 (float32) is the precision proof.");
	}

	glGenVertexArrays(1, &sVao);
	glGenBuffers(1, &sVbo);

	GLuint progs[CFG_COUNT] = {0,0,0};
	progs[CFG_BASELINE]  = linkProgram(kVertPlain,    kFragSolid,      @"P_BASELINE",  log);
	progs[CFG_FRAGDEPTH] = linkProgram(kVertPlain,    kFragDepthWrite, @"P_FRAGDEPTH", log);
	progs[CFG_CLIPREMAP] = linkProgram(kVertClipremap, kFragSolid,     @"P_CLIPREMAP", log);

	BOOL p1fragFiner = runPhase1Cpu(log);

	BOOL built = progs[CFG_BASELINE] && progs[CFG_FRAGDEPTH] && progs[CFG_CLIPREMAP];
	if (built) { runPhase2(progs, log); runPhase3(progs, log); }
	else { log(@"[cr] PHASE 2/3 = SKIP (a program failed to build)"); }

	// ---- machine-readable summary lines for the md5 gate (the verdict script recomputes from these) ----
	// The decisive finding: does CLIPREMAP (early-Z-preserving) recover FRAGDEPTH's precision, or only baseline's?
	const BOOL clipremapRecovers = built && (sP1Distinct[CFG_CLIPREMAP] * 2 >= sP1Distinct[CFG_FRAGDEPTH])
		&& (sP1Distinct[CFG_CLIPREMAP] > sP1Distinct[CFG_BASELINE] * 4);
	const BOOL fragdepthCleaner = built && (sP2Far[CFG_BASELINE] > 20) && (sP2Far[CFG_FRAGDEPTH] * 2 < sP2Far[CFG_BASELINE]);
	const BOOL clipremapCleaner = built && (sP2Far[CFG_BASELINE] > 20) && (sP2Far[CFG_CLIPREMAP] * 2 < sP2Far[CFG_BASELINE]);
	const BOOL layeringAll = built && sP3Bleed[CFG_BASELINE] < 512*512/100
		&& sP3Bleed[CFG_FRAGDEPTH] < 512*512/100 && sP3Bleed[CFG_CLIPREMAP] < 512*512/100;

	log([NSString stringWithFormat:@"[cr] RESULT P1_FRAGDEPTH_FINER = %@", p1fragFiner ? @"YES" : @"NO"]);
	log([NSString stringWithFormat:@"[cr] RESULT P1_CLIPREMAP_RECOVERS = %@", clipremapRecovers ? @"YES" : @"NO"]);
	log([NSString stringWithFormat:@"[cr] RESULT P2_FRAGDEPTH_CLEANER = %@", fragdepthCleaner ? @"YES" : @"NO"]);
	log([NSString stringWithFormat:@"[cr] RESULT P2_CLIPREMAP_CLEANER = %@", clipremapCleaner ? @"YES" : @"NO"]);
	log([NSString stringWithFormat:@"[cr] RESULT P3_LAYERING_ALL = %@", layeringAll ? @"YES" : @"NO"]);

	// Plain-language conclusion (also recomputed by the gate). Two mutually-exclusive headline outcomes.
	if (clipremapRecovers && clipremapCleaner)
		log(@"[cr] CONCLUSION = CLIPREMAP_WINS  (early-Z-preserving vertex remap recovers full reverse-Z precision; preferred EAGL fix)");
	else if (fragdepthCleaner)
		log(@"[cr] CONCLUSION = FRAGDEPTH_ONLY  (only the fragment-depth write fixes the z-fight; its device-only early-Z perf cost must be measured, else use ANGLE clip_control)");
	else
		log(@"[cr] CONCLUSION = NEITHER_FIXES  (unexpected; inspect the numbers)");

	log(@"[cr] ===== gpu-clipremap done =====");

	for (int i = 0; i < CFG_COUNT; i++) if (progs[i]) glDeleteProgram(progs[i]);
	glDeleteBuffers(1, &sVbo); glDeleteVertexArrays(1, &sVao);
	[EAGLContext setCurrentContext:nil];
}

@end
