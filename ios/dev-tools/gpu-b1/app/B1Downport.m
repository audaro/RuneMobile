/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import "B1Downport.h"

@implementation B1Downport

+ (NSString *)downport:(NSString *)src fragment:(BOOL)fragment
{
	NSMutableString *s = [src mutableCopy];

	// 1) version line. Match `#version 330` optionally followed by `core`, anywhere a line begins.
	NSError *err = nil;
	NSRegularExpression *ver = [NSRegularExpression regularExpressionWithPattern:@"#version\\s+330(\\s+core)?"
		options:0 error:&err];
	[ver replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"#version 300 es"];

	// 2) inject precision qualifiers immediately after the (first) #version line. ES fragment shaders have NO
	//    default precision for float/int/sampler types — they MUST be declared before first use.
	NSString *prec = fragment
		? @"\nprecision highp float;\nprecision highp int;\nprecision highp sampler2DArray;\nprecision highp sampler2D;\n"
		: @"\nprecision highp float;\nprecision highp int;\n";
	NSRange verLine = [s rangeOfString:@"#version 300 es"];
	if (verLine.location != NSNotFound)
	{
		// insert after the end of that line
		NSUInteger eol = verLine.location + verLine.length;
		[s insertString:prec atIndex:eol];
	}

	// 3) drop the `noperspective` qualifier (with its trailing whitespace).
	NSRegularExpression *nop = [NSRegularExpression regularExpressionWithPattern:@"\\bnoperspective\\s+"
		options:0 error:&err];
	[nop replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];

	// 4) strip float-literal `f`/`F` suffix. Requires a decimal point so hex (0xff) and ints are untouched.
	//    Matches: 1.0f  255.f  0.f  .5f  128.0F  ->  1.0  255.  0.  .5  128.0
	NSRegularExpression *fsuf = [NSRegularExpression regularExpressionWithPattern:@"(\\d*\\.\\d+|\\d+\\.\\d*)[fF]"
		options:0 error:&err];
	[fsuf replaceMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"$1"];

	// 5) explicit numeric casts (vertex shaders only). GLSL ES 3.00 — unlike desktop GLSL 330 — performs NO
	//    implicit int->float / ivec->vec conversions, so the scene vertex shader's arithmetic that mixes the
	//    engine's integer uniforms/attributes with floats must be cast explicitly. These sites are unique to
	//    the base `gpu` scene vertex shader (vert.glsl); they are no-ops in vertui.glsl. (Found by the B1 gate:
	//    every scene.vert error was an "X does not operate on int/float" implicit-conversion rejection.)
	if (!fragment)
	{
		NSDictionary<NSString *, NSString *> *casts = @{
			// vertf (vec3) + base (ivec3)
			@"vec4(vertf + base, 1)": @"vec4(vertf + vec3(base), 1)",
			// (entityTint.xyz ivec3 - hsl vec3) * entityTint.w int / 128 int
			@"hsl += ((entityTint.xyz - hsl) * entityTint.w) / 128;":
				@"hsl += ((vec3(entityTint.xyz) - hsl) * float(entityTint.w)) / 128.0;",
			// FOG_SCENE_EDGE_* macros: (int expr) * TILE_SIZE(float)
			@"((-expandedMapLoadingChunks * 8 + 1) * TILE_SIZE)":
				@"(float(-expandedMapLoadingChunks * 8 + 1) * TILE_SIZE)",
			@"((104 + expandedMapLoadingChunks * 8 - 1) * TILE_SIZE)":
				@"(float(104 + expandedMapLoadingChunks * 8 - 1) * TILE_SIZE)",
			// cameraX/Z (float) -/+ drawDistance (int)
			@"cameraX - drawDistance": @"cameraX - float(drawDistance)",
			@"cameraX + drawDistance": @"cameraX + float(drawDistance)",
			@"cameraZ - drawDistance": @"cameraZ - float(drawDistance)",
			@"cameraZ + drawDistance": @"cameraZ + float(drawDistance)",
			// fogDepth (int) * TILE_SIZE (float), and trailing * useFog (int)
			@"fogDepth * TILE_SIZE) * useFog": @"float(fogDepth) * TILE_SIZE) * float(useFog)",
		};
		for (NSString *from in casts)
		{
			[s replaceOccurrencesOfString:from withString:casts[from]
				options:0 range:NSMakeRange(0, s.length)];
		}
	}

	return [s copy];
}

@end
