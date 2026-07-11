#!/usr/bin/env python3
"""
GPU Route C step 3b — JNI GL bridge generator.

Reads used-descriptors.txt (the exact facade calls the base `gpu` plugin makes) and emits:
  - jni/routec_gl_jni.m  : the JNI forwarders + RegisterNatives tables + RouteC_registerGLNatives(JNIEnv*).
  - facade-native/org/lwjgl/opengl/GLALL.java : the device facade (GL methods turned `native`).

Design (see bridge-manifest.md): the ~80 core GL calls forward straight to glXxx; the 5 census shims +
AWTContext route to RouteCBridge (built + proven, step 2); GL.createCapabilities builds a GLCapabilities with
OpenGL33=true. BufferUtils.createIntBuffer + Configuration.set stay pure-Java (not emitted here).

NOTE: This is DEVICE-ONLY runtime-testable (no JVM on the Simulator). It is compile-checked for iOS arm64 here.
The handful of NIO-size marshallings are marked `TODO(device)` — LWJGL sizes by buffer.remaining(); the simplest
correct device refinement is to compute address/size in the Java facade and pass primitives (long addr, long size),
which removes all NIO JNI. Kept as direct-JNI here so the generated file is self-contained and compiles.
"""
import re
import sys
import os

USED = sys.argv[1] if len(sys.argv) > 1 else "used-descriptors.txt"
OUT_JNI = sys.argv[2] if len(sys.argv) > 2 else "jni/routec_gl_jni.m"
OUT_FACADE = sys.argv[3] if len(sys.argv) > 3 else "facade-native/org/lwjgl/opengl/GLALL.java"

# ---- per-frame upkeep + GPU publish helpers (Route C 2C/2D), emitted into the preamble ----------------------
RC_HELPERS = r'''// Cached JavaBridge handles for the per-frame GPU publish (resolved once, lazily, after registration).
static jclass    s_jb  = NULL;
static jmethodID s_bb  = NULL;  // gpuFrameBackBuffer(II)[I
static jmethodID s_pub = NULL;  // gpuPublish(II)V
static jmethodID s_cw  = NULL;  // canvasWidth()I
static jmethodID s_ch  = NULL;  // canvasHeight()I
static void rc_jb_cache(JNIEnv *env)
{
    if (s_jb) return;
    jclass c = (*env)->FindClass(env, "net/runelite/client/headless/JavaBridge");
    if (!c) { (*env)->ExceptionClear(env); return; }
    s_jb  = (*env)->NewGlobalRef(env, c);
    s_bb  = (*env)->GetStaticMethodID(env, s_jb, "gpuFrameBackBuffer", "(II)[I");
    s_pub = (*env)->GetStaticMethodID(env, s_jb, "gpuPublish", "(II)V");
    s_cw  = (*env)->GetStaticMethodID(env, s_jb, "canvasWidth", "()I");
    s_ch  = (*env)->GetStaticMethodID(env, s_jb, "canvasHeight", "()I");
    (*env)->ExceptionClear(env);
}

// Per-frame upkeep (called from getFramebuffer, early in each draw): re-bind the thread-affine EAGL context and
// recreate the FBO if the engine canvas resized. setCurrentContext is a no-op on the same thread (the expected
// case) but removes the off-thread-draw risk entirely.
static void rc_per_frame(JNIEnv *env)
{
    [RouteCBridge makeCurrent];
    rc_jb_cache(env);
    if (s_cw && s_ch) {
        jint w = (*env)->CallStaticIntMethod(env, s_jb, s_cw);
        jint h = (*env)->CallStaticIntMethod(env, s_jb, s_ch);
        if (w > 0 && h > 0) [RouteCBridge ensureSizeWidth:(int)w height:(int)h];
    }
}

// swapBuffers: read the composited FBO back and publish it as the SOLE frame (Hooks gates the CPU snapshot off
// when isGpu). glReadPixels straight into the JavaBridge back buffer via GetPrimitiveArrayCritical — no JNI calls
// inside the critical section (glReadPixels is a GL call; the flip/swizzle is pure C).
static void rc_swap_publish(JNIEnv *env)
{
    [RouteCBridge makeCurrent];
    int w = [RouteCBridge fbWidth], h = [RouteCBridge fbHeight];
    if (w <= 0 || h <= 0) return;
    rc_jb_cache(env);
    if (!s_bb || !s_pub) return;
    jintArray arr = (jintArray)(*env)->CallStaticObjectMethod(env, s_jb, s_bb, (jint)w, (jint)h);
    if (!arr) return;
    void *dst = (*env)->GetPrimitiveArrayCritical(env, arr, NULL);
    if (dst) {
        [RouteCBridge readbackInto:(uint32_t *)dst width:w height:h];
        (*env)->ReleasePrimitiveArrayCritical(env, arr, dst, 0);
    }
    (*env)->CallStaticVoidMethod(env, s_jb, s_pub, (jint)w, (jint)h);
    (*env)->DeleteLocalRef(env, arr);
}
'''

# ---- JNI descriptor parsing -------------------------------------------------
def parse_params(p):
    out, i = [], 0
    while i < len(p):
        c = p[i]
        if c == 'L':
            j = p.index(';', i)
            out.append(p[i:j + 1]); i = j + 1
        elif c == '[':
            c2 = p[i + 1]
            if c2 == 'L':
                j = p.index(';', i); out.append(p[i:j + 1]); i = j + 1
            else:
                out.append(p[i:i + 2]); i += 2
        else:
            out.append(c); i += 1
    return out

def jni_ctype(t):
    return {'V': 'void', 'I': 'jint', 'F': 'jfloat', 'D': 'jdouble', 'Z': 'jboolean', 'J': 'jlong',
            '[F': 'jfloatArray', '[I': 'jintArray'}.get(
        t, 'jstring' if t in ('Ljava/lang/String;', 'Ljava/lang/CharSequence;') else 'jobject')

# ---- per-method GL forwarder bodies ----------------------------------------
# args are named a0,a1,... ; `R` marks a return is needed. Trivial methods (params only I/F/Z/D, simple return)
# are handled generically below; only the non-trivial ones are listed here.
def body_gl(name, params, ret):
    a = [f"a{i}" for i in range(len(params))]
    # --- the 5 shims -> RouteCBridge ---
    if name == 'glClearDepth':
        return "[RouteCBridge glClearDepthShim:a0];"
    if name == 'glMultiDrawArrays':
        return ("const GLint *first = (const GLint *)(*env)->GetDirectBufferAddress(env, a1);\n"
                "    const GLsizei *count = (const GLsizei *)(*env)->GetDirectBufferAddress(env, a2);\n"
                "    GLsizei n = (GLsizei)((*env)->GetDirectBufferCapacity(env, a1));\n"
                "    [RouteCBridge glMultiDrawArraysShim:(GLenum)a0 first:first count:count drawcount:n];")
    if name == 'glClipControl':
        return "[RouteCBridge glClipControlShim:(GLenum)a0 depth:(GLenum)a1];"
    if name == 'glDebugMessageControl':
        return "[RouteCBridge glDebugMessageControlShim];"
    if name == 'glMapBuffer':
        return ("void *p = [RouteCBridge glMapBufferShim:(GLenum)a0 access:(GLenum)a1 size:0];\n"
                "    return p ? (*env)->NewDirectByteBuffer(env, p, 0) : NULL; "
                "/* TODO(device): size from the bound buffer's GL_BUFFER_SIZE */")
    # --- gen single (no-arg -> one name) ---
    if re.fullmatch(r'glGen(Buffers|Framebuffers|Renderbuffers|Textures|VertexArrays)', name):
        return f"GLuint id = 0; {name}(1, &id); return (jint)id;"
    # --- delete single (the *s variants take count+array; Program/Shader take a single id) ---
    if re.fullmatch(r'glDelete(Buffers|Framebuffers|Renderbuffers|Textures|VertexArrays)', name):
        return f"GLuint id = (GLuint)a0; {name}(1, &id);"
    if name in ('glDeleteProgram', 'glDeleteShader'):
        return f"{name}((GLuint)a0);"
    # --- LWJGL convenience getters returning via pointer ---
    if name == 'glGetInteger':
        return "GLint v = 0; glGetIntegerv((GLenum)a0, &v); return (jint)v;"
    if name == 'glGetFloat':
        return "GLfloat v = 0; glGetFloatv((GLenum)a0, &v); return (jfloat)v;"
    if name == 'glGetProgrami':
        return "GLint v = 0; glGetProgramiv((GLuint)a0, (GLenum)a1, &v); return (jint)v;"
    if name == 'glGetShaderi':
        return "GLint v = 0; glGetShaderiv((GLuint)a0, (GLenum)a1, &v); return (jint)v;"
    # --- String returns ---
    if name == 'glGetString':
        return "const char *s = (const char *)glGetString((GLenum)a0); return s ? (*env)->NewStringUTF(env, s) : NULL;"
    if name in ('glGetProgramInfoLog', 'glGetShaderInfoLog'):
        ge = 'glGetProgramInfoLog' if name == 'glGetProgramInfoLog' else 'glGetShaderInfoLog'
        return (f"char buf[4096]; GLsizei len = 0; {ge}((GLuint)a0, sizeof(buf), &len, buf);\n"
                "    return (*env)->NewStringUTF(env, buf);")
    # --- CharSequence (String at runtime) in ---
    if name in ('glGetUniformLocation', 'glGetUniformBlockIndex'):
        g = name
        return (f"const char *nm = (*env)->GetStringUTFChars(env, a1, NULL);\n"
                f"    jint r = (jint){g}((GLuint)a0, nm);\n"
                "    (*env)->ReleaseStringUTFChars(env, a1, nm); return r;")
    if name == 'glShaderSource':
        # Downport desktop GLSL 330 -> GLSL ES 3.00 (the 5 B1 edits) before upload. Query GL_SHADER_TYPE so the
        # vertex-only int->float casts / fragment-only precision qualifiers are applied to the right stage.
        return ("const char *src = (*env)->GetStringUTFChars(env, a1, NULL);\n"
                "    GLint stype = 0; glGetShaderiv((GLuint)a0, GL_SHADER_TYPE, &stype);\n"
                "    NSString *down = [RouteCBridge downportShaderSource:[NSString stringWithUTF8String:src]\n"
                "        fragment:(stype == GL_FRAGMENT_SHADER)];\n"
                "    const char *dsrc = [down UTF8String];\n"
                "    glShaderSource((GLuint)a0, 1, &dsrc, NULL);\n"
                "    (*env)->ReleaseStringUTFChars(env, a1, src);")
    # --- float[] arrays ---
    if name == 'glUniform2fv':
        return ("jfloat *p = (*env)->GetFloatArrayElements(env, a1, NULL);\n"
                "    jsize n = (*env)->GetArrayLength(env, a1);\n"
                "    glUniform2fv((GLint)a0, n / 2, p);\n"
                "    (*env)->ReleaseFloatArrayElements(env, a1, p, JNI_ABORT);")
    if name == 'glUniformMatrix4fv':
        return ("jfloat *p = (*env)->GetFloatArrayElements(env, a2, NULL);\n"
                "    jsize n = (*env)->GetArrayLength(env, a2);\n"
                "    glUniformMatrix4fv((GLint)a0, n / 16, (GLboolean)a1, p);\n"
                "    (*env)->ReleaseFloatArrayElements(env, a2, p, JNI_ABORT);")
    # --- nio.Buffer args (GetDirectBufferAddress) ---
    if name == 'glBufferData' and params == ['I', 'Ljava/nio/FloatBuffer;', 'I']:
        return ("void *d = (*env)->GetDirectBufferAddress(env, a1);\n"
                "    jlong cap = (*env)->GetDirectBufferCapacity(env, a1); /* TODO(device): floats->bytes, use remaining() */\n"
                "    glBufferData((GLenum)a0, (GLsizeiptr)(cap * 4), d, (GLenum)a2);")
    if name == 'glBufferData' and params == ['I', 'Ljava/nio/IntBuffer;', 'I']:
        return ("void *d = (*env)->GetDirectBufferAddress(env, a1);\n"
                "    jlong cap = (*env)->GetDirectBufferCapacity(env, a1); /* TODO(device): ints->bytes, use remaining() */\n"
                "    glBufferData((GLenum)a0, (GLsizeiptr)(cap * 4), d, (GLenum)a2);")
    if name == 'glReadPixels':
        return "glReadPixels((GLint)a0,(GLint)a1,(GLsizei)a2,(GLsizei)a3,(GLenum)a4,(GLenum)a5,(*env)->GetDirectBufferAddress(env,a6));"
    if name == 'glTexSubImage3D' and 'Ljava/nio/ByteBuffer;' in params:
        return ("glTexSubImage3D((GLenum)a0,(GLint)a1,(GLint)a2,(GLint)a3,(GLint)a4,(GLsizei)a5,(GLsizei)a6,"
                "(GLsizei)a7,(GLenum)a8,(GLenum)a9,(*env)->GetDirectBufferAddress(env,a10));")
    # --- J = size / J = byte-offset pointer ---
    if name == 'glBufferData' and params == ['I', 'J', 'I']:
        return "glBufferData((GLenum)a0, (GLsizeiptr)a1, NULL, (GLenum)a2);"
    if name == 'glFlushMappedBufferRange':
        return "glFlushMappedBufferRange((GLenum)a0, (GLintptr)a1, (GLsizeiptr)a2);"
    if name == 'glMapBufferRange':
        return ("void *p = glMapBufferRange((GLenum)a0,(GLintptr)a1,(GLsizeiptr)a2,(GLbitfield)a3);\n"
                "    return p ? (*env)->NewDirectByteBuffer(env, p, a2) : NULL;")
    if name == 'glDrawElements':
        return "glDrawElements((GLenum)a0,(GLsizei)a1,(GLenum)a2,(const void *)(intptr_t)a3);"
    if name == 'glTexImage2D':
        return "glTexImage2D((GLenum)a0,(GLint)a1,(GLint)a2,(GLsizei)a3,(GLsizei)a4,(GLint)a5,(GLenum)a6,(GLenum)a7,(const void *)(intptr_t)a8);"
    if name == 'glTexImage3D':
        return "glTexImage3D((GLenum)a0,(GLint)a1,(GLint)a2,(GLsizei)a3,(GLsizei)a4,(GLsizei)a5,(GLint)a6,(GLenum)a7,(GLenum)a8,(const void *)(intptr_t)a9);"
    if name == 'glTexSubImage2D':
        return "glTexSubImage2D((GLenum)a0,(GLint)a1,(GLint)a2,(GLint)a3,(GLsizei)a4,(GLsizei)a5,(GLenum)a6,(GLenum)a7,(const void *)(intptr_t)a8);"
    if name == 'glVertexAttribIPointer':
        return "glVertexAttribIPointer((GLuint)a0,(GLint)a1,(GLenum)a2,(GLsizei)a3,(const void *)(intptr_t)a4);"
    if name == 'glVertexAttribPointer':
        return "glVertexAttribPointer((GLuint)a0,(GLint)a1,(GLenum)a2,(GLboolean)a3,(GLsizei)a4,(const void *)(intptr_t)a5);"
    # --- generic primitive-direct ---
    call = f"{name}(" + ", ".join(a) + ");"
    if ret == 'V':
        return call
    cret = jni_ctype(ret)
    return f"return ({cret}){name}(" + ", ".join(a) + ");"

# AWTContext (instance) -> RouteCBridge statics
def body_awt(name, params, ret):
    m = {
        'loadNatives': "/* no-op (re-signed dylibs already loaded) */",
        'configurePixelFormat': "/* no-op (FBO format fixed in awtCreateGLContext) */",
        'createGLContext': "rc_awt_create_context(env); /* EAGL ES3 context + FBO, current on THIS (client) thread */",
        'getFramebuffer': "rc_per_frame(env); /* re-bind context + resize-if-changed, early each draw */\n    return (jint)[RouteCBridge awtGetFramebuffer];",
        'getBufferMode': "return (jint)GL_COLOR_ATTACHMENT0;",
        'setSwapInterval': "return a0;",
        'swapBuffers': "rc_swap_publish(env); /* glReadPixels the FBO -> JavaBridge back buffer -> publish (sole frameSeq publisher) */",
        'destroy': "[RouteCBridge awtDestroy];",
    }
    return m.get(name, "/* TODO(device) */")

def jni_method_name(cls, meth, idx):
    return f"rc_{cls}_{meth}_{idx}"

def gen():
    gl, awt, glcaps = [], [], []
    for line in open(USED):
        line = line.strip()
        if not line:
            continue
        m = re.match(r'(\S+)\.(\w+):\(([^)]*)\)(.+)', line)
        if not m:
            continue
        owner, meth, params_s, ret = m.groups()
        params = parse_params(params_s)
        if owner.startswith('org/lwjgl/opengl/GL3') or owner.startswith('org/lwjgl/opengl/GL4'):
            gl.append((meth, params, ret))
        elif owner == 'net/runelite/rlawt/AWTContext':
            awt.append((meth, params, ret))
        elif owner == 'org/lwjgl/opengl/GL' and meth in ('createCapabilities', 'getCapabilities'):
            glcaps.append((meth, params, ret))

    L = []
    L.append("/* GENERATED by gen/routec_jni_gen.py — Route C step 3b JNI GL bridge. DEVICE-ONLY runtime; compile-")
    L.append("   checked for iOS arm64. Forwards the base `gpu` plugin's facade calls to GLES / RouteCBridge. */")
    L.append("#import <Foundation/Foundation.h>")
    L.append("#define GLES_SILENCE_DEPRECATION 1   // OpenGLES is deprecated-since-iOS-12 but works on iOS 26 (no Metal-GL bridge needed)")
    L.append("#import <OpenGLES/ES3/gl.h>")
    L.append("#import <OpenGLES/ES3/glext.h>")
    L.append('#import "RouteCBridge.h"')
    L.append("#include <jni.h>")
    L.append("#include <stdint.h>")
    L.append("")
    # AWTContext.createGLContext() runs on the CLIENT THREAD (GpuPlugin.startUp, GpuPlugin.java:304); every later
    # GL call (draws, swapBuffers) is on that same thread. EAGL contexts are thread-affine, so the context MUST be
    # made current here, not pre-created by the shell on another thread. Size = the engine canvas
    # (JavaBridge.canvasWidth/Height) when present, else a default (the L1 kill-test has no engine/JavaBridge).
    L.append("static void rc_awt_create_context(JNIEnv *env)")
    L.append("{")
    L.append("    int w = 512, h = 512; /* default for the L1 probe (no engine canvas) */")
    L.append('    jclass jb = (*env)->FindClass(env, "net/runelite/client/headless/JavaBridge");')
    L.append("    if (jb) {")
    L.append('        jmethodID cw = (*env)->GetStaticMethodID(env, jb, "canvasWidth", "()I");')
    L.append('        jmethodID ch = (*env)->GetStaticMethodID(env, jb, "canvasHeight", "()I");')
    L.append("        if (cw && ch) {")
    L.append("            jint qw = (*env)->CallStaticIntMethod(env, jb, cw);")
    L.append("            jint qh = (*env)->CallStaticIntMethod(env, jb, ch);")
    L.append("            if (qw > 0 && qh > 0) { w = (int)qw; h = (int)qh; }")
    L.append("        }")
    L.append("    }")
    L.append("    (*env)->ExceptionClear(env); /* optional probe — ignore FindClass/NoSuchMethod (L1 has no JavaBridge) */")
    L.append("    [RouteCBridge awtCreateGLContextWidth:w height:h];")
    L.append("}")
    L.append("")
    L.append(RC_HELPERS)

    def emit(funcs, owner_kind):
        tbl = []
        seen = {}
        for meth, params, ret in funcs:
            idx = seen.get(meth, 0); seen[meth] = idx + 1
            fn = jni_method_name(owner_kind, meth, idx)
            cargs = ", ".join(f"{jni_ctype(t)} a{i}" for i, t in enumerate(params))
            recv = "JNIEnv *env, jclass cls" if owner_kind != 'AWT' else "JNIEnv *env, jobject self"
            sig = f"({recv}" + (", " + cargs if cargs else "") + ")"
            cret = jni_ctype(ret)
            if owner_kind == 'GL':
                b = body_gl(meth, params, ret)
            elif owner_kind == 'AWT':
                b = body_awt(meth, params, ret)
            else:
                b = "/* createCapabilities/getCapabilities handled specially below */"
            L.append(f"static JNIEXPORT {cret} JNICALL {fn}{sig}")
            L.append("{")
            for ln in b.split("\n"):
                L.append("    " + ln if ln else "")
            L.append("}")
            L.append("")
            jni_desc = f"({params_join(params)}){ret}"
            tbl.append((meth, jni_desc, fn))
        return tbl

    def params_join(params):
        return "".join(params)

    gl_tbl = emit(gl, 'GL')
    awt_tbl = emit(awt, 'AWT')

    # GL.createCapabilities / getCapabilities — build a GLCapabilities with OpenGL33=true (REQUIRED, else the
    # plugin aborts at GpuPlugin.java:317). Field presence probes set per real iOS GLES support.
    L.append("static jobject rc_make_caps(JNIEnv *env)")
    L.append("{")
    L.append('    jclass c = (*env)->FindClass(env, "org/lwjgl/opengl/GLCapabilities");')
    L.append('    jmethodID ctor = (*env)->GetMethodID(env, c, "<init>", "()V");')
    L.append("    jobject o = (*env)->NewObject(env, c, ctor);")
    L.append('    (*env)->SetBooleanField(env, o, (*env)->GetFieldID(env, c, "OpenGL33", "Z"), JNI_TRUE);')
    L.append('    (*env)->SetBooleanField(env, o, (*env)->GetFieldID(env, c, "OpenGL45", "Z"), JNI_FALSE);')
    L.append('    (*env)->SetLongField(env, o, (*env)->GetFieldID(env, c, "glTexStorage3D", "J"), 1);')
    L.append('    (*env)->SetLongField(env, o, (*env)->GetFieldID(env, c, "glDebugMessageControl", "J"), 0);')
    L.append('    const char *ext = (const char *)glGetString(GL_EXTENSIONS);')
    L.append('    jboolean aniso = (ext && strstr(ext, "texture_filter_anisotropic")) ? JNI_TRUE : JNI_FALSE;')
    L.append('    (*env)->SetBooleanField(env, o, (*env)->GetFieldID(env, c, "GL_EXT_texture_filter_anisotropic", "Z"), aniso);')
    L.append("    return o;")
    L.append("}")
    L.append("static JNIEXPORT jobject JNICALL rc_GL_createCapabilities_0(JNIEnv *env, jclass cls) { return rc_make_caps(env); }")
    L.append("static JNIEXPORT jobject JNICALL rc_GL_getCapabilities_0(JNIEnv *env, jclass cls) { return rc_make_caps(env); }")
    L.append("")

    def table(name, entries):
        L.append(f"static const JNINativeMethod {name}[] = {{")
        for meth, desc, fn in entries:
            L.append(f'    {{ "{meth}", "{desc}", (void *)&{fn} }},')
        L.append("};")

    table("kGLALL", gl_tbl)
    table("kAWT", awt_tbl)
    L.append('static const JNINativeMethod kGL[] = {')
    L.append('    { "createCapabilities", "()Lorg/lwjgl/opengl/GLCapabilities;", (void *)&rc_GL_createCapabilities_0 },')
    L.append('    { "getCapabilities", "()Lorg/lwjgl/opengl/GLCapabilities;", (void *)&rc_GL_getCapabilities_0 },')
    L.append("};")
    L.append("")
    L.append("// Call once after JNI_CreateJavaVM, before the gpu plugin starts.")
    L.append("jint RouteC_registerGLNatives(JNIEnv *env)")
    L.append("{")
    L.append('    jclass glall = (*env)->FindClass(env, "org/lwjgl/opengl/GLALL");')
    L.append('    jclass awt = (*env)->FindClass(env, "net/runelite/rlawt/AWTContext");')
    L.append('    jclass gl = (*env)->FindClass(env, "org/lwjgl/opengl/GL");')
    L.append("    if (!glall || !awt || !gl) return JNI_ERR;")
    L.append("    if ((*env)->RegisterNatives(env, glall, kGLALL, (jint)(sizeof(kGLALL)/sizeof(kGLALL[0]))) < 0) return JNI_ERR;")
    L.append("    if ((*env)->RegisterNatives(env, awt, kAWT, (jint)(sizeof(kAWT)/sizeof(kAWT[0]))) < 0) return JNI_ERR;")
    L.append("    if ((*env)->RegisterNatives(env, gl, kGL, (jint)(sizeof(kGL)/sizeof(kGL[0]))) < 0) return JNI_ERR;")
    L.append("    return JNI_OK;")
    L.append("}")

    os.makedirs(os.path.dirname(OUT_JNI), exist_ok=True)
    open(OUT_JNI, "w").write("\n".join(L) + "\n")
    print(f"wrote {OUT_JNI}: {len(gl_tbl)} GL + {len(awt_tbl)} AWTContext + 2 GL.caps natives")

if __name__ == "__main__":
    gen()
