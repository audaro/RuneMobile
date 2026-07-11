/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met.
 */
#import <Foundation/Foundation.h>
// Foundation ONLY — NO GL headers here. This header is imported by UIKit translation units (ViewController), and in
// the ANGLE build the GLES3 headers type-conflict with Apple's OpenGLES module (pulled by UIKit). So the public API
// uses plain C widths (the GL typedefs they alias to are noted inline); the .m includes routec_gl_compat.h for the
// real GL/EGL headers. The on-screen layer is passed as an opaque id (CAEAGLLayer for EAGL, CAMetalLayer for ANGLE).

/*
 * GPU Route C — native GL bridge core (the iOS half of the thin JNI GL bridge). This is the code the JNI natives
 * backing the `org.lwjgl.opengl` / `net.runelite.rlawt.AWTContext` facade will call. The ~80 GLES-3.0-core calls
 * the base `gpu` plugin makes are 1:1 with the GL driver and need NO wrapper (the JNI stub calls glXxx directly).
 * Only the AWTContext offscreen-context analogue and the 5 non-core shims live here. Backend is selected at build
 * time by RC_BACKEND_ANGLE (see routec_gl_compat.h): MetalANGLE EGL (Phase A1) or native EAGL ES3 (prior/fallback).
 */
@interface RouteCBridge : NSObject

// ---- AWTContext analogue (librlawt replacement): EAGL ES3 offscreen context + a COLOR+DEPTH FBO ----
// createGLContext(): make an EAGL ES3 context current + build the offscreen FBO. getFramebuffer(false) returns
// this FBO id — it is "framebuffer 0" for the unmodified plugin. swapBuffers() reads the FBO back and publishes
// it (see RouteCBridge.m / the JNI swapBuffers shim). Returns YES on success.
+ (BOOL)awtCreateGLContextWidth:(int)w height:(int)h;
+ (unsigned int)awtGetFramebuffer;   // GLuint — the FBO the plugin treats as "framebuffer 0" (0 in ANGLE window mode)
+ (void)awtDestroy;

// ---- direct present (kills the readback) ----
// When a CAEAGLLayer is set (on the main thread, before the GPU launch), the default-FBO COLOR attachment is the
// layer's drawable (via renderbufferStorage:fromDrawable:) instead of an offscreen RBO, and swapBuffers presents
// it straight to the screen (presentRenderbuffer) — no glReadPixels, no int[] blit, no CGImage. `id` to avoid a
// QuartzCore import in this header; it is a CAEAGLLayer.
+ (void)setPresentLayer:(id)caEaglLayer;
+ (BOOL)isPresenting;     // YES once a present layer is set (swapBuffers should present, not read back)
+ (BOOL)hasPresentedFrame;// YES once >=1 frame has been presented — UI switches CPU-blit -> direct present lazily
+ (void)present;          // EAGL: presentRenderbuffer; ANGLE: eglSwapBuffers

// ---- PiP present (EAGL only): the 117HD Picture-in-Picture path ----
// When an AVSampleBufferDisplayLayer is set INSTEAD of a CAEAGLLayer (main thread, before the GPU launch),
// the plugin renders into the plain offscreen FBO and swapBuffers presents by GPU-blitting it (Y-flipped)
// into an IOSurface-backed CVPixelBuffer enqueued on the layer — no glReadPixels, full frame rate. Because
// that layer is the SAME one the AVPictureInPictureController sources, 117HD shows live in PiP and keeps
// presenting while backgrounded (GL submission under an active PiP session is device-proven allowed).
// Enqueueing starts only once setPipPresentEnabled:YES (the shell flips it at the warmup reveal, so the
// boot/login CPU frames the shell feeds the same layer aren't raced); present() counts frames regardless,
// so hasPresentedFrame gates the reveal exactly like the CAEAGLLayer path. `id` = AVSampleBufferDisplayLayer.
+ (void)setPipPresentLayer:(id)sampleBufferDisplayLayer;
+ (void)setPipPresentEnabled:(BOOL)on;
// ANGLE only: create the EGL display + WINDOW surface from the present layer ON MAIN (the CAMetalLayer's thread),
// before the render thread's createGLContext. No-op/NO on EAGL or with no present layer. Returns NO -> use readback.
+ (BOOL)prepareWindowSurfaceOnMain;

// ---- per-frame upkeep (Route C 2C: thread-affine EAGL context + canvas-resize) ----
// makeCurrent: re-bind sCtx on the calling thread — cheap (no-op when already current) and removes the
// "draw runs off the createGLContext thread" risk entirely. fbWidth/fbHeight: the live FBO size. ensureSize:
// recreate the FBO when the engine canvas changes (rare on device — the canvas is fixed at the resizeSpec).
+ (void)makeCurrent;
+ (int)fbWidth;
+ (int)fbHeight;
+ (void)ensureSizeWidth:(int)w height:(int)h;

// ---- the GPU publish readback (Route C 2D) ----
// glReadPixels the color FBO (GL_RGBA — the only ES3-core readback format) into `dst` as packed 0x00RRGGBB,
// vertically flipped (GL origin is bottom-left; the display is top-left) and R<->B swizzled, in one row pass.
+ (void)readbackInto:(uint32_t *)dst width:(int)w height:(int)h;

// ---- water-shimmer diagnostic/fix mode (gated by Documents/routec-water-mode.txt; cached once) ----
// "stripes" = 4-band scene-fragment A/B (fix override OFF so band 0 keeps mips); "baseline" = raw unmodified
// (fix OFF, mips on); anything else / absent = the shipping fix (drop the broken array mip filter). STRIP
// with the rest of the water diagnostics once the fix is locked.
+ (NSString *)waterDiagMode;
// YES unless a raw-diagnostic mode (stripes/baseline/solidtex/depthalways/fragdepth) is selected, i.e. the
// shipping water-shimmer TEXTURE fix (trilinear minification + anisotropy + textureGrad) should be applied.
+ (BOOL)waterFixActive;
// YES for the shipping fix AND for the "fragdepth" depth-only A/B: apply the reverse-Z gl_FragDepth depth-
// precision fix (far-distance z-fighting). Separate from waterFixActive so "fragdepth" isolates depth alone.
+ (BOOL)depthFixActive;
// YES in the "fix2x" mode: render the 3D scene FBO at 2x and downsample on the composite blit (supersampling
// AA for the thin far-geometry / grazing-water aliasing the on-pixel-grid render can't resolve). UI stays 1x.
+ (BOOL)superSampleActive;
// Nonzero in "offsetalpha*" modes: apply a reverse-Z polygon offset during depth-mask-off alpha draws. This is a
// narrow A/B for water/overlay z-fighting without the global gl_FragDepth experiment.
+ (float)alphaOffsetUnits;

// ---- shader downport (Route C 2E) ----
// Rewrite desktop GLSL 330 -> GLSL ES 3.00 (the 5 B1 edits) before glShaderSource. Vertex shaders need the
// explicit int->float casts ES forbids implicitly; fragment shaders need precision qualifiers.
+ (NSString *)downportShaderSource:(NSString *)src fragment:(BOOL)fragment;

// ---- the 5 non-GLES-3.0-core shims (everything else is 1:1 with the GL driver). Types are plain C aliases of the
//      GL typedefs (GLenum=unsigned int, GLint/GLsizei=int, GLsizeiptr=long) so this header stays GL-header-free. ----
+ (void)glClearDepthShim:(double)depth;                  // -> glClearDepthf((float)depth)
+ (void)glMultiDrawArraysShim:(unsigned int)mode first:(const int *)first count:(const int *)count drawcount:(int)n; // -> loop glDrawArrays
+ (void)glClipControlShim:(unsigned int)origin depth:(unsigned int)depth; // EAGL: no-op (reverse-Z via matrix+depth state); ANGLE: real glClipControlEXT
+ (void)glDebugMessageControlShim;                        // no-op: KHR_debug absent on iOS GLES / this ANGLE build
+ (void *)glMapBufferShim:(unsigned int)target access:(unsigned int)access size:(long)size; // -> glMapBufferRange (ES has range-map only)

@end
