/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import "B1Probe.h"
#import "B1Downport.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>

@implementation B1Probe

static NSString *readResource(NSString *name)
{
	NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:nil];
	if (!path)
	{
		return nil;
	}
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
}

static void dumpNumbered(NSString *src, void (^log)(NSString *))
{
	int n = 1;
	for (NSString *line in [src componentsSeparatedByString:@"\n"])
	{
		log([NSString stringWithFormat:@"    %d: %@", n++, line]);
	}
}

// Compile one shader; return 0 on failure. Always logs the info log (warnings matter). Dumps numbered source on
// failure (mirrors RuneLite Shader.logShaderSource).
static GLuint compileShader(GLenum type, NSString *src, NSString *label, void (^log)(NSString *))
{
	GLuint sh = glCreateShader(type);
	const char *cstr = [src UTF8String];
	glShaderSource(sh, 1, &cstr, NULL);
	glCompileShader(sh);

	GLint status = 0;
	glGetShaderiv(sh, GL_COMPILE_STATUS, &status);

	GLint logLen = 0;
	glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &logLen);
	NSString *info = @"";
	if (logLen > 1)
	{
		char *buf = malloc(logLen);
		glGetShaderInfoLog(sh, logLen, NULL, buf);
		info = [NSString stringWithUTF8String:buf];
		free(buf);
	}

	if (status != GL_TRUE)
	{
		log([NSString stringWithFormat:@"[b1] COMPILE %@ = FAIL", label]);
		log([NSString stringWithFormat:@"[b1]   infolog: %@", info]);
		dumpNumbered(src, log);
		glDeleteShader(sh);
		return 0;
	}
	log([NSString stringWithFormat:@"[b1] COMPILE %@ = OK%@", label,
		info.length ? [@" (infolog: " stringByAppendingFormat:@"%@)", info] : @""]);
	return sh;
}

// Link + validate a program from two compiled shaders. Returns 0 on any failure. Logs structured status.
static GLuint linkValidate(GLuint vs, GLuint fs, NSString *progLabel, void (^log)(NSString *))
{
	if (vs == 0 || fs == 0)
	{
		log([NSString stringWithFormat:@"[b1] %@ link=SKIP validate=SKIP (a shader failed to compile)", progLabel]);
		return 0;
	}
	GLuint prog = glCreateProgram();
	glAttachShader(prog, vs);
	glAttachShader(prog, fs);
	glLinkProgram(prog);

	GLint linked = 0;
	glGetProgramiv(prog, GL_LINK_STATUS, &linked);
	NSString *linkInfo = @"";
	GLint ll = 0; glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &ll);
	if (ll > 1) { char *b = malloc(ll); glGetProgramInfoLog(prog, ll, NULL, b); linkInfo = [NSString stringWithUTF8String:b]; free(b); }

	if (!linked)
	{
		log([NSString stringWithFormat:@"[b1] %@ link=FAIL infolog: %@", progLabel, linkInfo]);
		glDeleteProgram(prog);
		return 0;
	}

	glValidateProgram(prog);
	GLint valid = 0;
	glGetProgramiv(prog, GL_VALIDATE_STATUS, &valid);
	NSString *valInfo = @"";
	GLint vl = 0; glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &vl);
	if (vl > 1) { char *b = malloc(vl); glGetProgramInfoLog(prog, vl, NULL, b); valInfo = [NSString stringWithUTF8String:b]; free(b); }

	log([NSString stringWithFormat:@"[b1] %@ link=OK validate=%@%@", progLabel,
		valid ? @"OK" : @"FAIL",
		valInfo.length ? [@" (" stringByAppendingFormat:@"%@)", valInfo] : @""]);

	// A failed validate is reported but we still return the program; validate can be conservative pre-draw.
	return prog;
}

static void identity4(GLfloat *m)
{
	for (int i = 0; i < 16; i++) m[i] = 0.0f;
	m[0] = m[5] = m[10] = m[15] = 1.0f;
}

// Count pixels in a w*h RGBA buffer whose max(r,g,b) exceeds `thresh`.
static int countNonBlank(const unsigned char *px, int w, int h, int thresh)
{
	int n = 0;
	for (int i = 0; i < w * h; i++)
	{
		const unsigned char *p = px + i * 4;
		if (p[0] > thresh || p[1] > thresh || p[2] > thresh) n++;
	}
	return n;
}

+ (void)runWithLog:(void (^)(NSString *))log
{
	log(@"[b1] ===== B1: RuneLite gpu-plugin shaders -> GLSL ES 3.00 on native EAGL =====");

	EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
	if (!ctx)
	{
		log(@"[b1] EAGL ES3 context creation FAILED -> NO-GO (native GLES3 unavailable)");
		return;
	}
	[EAGLContext setCurrentContext:ctx];
	log([NSString stringWithFormat:@"[b1] GL_VERSION = %s", (const char *) glGetString(GL_VERSION)]);
	log([NSString stringWithFormat:@"[b1] GL_SLVERSION = %s", (const char *) glGetString(GL_SHADING_LANGUAGE_VERSION)]);

	// ---- load the assembled (real Template output) desktop-GLSL sources ----
	NSString *vertSrc = readResource(@"vert.assembled.glsl");
	NSString *fragSrc = readResource(@"frag.assembled.glsl");
	NSString *vertUiSrc = readResource(@"vertui.assembled.glsl");
	NSString *fragUiSrc = readResource(@"fragui.assembled.glsl");
	if (!vertSrc || !fragSrc || !vertUiSrc || !fragUiSrc)
	{
		log(@"[b1] MISSING assembled shader resource(s) -> NO-GO (build did not bundle them)");
		return;
	}

	// ---- downport each to GLSL ES 3.00 (the transform an iOS runtime shim would do) ----
	NSString *vertES = [B1Downport downport:vertSrc fragment:NO];
	NSString *fragES = [B1Downport downport:fragSrc fragment:YES];
	NSString *vertUiES = [B1Downport downport:vertUiSrc fragment:NO];
	NSString *fragUiES = [B1Downport downport:fragUiSrc fragment:YES];

	// persist the downported sources to Documents for evidence/inspection
	NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSDictionary *outs = @{ @"vert.es300.glsl": vertES, @"frag.es300.glsl": fragES,
		@"vertui.es300.glsl": vertUiES, @"fragui.es300.glsl": fragUiES };
	for (NSString *fn in outs)
	{
		[outs[fn] writeToFile:[docs stringByAppendingPathComponent:fn] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}

	// ---- offscreen FBO (bound BEFORE program builds so glValidateProgram has a complete draw framebuffer) ----
	const int W = 64, H = 64;
	GLuint tex = 0, fbo = 0;
	glGenTextures(1, &tex);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glGenFramebuffers(1, &fbo);
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
	glViewport(0, 0, W, H);
	unsigned char *px = malloc(W * H * 4);

	// ---- SCENE program: vert.glsl + frag.glsl ----
	GLuint vs = compileShader(GL_VERTEX_SHADER, vertES, @"scene.vert", log);
	GLuint fs = compileShader(GL_FRAGMENT_SHADER, fragES, @"scene.frag", log);
	GLuint sceneProg = linkValidate(vs, fs, @"SCENE_PROGRAM", log);

	// ---- UI program: vertui.glsl + fragui.glsl ----
	GLuint uvs = compileShader(GL_VERTEX_SHADER, vertUiES, @"ui.vert", log);
	GLuint ufs = compileShader(GL_FRAGMENT_SHADER, fragUiES, @"ui.frag", log);
	GLuint uiProg = linkValidate(uvs, ufs, @"UI_PROGRAM", log);

	// ============ UI render proof ============
	if (uiProg)
	{
		while (glGetError() != GL_NO_ERROR) {}
		glClearColor(0, 0, 0, 1);
		glClear(GL_COLOR_BUFFER_BIT);
		glUseProgram(uiProg);

		// 2x2 source texture, solid (40,80,160,255)
		GLuint srcTex = 0; glGenTextures(1, &srcTex); glBindTexture(GL_TEXTURE_2D, srcTex);
		unsigned char texel[2 * 2 * 4];
		for (int i = 0; i < 4; i++) { texel[i*4+0]=40; texel[i*4+1]=80; texel[i*4+2]=160; texel[i*4+3]=255; }
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, texel);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, srcTex);
		glUniform1i(glGetUniformLocation(uiProg, "tex"), 0);
		glUniform2i(glGetUniformLocation(uiProg, "sourceDimensions"), 2, 2);
		glUniform2i(glGetUniformLocation(uiProg, "targetDimensions"), W, H);
		glUniform4f(glGetUniformLocation(uiProg, "alphaOverlay"), 0, 0, 0, 0);

		// full-screen quad
		GLfloat quad[] = {
			// aPos.xyz           aTexCoord.uv
			-1,-1,0,  0,0,
			 1,-1,0,  1,0,
			 1, 1,0,  1,1,
			-1,-1,0,  0,0,
			 1, 1,0,  1,1,
			-1, 1,0,  0,1,
		};
		GLuint vao=0, vbo=0;
		glGenVertexArrays(1, &vao); glBindVertexArray(vao);
		glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
		glEnableVertexAttribArray(0);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat), (void *)0);
		glEnableVertexAttribArray(1);
		glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(GLfloat), (void *)(3 * sizeof(GLfloat)));
		glDrawArrays(GL_TRIANGLES, 0, 6);
		glFinish();

		GLenum gerr = glGetError();
		glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
		unsigned char *c = px + (H/2 * W + W/2) * 4;
		int nb = countNonBlank(px, W, H, 8);
		BOOL ok = (gerr == GL_NO_ERROR) && c[0] > 30 && c[0] < 50 && c[1] > 70 && c[1] < 90 && c[2] > 150 && c[2] < 170;
		log([NSString stringWithFormat:@"[b1] UI_RENDER glerr=0x%04x center=(%d,%d,%d,%d) expect~(40,80,160) nonblank=%d -> %@",
			gerr, c[0], c[1], c[2], c[3], nb, ok ? @"OK" : @"FAIL"]);
		glDeleteBuffers(1, &vbo); glDeleteVertexArrays(1, &vao); glDeleteTextures(1, &srcTex);
	}
	else
	{
		log(@"[b1] UI_RENDER = SKIP (program did not build)");
	}

	// ============ SCENE render proof ============
	if (sceneProg)
	{
		while (glGetError() != GL_NO_ERROR) {}
		glClearColor(0, 0, 0, 1);
		glClear(GL_COLOR_BUFFER_BIT);
		glUseProgram(sceneProg);

		// identity transforms => gl_Position = vec4(vertf + base, 1)
		GLfloat I[16]; identity4(I);
		glUniformMatrix4fv(glGetUniformLocation(sceneProg, "worldProj"), 1, GL_FALSE, I);
		glUniformMatrix4fv(glGetUniformLocation(sceneProg, "entityProj"), 1, GL_FALSE, I);
		glUniform4i(glGetUniformLocation(sceneProg, "entityTint"), 0, 0, 0, 0);
		glUniform1f(glGetUniformLocation(sceneProg, "brightness"), 1.0f);
		glUniform1i(glGetUniformLocation(sceneProg, "useFog"), 0);
		glUniform1i(glGetUniformLocation(sceneProg, "fogDepth"), 0);
		glUniform1i(glGetUniformLocation(sceneProg, "drawDistance"), 0);
		glUniform1i(glGetUniformLocation(sceneProg, "expandedMapLoadingChunks"), 0);
		glUniform3i(glGetUniformLocation(sceneProg, "base"), 0, 0, 0);
		glUniform1i(glGetUniformLocation(sceneProg, "tick"), 0);
		glUniform1f(glGetUniformLocation(sceneProg, "smoothBanding"), 0.0f);
		glUniform4f(glGetUniformLocation(sceneProg, "fogColor"), 0, 0, 0, 1);
		glUniform1f(glGetUniformLocation(sceneProg, "textureLightMode"), 0.0f);
		glUniform1i(glGetUniformLocation(sceneProg, "textures"), 0);

		// std140 uniform block `uniforms` { float cameraYaw,Pitch,X,Y,Z; } — bind a zeroed buffer to point 0
		GLuint ubo = 0; glGenBuffers(1, &ubo); glBindBuffer(GL_UNIFORM_BUFFER, ubo);
		GLfloat camera[5] = {0,0,0,0,0};
		glBufferData(GL_UNIFORM_BUFFER, sizeof(camera), camera, GL_STATIC_DRAW);
		GLuint blockIdx = glGetUniformBlockIndex(sceneProg, "uniforms");
		if (blockIdx != GL_INVALID_INDEX) { glUniformBlockBinding(sceneProg, blockIdx, 0); }
		glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);

		// a 1x1x1 sampler2DArray so the `textures` sampler is complete (not sampled at tex.x=0, but bound)
		GLuint arrTex = 0; glGenTextures(1, &arrTex); glBindTexture(GL_TEXTURE_2D_ARRAY, arrTex);
		unsigned char one[4] = {255,255,255,255};
		glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_RGBA, 1, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, one);
		glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D_ARRAY, arrTex);

		// one opaque, non-textured triangle. abhsl = (a<<24)|(bias<<16)|(hue<<10)|(sat<<7)|lum
		// a=0 (opaque, fColor.a = 1-a), hue=32 sat=4 lum=80 -> a mid colour; tex.x=0 -> non-textured path.
		GLint abhsl = (0 << 24) | (0 << 16) | (32 << 10) | (4 << 7) | 80;
		struct { GLfloat x,y,z; GLint abhsl; GLint tx,ty,tz,tw; } verts[3] = {
			{-0.6f,-0.6f,0.0f, abhsl, 0,0,0,0},
			{ 0.6f,-0.6f,0.0f, abhsl, 0,0,0,0},
			{ 0.0f, 0.6f,0.0f, abhsl, 0,0,0,0},
		};
		GLuint vao=0, vbo=0;
		glGenVertexArrays(1, &vao); glBindVertexArray(vao);
		glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
		GLsizei stride = sizeof(verts[0]);
		glEnableVertexAttribArray(0);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride, (void *)0);                 // vertf
		glEnableVertexAttribArray(1);
		glVertexAttribIPointer(1, 1, GL_INT, stride, (void *)(offsetof(__typeof__(verts[0]), abhsl))); // abhsl
		glEnableVertexAttribArray(2);
		glVertexAttribIPointer(2, 4, GL_INT, stride, (void *)(offsetof(__typeof__(verts[0]), tx)));     // tex ivec4
		glDrawArrays(GL_TRIANGLES, 0, 3);
		glFinish();

		GLenum gerr = glGetError();
		glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
		int nb = countNonBlank(px, W, H, 8);
		unsigned char *c = px + (H/2 * W + W/2) * 4;
		BOOL ok = (gerr == GL_NO_ERROR) && nb > 50; // a filled triangle covers a good chunk of the 64x64
		log([NSString stringWithFormat:@"[b1] SCENE_RENDER glerr=0x%04x center=(%d,%d,%d,%d) nonblank=%d -> %@",
			gerr, c[0], c[1], c[2], c[3], nb, ok ? @"OK" : @"FAIL"]);
		glDeleteBuffers(1, &vbo); glDeleteVertexArrays(1, &vao); glDeleteTextures(1, &arrTex); glDeleteBuffers(1, &ubo);
	}
	else
	{
		log(@"[b1] SCENE_RENDER = SKIP (program did not build)");
	}

	free(px);
	glDeleteFramebuffers(1, &fbo);
	glDeleteTextures(1, &tex);

	// ---- one-line machine verdict tuple for the md5 gate ----
	BOOL sceneOk = (sceneProg != 0);
	BOOL uiOk = (uiProg != 0);
	log([NSString stringWithFormat:@"[b1] VERDICT scene_program=%@ ui_program=%@",
		sceneOk ? @"BUILT" : @"FAILED", uiOk ? @"BUILT" : @"FAILED"]);
	log(@"[b1] ===== B1 done =====");
	[EAGLContext setCurrentContext:nil];
}

@end
