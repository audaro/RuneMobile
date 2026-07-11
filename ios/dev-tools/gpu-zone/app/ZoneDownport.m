/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import "ZoneDownport.h"

@implementation ZoneDownport

+ (NSString *)downport:(NSString *)src fragment:(BOOL)fragment
{
	NSMutableString *s = [src mutableCopy];
	NSError *err = nil;

	// 1) version line. RLHD's assembled output carries `#version 420` (Linux header) or `#version 430` (Windows
	//    header) injected via VERSION_HEADER (HdPlugin.java:905) — NOT 330 like the base gpu plugin. Match ANY
	//    `#version <num>` (optionally `core`) and replace with `#version 300 es`. (The base B1 downporter matched
	//    330 only; this is blueprint §5 blocker #7.)
	NSRegularExpression *ver = [NSRegularExpression regularExpressionWithPattern:@"#version\\s+\\d+(\\s+core)?"
		options:0 error:&err];
	[ver replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"#version 300 es"];

	// 2) inject precision qualifiers immediately after the (first) #version line. ES fragment shaders have NO
	//    default precision for float/int/sampler types — declared before first use. isampler2D is added for the
	//    repacked textureFaces (rule 6) and the zone path's integer samplers.
	NSString *prec = fragment
		? @"\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\nprecision highp sampler2DArray;\nprecision highp isampler2D;\nprecision highp isampler2DArray;\nprecision highp usampler2D;\nprecision highp usampler2DArray;\nprecision highp sampler2DShadow;\n"
		: @"\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\nprecision highp sampler2DArray;\nprecision highp isampler2D;\nprecision highp isampler2DArray;\nprecision highp usampler2D;\nprecision highp usampler2DArray;\n";
	NSRange verLine = [s rangeOfString:@"#version 300 es"];
	if (verLine.location != NSNotFound)
	{
		[s insertString:prec atIndex:verLine.location + verLine.length];
	}

	// 3) drop the `noperspective` qualifier (desktop-only; `flat`/`centroid` stay).
	NSRegularExpression *nop = [NSRegularExpression regularExpressionWithPattern:@"\\bnoperspective\\s+"
		options:0 error:&err];
	[nop replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];

	// 4) strip float-literal `f`/`F` suffix (illegal in ES 3.00). Requires a decimal point so hex/ints are untouched.
	//    The (?![A-Za-z0-9_]) is REQUIRED: else `material1.flowMap` matches `1.f` and the identifier's `f` is stripped
	//    -> `material1.lowMap` (silent corruption). Only strip a real literal suffix, not an identifier's leading f/F.
	NSRegularExpression *fsuf = [NSRegularExpression regularExpressionWithPattern:@"(\\d*\\.\\d+|\\d+\\.\\d*)[fF](?![A-Za-z0-9_])"
		options:0 error:&err];
	[fsuf replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"$1"];

	// 5) textureFaces texture-buffer -> 2D repack (blueprint §5 blocker #1; proven byte-exact in gpu-tbo2d). Three
	//    mechanical rules applied to any shader that declares the sampler (scene_vert, shadow_vert):
	if ([s rangeOfString:@"textureFaces"].location != NSNotFound)
	{
		// 5a) declaration: isamplerBuffer -> highp isampler2D
		NSRegularExpression *decl = [NSRegularExpression regularExpressionWithPattern:
			@"uniform\\s+isamplerBuffer\\s+textureFaces\\s*;" options:0 error:&err];
		[decl replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length)
			withTemplate:@"uniform highp isampler2D textureFaces;"];

		// 5b) inject `int tfW = textureSize(textureFaces, 0).x;` at the top of main() (width for the 1D->2D unwrap).
		NSRange mainR = [s rangeOfString:@"void main()"];
		if (mainR.location != NSNotFound)
		{
			NSRange braceR = [s rangeOfString:@"{"
				options:0 range:NSMakeRange(mainR.location, s.length - mainR.location)];
			if (braceR.location != NSNotFound)
			{
				[s insertString:@"\n  int tfW = textureSize(textureFaces, 0).x;"
					atIndex:braceR.location + braceR.length];
			}
		}

		// 5c) every `texelFetch(textureFaces, EXPR)` -> `texelFetch(textureFaces, ivec2((EXPR)%tfW,(EXPR)/tfW), 0)`.
		//     EXPR is the 1D texel index (vTextureFaceIdx{,+1,+2}); the trailing `.xyz`/`[vertex]` swizzle is left
		//     untouched (it follows the call). Pattern captures a single balanced-paren-free index expression.
		NSRegularExpression *fetch = [NSRegularExpression regularExpressionWithPattern:
			@"texelFetch\\(\\s*textureFaces\\s*,\\s*([^(),]+?)\\s*\\)" options:0 error:&err];
		[fetch replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length)
			withTemplate:@"texelFetch(textureFaces, ivec2(($1)%tfW,($1)/tfW), 0)"];
	}

	// 6) explicit int<->float / ivec<->vec casts. GLSL ES 3.00 does NO implicit numeric conversions that GLSL 330+
	//    allows. The exact site set is RLHD-shader-specific and is DISCOVERED by compiling each assembled shader and
	//    reading the ES errors (blueprint: prefer hand-maintained variants over a brittle keyed pass for the
	//    cast-heavy files). Sites are added here as the Z0 compile loop surfaces them. (Empty until the assemble
	//    step exists — see README "Status".)
	//    HYBRID POLICY (README "Status"): isolated/distinctive sites are fixed here as targeted string rules;
	//    genuinely cast-heavy math files (e.g. utils/color_utils.glsl color-temperature math on the scene path) get
	//    a hand-maintained ios-override instead of dozens of brittle rules. The sites below are UI-path scaling
	//    includes (fragment stage), so the rules apply to both stages.
	NSDictionary<NSString *, NSString *> *casts = @{
		// scaling/bicubic.glsl — `t` is float, the bicubic-window bounds are int literals (Mitchell + Catmull fns).
		@"if (t < 1)": @"if (t < 1.0)",
		@"if (t < 2)": @"if (t < 2.0)",
		// scaling/hybrid.glsl — sourceDimensions/targetDimensions are ivec2; `1 - texelUv` mixes int with a vec2.
		@"uv *= sourceDimensions;": @"uv *= vec2(sourceDimensions);",
		@"(1 - texelUv)": @"(vec2(1.0) - texelUv)",
	};
	for (NSString *from in casts)
		[s replaceOccurrencesOfString:from withString:casts[from] options:0 range:NSMakeRange(0, s.length)];

	return [s copy];
}

@end
