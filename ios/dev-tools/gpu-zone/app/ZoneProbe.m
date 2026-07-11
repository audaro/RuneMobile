/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import "ZoneProbe.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>

@implementation ZoneProbe

static void dumpNumbered(NSString *src, void (^log)(NSString *))
{
	int n = 1;
	for (NSString *line in [src componentsSeparatedByString:@"\n"])
		log([NSString stringWithFormat:@"    %d: %@", n++, line]);
}

// Infer the GL shader stage from the assembled filename convention `<name>.<stage>.assembled.glsl`.
static GLenum stageForName(NSString *name)
{
	if ([name containsString:@".vert."]) return GL_VERTEX_SHADER;
	if ([name containsString:@".frag."]) return GL_FRAGMENT_SHADER;
	return 0;   // geometry/compute are not part of the zone path — skipped
}

// Compile one shader; return the shader object (kept for linking) or 0 on failure.
static GLuint compileOne(NSString *name, NSString *src, GLenum stage, void (^log)(NSString *))
{
	// The bundled assembled shaders are already ES 3.00 (downported at assemble time by ZoneShaderAssemble — the
	// single source of truth for the GLSL 330->ES300 rules). Compile as-is; no runtime downport here.
	GLuint sh = glCreateShader(stage);
	const char *c = [src UTF8String];
	glShaderSource(sh, 1, &c, NULL);
	glCompileShader(sh);

	GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
	GLint len = 0; glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &len);
	NSString *info = @"";
	if (len > 1) { char *b = malloc(len); glGetShaderInfoLog(sh, len, NULL, b); info = @(b); free(b); }

	if (ok != GL_TRUE)
	{
		log([NSString stringWithFormat:@"[z0] COMPILE %@ = FAIL", name]);
		log([NSString stringWithFormat:@"[z0]   infolog: %@", info]);
		dumpNumbered(src, log);
		glDeleteShader(sh);
		return 0;
	}
	log([NSString stringWithFormat:@"[z0] COMPILE %@ = OK%@", name,
		info.length ? [@" (infolog: " stringByAppendingFormat:@"%@)", info] : @""]);
	return sh;   // keep — linked below
}

// Link a vert+frag program; returns YES on GL_LINK_STATUS == TRUE. Logs the link infolog (varying-interface
// mismatches between the vertex out block and the fragment in block surface HERE, not at compile).
static BOOL linkProgram(NSString *prog, GLuint vert, GLuint frag, void (^log)(NSString *))
{
	GLuint p = glCreateProgram();
	glAttachShader(p, vert); glAttachShader(p, frag);
	glLinkProgram(p);
	GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
	GLint len = 0; glGetProgramiv(p, GL_INFO_LOG_LENGTH, &len);
	NSString *info = @"";
	if (len > 1) { char *b = malloc(len); glGetProgramInfoLog(p, len, NULL, b); info = @(b); free(b); }
	glDeleteProgram(p);
	if (ok != GL_TRUE)
	{
		log([NSString stringWithFormat:@"[z0] LINK %@ = FAIL", prog]);
		log([NSString stringWithFormat:@"[z0]   infolog: %@", info]);
		return NO;
	}
	log([NSString stringWithFormat:@"[z0] LINK %@ = OK%@", prog,
		info.length ? [@" (infolog: " stringByAppendingFormat:@"%@)", info] : @""]);
	return YES;
}

+ (void)runWithLog:(void (^)(NSString *))log
{
	EAGLContext *ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
	if (!ctx || ![EAGLContext setCurrentContext:ctx])
	{
		log(@"[z0] FAIL: could not create an EAGL ES3 context");
		return;
	}
	log([NSString stringWithFormat:@"[z0] GL_VERSION = %s", glGetString(GL_VERSION)]);
	log([NSString stringWithFormat:@"[z0] GL_SLVERSION = %s", glGetString(GL_SHADING_LANGUAGE_VERSION)]);

	NSArray<NSString *> *paths = [[NSBundle mainBundle] pathsForResourcesOfType:@"glsl" inDirectory:nil];
	NSArray<NSString *> *assembled = [paths filteredArrayUsingPredicate:
		[NSPredicate predicateWithFormat:@"self CONTAINS '.assembled.'"]];
	assembled = [assembled sortedArrayUsingSelector:@selector(compare:)];

	if (assembled.count == 0)
	{
		log(@"[z0] NO_ASSEMBLED_SHADERS — assemble step not wired yet (see gpu-zone/README.md 'Status'). PENDING.");
		return;
	}

	// Compile every shader, keeping the objects grouped by program (filename `<prog>.<stage>.assembled.glsl`).
	NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSNumber *> *> *programs = [NSMutableDictionary dictionary];
	int total = 0, okCount = 0, skipped = 0;
	for (NSString *path in assembled)
	{
		NSString *name = [path lastPathComponent];
		GLenum stage = stageForName(name);
		if (stage == 0) { skipped++; log([NSString stringWithFormat:@"[z0] SKIP %@ (non-vert/frag stage)", name]); continue; }
		NSString *src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
		if (!src) { log([NSString stringWithFormat:@"[z0] FAIL: could not read %@", name]); continue; }
		total++;
		GLuint sh = compileOne(name, src, stage, log);
		if (sh) {
			okCount++;
			NSString *prog = [[name componentsSeparatedByString:@"."] firstObject];
			if (!programs[prog]) programs[prog] = [NSMutableDictionary dictionary];
			programs[prog][@(stage)] = @(sh);
		}
	}
	log([NSString stringWithFormat:@"[z0] SUMMARY compiled=%d/%d skipped=%d", okCount, total, skipped]);

	// Link each program that has both a vertex and a fragment stage that compiled.
	int progTotal = 0, progOk = 0;
	for (NSString *prog in [programs.allKeys sortedArrayUsingSelector:@selector(compare:)])
	{
		NSNumber *v = programs[prog][@(GL_VERTEX_SHADER)], *f = programs[prog][@(GL_FRAGMENT_SHADER)];
		if (v && f) {
			progTotal++;
			if (linkProgram(prog, v.unsignedIntValue, f.unsignedIntValue, log)) progOk++;
		} else {
			log([NSString stringWithFormat:@"[z0] LINK %@ = SKIP (missing %@ stage)", prog, v ? @"fragment" : @"vertex"]);
		}
	}
	log([NSString stringWithFormat:@"[z0] LINK SUMMARY linked=%d/%d", progOk, progTotal]);

	BOOL green = okCount == total && total > 0 && progOk == progTotal && progTotal > 0;
	log(green ? @"[z0] VERDICT = ALL_ZONE_PROGRAMS_LINK_ES300"
	          : @"[z0] VERDICT = ZONE_GATE_INCOMPLETE");
}

@end
