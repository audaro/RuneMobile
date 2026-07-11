/*
 * GPU Zone B0.2/B0.3 — RLHD (117HD) Zone JNI delta forwarders. The iOS-bridge half of the gpu-zone/facade
 * delta (facade-delta.md): the GL/MemoryUtil calls RLHD makes BEYOND the base gpu plugin's 100-call surface.
 *
 * Registered ON TOP of the base RouteC_registerGLNatives (../gpu-routec/jni/routec_gl_jni.m) by
 * RouteC_registerZoneNatives(JNIEnv*) when booting in zone mode — the proven base bridge is untouched. All GL
 * facade classes (GL33C/GL40/GL41C/GL43/GL43C/GL44/ARB*) are `extends GLALL {}` shims, so every GL native is
 * declared on org/lwjgl/opengl/GLALL and registered there; the off-heap ops are on org/lwjgl/system/MemoryUtil.
 *
 * HAND-WRITTEN (not gen/routec_jni_gen.py) because the delta has bespoke shapes the base generator doesn't cover:
 * 3D-texture NIO uploads, ES3 sync handles, off-heap malloc, the glTexBuffer->2D RGB32I repack (blocker #1), the
 * glDrawBuffer->plural shim (#11), and the bucket-B no-op stubs. The bucket-B calls (compute / indirect draw /
 * timer queries / KHR_debug) are caps-gated OFF on the iOS zone path (see B0-conformance-notes.md) so they never
 * fire — they exist only so the RegisterNatives table is complete and a stray call can't UnsatisfiedLinkError.
 * Several non-1:1 marshallings carry TODO(device): LWJGL sizes NIO buffers by remaining(); the device-correct
 * refinement is to size in the Java facade. DEVICE-ONLY runtime; this file is compile-checked for iOS arm64.
 */
#import <Foundation/Foundation.h>
#import "RouteCBridge.h"
#import "routec_gl_compat.h"   // EAGL vs MetalANGLE/EGL (RC_BACKEND_ANGLE) + GL/EGL headers
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

// The desktop-GL glMapBuffer access enums LWJGL passes (absent from iOS GLES, which only has glMapBufferRange
// bitfields). Used to translate glMapBuffer(target, access) -> glMapBufferRange flags.
#ifndef GL_READ_ONLY
#define GL_READ_ONLY  0x88B8
#endif
#ifndef GL_WRITE_ONLY
#define GL_WRITE_ONLY 0x88B9
#endif
#ifndef GL_READ_WRITE
#define GL_READ_WRITE 0x88BA
#endif
// The desktop/ES3.2 texture-buffer target RLHD binds `textureFaces` to (absent on iOS GLES 3.0). We remap it to
// GL_TEXTURE_2D everywhere (glBindTexture override + the glTexBuffer 2D repack) so the TBO becomes an isampler2D.
#ifndef GL_TEXTURE_BUFFER
#define GL_TEXTURE_BUFFER 0x8C2A
#endif

// ============================================================================================================
//  Bucket A — GLES-3.0-core forwarders (run on the flat-scene path). All target symbols exist in iOS GLES 3.0.
// ============================================================================================================

static void JNICALL z_glCullFace(JNIEnv *e, jclass c, jint a0) { glCullFace((GLenum)a0); }
static void JNICALL z_glFinish(JNIEnv *e, jclass c) { glFinish(); }
static void JNICALL z_glFlush(JNIEnv *e, jclass c) { glFlush(); }
static void JNICALL z_glVertexAttribDivisor(JNIEnv *e, jclass c, jint a0, jint a1) { glVertexAttribDivisor((GLuint)a0, (GLuint)a1); }

static void JNICALL z_glUniform2f(JNIEnv *e, jclass c, jint l, jfloat a, jfloat b) { glUniform2f(l, a, b); }
static void JNICALL z_glUniform3f(JNIEnv *e, jclass c, jint l, jfloat a, jfloat b, jfloat d) { glUniform3f(l, a, b, d); }

// glUniformNfv / glUniformNiv: LWJGL passes a flat array; count = length / N.
static void JNICALL z_glUniform3fv(JNIEnv *e, jclass c, jint l, jfloatArray arr) {
    jsize n = (*e)->GetArrayLength(e, arr); jfloat *p = (*e)->GetFloatArrayElements(e, arr, NULL);
    glUniform3fv(l, n / 3, p); (*e)->ReleaseFloatArrayElements(e, arr, p, JNI_ABORT);
}
static void JNICALL z_glUniform4fv(JNIEnv *e, jclass c, jint l, jfloatArray arr) {
    jsize n = (*e)->GetArrayLength(e, arr); jfloat *p = (*e)->GetFloatArrayElements(e, arr, NULL);
    glUniform4fv(l, n / 4, p); (*e)->ReleaseFloatArrayElements(e, arr, p, JNI_ABORT);
}
static void JNICALL z_glUniform2iv(JNIEnv *e, jclass c, jint l, jintArray arr) {
    jsize n = (*e)->GetArrayLength(e, arr); jint *p = (*e)->GetIntArrayElements(e, arr, NULL);
    glUniform2iv(l, n / 2, (const GLint *)p); (*e)->ReleaseIntArrayElements(e, arr, p, JNI_ABORT);
}
static void JNICALL z_glUniform3iv(JNIEnv *e, jclass c, jint l, jintArray arr) {
    jsize n = (*e)->GetArrayLength(e, arr); jint *p = (*e)->GetIntArrayElements(e, arr, NULL);
    glUniform3iv(l, n / 3, (const GLint *)p); (*e)->ReleaseIntArrayElements(e, arr, p, JNI_ABORT);
}
static void JNICALL z_glUniform4iv(JNIEnv *e, jclass c, jint l, jintArray arr) {
    jsize n = (*e)->GetArrayLength(e, arr); jint *p = (*e)->GetIntArrayElements(e, arr, NULL);
    glUniform4iv(l, n / 4, (const GLint *)p); (*e)->ReleaseIntArrayElements(e, arr, p, JNI_ABORT);
}

// LWJGL NIO-buffer semantics: a Buffer argument means the [position, limit) window — the data pointer is
// base + position elements and the element count is remaining(), NOT capacity() from the base. The base
// bridge's capacity-sized wrappers caused the reused/flip()ed-buffer scene corruption (routec_gl_jni.m,
// rc_buf_position/rc_buf_remaining); same contract here.
static jint z_buf_position(JNIEnv *e, jobject buf) {
    static jmethodID mid = NULL;
    if (!mid) {
        jclass c = (*e)->FindClass(e, "java/nio/Buffer");
        mid = (*e)->GetMethodID(e, c, "position", "()I");
        (*e)->DeleteLocalRef(e, c);
    }
    return (*e)->CallIntMethod(e, buf, mid);
}
static jint z_buf_remaining(JNIEnv *e, jobject buf) {
    static jmethodID mid = NULL;
    if (!mid) {
        jclass c = (*e)->FindClass(e, "java/nio/Buffer");
        mid = (*e)->GetMethodID(e, c, "remaining", "()I");
        (*e)->DeleteLocalRef(e, c);
    }
    return (*e)->CallIntMethod(e, buf, mid);
}

// glBufferSubData(target, offset, <typed buffer>) — pointer = base + position*elem, size = remaining*elem.
static void z_buffer_sub_data(JNIEnv *e, jint target, jlong off, jobject buf, int elem) {
    const char *p = (const char *)(*e)->GetDirectBufferAddress(e, buf);
    jint rem = z_buf_remaining(e, buf);
    if (p && rem > 0)
        glBufferSubData((GLenum)target, (GLintptr)off, (GLsizeiptr)rem * elem,
                        p + (size_t)z_buf_position(e, buf) * elem);
}
static void JNICALL z_glBufferSubData_B(JNIEnv *e, jclass c, jint t, jlong o, jobject b) { z_buffer_sub_data(e, t, o, b, 1); }
static void JNICALL z_glBufferSubData_F(JNIEnv *e, jclass c, jint t, jlong o, jobject b) { z_buffer_sub_data(e, t, o, b, 4); }
static void JNICALL z_glBufferSubData_I(JNIEnv *e, jclass c, jint t, jlong o, jobject b) { z_buffer_sub_data(e, t, o, b, 4); }

static void JNICALL z_glCopyBufferSubData(JNIEnv *e, jclass c, jint rt, jint wt, jlong ro, jlong wo, jlong sz) {
    glCopyBufferSubData((GLenum)rt, (GLenum)wt, (GLintptr)ro, (GLintptr)wo, (GLsizeiptr)sz);
}

// ES3 sync objects (GLFence.java — real on the zone path). The J handle is the GLsync pointer as intptr_t.
static jlong JNICALL z_glFenceSync(JNIEnv *e, jclass c, jint cond, jint flags) {
    return (jlong)(intptr_t)glFenceSync((GLenum)cond, (GLbitfield)flags);
}
static jint JNICALL z_glClientWaitSync(JNIEnv *e, jclass c, jlong sync, jint flags, jlong timeout) {
    return (jint)glClientWaitSync((GLsync)(intptr_t)sync, (GLbitfield)flags, (GLuint64)timeout);
}
static void JNICALL z_glDeleteSync(JNIEnv *e, jclass c, jlong sync) { glDeleteSync((GLsync)(intptr_t)sync); }

// FBO attach (non-array attaches are B0; the layered tiled-lighting array FBO is B5).
static void JNICALL z_glFramebufferTexture2D(JNIEnv *e, jclass c, jint t, jint att, jint tt, jint tex, jint lvl) {
    glFramebufferTexture2D((GLenum)t, (GLenum)att, (GLenum)tt, (GLuint)tex, lvl);
}
static void JNICALL z_glFramebufferTextureLayer(JNIEnv *e, jclass c, jint t, jint att, jint tex, jint lvl, jint layer) {
    glFramebufferTextureLayer((GLenum)t, (GLenum)att, (GLuint)tex, lvl, layer);
}
// glFramebufferTexture (whole-texture attach, no layer) is ES 3.2 — emulate by attaching layer 0. TODO(device):
// true layered attach is a B5 (tiled-lighting / cubemap shadow) item, gated off in B0.
static void JNICALL z_glFramebufferTexture(JNIEnv *e, jclass c, jint t, jint att, jint tex, jint lvl) {
    glFramebufferTextureLayer((GLenum)t, (GLenum)att, (GLuint)tex, lvl, 0);
}

// Introspection getters (array-out overloads).
static void JNICALL z_glGetIntegerv(JNIEnv *e, jclass c, jint pname, jintArray arr) {
    jint *p = (*e)->GetIntArrayElements(e, arr, NULL);
    glGetIntegerv((GLenum)pname, (GLint *)p); (*e)->ReleaseIntArrayElements(e, arr, p, 0);
}
static void JNICALL z_glGetProgramiv(JNIEnv *e, jclass c, jint prog, jint pname, jintArray arr) {
    jint *p = (*e)->GetIntArrayElements(e, arr, NULL);
    glGetProgramiv((GLuint)prog, (GLenum)pname, (GLint *)p); (*e)->ReleaseIntArrayElements(e, arr, p, 0);
}
static jlong JNICALL z_glGetBufferParameteri64(JNIEnv *e, jclass c, jint t, jint pname) {
    GLint64 v = 0; glGetBufferParameteri64v((GLenum)t, (GLenum)pname, &v); return (jlong)v;
}
static jint JNICALL z_glGetFramebufferAttachmentParameteri(JNIEnv *e, jclass c, jint t, jint att, jint pname) {
    GLint v = 0; glGetFramebufferAttachmentParameteriv((GLenum)t, (GLenum)att, (GLenum)pname, &v); return (jint)v;
}
// Program-binary cache (ES3 core). a1=length[1], a2=binaryFormat[1], buf=binary sink.
static void JNICALL z_glGetProgramBinary(JNIEnv *e, jclass c, jint prog, jintArray lenArr, jintArray fmtArr, jobject buf) {
    GLsizei bufSize = (GLsizei)(*e)->GetDirectBufferCapacity(e, buf);
    void *bin = (*e)->GetDirectBufferAddress(e, buf);
    GLsizei length = 0; GLenum fmt = 0;
    glGetProgramBinary((GLuint)prog, bufSize, &length, &fmt, bin);
    jint l = (jint)length, f = (jint)fmt;
    if (lenArr) (*e)->SetIntArrayRegion(e, lenArr, 0, 1, &l);
    if (fmtArr) (*e)->SetIntArrayRegion(e, fmtArr, 0, 1, &f);
}

// JNI NewDirectByteBuffer defaults to BIG-endian; the GPU reads buffer bytes in the platform's NATIVE order
// (little-endian on arm64). RLHD's upload workers write vertex positions + per-face data (HSL/material/terrain)
// into the mapped buffer via IntBuffer/FloatBuffer views, so a non-native ByteBuffer byte-swaps EVERY int/float
// -> garbage geometry (the huge camera-locked shapes) + zero HSL (black world). The base bridge already wraps its
// mapped buffers with native order (rc_native_order, routec_gl_jni.m); the zone map functions must too.
static jobject z_native_order(JNIEnv *e, jobject bb) {
    if (!bb) return bb;
    jclass boCls = (*e)->FindClass(e, "java/nio/ByteOrder");
    jclass bbCls = (*e)->FindClass(e, "java/nio/ByteBuffer");
    if (boCls && bbCls) {
        jmethodID nativeOrder = (*e)->GetStaticMethodID(e, boCls, "nativeOrder", "()Ljava/nio/ByteOrder;");
        jmethodID order = (*e)->GetMethodID(e, bbCls, "order", "(Ljava/nio/ByteOrder;)Ljava/nio/ByteBuffer;");
        if (nativeOrder && order) {
            jobject no = (*e)->CallStaticObjectMethod(e, boCls, nativeOrder);
            jobject ret = (*e)->CallObjectMethod(e, bb, order, no); // returns `this`, reconfigured
            if (ret) bb = ret;
        }
    }
    (*e)->ExceptionClear(e);
    return bb;
}

// Buffer mapping (ES3 range-map only).
static jobject JNICALL z_glMapBufferRange(JNIEnv *e, jclass c, jint t, jlong off, jlong len, jint access) {
    // iOS GLES 3.0 has NO persistent mapping (GL_MAP_PERSISTENT_BIT) or glBufferStorage (it's a no-op stub here).
    // RLHD's storage buffers (DynamicModelVAO — the animated NPC/player model streaming) try a persistent map and,
    // on a NULL result, fall back to a per-frame non-persistent map/unmap that IS ES-3.0-compatible
    // (GLBuffer.ensureCapacity recreates the buffer as STORAGE_NONE). Force NULL for persistent requests to trigger
    // that fallback; otherwise the model VBO/TBO get a bogus mapping over the no-op storage and render black.
    if (access & 0x40 /* GL_MAP_PERSISTENT_BIT */) return NULL;
    void *p = glMapBufferRange((GLenum)t, (GLintptr)off, (GLsizeiptr)len, (GLbitfield)access);
    return p ? z_native_order(e, (*e)->NewDirectByteBuffer(e, p, len)) : NULL;
}
// glMapBuffer(target, access-enum, oldBuffer) — ES has no whole-buffer map; range-map the full GL_BUFFER_SIZE and
// translate the access enum to a bitfield.
// IMPORTANT (device): Apple's GLES-on-Metal returns NULL when mapping a buffer for WRITE without orphaning — a
// bare GL_MAP_WRITE_BIT asks the driver to preserve+sync the existing GPU contents, which it refuses (every
// ZoneUploadJob "Failed to map buffer" was this). A whole-buffer glMapBuffer is a full rewrite, so we orphan with
// GL_MAP_INVALIDATE_BUFFER_BIT — exactly what the base-gpu glMapBufferShim does (RouteCBridge.m), which renders
// fine on device. The zone VBO/TBO buffers are freshly glBufferData'd then fully written by the upload workers,
// so discarding the (undefined) old contents is correct.
static jobject JNICALL z_glMapBuffer(JNIEnv *e, jclass c, jint t, jint access, jobject old) {
    GLint sz = 0; glGetBufferParameteriv((GLenum)t, GL_BUFFER_SIZE, &sz);
    if (sz <= 0) return NULL;
    GLbitfield f = (access == GL_READ_ONLY)  ? GL_MAP_READ_BIT
                 : (access == GL_WRITE_ONLY) ? (GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT)
                 : (GL_MAP_READ_BIT | GL_MAP_WRITE_BIT);
    void *p = glMapBufferRange((GLenum)t, 0, sz, f);
    return p ? z_native_order(e, (*e)->NewDirectByteBuffer(e, p, sz)) : NULL;
}

// Texture-array uploads (materials + shadow). NIO data via the direct buffer address.
static void JNICALL z_glTexStorage3D(JNIEnv *e, jclass c, jint t, jint lvls, jint ifmt, jint w, jint h, jint d) {
    glTexStorage3D((GLenum)t, lvls, (GLenum)ifmt, w, h, d);
}
static void JNICALL z_glTexImage3D(JNIEnv *e, jclass c, jint t, jint lvl, jint ifmt, jint w, jint h, jint d,
                                   jint border, jint fmt, jint type, jobject buf) {
    // QA-P1-09: LWJGL marshals an NIO buffer from its position(), not the base address — the data starts at
    // base + position*elem. Honor that (ShortBuffer here -> elem 2) instead of passing the raw base.
    const char *base = buf ? (const char *)(*e)->GetDirectBufferAddress(e, buf) : NULL;
    const void *p = base ? (const void *)(base + (size_t)z_buf_position(e, buf) * 2) : NULL;
    glTexImage3D((GLenum)t, lvl, ifmt, w, h, d, border, (GLenum)fmt, (GLenum)type, p);
}
static void JNICALL z_glTexSubImage3D(JNIEnv *e, jclass c, jint t, jint lvl, jint xo, jint yo, jint zo,
                                      jint w, jint h, jint d, jint fmt, jint type, jobject buf) {
    // QA-P1-09: the data starts at base + position*elem and only remaining() elements are valid (LWJGL's NIO
    // contract); the BGRA repack below previously read w*h*d ints from the base, over-reading a positioned or
    // short (reused/flip()ed) buffer — the same capacity-from-base bug z_buffer_sub_data fixes. IntBuffer -> elem 4.
    const char *base = buf ? (const char *)(*e)->GetDirectBufferAddress(e, buf) : NULL;
    const void *p = base ? (const void *)(base + (size_t)z_buf_position(e, buf) * 4) : NULL;
    const size_t count = (size_t)w * (size_t)h * (size_t)d;
    // iOS GLES 3.0 has no GL_BGRA upload format. RLHD uploads the material texture array as
    // GL_BGRA + GL_UNSIGNED_INT_8_8_8_8_REV over 0xAARRGGBB ints (TextureManager.uploadTexture); on iOS that
    // errors and leaves the texture array BLACK (untextured models + ground, while vertex-HSL grass is fine).
    // Convert to RGBA8 by swapping the R<->B bytes and upload as GL_RGBA + GL_UNSIGNED_BYTE (the Android real-Mali
    // run needed the same swizzle; this is its iOS home). One-time per texture load, not per frame.
    if (p && fmt == 0x80E1 /*GL_BGRA*/ && type == 0x8367 /*GL_UNSIGNED_INT_8_8_8_8_REV*/
        && (size_t)z_buf_remaining(e, buf) >= count) {
        const uint32_t *src = (const uint32_t *)p;
        uint32_t *tmp = (uint32_t *)malloc(count * 4);
        if (tmp) {
            for (size_t i = 0; i < count; i++) {
                uint32_t v = src[i];   // mem bytes [B,G,R,A]; want [R,G,B,A] -> swap byte 0 and 2
                tmp[i] = (v & 0xFF00FF00u) | ((v & 0x000000FFu) << 16) | ((v & 0x00FF0000u) >> 16);
            }
            glTexSubImage3D((GLenum)t, lvl, xo, yo, zo, w, h, d, GL_RGBA, GL_UNSIGNED_BYTE, tmp);
            free(tmp);
            return;
        }
    }
    glTexSubImage3D((GLenum)t, lvl, xo, yo, zo, w, h, d, (GLenum)fmt, (GLenum)type, p);
}
// Interface-texture (texUi) upload, PBO-offset variant. RLHD's HdPlugin.drawUi uploads the composited engine UI
// + ALL 2D overlays (HUD, inventory, chat, hit splats, HP/overhead bars, tile markers, our model-outline) into
// texUi with GL_BGRA + GL_UNSIGNED_INT_8_8_8_8_REV from pboUi. That format/type pair is desktop-only: iOS GLES 3.0
// accepts GL_BGRA_EXT only with GL_UNSIGNED_BYTE, so on device the upload errors and texUi stays the empty
// glTexImage2D(...,NULL) allocation -> the WHOLE engine UI layer composites blank (only the native chrome veneers
// are visible; world-area overlays like splats/HP bars/markers/outlines have nothing behind them and vanish). The
// pboUi bytes are already [B,G,R,A] per pixel (native-order 0xAARRGGBB ints), which GL_BGRA + GL_UNSIGNED_BYTE
// consumes with correct channels — so just downgrade the type. Other glTexSubImage2D callers (the TBO->2D repack
// uses GL_RGB_INTEGER) are untouched. iOS-only home; desktop/Android keep the pristine call.
static void JNICALL z_glTexSubImage2D_J(JNIEnv *e, jclass c, jint a0, jint a1, jint a2, jint a3,
                                        jint a4, jint a5, jint a6, jint a7, jlong a8) {
    GLenum type = (GLenum)a7;
    if ((GLenum)a6 == 0x80E1 /*GL_BGRA*/ && type == 0x8367 /*GL_UNSIGNED_INT_8_8_8_8_REV*/) {
        type = GL_UNSIGNED_BYTE;
    }
    glTexSubImage2D((GLenum)a0, (GLint)a1, (GLint)a2, (GLint)a3, (GLsizei)a4, (GLsizei)a5,
                    (GLenum)a6, type, (const void *)(intptr_t)a8);
}
static void JNICALL z_glTexParameterfv(JNIEnv *e, jclass c, jint t, jint pname, jfloatArray arr) {
    // GL_TEXTURE_BORDER_COLOR (0x1004) is desktop/ES3.2-only -> GL_INVALID_ENUM on iOS GLES 3.0. RLHD sets it on
    // the shadow-map texture to pair with GL_CLAMP_TO_BORDER (remapped to CLAMP_TO_EDGE in the base bridge); since
    // shadows.glsl samples via texelFetch (wrap/border state ignored), the border colour is unused -> no-op it.
    if (pname == 0x1004) return;
    jfloat *p = (*e)->GetFloatArrayElements(e, arr, NULL);
    glTexParameterfv((GLenum)t, (GLenum)pname, p); (*e)->ReleaseFloatArrayElements(e, arr, p, JNI_ABORT);
}

// Query OBJECT lifetime (gen/delete are ES3 core; the TIMER use of them is stubbed below).
static void JNICALL z_glGenQueries(JNIEnv *e, jclass c, jintArray arr) {
    jsize n = (*e)->GetArrayLength(e, arr); jint *p = (*e)->GetIntArrayElements(e, arr, NULL);
    glGenQueries(n, (GLuint *)p); (*e)->ReleaseIntArrayElements(e, arr, p, 0);
}
static void JNICALL z_glDeleteQueries(JNIEnv *e, jclass c, jintArray arr) {
    jsize n = (*e)->GetArrayLength(e, arr); jint *p = (*e)->GetIntArrayElements(e, arr, NULL);
    glDeleteQueries(n, (const GLuint *)p); (*e)->ReleaseIntArrayElements(e, arr, p, JNI_ABORT);
}

// ============================================================================================================
//  #11 / #1 shims
// ============================================================================================================

// #11 — ES3 has only the plural glDrawBuffers; the singular is the facade's job. RLHD stays unmodified.
static void JNICALL z_glDrawBuffer(JNIEnv *e, jclass c, jint buf) {
    GLenum b = (GLenum)buf; glDrawBuffers(1, &b);
}

// #1 companion — OVERRIDE the base glBindTexture(II)V: remap GL_TEXTURE_BUFFER -> GL_TEXTURE_2D so RLHD's
// `textureFaces` texture object is created/bound consistently as 2D (the target it samples via isampler2D after
// the glTexBuffer 2D repack). Registered AFTER the base table (later RegisterNatives wins), so base mode is
// unaffected (it never binds GL_TEXTURE_BUFFER); all other targets pass straight through.
static void JNICALL z_glBindTexture(JNIEnv *e, jclass c, jint target, jint tex) {
    glBindTexture((GLenum)target == GL_TEXTURE_BUFFER ? GL_TEXTURE_2D : (GLenum)target, (GLuint)tex);
}

// #1 — glTexBuffer(GL_TEXTURE_BUFFER, internalformat, buffer) has no ES3 equivalent. Repack the buffer object's
// bytes as a 2D texture (proven byte-exact in gpu-tbo2d) so the shader's `isampler2D textureFaces` +
// texelFetch(ivec2(idx%W, idx/W)) (already emitted by the Z0 downport) reads identical data. RGB32I = 12 B/texel.
// W = min(GL_MAX_TEXTURE_SIZE, N); the shader recovers W from textureSize(...).x, so any W is self-consistent.
// TODO(device): the COMPANION glBindTexture(GL_TEXTURE_BUFFER,...) must be remapped to GL_TEXTURE_2D in the base
// bridge so the upload + sampler land on the same 2D texture object (the only piece that touches the base path).
static void JNICALL z_glTexBuffer(JNIEnv *e, jclass c, jint target, jint internalformat, jint buffer) {
    GLint bytes = 0;
    glBindBuffer(GL_COPY_READ_BUFFER, (GLuint)buffer);
    glGetBufferParameteriv(GL_COPY_READ_BUFFER, GL_BUFFER_SIZE, &bytes);
    if (bytes <= 0) { glBindBuffer(GL_COPY_READ_BUFFER, 0); return; }
    void *src = glMapBufferRange(GL_COPY_READ_BUFFER, 0, bytes, GL_MAP_READ_BIT);
    if (src) {
        GLint texelBytes = 12;                 // GL_RGB32I = 3 * int32
        GLint n = bytes / texelBytes;
        GLint maxW = 4096; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxW);
        GLint w = n < maxW ? n : maxW; if (w < 1) w = 1;
        GLint h = (n + w - 1) / w;
        // Uploads to the currently-bound GL_TEXTURE_2D on the active unit (bound via the z_glBindTexture remap).
        // CRITICAL: the buffer holds only n texels but the texture is w*h (n <= w*h). A single
        // glTexImage2D(..., src) would have the driver read the WHOLE w*h*12-byte rectangle, running past the
        // mapped buffer on the partial last row -> SIGSEGV in libGLImage (device). So allocate the texture, then
        // upload EXACTLY the n valid texels: the complete rows, then the partial last row. The unused tail is
        // never sampled (every shader texelFetch index is < n).
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB32I, w, h, 0, GL_RGB_INTEGER, GL_INT, NULL);
        GLint fullRows = n / w;
        if (fullRows > 0)
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, fullRows, GL_RGB_INTEGER, GL_INT, src);
        GLint rem = n - fullRows * w;
        if (rem > 0)
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, fullRows, rem, 1, GL_RGB_INTEGER, GL_INT,
                            (const char *)src + (size_t)fullRows * w * texelBytes);
        // Integer 2D textures are incomplete unless sampled with GL_NEAREST + no mipmaps (GL_LINEAR is invalid for
        // integer formats); RLHD set no params on the TBO. Make it complete so the isampler2D fetch returns data.
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glUnmapBuffer(GL_COPY_READ_BUFFER);
    }
    glBindBuffer(GL_COPY_READ_BUFFER, 0);
}

// ============================================================================================================
//  Bucket B — no-op stubs (caps-gated OFF on the iOS zone path; never fire). NO GL symbol referenced (these are
//  ES 3.1+/desktop-only). Present so the RegisterNatives table is complete and a stray call can't ULE.
// ============================================================================================================

static void JNICALL z_noop_III(JNIEnv *e, jclass c, jint a, jint b, jint d) {}              // glDispatchCompute
static void JNICALL z_noop_I(JNIEnv *e, jclass c, jint a) {}                                 // glMemoryBarrier
static void JNICALL z_noop_IJ(JNIEnv *e, jclass c, jint a, jlong b) {}                       // glDrawArraysIndirect
static void JNICALL z_noop_IIJ(JNIEnv *e, jclass c, jint a, jint b, jlong d) {}              // glDrawElementsIndirect
static void JNICALL z_noop_IJII(JNIEnv *e, jclass c, jint a, jlong b, jint d, jint f) {}     // glMultiDrawArraysIndirect
static void JNICALL z_noop_IJI(JNIEnv *e, jclass c, jint a, jlong b, jint d) {}              // glBufferStorage
static void JNICALL z_noop_IIIZIII(JNIEnv *e, jclass c, jint a, jint b, jint d, jboolean f,
                                   jint g, jint h, jint i) {}                                // glBindImageTexture
static void JNICALL z_noop_II(JNIEnv *e, jclass c, jint a, jint b) {}                        // glQueryCounter
static void JNICALL z_noop_void(JNIEnv *e, jclass c) {}                                      // glPopDebugGroup
static void JNICALL z_noop_IIObj(JNIEnv *e, jclass c, jint a, jint b, jobject s) {}          // glPushDebugGroup / glObjectLabel
static void JNICALL z_noop_IIIarrZ(JNIEnv *e, jclass c, jint a, jint b, jint d,
                                    jintArray arr, jboolean f) {}                            // glDebugMessageControl
// Timer-query getters: ES 3.0 has no timer queries; return 0 so RLHD's timing reads as 0.
static void JNICALL z_glGetQueryObjectiv(JNIEnv *e, jclass c, jint id, jint pname, jintArray arr) {
    if (arr && (*e)->GetArrayLength(e, arr) > 0) { jint z = 0; (*e)->SetIntArrayRegion(e, arr, 0, 1, &z); }
}
static jlong JNICALL z_glGetQueryObjectui64(JNIEnv *e, jclass c, jint id, jint pname) { return 0; }

// ============================================================================================================
//  Bucket D — off-heap (ModelCache.java). Real malloc/free/direct-address.
// ============================================================================================================

static jlong JNICALL z_nmemAllocChecked(JNIEnv *e, jclass c, jlong size) {
    return (jlong)(intptr_t)malloc((size_t)size);
}
static void JNICALL z_nmemFree(JNIEnv *e, jclass c, jlong ptr) { free((void *)(intptr_t)ptr); }
static jlong JNICALL z_memAddress0(JNIEnv *e, jclass c, jobject buf) {
    return (jlong)(intptr_t)(*e)->GetDirectBufferAddress(e, buf);
}

// ============================================================================================================
//  RegisterNatives tables + entry point
// ============================================================================================================

static const JNINativeMethod kGLALLZone[] = {
    // bucket A
    {"glCullFace",                         "(I)V",                                    (void *)z_glCullFace},
    {"glFinish",                           "()V",                                     (void *)z_glFinish},
    {"glFlush",                            "()V",                                     (void *)z_glFlush},
    {"glVertexAttribDivisor",              "(II)V",                                   (void *)z_glVertexAttribDivisor},
    {"glUniform2f",                        "(IFF)V",                                  (void *)z_glUniform2f},
    {"glUniform3f",                        "(IFFF)V",                                 (void *)z_glUniform3f},
    {"glUniform3fv",                       "(I[F)V",                                  (void *)z_glUniform3fv},
    {"glUniform4fv",                       "(I[F)V",                                  (void *)z_glUniform4fv},
    {"glUniform2iv",                       "(I[I)V",                                  (void *)z_glUniform2iv},
    {"glUniform3iv",                       "(I[I)V",                                  (void *)z_glUniform3iv},
    {"glUniform4iv",                       "(I[I)V",                                  (void *)z_glUniform4iv},
    {"glBufferSubData",                    "(IJLjava/nio/ByteBuffer;)V",              (void *)z_glBufferSubData_B},
    {"glBufferSubData",                    "(IJLjava/nio/FloatBuffer;)V",             (void *)z_glBufferSubData_F},
    {"glBufferSubData",                    "(IJLjava/nio/IntBuffer;)V",               (void *)z_glBufferSubData_I},
    {"glCopyBufferSubData",                "(IIJJJ)V",                                (void *)z_glCopyBufferSubData},
    {"glFenceSync",                        "(II)J",                                   (void *)z_glFenceSync},
    {"glClientWaitSync",                   "(JIJ)I",                                  (void *)z_glClientWaitSync},
    {"glDeleteSync",                       "(J)V",                                    (void *)z_glDeleteSync},
    {"glFramebufferTexture2D",             "(IIIII)V",                                (void *)z_glFramebufferTexture2D},
    {"glFramebufferTextureLayer",          "(IIIII)V",                                (void *)z_glFramebufferTextureLayer},
    {"glFramebufferTexture",               "(IIII)V",                                 (void *)z_glFramebufferTexture},
    {"glGetIntegerv",                      "(I[I)V",                                  (void *)z_glGetIntegerv},
    {"glGetProgramiv",                     "(II[I)V",                                 (void *)z_glGetProgramiv},
    {"glGetBufferParameteri64",            "(II)J",                                   (void *)z_glGetBufferParameteri64},
    {"glGetFramebufferAttachmentParameteri","(III)I",                                 (void *)z_glGetFramebufferAttachmentParameteri},
    {"glGetProgramBinary",                 "(I[I[ILjava/nio/ByteBuffer;)V",           (void *)z_glGetProgramBinary},
    {"glMapBufferRange",                   "(IJJI)Ljava/nio/ByteBuffer;",             (void *)z_glMapBufferRange},
    {"glMapBuffer",                        "(IILjava/nio/ByteBuffer;)Ljava/nio/ByteBuffer;", (void *)z_glMapBuffer},
    {"glTexStorage3D",                     "(IIIIII)V",                               (void *)z_glTexStorage3D},
    {"glTexImage3D",                       "(IIIIIIIIILjava/nio/ShortBuffer;)V",      (void *)z_glTexImage3D},
    {"glTexSubImage3D",                    "(IIIIIIIIIILjava/nio/IntBuffer;)V",       (void *)z_glTexSubImage3D},
    {"glTexSubImage2D",                    "(IIIIIIIIJ)V",                            (void *)z_glTexSubImage2D_J},
    {"glTexParameterfv",                   "(II[F)V",                                 (void *)z_glTexParameterfv},
    {"glGenQueries",                       "([I)V",                                   (void *)z_glGenQueries},
    {"glDeleteQueries",                    "([I)V",                                   (void *)z_glDeleteQueries},
    // #11 / #1 shims
    {"glDrawBuffer",                       "(I)V",                                    (void *)z_glDrawBuffer},
    {"glTexBuffer",                        "(III)V",                                  (void *)z_glTexBuffer},
    // #1 companion — OVERRIDE base glBindTexture to remap GL_TEXTURE_BUFFER -> GL_TEXTURE_2D (later-wins).
    {"glBindTexture",                      "(II)V",                                   (void *)z_glBindTexture},
    // bucket B — no-op stubs (caps-gated off)
    {"glDispatchCompute",                  "(III)V",                                  (void *)z_noop_III},
    {"glMemoryBarrier",                    "(I)V",                                    (void *)z_noop_I},
    {"glDrawArraysIndirect",               "(IJ)V",                                   (void *)z_noop_IJ},
    {"glDrawElementsIndirect",             "(IIJ)V",                                  (void *)z_noop_IIJ},
    {"glMultiDrawArraysIndirect",          "(IJII)V",                                 (void *)z_noop_IJII},
    {"glBufferStorage",                    "(IJI)V",                                  (void *)z_noop_IJI},
    {"glBindImageTexture",                 "(IIIZIII)V",                              (void *)z_noop_IIIZIII},
    {"glQueryCounter",                     "(II)V",                                   (void *)z_noop_II},
    {"glPopDebugGroup",                    "()V",                                     (void *)z_noop_void},
    {"glPushDebugGroup",                   "(IILjava/lang/CharSequence;)V",           (void *)z_noop_IIObj},
    {"glObjectLabel",                      "(IILjava/lang/CharSequence;)V",           (void *)z_noop_IIObj},
    {"glDebugMessageControl",              "(III[IZ)V",                               (void *)z_noop_IIIarrZ},
    {"glGetQueryObjectiv",                 "(II[I)V",                                 (void *)z_glGetQueryObjectiv},
    {"glGetQueryObjectui64",               "(II)J",                                   (void *)z_glGetQueryObjectui64},
};

static const JNINativeMethod kMemUtilZone[] = {
    {"nmemAllocChecked", "(J)J",                  (void *)z_nmemAllocChecked},
    {"nmemFree",         "(J)V",                  (void *)z_nmemFree},
    {"memAddress0",      "(Ljava/nio/Buffer;)J",  (void *)z_memAddress0},
};

// Register the zone delta ON TOP of the base bridge. Call after JNI_CreateJavaVM in zone mode (the base
// RouteC_registerGLNatives must have run first — they register disjoint method sets on the same GLALL class).
jint RouteC_registerZoneNatives(JNIEnv *env)
{
    jclass glall = (*env)->FindClass(env, "org/lwjgl/opengl/GLALL");
    if (!glall) { (*env)->ExceptionClear(env); return -1; }
    if ((*env)->RegisterNatives(env, glall, kGLALLZone,
            (jint)(sizeof(kGLALLZone) / sizeof(kGLALLZone[0]))) != JNI_OK) return -2;

    jclass mem = (*env)->FindClass(env, "org/lwjgl/system/MemoryUtil");
    if (!mem) { (*env)->ExceptionClear(env); return -3; }
    if ((*env)->RegisterNatives(env, mem, kMemUtilZone,
            (jint)(sizeof(kMemUtilZone) / sizeof(kMemUtilZone[0]))) != JNI_OK) return -4;

    return 0;
}
