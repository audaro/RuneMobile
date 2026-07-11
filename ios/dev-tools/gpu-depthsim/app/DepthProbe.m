/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 *
 * ----------------------------------------------------------------------------------------------------------------
 * Controlled iOS-GLES depth-precision repro for the GPU "Route C" river z-fighting artifact.
 *
 * The base gpu plugin uses a REVERSE-Z projection (Mat4.projection): clip.z = 2*near = 100 (CONSTANT),
 * clip.w = viewZ, so NDC.z = clip.z/clip.w = 100/viewZ in (0,1] (near=1, far->0), paired with
 * glDepthFunc(GL_GREATER) + glClearDepthf(0). On DESKTOP the plugin also calls glClipControl(ZERO_TO_ONE), so the
 * window depth is window_z = NDC.z = 100/viewZ directly -> full float32 precision at the far plane.
 *
 * iOS GLES has NO glClipControl, so the fixed-function viewport transform applies window_z = (NDC.z + 1)/2, which
 * (a) uses only the upper HALF of [0,1] and (b) adds the small reverse-Z value to 1.0 -> the far plane collapses to
 * window_z ~= 0.5..0.51, a low-precision region of float32. That is the z-fight.
 *
 * THE FIX UNDER TEST ("fragdepth" in the bridge): write the depth in the fragment shader as
 *     gl_FragDepth = vClipDepth * gl_FragCoord.w      (vClipDepth = clip.z carried FLAT; gl_FragCoord.w = 1/clip.w)
 *                  = clip.z / clip.w = NDC.z = 100/viewZ
 * i.e. exactly the desktop glClipControl values, at full float32 precision, bypassing the lossy (NDC.z+1)/2.
 *
 * This probe answers, off-device on the iOS Simulator GLES:
 *   PHASE 1 — does the fix carry finer depth precision at distance, in the float32 a true-32F depth buffer stores?
 *             (Computed in CPU float32 — renderer-independent, and the DEVICE depth buffer is a confirmed true 32F,
 *             so this is the device-relevant precision ground truth. See the GL_RENDERER caveat the probe logs:
 *             the Simulator's GLES is a SOFTWARE renderer with no EXT_color_buffer_float, so an on-GPU float
 *             readback can't run here and would not represent the device GPU's precision anyway.)
 *   PHASE 2 — is gl_FragDepth HONORED, and does it resolve a real z-fight? (a real DEPTH_COMPONENT32F buffer +
 *             GL_GREATER + two near-coplanar intersecting planes at distance; count z-fight contamination pixels,
 *             control vs fix, on the actual GLES pipeline.)
 * ----------------------------------------------------------------------------------------------------------------
 */
#import "DepthProbe.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <math.h>

@implementation DepthProbe

// ----- the plugin's reverse-Z constant: clip.z = 2 * near, near = 50 (Mat4.projection(w,h,50)) -----
static const float CLIP_Z = 100.0f;

// =================================================================================================================
//  PHASE 1 depth model, in genuine float32 (the precision a true-32F depth buffer — what the DEVICE has — stores).
//  `volatile` forces each step to round to float32 (no double promotion, no FMA contraction), faithfully modelling
//  the GPU's highp float depth path.
// =================================================================================================================
static float controlDepth(float viewZ)   // iOS default: window_z = (NDC.z + 1)/2
{
	volatile float ndcz = CLIP_Z / viewZ;       // 100/viewZ
	volatile float plus = ndcz + 1.0f;          // the precision-killing add-to-1.0
	volatile float half = plus * 0.5f;
	return half;
}
static float fixDepth(float viewZ)        // the fix / desktop: window_z = NDC.z directly
{
	volatile float ndcz = CLIP_Z / viewZ;
	return ndcz;
}

// =================================================================================================================
//  shaders (GLSL ES 3.00) — faithful to the plugin's reverse-Z. The vertex shader reconstructs the EXACT clip
//  coords the plugin's projection produces: clip = (ndc.xy * viewZ, CLIP_Z, viewZ). After perspective divide:
//  NDC = (ndc.xy, CLIP_Z/viewZ, 1); the fixed-function window_z = (NDC.z + 1)/2 (control). clip.z is carried as a
//  FLAT varying (it is constant per primitive here) so the fix's gl_FragDepth = clip.z * gl_FragCoord.w is exact.
// =================================================================================================================
static NSString *const kVert =
	@"#version 300 es\n"
	 "precision highp float;\n"
	 "precision highp int;\n"
	 "layout(location = 0) in vec2 aNdc;\n"     // target NDC xy in [-1,1]
	 "layout(location = 1) in float aViewZ;\n"  // per-vertex clip.w (the depth)
	 "uniform float uClipZ;\n"                  // clip.z = 2*near (constant per draw)
	 "flat out float vClipDepth;\n"
	 "void main() {\n"
	 "  gl_Position = vec4(aNdc * aViewZ, uClipZ, aViewZ);\n"
	 "  vClipDepth = uClipZ;\n"
	 "}\n";

// control: solid colour, default (fixed-function) depth = (NDC.z+1)/2.
static NSString *const kFragControl =
	@"#version 300 es\n"
	 "precision highp float;\n"
	 "uniform vec3 uColor;\n"
	 "out vec4 FragColor;\n"
	 "void main() { FragColor = vec4(uColor, 1.0); }\n";

// fix: solid colour, depth written via gl_FragDepth = clip.z/clip.w = NDC.z (the fix under test).
static NSString *const kFragFix =
	@"#version 300 es\n"
	 "precision highp float;\n"
	 "uniform vec3 uColor;\n"
	 "flat in float vClipDepth;\n"
	 "out vec4 FragColor;\n"
	 "void main() { FragColor = vec4(uColor, 1.0); gl_FragDepth = vClipDepth * gl_FragCoord.w; }\n";

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
		log([NSString stringWithFormat:@"[ds] COMPILE %@ = FAIL: %s", label, b ? b : "(no log)"]);
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
		log([NSString stringWithFormat:@"[ds] LINK %@ = FAIL: %s", label, b ? b : "(no log)"]);
		free(b); glDeleteProgram(prog); return 0;
	}
	log([NSString stringWithFormat:@"[ds] PROGRAM %@ = OK", label]);
	return prog;
}

// Upload + draw a screen-covering quad (2 tris) whose four corners carry the given viewZ values
// (order: bottom-left, bottom-right, top-right, top-left; bottom-left is NDC (-1,-1) = glReadPixels row 0).
static GLuint sVao = 0, sVbo = 0;
static void drawCoveringQuad(float vzBL, float vzBR, float vzTR, float vzTL)
{
	const float v[] = {
		-1.f, -1.f, vzBL,   1.f, -1.f, vzBR,   1.f, 1.f, vzTR,   // tri 1: BL BR TR
		-1.f, -1.f, vzBL,   1.f,  1.f, vzTR,  -1.f, 1.f, vzTL,   // tri 2: BL TR TL
	};
	glBindVertexArray(sVao);
	glBindBuffer(GL_ARRAY_BUFFER, sVbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STREAM_DRAW);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 3 * sizeof(float), (void *)0);
	glEnableVertexAttribArray(1);
	glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 3 * sizeof(float), (void *)(2 * sizeof(float)));
	glDrawArrays(GL_TRIANGLES, 0, 6);
}

// =================================================================================================================
//  PHASE 1 — depth precision in float32 (the storage the DEVICE's confirmed-32F depth buffer uses).
//  Over a fixed viewZ window at the far plane, sampled at the float32 viewZ resolution, count how many DISTINCT
//  stored depth values each path produces. More distinct values = finer precision = fewer surfaces collapsing onto
//  the same depth (= less z-fighting). The fix should preserve far more distinctions because its values live near 0
//  (NDC.z ~= 0.0167), where float32 has ~30-60x more mantissa precision than control's ~0.5083.
// =================================================================================================================
static BOOL runPhase1Cpu(void (^log)(NSString *))
{
	log(@"[ds] ===== PHASE 1: depth precision in float32 (CPU; models the device's confirmed-32F depth buffer) =====");
	log(@"[ds]   (on-GPU float readback is unavailable here: GL_RENDERER is a SOFTWARE renderer with no");
	log(@"[ds]    EXT_color_buffer_float; a software-renderer precision number would not represent the device GPU.");
	log(@"[ds]    The mechanism is pure float32 arithmetic ((NDC.z+1)/2 vs NDC.z); this computes it at float32.)");

	const float sweep[] = {200.f, 500.f, 1000.f, 2000.f, 4000.f, 6000.f, 9000.f};
	for (size_t i = 0; i < sizeof(sweep) / sizeof(sweep[0]); i++)
	{
		const float vz = sweep[i];
		log([NSString stringWithFormat:@"[ds]   viewZ=%6.0f  control window_z=(NDC.z+1)/2=%.9g   fix window_z=NDC.z=%.9g",
			vz, controlDepth(vz), fixDepth(vz)]);
	}

	// distinct-depth count over a window at the far plane, walking float32 viewZ values one ULP at a time.
	const float Zfar = 6000.f;
	const int N = 100000;
	float z = Zfar;
	float prevC = controlDepth(z), prevF = fixDepth(z);
	int distinctC = 1, distinctF = 1;
	for (int i = 1; i < N; i++)
	{
		z = nextafterf(z, INFINITY);
		const float c = controlDepth(z), f = fixDepth(z);
		if (c != prevC) { distinctC++; prevC = c; }
		if (f != prevF) { distinctF++; prevF = f; }
	}
	const float covered = z - Zfar;   // viewZ units spanned by N float32 steps at Zfar
	log([NSString stringWithFormat:@"[ds] PHASE 1 far-plane precision: over %.4g viewZ units at Zfar=%.0f (%d float32 samples):",
		covered, Zfar, N]);
	log([NSString stringWithFormat:@"[ds]   control distinct depths=%d  (avg %.5g units per resolvable step)",
		distinctC, covered / (float) distinctC]);
	log([NSString stringWithFormat:@"[ds]   fix     distinct depths=%d  (avg %.6g units per resolvable step)",
		distinctF, covered / (float) distinctF]);
	const float ratio = (float) distinctF / (float) distinctC;
	log([NSString stringWithFormat:@"[ds]   fix/control precision ratio = %.1fx", ratio]);

	const BOOL finer = distinctF > distinctC * 2;   // fix meaningfully (>2x) finer
	log([NSString stringWithFormat:@"[ds] P1_FIX_FINER = %@  (control=%d fix=%d distinct depth values)",
		finer ? @"YES" : @"NO", distinctC, distinctF]);
	return finer;
}

// =================================================================================================================
//  PHASE 2 — a REAL z-fight on a real DEPTH_COMPONENT32F buffer (the actual GLES pipeline; proves gl_FragDepth is
//  honored and orders correctly).
//  Two screen-covering planes at distance: A (blue) is flat at viewZ = Zfar; B (red, drawn second) is the SAME
//  plane tilted by `slope` so the two COINCIDE at screen center (ndc.y = 0) and separate linearly: above center B
//  is farther (A should win = blue), below center B is nearer (B should win = red). The analytic image is a clean
//  blue-over-red split at the center row. Z-FIGHTING shows as the "wrong" colour bleeding across a band near the
//  center whose WIDTH is set by depth precision (and, in extreme collapse, the second-drawn surface taking over
//  the whole frame — the device's "dark surface takes over" symptom).
//  Metric: contamination = (blue pixels in the bottom half, where red should win) + (red pixels in the top half).
// =================================================================================================================
static int runPhase2Config(GLuint prog, GLint locClipZ, GLint locColor, float Zfar, float slope,
	int W, int H, unsigned char *px, void (^log)(NSString *), NSString *modeTag, NSString *cfgTag)
{
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_GREATER);          // reverse-Z: nearer = larger depth, kept by GREATER
	glDepthMask(GL_TRUE);
	glClearDepthf(0.f);               // far = 0
	glViewport(0, 0, W, H);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glUseProgram(prog);
	glUniform1f(locClipZ, CLIP_Z);

	// A — blue, flat at Zfar.
	glUniform3f(locColor, 0.f, 0.f, 1.f);
	drawCoveringQuad(Zfar, Zfar, Zfar, Zfar);
	// B — red, tilted: bottom corners (ndc.y=-1) nearer, top corners (ndc.y=+1) farther; equal to A at center.
	glUniform3f(locColor, 1.f, 0.f, 0.f);
	drawCoveringQuad(Zfar - slope, Zfar - slope, Zfar + slope, Zfar + slope);

	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);

	// glReadPixels origin is bottom-left: row 0 = ndc.y = -1 (B should win = red). Top half = A should win = blue.
	int bottomBlue = 0, topRed = 0;
	for (int y = 0; y < H; y++)
	{
		const BOOL bottom = (y < H / 2);
		for (int x = 0; x < W; x++)
		{
			const unsigned char *p = px + ((size_t)y * W + x) * 4;
			const BOOL isBlue = p[2] > p[0];
			const BOOL isRed  = p[0] > p[2];
			if (bottom && isBlue) { bottomBlue++; }   // blue bleeding into red territory (the z-fight)
			if (!bottom && isRed) { topRed++; }        // red bleeding into blue territory
		}
	}
	const int contamination = bottomBlue + topRed;
	log([NSString stringWithFormat:@"[ds]   cfg=%@ Zfar=%.0f slope=%g mode=%@ contamination=%d (bottomBlue=%d topRed=%d of %d px)",
		cfgTag, Zfar, slope, modeTag, contamination, bottomBlue, topRed, W * H]);
	return contamination;
}

// returns YES if, at the FAR config, the fix produces substantially less contamination than control.
// Also reports HONORED — whether gl_FragDepth changed the GLES output at all (control vs fix differ).
static BOOL runPhase2(GLuint progControl, GLuint progFix, BOOL *honoredOut, void (^log)(NSString *))
{
	log(@"[ds] ===== PHASE 2: real z-fight on DEPTH_COMPONENT32F (two near-coplanar intersecting planes) =====");

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
	glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
		GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE, &depthBits);
	log([NSString stringWithFormat:@"[ds] PHASE 2 fbo status=0x%04x depth_attach_bits=%d (requested DEPTH_COMPONENT32F)",
		st, depthBits]);
	if (st != GL_FRAMEBUFFER_COMPLETE)
	{
		log(@"[ds] PHASE 2 fbo INCOMPLETE -> SKIP");
		glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &color); glDeleteTextures(1, &depth);
		*honoredOut = NO;
		return NO;
	}

	GLint locClipZC = glGetUniformLocation(progControl, "uClipZ");
	GLint locColorC = glGetUniformLocation(progControl, "uColor");
	GLint locClipZF = glGetUniformLocation(progFix, "uClipZ");
	GLint locColorF = glGetUniformLocation(progFix, "uColor");

	unsigned char *px = malloc((size_t)W * H * 4);

	// NEAR config: precision is least stressed -> smaller bands (sanity: the effect is distance-driven).
	const float slope = 0.5f;
	int nearC = runPhase2Config(progControl, locClipZC, locColorC, 600.f, slope, W, H, px, log, @"control", @"NEAR");
	int nearF = runPhase2Config(progFix, locClipZF, locColorF, 600.f, slope, W, H, px, log, @"fix", @"NEAR");

	// FAR config: ~max OSRS draw distance (50 tiles * 128), where the (NDC.z+1)/2 collapse bites.
	int farC = runPhase2Config(progControl, locClipZC, locColorC, 6000.f, slope, W, H, px, log, @"control", @"FAR");
	int farF = runPhase2Config(progFix, locClipZF, locColorF, 6000.f, slope, W, H, px, log, @"fix", @"FAR");

	// VERYFAR config: deeper collapse still.
	int vfarC = runPhase2Config(progControl, locClipZC, locColorC, 9000.f, slope, W, H, px, log, @"control", @"VERYFAR");
	int vfarF = runPhase2Config(progFix, locClipZF, locColorF, 9000.f, slope, W, H, px, log, @"fix", @"VERYFAR");

	free(px);
	glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &color); glDeleteTextures(1, &depth);

	log([NSString stringWithFormat:@"[ds] PHASE 2 summary: NEAR control=%d fix=%d | FAR control=%d fix=%d | VERYFAR control=%d fix=%d",
		nearC, nearF, farC, farF, vfarC, vfarF]);

	// gl_FragDepth is HONORED iff writing it changed the GLES output anywhere (fix != control at some config).
	const BOOL honored = (farC != farF) || (vfarC != vfarF) || (nearC != nearF);
	log([NSString stringWithFormat:@"[ds] FRAGDEPTH_HONORED = %@  (gl_FragDepth changed the GLES depth result)",
		honored ? @"YES" : @"NO"]);
	*honoredOut = honored;

	// fix is "cleaner" iff at FAR it cuts contamination by at least half AND ends materially below control.
	const BOOL cleaner = (farC > 20) && (farF * 2 < farC);
	log([NSString stringWithFormat:@"[ds] P2_FIX_CLEANER = %@  (FAR control=%d fix=%d)", cleaner ? @"YES" : @"NO", farC, farF]);
	return cleaner;
}

// =================================================================================================================
//  PHASE 3 — coplanar depth-BIAS layering. The base plugin layers coplanar surfaces (floor decorations, overlays)
//  with a per-face bias: screenPos.z += bias/128 -> clip.z = 100 + bias/128. The fix carries clip.z as the depth,
//  so it MUST preserve that layering (this is the most likely way the fix could break the scene on-device, since the
//  earlier device run reported "broad depth-ordering planes"). Two FULLY coplanar quads at the same far viewZ: floor
//  (blue, clip.z=100) drawn first, decoration (red, clip.z=100+bias/128) drawn second with GL_GREATER. The
//  decoration's larger clip.z must keep it on top everywhere; layering FAILS wherever the floor (blue) bleeds through.
// =================================================================================================================
static int runPhase3Config(GLuint prog, GLint locClipZ, GLint locColor, float Zfar, float biasUnits,
	int W, int H, unsigned char *px, void (^log)(NSString *), NSString *modeTag)
{
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_GREATER);
	glDepthMask(GL_TRUE);
	glClearDepthf(0.f);
	glViewport(0, 0, W, H);
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glUseProgram(prog);

	// floor — blue, clip.z = 100 (bias 0), flat at Zfar.
	glUniform1f(locClipZ, CLIP_Z);
	glUniform3f(locColor, 0.f, 0.f, 1.f);
	drawCoveringQuad(Zfar, Zfar, Zfar, Zfar);
	// decoration — red, clip.z = 100 + bias/128, fully coplanar with the floor; must win everywhere.
	glUniform1f(locClipZ, CLIP_Z + biasUnits / 128.f);
	glUniform3f(locColor, 1.f, 0.f, 0.f);
	drawCoveringQuad(Zfar, Zfar, Zfar, Zfar);

	glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	int floorBleed = 0;   // blue pixels = floor showing through = layering broken
	for (int i = 0; i < W * H; i++)
	{
		const unsigned char *p = px + (size_t)i * 4;
		if (p[2] > p[0]) { floorBleed++; }
	}
	log([NSString stringWithFormat:@"[ds]   bias=%g/128 Zfar=%.0f mode=%@ floor_bleed=%d of %d px (0 = layering intact)",
		biasUnits, Zfar, modeTag, floorBleed, W * H]);
	return floorBleed;
}

// returns YES if the fix keeps the coplanar bias layering intact at distance (decoration stays on top).
static BOOL runPhase3(GLuint progControl, GLuint progFix, void (^log)(NSString *))
{
	log(@"[ds] ===== PHASE 3: coplanar depth-bias layering (does gl_FragDepth preserve decorations-on-floors?) =====");
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
		log(@"[ds] PHASE 3 fbo INCOMPLETE -> SKIP");
		glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &color); glDeleteTextures(1, &depth);
		return NO;
	}
	GLint locClipZC = glGetUniformLocation(progControl, "uClipZ"), locColorC = glGetUniformLocation(progControl, "uColor");
	GLint locClipZF = glGetUniformLocation(progFix, "uClipZ"), locColorF = glGetUniformLocation(progFix, "uColor");
	unsigned char *px = malloc((size_t)W * H * 4);

	// bias=4/128 at the far plane (a representative small layer offset).
	int c = runPhase3Config(progControl, locClipZC, locColorC, 6000.f, 4.f, W, H, px, log, @"control");
	int f = runPhase3Config(progFix, locClipZF, locColorF, 6000.f, 4.f, W, H, px, log, @"fix");

	free(px);
	glDeleteFramebuffers(1, &fbo); glDeleteTextures(1, &color); glDeleteTextures(1, &depth);

	// layering preserved iff the fix shows essentially no floor bleed-through (< 1% of pixels).
	const BOOL preserved = (f < W * H / 100);
	log([NSString stringWithFormat:@"[ds] P3_FIX_PRESERVES_LAYERING = %@  (control floor_bleed=%d  fix floor_bleed=%d)",
		preserved ? @"YES" : @"NO", c, f]);
	return preserved;
}

+ (void)runWithLog:(void (^)(NSString *))log
{
	log(@"[ds] ===== gpu-depthsim: gl_FragDepth reverse-Z vs (NDC.z+1)/2 half-range, on iOS Simulator GLES =====");

	EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
	if (!ctx) { log(@"[ds] EAGL ES3 context creation FAILED -> NO-GO"); return; }
	[EAGLContext setCurrentContext:ctx];
	const char *renderer = (const char *) glGetString(GL_RENDERER);
	log([NSString stringWithFormat:@"[ds] GL_VERSION = %s", (const char *) glGetString(GL_VERSION)]);
	log([NSString stringWithFormat:@"[ds] GL_SLVERSION = %s", (const char *) glGetString(GL_SHADING_LANGUAGE_VERSION)]);
	log([NSString stringWithFormat:@"[ds] GL_RENDERER = %s", renderer]);
	const char *exts = (const char *) glGetString(GL_EXTENSIONS);
	BOOL software = renderer && strstr(renderer, "Software");
	log([NSString stringWithFormat:@"[ds] EXT_color_buffer_float = %@",
		(exts && strstr(exts, "EXT_color_buffer_float")) ? @"YES" : @"NO"]);
	if (software)
	{
		log(@"[ds] NOTE: Simulator GLES is a SOFTWARE renderer (not the Metal GPU). It reproduces the depth-collapse");
		log(@"[ds]       z-fight and HONORS gl_FragDepth, so it validates the fix's mechanism + correctness, but its");
		log(@"[ds]       absolute precision is NOT the device GPU's. Phase 1 (float32, = device's 32F buffer) is the");
		log(@"[ds]       device-relevant precision proof; Phase 2 magnitudes are indicative, not device-exact.");
	}

	glGenVertexArrays(1, &sVao);
	glGenBuffers(1, &sVbo);

	GLuint pc = linkProgram(kVert, kFragControl, @"P_CONTROL", log);
	GLuint pf = linkProgram(kVert, kFragFix, @"P_FIX", log);

	BOOL p1finer = runPhase1Cpu(log);

	BOOL p2cleaner = NO, honored = NO, p3preserved = NO;
	if (pc && pf)
	{
		p2cleaner = runPhase2(pc, pf, &honored, log);
		p3preserved = runPhase3(pc, pf, log);
	}
	else { log(@"[ds] PHASE 2/3 = SKIP (programs failed to build)"); }

	// ---- one-line machine verdict for the md5 gate ----
	// GREEN = gl_FragDepth is honored by this GLES driver AND it (P1) carries finer float32 depth precision at
	// distance, (P2) substantially reduces the real z-fight, and (P3) preserves the plugin's coplanar bias layering.
	// (Confidence is bounded by the SOFTWARE-renderer caveat above; a single device confirmation on the river band
	// is still warranted — see the findings doc.)
	const BOOL resolves = honored && p1finer && p2cleaner && p3preserved;
	log([NSString stringWithFormat:@"[ds] VERDICT fragdepth_resolves_zfight = %@  (honored=%@ p1_fix_finer=%@ p2_fix_cleaner=%@ p3_layering=%@)",
		resolves ? @"YES" : @"NO", honored ? @"YES" : @"NO", p1finer ? @"YES" : @"NO", p2cleaner ? @"YES" : @"NO",
		p3preserved ? @"YES" : @"NO"]);
	log(@"[ds] ===== gpu-depthsim done =====");

	glDeleteProgram(pc); glDeleteProgram(pf);
	glDeleteBuffers(1, &sVbo); glDeleteVertexArrays(1, &sVao);
	[EAGLContext setCurrentContext:nil];
}

@end
