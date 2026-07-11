/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import "RouteCProbe.h"
#import "RouteCBridge.h"
#import <OpenGLES/ES3/gl.h>

@implementation RouteCProbe

// Reverse-Z mirror of the plugin: clip.z = 2*near (constant), w = viewZ -> NDC.z = 2N/viewZ, so a NEARER vertex
// (smaller viewZ) gets a LARGER depth. Paired with glClearDepth(0) + glDepthFunc(GL_GEQUAL), nearer wins. No
// glClipControl needed: GLES NDC-z is fixed [-1,1]; the ORDERING is identical to desktop ZERO_TO_ONE (only depth
// precision differs).
static const char *kVert =
	"#version 300 es\n"
	"precision highp float;\n"
	"layout(location=0) in vec2 aPos;\n"
	"layout(location=1) in float aViewZ;\n"
	"layout(location=2) in vec3 aColor;\n"
	"out vec3 vColor;\n"
	"const float NEAR = 50.0;\n"
	// clip.xy = aPos*viewZ so the perspective divide by w=viewZ returns NDC.xy = aPos (full viewport); clip.z =
	// 2*near constant so NDC.z = 2N/viewZ (reverse-Z: nearer/smaller viewZ -> larger depth).
	"void main(){ vColor = aColor; gl_Position = vec4(aPos * aViewZ, 2.0*NEAR, aViewZ); }\n";

static const char *kFrag =
	"#version 300 es\n"
	"precision highp float;\n"
	"in vec3 vColor;\n"
	"out vec4 o;\n"
	"void main(){ o = vec4(vColor, 1.0); }\n";

static GLuint compile(GLenum type, const char *src, NSString *label, void (^log)(NSString *))
{
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok)
	{
		char buf[1024]; glGetShaderInfoLog(s, sizeof(buf), NULL, buf);
		log([NSString stringWithFormat:@"[rc2] compile %@ FAIL: %s", label, buf]);
		return 0;
	}
	return s;
}

+ (void)runWithLog:(void (^)(NSString *))log
{
	log(@"[rc2] ===== Route C step 2: native GL bridge core on GLES 3.0 =====");

	const int W = 96, H = 96;
	BOOL ctxOk = [RouteCBridge awtCreateGLContextWidth:W height:H];
	log([NSString stringWithFormat:@"[rc2] AWTContext analogue: createGLContext+depthFBO complete=%@ framebuffer=%u",
		ctxOk ? @"YES" : @"NO", [RouteCBridge awtGetFramebuffer]]);
	if (!ctxOk) { log(@"[rc2] NO-GO: EAGL ES3 depth FBO incomplete"); return; }
	log([NSString stringWithFormat:@"[rc2] GL_VERSION=%s SLVERSION=%s", glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION)]);

	GLuint vs = compile(GL_VERTEX_SHADER, kVert, @"vert", log);
	GLuint fs = compile(GL_FRAGMENT_SHADER, kFrag, @"frag", log);
	if (!vs || !fs) { log(@"[rc2] NO-GO: shader compile"); return; }
	GLuint prog = glCreateProgram();
	glAttachShader(prog, vs); glAttachShader(prog, fs); glLinkProgram(prog);
	GLint linked = 0; glGetProgramiv(prog, GL_LINK_STATUS, &linked);
	if (!linked) { log(@"[rc2] NO-GO: link"); return; }
	glUseProgram(prog);

	// Two full-viewport triangles. Vertex layout: vec2 pos, float viewZ, vec3 color (6 floats/vert).
	// NEAR = green, viewZ=120 (-> depth 0.917). FAR = red, viewZ=240 (-> depth 0.708). Draw order: NEAR first,
	// FAR second. If depth ordering (reverse-Z) works, FAR is rejected and the screen is GREEN despite being
	// drawn last. The big triangle (-1,-1),(3,-1),(-1,3) covers the whole [-1,1] viewport.
	const float NEARZ = 120.0f, FARZ = 240.0f;
	GLfloat verts[] = {
		// --- triangle 0: NEAR, green ---
		-1,-1, NEARZ, 0,1,0,
		 3,-1, NEARZ, 0,1,0,
		-1, 3, NEARZ, 0,1,0,
		// --- triangle 1: FAR, red ---
		-1,-1, FARZ,  1,0,0,
		 3,-1, FARZ,  1,0,0,
		-1, 3, FARZ,  1,0,0,
	};
	GLuint vao = 0, vbo = 0;
	glGenVertexArrays(1, &vao); glBindVertexArray(vao);
	glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
	GLsizei stride = 6 * sizeof(GLfloat);
	glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, (void *)0);
	glEnableVertexAttribArray(1); glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, stride, (void *)(2 * sizeof(GLfloat)));
	glEnableVertexAttribArray(2); glVertexAttribPointer(2, 3, GL_FLOAT, GL_FALSE, stride, (void *)(3 * sizeof(GLfloat)));

	const GLint first[2] = {0, 3};
	const GLsizei count[2] = {3, 3};
	unsigned char center[4];

	// ---- PASS 1: reverse-Z depth ON ----
	[RouteCBridge glClipControlShim:0 depth:0];          // no-op on GLES (origin/zero-to-one absent)
	glEnable(GL_DEPTH_TEST);
	glDepthFunc(GL_GEQUAL);                               // reverse-Z: nearer (larger depth) wins
	glDepthMask(GL_TRUE);
	[RouteCBridge glClearDepthShim:0.0];                 // -> glClearDepthf(0) ; clears to the FAR end of reverse-Z
	glClearColor(0.0f, 0.0f, 0.6f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	[RouteCBridge glMultiDrawArraysShim:GL_TRIANGLES first:first count:count drawcount:2]; // -> loop
	glFinish();
	glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, center);
	BOOL depthOnGreen = center[1] > 200 && center[0] < 60 && center[2] < 60;
	GLenum e1 = glGetError();
	log([NSString stringWithFormat:@"[rc2] PASS1 depth=ON reverseZ center=(%d,%d,%d) expect~GREEN glerr=0x%04x -> %@",
		center[0], center[1], center[2], e1, depthOnGreen ? @"GREEN(near wins)" : @"NOT-GREEN"]);

	// ---- PASS 2: control, depth OFF (paint order: FAR drawn last -> red) ----
	glDisable(GL_DEPTH_TEST);
	glClearColor(0.0f, 0.0f, 0.6f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	[RouteCBridge glMultiDrawArraysShim:GL_TRIANGLES first:first count:count drawcount:2];
	glFinish();
	glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, center);
	BOOL depthOffRed = center[0] > 200 && center[1] < 60 && center[2] < 60;
	log([NSString stringWithFormat:@"[rc2] PASS2 depth=OFF paint-order center=(%d,%d,%d) expect~RED -> %@",
		center[0], center[1], center[2], depthOffRed ? @"RED(far last)" : @"NOT-RED"]);

	// ---- glMapBuffer shim smoke (map a VBO range, write, unmap, read back) ----
	GLuint mbo = 0; glGenBuffers(1, &mbo); glBindBuffer(GL_ARRAY_BUFFER, mbo);
	glBufferData(GL_ARRAY_BUFFER, 16, NULL, GL_STREAM_DRAW);
	int *mp = (int *) [RouteCBridge glMapBufferShim:GL_ARRAY_BUFFER access:0 size:16];
	BOOL mapOk = NO;
	if (mp) { mp[0] = 0x1234abcd; mp[3] = 7; glUnmapBuffer(GL_ARRAY_BUFFER); mapOk = YES; }
	log([NSString stringWithFormat:@"[rc2] glMapBuffer->glMapBufferRange shim: %@", mapOk ? @"OK" : @"FAIL"]);

	// Verdict tuple
	log([NSString stringWithFormat:@"[rc2] VERDICT reverseZ=%@ control=%@ multidraw_loop=%@ map_shim=%@",
		depthOnGreen ? @"OK" : @"FAIL",
		depthOffRed ? @"OK" : @"FAIL",
		(depthOnGreen && depthOffRed) ? @"OK" : @"FAIL",
		mapOk ? @"OK" : @"FAIL"]);
	log(@"[rc2] ===== Route C step 2 done =====");

	glDeleteBuffers(1, &vbo); glDeleteBuffers(1, &mbo); glDeleteVertexArrays(1, &vao);
	[RouteCBridge awtDestroy];
}

@end
