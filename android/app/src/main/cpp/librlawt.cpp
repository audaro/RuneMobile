// Track G AG1a — the per-ABI `librlawt` replacement: an Android EGL/GLES backing for the unmodified base `gpu`
// plugin's `net.runelite.rlawt.AWTContext` + `org.lwjgl.opengl.*` facade. Ported from the iOS Route-C JNI GL
// bridge (gpu branch: ios/dev-tools/gpu-routec/jni/routec_gl_jni.m + RouteCBridge.m's EGL path), swapping EAGL
// for Android's native EGL — and DROPPING the iOS platform tax (ANGLE platform selectors, the water/2x-SS diag
// modes, the perf logging, the CAEAGLLayer present path, the JavaBridge readback publish — all AG2+).
//
// It creates an offscreen pbuffer ES3 context + a COLOR(RGBA8)+DEPTH(24) FBO, makes it current on the calling
// (embedded-VM worker) thread, and forwards the plugin's GL surface straight to GLES (Android restores the
// objects/entry points iOS lacked). The host (jvm_bootstrap, smoke mode) dlopen's this + calls
// RouteC_registerGLNatives(env) to RegisterNatives the facade BEFORE the probe/plugin runs. `GpuPlugin.java` and
// the real `AWTContext` stay byte-for-byte unmodified — the work is this native + the pure-Java facade.
//
// AG1a scope: prove `GL.createCapabilities().OpenGL33==true` + a non-zero program id through the facade on a live
// EGL context, headless. The full forward table is wired here (reusable for AG2), but the offscreen+no readback
// present, the GLSL 330->ES downport, and the real-shader/canvas path are AG1b/AG2.

#include <jni.h>
#include <EGL/egl.h>
#include <GLES3/gl32.h>
#include <android/log.h>
#include <sys/system_properties.h>
#include <pthread.h>
#include <unistd.h>
#include <time.h>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <string>
#include <regex>
#include <atomic>

#define LOG_TAG "librlawt"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ---- GL constants the plugin passes that are NOT in the GLES headers (desktop/LWJGL values) ------------------
#ifndef GL_BGRA
#define GL_BGRA 0x80E1
#endif
#ifndef GL_UNSIGNED_INT_8_8_8_8_REV
#define GL_UNSIGNED_INT_8_8_8_8_REV 0x8367
#endif
// EXT_clip_control (reverse-Z) — resolved at runtime via eglGetProcAddress; absent on a driver -> reverse-Z cannot
// be enabled and depth stays the GL standard [-1,1] range. NOTE: GEQUAL alone does NOT emulate reverse-Z — the
// 117HD reverse-Z projection (Mat4.perspectiveInfiniteReverseZ + glClearDepth(0) + GL_GEQUAL) only maps depth
// correctly when the clip volume is [0,1], which requires glClipControl(LOWER_LEFT, ZERO_TO_ONE). It is enabled +
// self-tested at context creation (see rcSetupClipControl), since the Zone renderer never calls glClipControl itself.
#ifndef GL_LOWER_LEFT
#define GL_LOWER_LEFT 0x8CA1
#endif
#ifndef GL_ZERO_TO_ONE
#define GL_ZERO_TO_ONE 0x935F
#endif
#ifndef GL_NEGATIVE_ONE_TO_ONE
#define GL_NEGATIVE_ONE_TO_ONE 0x935E
#endif
typedef void (*PFNGLCLIPCONTROLEXTPROC)(GLenum origin, GLenum depth);
static PFNGLCLIPCONTROLEXTPROC pglClipControlEXT = nullptr;
// Phase 1: true once glClipControl(ZERO_TO_ONE) is enabled AND the self-test confirms the [0,1] range engaged.
static bool sClipReverseZ = false;

// Phase 4 probe — EXT_buffer_storage + EXT_multi_draw_indirect (NOT in gl32.h core). Resolved via eglGetProcAddress
// at context creation purely to GATE the (currently unimplemented + no-op'd) draw-batching / persistent-mapping
// levers; this probe never enables them. The persistent-storage map bits are EXT-suffixed values.
#ifndef GL_MAP_PERSISTENT_BIT_EXT
#define GL_MAP_PERSISTENT_BIT_EXT 0x0040
#endif
#ifndef GL_MAP_COHERENT_BIT_EXT
#define GL_MAP_COHERENT_BIT_EXT 0x0080
#endif
typedef void (*PFNGLBUFFERSTORAGEEXTPROC)(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags);
typedef void (*PFNGLMULTIDRAWARRAYSINDIRECTEXTPROC)(GLenum mode, const void* indirect, GLsizei drawcount, GLsizei stride);

// ---- EGL offscreen context + FBO (ported from RouteCBridge.m's RC_BACKEND_ANGLE path, ANGLE selectors dropped)
static EGLDisplay sDpy  = EGL_NO_DISPLAY;
static EGLContext sCtx  = EGL_NO_CONTEXT;
static EGLSurface sSurf = EGL_NO_SURFACE;
static EGLConfig  sCfg  = nullptr;
static GLuint sFbo = 0, sColorRbo = 0, sDepthRbo = 0;
static int sFboW = 0, sFboH = 0;
// GLSL ES target for the runtime downport — set from the real GL_VERSION once the context is current
// ("320 es" on ES 3.2, "310 es" on 3.1, "300 es" on 3.0). AG1b validated the base shaders at "320 es" on Mali.
static char sEsVer[16] = "320 es";
// glReadPixels scratch (read straight, then flip + swizzle into the Java array) — grown on demand.
static uint32_t *sReadback = nullptr;
static size_t sReadbackN = 0;

// Direct-present seam: jvm_bootstrap (which owns libandroid) hands these in via RouteC_setPresentCallbacks so we
// can present 117HD straight to the SurfaceView via an EGL window surface — no glReadPixels, no CPU blit. When
// these are set we are the SOLE Surface producer (the CPU present thread stands down).
static void*    (*sCbAcquireWindow)(uint64_t*) = nullptr;   // returns ANativeWindow* (acquired) or null; we release it
static uint64_t (*sCbSurfaceGen)(void)         = nullptr;
static void     (*sCbReleaseWindow)(void*)     = nullptr;
static void     (*sCbSetFrameDims)(int, int)   = nullptr;   // publish canvas dims for touch->game mapping
static EGLSurface sWinSurf = EGL_NO_SURFACE;
static void*      sWin     = nullptr;            // ANativeWindow* (opaque here; released via sCbReleaseWindow)
static uint64_t   sWinGen  = (uint64_t)-1;
// Phase 3 (auto-GPU watchdog): monotonic count of frames actually presented to the window surface (direct path).
// >0 + climbing == the GPU/117HD renderer activated and is presenting (NOT crashed / black / failed-to-start) — the
// success signal the Kotlin first-boot fallback polls (via RouteC_framesPresented) to commit or revert the promote.
static std::atomic<uint64_t> sFramesPresented{0};

// ---- Phase 0 instrumentation & swap-interval control ---------------------------------------------------------
// Read an Android system property as an int (settable live with `adb shell setprop`, no rebuild). Returns dflt if
// unset/empty — used for the A/B knobs below so a benchmark can pin them without a redeploy.
static int rc_prop_int(const char* name, int dflt) {
    char buf[PROP_VALUE_MAX] = {0};
    int n = __system_property_get(name, buf);
    if (n <= 0) return dflt;
    return atoi(buf);
}
static double rc_now_ms() {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// ---- Phase 4 draw-call probe (debug.routec.drawcount=1) ------------------------------------------------------
// Counts the GL draw calls the 117HD Zone path issues so we can PREDICT the multi-draw-indirect win before building
// it: every glMultiDrawArrays the renderer emits currently expands to N glDrawArrays HERE (GLES has no real
// glMultiDrawArrays), so an N-range batch costs N driver draw calls; with EXT_multi_draw_indirect that whole batch
// collapses to ONE glMultiDrawArraysIndirect. The saving/frame is therefore ~ (mdaRanges - mdaCalls). All draw
// forwarders + swapBuffers run on the single GL/draw thread, so plain ints suffice. Gated like the gputime probe.
static bool   sDrawCountOn   = false;
static int    sDcDrawArrays  = 0, sDcDrawElements = 0, sDcMultiCalls = 0, sDcMultiRanges = 0, sDcIndirect = 0;
static int    sDcFrames      = 0;

// eglSwapInterval control. The plugin's requested interval is stored here; the boot prop
// `debug.routec.swapinterval` overrides it (0=uncapped bench, 1=display refresh, 2=half-rate/30 cap). Applied on
// the current draw surface when the window surface is (re)created or the request/prop changes.
static int  sReqSwapInterval = 1;     // plugin default (display refresh) until it calls setSwapInterval
static bool sSwapDirty       = true;  // re-apply on next present
static void rcApplySwapInterval() {
    int eff = rc_prop_int("debug.routec.swapinterval", sReqSwapInterval);
    if (eglSwapInterval(sDpy, eff)) {
        LOGI("eglSwapInterval=%d (requested=%d, prop override=%s)", eff, sReqSwapInterval,
             rc_prop_int("debug.routec.swapinterval", -999) == -999 ? "none" : "yes");
    } else {
        LOGE("eglSwapInterval(%d) failed 0x%x", eff, eglGetError());
    }
}

// GPU frame-time probe via EXT_disjoint_timer_query (GLES timer queries; resolved at context creation). Gated on
// the `debug.routec.gputime` prop so it's off in normal play. One GL_TIME_ELAPSED query brackets each frame's
// plugin draws (begin after present, end before the next present) so it excludes our own present blit; results are
// read back non-blocking via a small pool and the per-second average is logged as `[gpuprobe]`.
#define GL_TIME_ELAPSED_EXT           0x88BF
#define GL_QUERY_RESULT_EXT           0x8866
#define GL_QUERY_RESULT_AVAILABLE_EXT 0x8867
#define GL_GPU_DISJOINT_EXT           0x8FBB
typedef void (*PFNGENQEXT)(GLsizei, GLuint*);
typedef void (*PFNQEXT)(GLenum, GLuint);
typedef void (*PFNENDQEXT)(GLenum);
typedef void (*PFNGETQUIVEXT)(GLuint, GLenum, GLuint*);
typedef void (*PFNGETQUI64VEXT)(GLuint, GLenum, GLuint64*);
static PFNGENQEXT      pglGenQueriesEXT          = nullptr;
static PFNQEXT         pglBeginQueryEXT          = nullptr;
static PFNENDQEXT      pglEndQueryEXT            = nullptr;
static PFNGETQUIVEXT   pglGetQueryObjectuivEXT   = nullptr;
static PFNGETQUI64VEXT pglGetQueryObjectui64vEXT = nullptr;
static bool sTimerFns = false;        // EXT functions resolved on this driver
#define RC_NQ 8
static GLuint sTQId[RC_NQ];           // pool of query objects (0 = free, 1 = active/between begin-end, 2 = pending)
static int    sTQState[RC_NQ] = {0};
static bool   sTQGen   = false;
static int    sTQActive = -1;
static bool   sTimerOn  = false;      // gputime prop currently enabling the probe
static double sGpuSumMs = 0, sGpuMinMs = 0, sGpuMaxMs = 0;
static int    sGpuFrames = 0;
static int    sGpuDisjoint = 0;       // drains this window that saw GPU_DISJOINT (Mali DVFS raises these; per-window, not per-event)
static int    sGpuAvailSeen = 0;      // results that became available this window (0 => availability, not disjoint, is the wall)
static int    sGpuHitch = 0;          // kept results above the hitch threshold this window (real stalls, surfaced not hidden)
#define RC_GPU_HITCH_MS  100.0        // a kept result over this is a real stall (shader compile / streaming / GC) — flagged
#define RC_GPU_GARBAGE_MS 10000.0     // a result over this is disjoint OVERFLOW garbage, not a real frame — only THESE are dropped
static double sGpuLastLog = 0;        // ms (monotonic) of the last [gpuprobe] emit

// JavaBridge GPU seam (resolved lazily once the GPU jar's class is on the classpath).
static jclass sJbCls = nullptr;
static jmethodID sJbBackBuf = nullptr;   // gpuFrameBackBuffer(II)[I
static jmethodID sJbPublish = nullptr;   // gpuPublish(II)V
static jmethodID sJbCanvasW = nullptr;   // canvasWidth()I
static jmethodID sJbCanvasH = nullptr;   // canvasHeight()I

static bool rc_jb_cache(JNIEnv *env) {
    if (sJbCls) return sJbBackBuf && sJbPublish;
    jclass c = env->FindClass("net/runelite/client/headless/JavaBridge");
    if (!c) { if (env->ExceptionCheck()) env->ExceptionClear(); return false; }
    sJbCls = (jclass) env->NewGlobalRef(c);
    sJbBackBuf = env->GetStaticMethodID(sJbCls, "gpuFrameBackBuffer", "(II)[I");
    sJbPublish = env->GetStaticMethodID(sJbCls, "gpuPublish", "(II)V");
    sJbCanvasW = env->GetStaticMethodID(sJbCls, "canvasWidth", "()I");
    sJbCanvasH = env->GetStaticMethodID(sJbCls, "canvasHeight", "()I");
    if (env->ExceptionCheck()) env->ExceptionClear();
    LOGI("JavaBridge cache: backBuf=%p publish=%p canvasW=%p canvasH=%p", sJbBackBuf, sJbPublish, sJbCanvasW, sJbCanvasH);
    return sJbBackBuf && sJbPublish;
}

// Re-bind the thread-affine EGL context on the calling (client/draw) thread. Cheap when already current.
static void rc_make_current() {
    if (sDpy != EGL_NO_DISPLAY && sCtx != EGL_NO_CONTEXT && eglGetCurrentContext() != sCtx) {
        eglMakeCurrent(sDpy, sSurf, sSurf, sCtx);
    }
}

// Map the live GL_VERSION ("OpenGL ES X.Y …") to the GLSL ES target string the downport prepends.
static void rc_set_es_target() {
    const char *v = (const char *) glGetString(GL_VERSION);
    int maj = 3, min = 0;
    if (v) sscanf(v, "OpenGL ES %d.%d", &maj, &min);
    int tier = maj * 10 + min;
    const char *es = (tier >= 32) ? "320 es" : (tier >= 31) ? "310 es" : "300 es";
    strncpy(sEsVer, es, sizeof(sEsVer) - 1);
    sEsVer[sizeof(sEsVer) - 1] = 0;
}

// ---- GLSL 330 -> GLES downport (the AG1b-validated recipe; see ReconActivity.downport) ----------------------
// (1+2) drop the pre-#version license + original #version line, prepend `#version <esVer>` + precision; (3) strip
// the ES-reserved `noperspective`; (4) strip the float-literal `f` suffix; (5) explicit int->float / ivec->vec
// casts at the exact scene-vertex sites that mix integer engine uniforms with floats (vertex-only strings, so
// applying to both stages is a no-op on the fragment shader). Validated PASS on Mali-G715 (AG1b).
static const char *kSceneVertexCasts[][2] = {
    {"vec4(vertf + base, 1)", "vec4(vertf + vec3(base), 1)"},
    {"hsl += ((entityTint.xyz - hsl) * entityTint.w) / 128;",
     "hsl += ((vec3(entityTint.xyz) - hsl) * float(entityTint.w)) / 128.0;"},
    {"((-expandedMapLoadingChunks * 8 + 1) * TILE_SIZE)", "(float(-expandedMapLoadingChunks * 8 + 1) * TILE_SIZE)"},
    {"((104 + expandedMapLoadingChunks * 8 - 1) * TILE_SIZE)", "(float(104 + expandedMapLoadingChunks * 8 - 1) * TILE_SIZE)"},
    {"cameraX - drawDistance", "cameraX - float(drawDistance)"},
    {"cameraX + drawDistance", "cameraX + float(drawDistance)"},
    {"cameraZ - drawDistance", "cameraZ - float(drawDistance)"},
    {"cameraZ + drawDistance", "cameraZ + float(drawDistance)"},
    {"fogDepth * TILE_SIZE) * useFog", "float(fogDepth) * TILE_SIZE) * float(useFog)"},
};

static void rc_replace_all(std::string &s, const std::string &from, const std::string &to) {
    if (from.empty()) return;
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) { s.replace(pos, from.size(), to); pos += to.size(); }
}

static std::string rc_downport(const std::string &src) {
    size_t v = src.find("#version");
    std::string body = (v != std::string::npos) ? src.substr(v) : src;
    size_t nl = body.find('\n');                                   // drop the original #version line
    body = (nl != std::string::npos) ? body.substr(nl + 1) : std::string();
    body = std::regex_replace(body, std::regex("#line[^\\n]*\\n"), "");                // strip RLHD #line directives (ES error lines then map to the flat source; our error path doesn't parse them)
    body = std::regex_replace(body, std::regex("\\bnoperspective\\b"), "");           // (3) reserved in ES
    // (4) strip the float `f` suffix — but ONLY a real suffix: require a non-identifier char after the f, else
    //     `\d+\.\d*[fF]` wrongly eats the `f` in `material1.flowMap` (matches "1.f") -> "material1.lowMap".
    body = std::regex_replace(body, std::regex("(\\d*\\.\\d+|\\d+\\.\\d*)[fF](?![a-zA-Z0-9_])"), "$1");
    for (auto &c : kSceneVertexCasts) rc_replace_all(body, c[0], c[1]);                // (5) explicit casts
    std::string precision =
        "precision highp float;\nprecision highp int;\n"
        "precision highp sampler2DArray;\nprecision highp usampler2DArray;\nprecision highp sampler2D;\n";
    // GLSL ES needs a default precision for EVERY sampler type used. RLHD's Zone vertex/shadow shaders use a
    // texture-buffer sampler (isamplerBuffer textureFaces) — add its precision, but only when the shader actually
    // uses one (the buffer-sampler types are unknown on a driver without texture_buffer, so don't emit it otherwise).
    if (body.find("samplerBuffer") != std::string::npos)
        precision += "precision highp isamplerBuffer;\nprecision highp usamplerBuffer;\nprecision highp samplerBuffer;\n";
    // 117HD Zone shaders use interface (IO) blocks + texture-buffer samplers (isamplerBuffer). These are CORE in
    // GLSL ES 3.2 (#version 320 es, the real Pixel 8/Mali tier — no directives needed) but on an ES 3.1 context
    // (the emulator's ANGLE) they require EXT directives. Geometry shaders (shadow pass) likewise. Emit them only
    // for 310 es; `enable` (not `require`) keeps shaders that don't use a feature compiling even if the ext is absent.
    std::string extns;
    if (std::string(sEsVer) == "310 es") {
        extns =
            "#extension GL_EXT_shader_io_blocks : enable\n"
            "#extension GL_OES_shader_io_blocks : enable\n"
            "#extension GL_EXT_texture_buffer : enable\n"
            "#extension GL_OES_texture_buffer : enable\n"
            "#extension GL_EXT_geometry_shader : enable\n"
            "#extension GL_OES_geometry_shader : enable\n";
    }
    return std::string("#version ") + sEsVer + "\n" + extns + precision + body;
}

static bool rcEglPrepareSurface(int w, int h) {
    if (sDpy == EGL_NO_DISPLAY) {
        sDpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (sDpy == EGL_NO_DISPLAY) { LOGE("eglGetDisplay failed"); return false; }
        EGLint vmaj = 0, vmin = 0;
        if (!eglInitialize(sDpy, &vmaj, &vmin)) { LOGE("eglInitialize failed"); return false; }
        LOGI("EGL %d.%d initialized", vmaj, vmin);
    }
    const EGLint cfgAttr[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT | EGL_WINDOW_BIT,   // pbuffer for bring-up + window surface for direct present
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_NONE };
    EGLint nc = 0;
    if (!eglChooseConfig(sDpy, cfgAttr, &sCfg, 1, &nc) || nc < 1) { LOGE("eglChooseConfig failed (nc=%d)", nc); return false; }
    const EGLint pb[] = { EGL_WIDTH, (w > 0 ? w : 16), EGL_HEIGHT, (h > 0 ? h : 16), EGL_NONE };
    sSurf = eglCreatePbufferSurface(sDpy, sCfg, pb);
    if (sSurf == EGL_NO_SURFACE) { LOGE("eglCreatePbufferSurface failed 0x%x", eglGetError()); return false; }
    return true;
}

static bool rcEglCreateContextCurrent() {
    eglBindAPI(EGL_OPENGL_ES_API);
    // Request the HIGHEST ES the driver gives (3.2 -> 3.1 -> 3.0); the base shaders downport to the matching
    // GLSL ES (320/310/300 es). AG1b validated 320 es on a 3.2 context — a 3.0-only context would reject them.
    for (int mn = 2; mn >= 0 && sCtx == EGL_NO_CONTEXT; mn--) {
        const EGLint ctxAttr[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, mn, EGL_NONE };
        sCtx = eglCreateContext(sDpy, sCfg, EGL_NO_CONTEXT, ctxAttr);
    }
    if (sCtx == EGL_NO_CONTEXT) { LOGE("eglCreateContext failed for ES 3.x 0x%x", eglGetError()); return false; }
    if (!eglMakeCurrent(sDpy, sSurf, sSurf, sCtx)) { LOGE("eglMakeCurrent failed 0x%x", eglGetError()); return false; }
    return true;
}

// Offscreen FBO (RGBA8 COLOR + DEPTH24) — the plugin renders depth-tested, so the AWTContext analogue supplies a
// depth attachment like librlawt's window FBO. Returned to the plugin as "framebuffer 0".
static bool rcBuildFbo(int w, int h) {
    if (sDepthRbo) { glDeleteRenderbuffers(1, &sDepthRbo); sDepthRbo = 0; }
    if (sColorRbo) { glDeleteRenderbuffers(1, &sColorRbo); sColorRbo = 0; }
    if (sFbo)      { glDeleteFramebuffers(1, &sFbo); sFbo = 0; }
    glGenFramebuffers(1, &sFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, sFbo);
    glGenRenderbuffers(1, &sColorRbo);
    glBindRenderbuffer(GL_RENDERBUFFER, sColorRbo);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, sColorRbo);
    glGenRenderbuffers(1, &sDepthRbo);
    glBindRenderbuffer(GL_RENDERBUFFER, sDepthRbo);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, sDepthRbo);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glViewport(0, 0, w, h);
    sFboW = w; sFboH = h;
    return status == GL_FRAMEBUFFER_COMPLETE;
}

// Phase 3 (Task A): resize the offscreen FBO in place on a canvas resize — reallocate the EXISTING color/depth
// renderbuffers' storage (their FBO attachments are by name, so they stay attached) instead of deleting and
// regenerating the FBO + both RBOs each time (driver object churn). First-ever build still goes through rcBuildFbo.
static bool rcResizeFbo(int w, int h) {
    if (sFbo == 0 || sColorRbo == 0 || sDepthRbo == 0) return rcBuildFbo(w, h);
    while (glGetError() != GL_NO_ERROR) {}   // drain stale errors so the check below is meaningful
    glBindFramebuffer(GL_FRAMEBUFFER, sFbo);
    glBindRenderbuffer(GL_RENDERBUFFER, sColorRbo);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
    glBindRenderbuffer(GL_RENDERBUFFER, sDepthRbo);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, w, h);
    // If in-place reallocation errored (e.g. GL_OUT_OF_MEMORY under pressure — in-place holds the OLD storage while
    // allocating the NEW, so peak = old+new), fall back to the delete-then-allocate path: it frees the old storage
    // FIRST (peak = max(old,new)), so it can still succeed, and it returns a trustworthy completeness status rather
    // than relying on glCheckFramebufferStatus over a half-allocated RBO (the driver-quirk false-COMPLETE risk).
    if (glGetError() != GL_NO_ERROR) return rcBuildFbo(w, h);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glViewport(0, 0, w, h);
    sFboW = w; sFboH = h;
    return status == GL_FRAMEBUFFER_COMPLETE;
}

// ---- Phase 1: reverse-Z clip-control enable + fail-safe self-test --------------------------------------------
// The 117HD Zone renderer renders reverse-Z (perspectiveInfiniteReverseZ + glClearDepth(0) + GL_GEQUAL), which is
// only depth-correct under a [0,1] clip volume. It never calls glClipControl, so we enable it here. A driver can
// expose glClipControlEXT yet not honour it; the self-test below PROVES the [0,1] range actually engaged before we
// trust it, and the fallback (standard [-1,1]) is exactly what the renderer ran under before this change — so a
// lying driver can never brick the scene to black.
static GLuint rcCompileSelfTestProgram() {
    static const char* vs =
        "#version 300 es\n"
        "void main(){\n"
        "  vec2 p = vec2(gl_VertexID==1 ? 3.0 : -1.0, gl_VertexID==2 ? 3.0 : -1.0);\n"  // fullscreen triangle
        "  gl_Position = vec4(p, 0.25, 1.0);\n"   // clip z=0.25, w=1 -> NDC z = 0.25 (inside both clip volumes)
        "}\n";
    static const char* fs =
        "#version 300 es\n"
        "precision mediump float;\n"
        "out vec4 o;\n"
        "void main(){ o = vec4(0.0, 1.0, 0.0, 1.0); }\n";  // green = the fragment survived the depth test
    GLuint v = glCreateShader(GL_VERTEX_SHADER);   glShaderSource(v,1,&vs,nullptr); glCompileShader(v);
    GLuint f = glCreateShader(GL_FRAGMENT_SHADER); glShaderSource(f,1,&fs,nullptr); glCompileShader(f);
    GLint ok = 0;
    glGetShaderiv(v, GL_COMPILE_STATUS, &ok); if (!ok) { glDeleteShader(v); glDeleteShader(f); return 0; }
    glGetShaderiv(f, GL_COMPILE_STATUS, &ok); if (!ok) { glDeleteShader(v); glDeleteShader(f); return 0; }
    GLuint p = glCreateProgram(); glAttachShader(p, v); glAttachShader(p, f); glLinkProgram(p);
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    glDeleteShader(v); glDeleteShader(f);
    if (!ok) { glDeleteProgram(p); return 0; }
    return p;
}

// Returns true iff the [0,1] (ZERO_TO_ONE) clip range is actually in effect. Draws one fragment at NDC z = 0.25
// with clearDepth 0.4 + GEQUAL into sFbo, then reads back the centre pixel:
//   ZERO_TO_ONE -> window depth 0.25 ; 0.25 >= 0.4 is FALSE -> fragment killed -> pixel stays RED  (engaged)
//   [-1,1]      -> window depth (0.25+1)/2 = 0.625 ; 0.625 >= 0.4 TRUE -> fragment drawn -> pixel GREEN (not engaged)
static bool rcClipControlSelfTest() {
    GLuint prog = rcCompileSelfTestProgram();
    if (!prog) { LOGE("clipcontrol self-test: shader build FAILED -> treating clip as NOT engaged"); return false; }
    GLuint vao = 0; glGenVertexArrays(1, &vao); glBindVertexArray(vao);   // GLES3 draw needs a bound VAO
    glBindFramebuffer(GL_FRAMEBUFFER, sFbo);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {   // self-contained guard; caller also gates on fboOk
        LOGE("clipcontrol self-test: target FBO not complete -> treating clip as NOT engaged");
        glBindVertexArray(0); glDeleteVertexArrays(1, &vao); glDeleteProgram(prog);
        return false;   // -> caller reverts to known-good standard depth
    }
    glViewport(0, 0, sFboW, sFboH);
    glDisable(GL_SCISSOR_TEST);                          // glClear is clipped by scissor -> ensure the whole buffer is painted
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);     // and gated by the colour mask -> ensure the red clear actually writes
    glDisable(GL_CULL_FACE);
    glEnable(GL_DEPTH_TEST);
    glDepthMask(GL_TRUE);
    glDepthRangef(0.0f, 1.0f);
    glDepthFunc(GL_GEQUAL);
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);   // red = fragment failed the depth test (i.e. ZERO_TO_ONE engaged)
    glClearDepthf(0.4f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glUseProgram(prog);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();
    unsigned char px[4] = {0, 0, 0, 0};
    glReadPixels(sFboW / 2, sFboH / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    // Leave GL neutral; the plugin re-sets depthFunc/clearColor/clearDepth/program/VAO every frame via RenderState.
    glUseProgram(0);
    glBindVertexArray(0);
    glDeleteVertexArrays(1, &vao);
    glDeleteProgram(prog);
    glDepthFunc(GL_LESS);
    glDisable(GL_DEPTH_TEST);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    bool isRed   = px[0] > 200 && px[1] < 60 && px[2] < 60;
    bool isGreen = px[1] > 200 && px[0] < 60 && px[2] < 60;
    LOGI("clipcontrol self-test: centre px=(%u,%u,%u,%u) -> %s", px[0], px[1], px[2], px[3],
         isRed ? "RED (ZERO_TO_ONE engaged)" : isGreen ? "GREEN (clip NOT engaged)" : "INDETERMINATE");
    return isRed;   // only a clean RED proves the [0,1] range took effect
}

// Enable reverse-Z [0,1] clip at context bring-up, with the fail-safe revert. `setprop debug.routec.clipcontrol 0`
// forces standard depth (the pre-Phase-1 behaviour) on device with no rebuild.
static void rcSetupClipControl() {
    sClipReverseZ = false;
    if (!pglClipControlEXT) pglClipControlEXT = (PFNGLCLIPCONTROLEXTPROC) eglGetProcAddress("glClipControlEXT");
    if (rc_prop_int("debug.routec.clipcontrol", 1) == 0) {
        if (pglClipControlEXT) pglClipControlEXT(GL_LOWER_LEFT, GL_NEGATIVE_ONE_TO_ONE);
        LOGI("clipcontrol: forced OFF (debug.routec.clipcontrol=0) -> standard [-1,1] depth");
        return;
    }
    if (!pglClipControlEXT) {
        LOGE("clipcontrol: glClipControlEXT absent -> reverse-Z [0,1] unavailable; depth stays standard [-1,1]");
        return;
    }
    pglClipControlEXT(GL_LOWER_LEFT, GL_ZERO_TO_ONE);
    if (rcClipControlSelfTest()) {
        sClipReverseZ = true;
        LOGI("clipcontrol: reverse-Z [0,1] ENGAGED + verified");
    } else {
        pglClipControlEXT(GL_LOWER_LEFT, GL_NEGATIVE_ONE_TO_ONE);   // FAIL-SAFE: revert to known-good standard range
        LOGE("clipcontrol: self-test did NOT confirm [0,1] -> reverted to standard [-1,1] (known-good)");
    }
}

// ---- ByteBuffer native-order helper (LWJGL maps return native-ordered buffers) ------------------------------
static jobject rc_native_order(JNIEnv *env, jobject bb) {
    if (!bb) return bb;
    jclass boCls = env->FindClass("java/nio/ByteOrder");
    jclass bbCls = env->FindClass("java/nio/ByteBuffer");
    if (boCls && bbCls) {
        jmethodID nativeOrder = env->GetStaticMethodID(boCls, "nativeOrder", "()Ljava/nio/ByteOrder;");
        jmethodID order = env->GetMethodID(bbCls, "order", "(Ljava/nio/ByteOrder;)Ljava/nio/ByteBuffer;");
        if (nativeOrder && order) {
            jobject no = env->CallStaticObjectMethod(boCls, nativeOrder);
            jobject ret = env->CallObjectMethod(bb, order, no);
            if (ret) bb = ret;
        }
    }
    if (env->ExceptionCheck()) env->ExceptionClear();
    return bb;
}

static bool rc_gl_has_ext(const char *name) {
    const char *ext = (const char *) glGetString(GL_EXTENSIONS);
    return ext && strstr(ext, name) != nullptr;
}

// Phase 4 (extension probe): read-only gate prerequisite. Detects whether this driver actually supports the two
// extensions the 117HD Zone path would need to engage its draw-batching / persistent-mapping levers, and verifies
// the persistent-map lifetime contract — then logs a single verdict. It NEVER flips a cap or implements a forwarder;
// those L-effort steps stay gated on a confirmed result here. An extension string can be present yet the entry point
// absent (or vice-versa), so both the string AND a non-null eglGetProcAddress are required (the clipControl lesson).
static void rcProbePhase4Caps() {
    bool extMdi = rc_gl_has_ext("GL_EXT_multi_draw_indirect");
    bool extBs  = rc_gl_has_ext("GL_EXT_buffer_storage");
    void* fnMdi = (void*) eglGetProcAddress("glMultiDrawArraysIndirectEXT");
    void* fnBs  = (void*) eglGetProcAddress("glBufferStorageEXT");
    bool mdiOk  = extMdi && fnMdi != nullptr;
    bool bsOk   = extBs  && fnBs  != nullptr;

    // Persistent-map lifetime check (only if buffer_storage is real). At context-creation there are no frames yet,
    // so this validates the FUNCTIONAL contract: immutable storage with the persistent+coherent flags allocates, the
    // mapping returns a usable pointer, survives a write -> GPU sync (glFinish) -> write WITHOUT a remap, and unmaps
    // cleanly — all GL-error-free. -1 = not tested (no buffer_storage), 0 = failed (skip persistent mapping), 1 = ok.
    int persistOk = -1;
    if (bsOk) {
        PFNGLBUFFERSTORAGEEXTPROC pBufferStorage = (PFNGLBUFFERSTORAGEEXTPROC) fnBs;
        while (glGetError() != GL_NO_ERROR) {}                       // drain stale errors so the checks below are real
        GLuint b = 0; glGenBuffers(1, &b); glBindBuffer(GL_ARRAY_BUFFER, b);
        const GLsizeiptr sz = 4096;
        const GLbitfield flags = GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_COHERENT_BIT_EXT;
        pBufferStorage(GL_ARRAY_BUFFER, sz, nullptr, flags);
        // Only map if storage SUCCEEDED — the ternary keeps the EXT map bits out of glMapBufferRange unless
        // glBufferStorage went clean (and we are already inside the bsOk gate, so the persistent/coherent bits are
        // valid for glMapBufferRange per EXT_buffer_storage). A storage failure short-circuits to p=nullptr.
        void* p = (glGetError() == GL_NO_ERROR) ? glMapBufferRange(GL_ARRAY_BUFFER, 0, sz, flags) : nullptr;
        if (p && glGetError() == GL_NO_ERROR) {
            ((volatile uint32_t*) p)[0] = 0xC0FFEEu;                 // write through the persistent mapping
            glFinish();                                             // cross a GPU sync point with the mapping live
            ((volatile uint32_t*) p)[1] = 0x0BEEFu;                 // still writable after, no remap?
            persistOk = (glGetError() == GL_NO_ERROR) ? 1 : 0;
            glUnmapBuffer(GL_ARRAY_BUFFER);
            if (glGetError() != GL_NO_ERROR) persistOk = 0;
        } else {
            persistOk = 0;
        }
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glDeleteBuffers(1, &b);
        while (glGetError() != GL_NO_ERROR) {}                       // leave no error pending for the renderer
    }
    LOGI("[gpuprobe-caps] multi_draw_indirect=%d (ext=%d fn=%d) buffer_storage=%d (ext=%d fn=%d) persistent_map_ok=%d "
         "-- L-effort gated on this; draw-call profile: setprop debug.routec.drawcount 1",
         mdiOk, extMdi, fnMdi != nullptr, bsOk, extBs, fnBs != nullptr, persistOk);
}

// =============================================================================================================
// GL forwards — kGLALL. Clean GLES forwards (iOS diag/perf/water/SS stripped). The 5 non-ES-core entry points
// are shimmed; the BGRA UI-texture upload is swizzled to RGBA (silently corrupts colour on GLES otherwise).
// =============================================================================================================
#define GLF static void JNICALL
GLF rc_glActiveTexture(JNIEnv*, jclass, jint a0){ glActiveTexture(a0); }
GLF rc_glAttachShader(JNIEnv*, jclass, jint a0, jint a1){ glAttachShader(a0,a1); }
GLF rc_glBindBuffer(JNIEnv*, jclass, jint a0, jint a1){ glBindBuffer(a0,a1); }
GLF rc_glBindBufferBase(JNIEnv*, jclass, jint a0, jint a1, jint a2){ glBindBufferBase(a0,a1,a2); }
GLF rc_glBindFramebuffer(JNIEnv*, jclass, jint a0, jint a1){ glBindFramebuffer(a0,a1); }
GLF rc_glBindRenderbuffer(JNIEnv*, jclass, jint a0, jint a1){ glBindRenderbuffer(a0,a1); }
GLF rc_glBindTexture(JNIEnv*, jclass, jint a0, jint a1){ glBindTexture(a0,a1); }
GLF rc_glBindVertexArray(JNIEnv*, jclass, jint a0){ glBindVertexArray(a0); }
GLF rc_glBlendFunc(JNIEnv*, jclass, jint a0, jint a1){ glBlendFunc(a0,a1); }
GLF rc_glBlendFuncSeparate(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3){ glBlendFuncSeparate(a0,a1,a2,a3); }
GLF rc_glBlitFramebuffer(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jint a7, jint a8, jint a9){ glBlitFramebuffer(a0,a1,a2,a3,a4,a5,a6,a7,a8,a9); }
GLF rc_glBufferData_J(JNIEnv*, jclass, jint a0, jlong a1, jint a2){ glBufferData((GLenum)a0,(GLsizeiptr)a1,nullptr,(GLenum)a2); }
GLF rc_glBufferData_F(JNIEnv* e, jclass, jint a0, jobject a1, jint a2){ void*d=e->GetDirectBufferAddress(a1); jlong cap=e->GetDirectBufferCapacity(a1); glBufferData((GLenum)a0,(GLsizeiptr)(cap*4),d,(GLenum)a2); }
GLF rc_glBufferData_I(JNIEnv* e, jclass, jint a0, jobject a1, jint a2){ void*d=e->GetDirectBufferAddress(a1); jlong cap=e->GetDirectBufferCapacity(a1); glBufferData((GLenum)a0,(GLsizeiptr)(cap*4),d,(GLenum)a2); }
static jint JNICALL rc_glCheckFramebufferStatus(JNIEnv*, jclass, jint a0){ return (jint)glCheckFramebufferStatus(a0); }
GLF rc_glClear(JNIEnv*, jclass, jint a0){ glClear(a0); }
GLF rc_glClearColor(JNIEnv*, jclass, jfloat a0, jfloat a1, jfloat a2, jfloat a3){ glClearColor(a0,a1,a2,a3); }
GLF rc_glClearDepth(JNIEnv*, jclass, jdouble a0){ glClearDepthf((GLfloat)a0); }              // shim: GLES has only glClearDepthf
GLF rc_glColorMask(JNIEnv*, jclass, jboolean a0, jboolean a1, jboolean a2, jboolean a3){ glColorMask(a0,a1,a2,a3); }
GLF rc_glCompileShader(JNIEnv*, jclass, jint a0){ glCompileShader(a0); }
static jint JNICALL rc_glCreateProgram(JNIEnv*, jclass){ return (jint)glCreateProgram(); }
static jint JNICALL rc_glCreateShader(JNIEnv*, jclass, jint a0){ return (jint)glCreateShader(a0); }
GLF rc_glDeleteBuffers(JNIEnv*, jclass, jint a0){ GLuint x=(GLuint)a0; glDeleteBuffers(1,&x); }
GLF rc_glDeleteFramebuffers(JNIEnv*, jclass, jint a0){ GLuint x=(GLuint)a0; glDeleteFramebuffers(1,&x); }
GLF rc_glDeleteProgram(JNIEnv*, jclass, jint a0){ glDeleteProgram(a0); }
GLF rc_glDeleteRenderbuffers(JNIEnv*, jclass, jint a0){ GLuint x=(GLuint)a0; glDeleteRenderbuffers(1,&x); }
GLF rc_glDeleteShader(JNIEnv*, jclass, jint a0){ glDeleteShader(a0); }
GLF rc_glDeleteTextures(JNIEnv*, jclass, jint a0){ GLuint x=(GLuint)a0; glDeleteTextures(1,&x); }
GLF rc_glDeleteVertexArrays(JNIEnv*, jclass, jint a0){ GLuint x=(GLuint)a0; glDeleteVertexArrays(1,&x); }
GLF rc_glDepthFunc(JNIEnv*, jclass, jint a0){ glDepthFunc(a0); }
GLF rc_glDepthMask(JNIEnv*, jclass, jboolean a0){ glDepthMask(a0); }
GLF rc_glDetachShader(JNIEnv*, jclass, jint a0, jint a1){ glDetachShader(a0,a1); }
GLF rc_glDisable(JNIEnv*, jclass, jint a0){ glDisable(a0); }
GLF rc_glDrawArrays(JNIEnv*, jclass, jint a0, jint a1, jint a2){ if (sDrawCountOn) sDcDrawArrays++; glDrawArrays(a0,a1,a2); }
GLF rc_glDrawElements(JNIEnv*, jclass, jint a0, jint a1, jint a2, jlong a3){ if (sDrawCountOn) sDcDrawElements++; glDrawElements(a0,a1,a2,(const void*)(intptr_t)a3); }
GLF rc_glEnable(JNIEnv*, jclass, jint a0){ glEnable(a0); }
GLF rc_glEnableVertexAttribArray(JNIEnv*, jclass, jint a0){ glEnableVertexAttribArray(a0); }
GLF rc_glFlushMappedBufferRange(JNIEnv*, jclass, jint a0, jlong a1, jlong a2){ glFlushMappedBufferRange(a0,(GLintptr)a1,(GLsizeiptr)a2); }
GLF rc_glFramebufferRenderbuffer(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3){ glFramebufferRenderbuffer(a0,a1,a2,a3); }
static jint JNICALL rc_glGenBuffers(JNIEnv*, jclass){ GLuint x=0; glGenBuffers(1,&x); return (jint)x; }
static jint JNICALL rc_glGenFramebuffers(JNIEnv*, jclass){ GLuint x=0; glGenFramebuffers(1,&x); return (jint)x; }
static jint JNICALL rc_glGenRenderbuffers(JNIEnv*, jclass){ GLuint x=0; glGenRenderbuffers(1,&x); return (jint)x; }
static jint JNICALL rc_glGenTextures(JNIEnv*, jclass){ GLuint x=0; glGenTextures(1,&x); return (jint)x; }
static jint JNICALL rc_glGenVertexArrays(JNIEnv*, jclass){ GLuint x=0; glGenVertexArrays(1,&x); return (jint)x; }
GLF rc_glGenerateMipmap(JNIEnv*, jclass, jint a0){ glGenerateMipmap(a0); }
static jint JNICALL rc_glGetError(JNIEnv*, jclass){ return (jint)glGetError(); }
static jfloat JNICALL rc_glGetFloat(JNIEnv*, jclass, jint a0){ GLfloat v=0; glGetFloatv(a0,&v); return v; }
static jint JNICALL rc_glGetInteger(JNIEnv*, jclass, jint a0){ GLint v=0; glGetIntegerv(a0,&v); return (jint)v; }
static jstring JNICALL rc_glGetProgramInfoLog(JNIEnv* e, jclass, jint a0){ char buf[4096]; GLsizei n=0; glGetProgramInfoLog(a0,sizeof(buf),&n,buf); buf[n<(GLsizei)sizeof(buf)?n:sizeof(buf)-1]=0; return e->NewStringUTF(buf); }
static jint JNICALL rc_glGetProgrami(JNIEnv*, jclass, jint a0, jint a1){ GLint v=0; glGetProgramiv(a0,a1,&v); return (jint)v; }
static jstring JNICALL rc_glGetShaderInfoLog(JNIEnv* e, jclass, jint a0){ char buf[4096]; GLsizei n=0; glGetShaderInfoLog(a0,sizeof(buf),&n,buf); buf[n<(GLsizei)sizeof(buf)?n:sizeof(buf)-1]=0; return e->NewStringUTF(buf); }
static jint JNICALL rc_glGetShaderi(JNIEnv*, jclass, jint a0, jint a1){ GLint v=0; glGetShaderiv(a0,a1,&v); return (jint)v; }
static jstring JNICALL rc_glGetString(JNIEnv* e, jclass, jint a0){ const char* s=(const char*)glGetString((GLenum)a0); return e->NewStringUTF(s?s:""); }
static jint JNICALL rc_glGetUniformBlockIndex(JNIEnv* e, jclass, jint a0, jstring a1){ const char* n=e->GetStringUTFChars(a1,nullptr); jint r=(jint)glGetUniformBlockIndex(a0,n); e->ReleaseStringUTFChars(a1,n); return r; }
static jint JNICALL rc_glGetUniformLocation(JNIEnv* e, jclass, jint a0, jstring a1){ const char* n=e->GetStringUTFChars(a1,nullptr); jint r=(jint)glGetUniformLocation(a0,n); e->ReleaseStringUTFChars(a1,n); return r; }
GLF rc_glLinkProgram(JNIEnv*, jclass, jint a0){ glLinkProgram(a0); }
// Classic glMapBuffer has no range form on GLES, so map the WHOLE buffer via glMapBufferRange with bits derived
// from the GL access enum. Crucially this must match classic glMapBuffer semantics: GL_WRITE_ONLY maps for
// writing and PRESERVES existing contents — it does NOT discard. RLHD reaches this path (GL_ARB_map_buffer_range
// reported false) for buffers it only PARTIALLY rewrites (e.g. dynamic player-model geometry written at offsets);
// adding GL_MAP_INVALIDATE_BUFFER_BIT here would discard the whole buffer so the un-rewritten regions render as
// garbage (stale scene data) — exactly the "player models flash with environment colours" bug. So: no invalidate.
static GLbitfield rc_mapBitsFor(GLenum access){
    switch (access) {
        case GL_READ_ONLY:  return GL_MAP_READ_BIT;
        case GL_READ_WRITE: return GL_MAP_READ_BIT | GL_MAP_WRITE_BIT;
        default:            return GL_MAP_WRITE_BIT;   // GL_WRITE_ONLY — preserve contents (no discard)
    }
}
static jobject rc_mapReuse(JNIEnv* e, GLenum target, GLenum access, GLsizeiptr sz, jobject old){
    if (sz<=0) return nullptr;
    void* p = glMapBufferRange(target, 0, sz, rc_mapBitsFor(access));
    if (!p) return nullptr;
    // LWJGL reuse contract: hand back the SAME ByteBuffer when it still describes this mapping, so the per-frame
    // map() in GLMappedBuffer doesn't allocate a fresh direct buffer every draw.
    if (old != nullptr && e->GetDirectBufferAddress(old) == p && e->GetDirectBufferCapacity(old) == (jlong)sz)
        return old;
    return rc_native_order(e, e->NewDirectByteBuffer(p, sz));
}
static jobject JNICALL rc_glMapBuffer(JNIEnv* e, jclass, jint a0, jint a1){
    GLint sz=0; glGetBufferParameteriv((GLenum)a0, GL_BUFFER_SIZE, &sz);
    if (sz<=0) return nullptr;
    GLbitfield acc = GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT;   // glMapBuffer(WRITE_ONLY) -> range equivalent
    void* p = glMapBufferRange((GLenum)a0, 0, sz, acc);
    return p ? rc_native_order(e, e->NewDirectByteBuffer(p, sz)) : nullptr;
}
// 3-arg glMapBuffer(target, access, oldBuffer) — the LWJGL "reuse the old mapped buffer" form. RLHD's
// GLMappedBuffer takes this path when it doesn't use the range mapper (the branch real-Nvidia drivers hit,
// where the 2-arg form above is never reached). Query the size, then map+reuse.
static jobject JNICALL rc_glMapBuffer3(JNIEnv* e, jclass, jint t, jint a, jobject old){
    GLint sz=0; glGetBufferParameteriv((GLenum)t, GL_BUFFER_SIZE, &sz);
    return rc_mapReuse(e, (GLenum)t, (GLenum)a, (GLsizeiptr)sz, old);
}
// 4-arg glMapBuffer(target, access, length, oldBuffer) — same, with the size supplied by the caller.
static jobject JNICALL rc_glMapBuffer4(JNIEnv* e, jclass, jint t, jint a, jlong len, jobject old){
    return rc_mapReuse(e, (GLenum)t, (GLenum)a, (GLsizeiptr)len, old);
}
static jobject JNICALL rc_glMapBufferRange(JNIEnv* e, jclass, jint a0, jlong a1, jlong a2, jint a3, jobject){
    void* p = glMapBufferRange((GLenum)a0,(GLintptr)a1,(GLsizeiptr)a2,(GLbitfield)a3);
    return p ? rc_native_order(e, e->NewDirectByteBuffer(p, a2)) : nullptr;
}
GLF rc_glMultiDrawArrays(JNIEnv* e, jclass, jint a0, jobject a1, jobject a2){
    const GLint* first=(const GLint*)e->GetDirectBufferAddress(a1);
    const GLsizei* count=(const GLsizei*)e->GetDirectBufferAddress(a2);
    GLsizei n=(GLsizei)e->GetDirectBufferCapacity(a1);
    if (sDrawCountOn && first && count) { sDcMultiCalls++; sDcMultiRanges += n; }   // 1 emit = n driver draw calls here
    for (GLsizei i=0;i<n && first && count;i++) glDrawArrays((GLenum)a0, first[i], count[i]);   // GLES has no glMultiDrawArrays
}
GLF rc_glReadBuffer(JNIEnv*, jclass, jint a0){ glReadBuffer(a0); }
GLF rc_glReadPixels(JNIEnv* e, jclass, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jobject a6){ glReadPixels(a0,a1,a2,a3,(GLenum)a4,(GLenum)a5,e->GetDirectBufferAddress(a6)); }
GLF rc_glRenderbufferStorageMultisample(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4){
    GLenum ifmt=(GLenum)a2; if (ifmt==GL_RGBA) ifmt=GL_RGBA8;   // ES needs a SIZED internalformat
    glRenderbufferStorageMultisample(a0,a1,ifmt,a3,a4);
}
GLF rc_glShaderSource(JNIEnv* e, jclass, jint a0, jstring a1){
    const char* s=e->GetStringUTFChars(a1,nullptr);
    std::string down = rc_downport(s ? s : "");         // 330 -> GLES (the AG1b-validated recipe)
    e->ReleaseStringUTFChars(a1,s);
    // AG3-c shader-port aid: numbered dump of the downported source so a driver "shader N line M" error maps to
    // an exact source line (the #line strip above makes M index this flat source). Toggle by `adb shell run-as
    // <pkg> touch files/rlhd_shaderdump` — off by default so it doesn't flood logcat in normal runs.
    if (access("/data/data/dev.audaro.runemobile/files/rlhd_shaderdump", F_OK) == 0 ||
        access("/sdcard/Android/data/dev.audaro.runemobile/files/rlhd_shaderdump", F_OK) == 0) {   // external = Firebase --other-files
        static int sdidx=0; int idx=sdidx++; int ln=1; size_t p=0;
        while (p<down.size()){ size_t nl=down.find('\n',p);
            std::string line = down.substr(p, nl==std::string::npos ? std::string::npos : nl-p);
            LOGI("SHDR[%d]%3d|%s", idx, ln, line.c_str()); ln++;
            if (nl==std::string::npos) break; p=nl+1; }
    }
    const char* ds = down.c_str();
    glShaderSource((GLuint)a0,1,&ds,nullptr);
}
GLF rc_glTexImage2D(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jint a7, jlong a8){
    if ((GLenum)a6==GL_BGRA){ a6=GL_RGBA; glTexImage2D((GLenum)a0,a1,a2,a3,a4,a5,(GLenum)a6,(GLenum)a7,(const void*)(intptr_t)a8);
        glTexParameteri((GLenum)a0, GL_TEXTURE_SWIZZLE_R, GL_BLUE); glTexParameteri((GLenum)a0, GL_TEXTURE_SWIZZLE_B, GL_RED); return; }
    glTexImage2D((GLenum)a0,a1,a2,a3,a4,a5,(GLenum)a6,(GLenum)a7,(const void*)(intptr_t)a8);
}
GLF rc_glTexImage3D(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jint a7, jint a8, jlong a9){ glTexImage3D((GLenum)a0,a1,a2,a3,a4,a5,a6,(GLenum)a7,(GLenum)a8,(const void*)(intptr_t)a9); }
GLF rc_glTexParameterf(JNIEnv*, jclass, jint a0, jint a1, jfloat a2){ glTexParameterf(a0,a1,a2); }
GLF rc_glTexParameteri(JNIEnv*, jclass, jint a0, jint a1, jint a2){ glTexParameteri(a0,a1,a2); }
GLF rc_glTexSubImage2D(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jint a7, jlong a8){
    if ((GLenum)a6==GL_BGRA) a6=GL_RGBA;
    if ((GLenum)a7==GL_UNSIGNED_INT_8_8_8_8_REV) a7=GL_UNSIGNED_BYTE;
    glTexSubImage2D((GLenum)a0,a1,a2,a3,a4,a5,(GLenum)a6,(GLenum)a7,(const void*)(intptr_t)a8);
}
GLF rc_glTexSubImage3D(JNIEnv* e, jclass, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jint a7, jint a8, jint a9, jobject a10){ glTexSubImage3D((GLenum)a0,a1,a2,a3,a4,a5,a6,a7,(GLenum)a8,(GLenum)a9,e->GetDirectBufferAddress(a10)); }
GLF rc_glUniform1f(JNIEnv*, jclass, jint a0, jfloat a1){ glUniform1f(a0,a1); }
GLF rc_glUniform1i(JNIEnv*, jclass, jint a0, jint a1){ glUniform1i(a0,a1); }
GLF rc_glUniform2fv(JNIEnv* e, jclass, jint a0, jfloatArray a1){ jfloat* p=e->GetFloatArrayElements(a1,nullptr); jsize n=e->GetArrayLength(a1); glUniform2fv(a0,n/2,p); e->ReleaseFloatArrayElements(a1,p,JNI_ABORT); }
GLF rc_glUniform2i(JNIEnv*, jclass, jint a0, jint a1, jint a2){ glUniform2i(a0,a1,a2); }
GLF rc_glUniform3i(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3){ glUniform3i(a0,a1,a2,a3); }
GLF rc_glUniform4f(JNIEnv*, jclass, jint a0, jfloat a1, jfloat a2, jfloat a3, jfloat a4){ glUniform4f(a0,a1,a2,a3,a4); }
GLF rc_glUniform4i(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4){ glUniform4i(a0,a1,a2,a3,a4); }
GLF rc_glUniformBlockBinding(JNIEnv*, jclass, jint a0, jint a1, jint a2){ glUniformBlockBinding(a0,a1,a2); }
GLF rc_glUniformMatrix4fv(JNIEnv* e, jclass, jint a0, jboolean a1, jfloatArray a2){ jfloat* p=e->GetFloatArrayElements(a2,nullptr); jsize n=e->GetArrayLength(a2); glUniformMatrix4fv(a0,n/16,a1,p); e->ReleaseFloatArrayElements(a2,p,JNI_ABORT); }
static jboolean JNICALL rc_glUnmapBuffer(JNIEnv*, jclass, jint a0){ return (jboolean)glUnmapBuffer(a0); }
GLF rc_glUseProgram(JNIEnv*, jclass, jint a0){ glUseProgram(a0); }
GLF rc_glValidateProgram(JNIEnv*, jclass, jint a0){ glValidateProgram(a0); }
GLF rc_glVertexAttribIPointer(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jlong a4){ glVertexAttribIPointer(a0,a1,(GLenum)a2,a3,(const void*)(intptr_t)a4); }
GLF rc_glVertexAttribPointer(JNIEnv*, jclass, jint a0, jint a1, jint a2, jboolean a3, jint a4, jlong a5){ glVertexAttribPointer(a0,a1,(GLenum)a2,a3,a4,(const void*)(intptr_t)a5); }
GLF rc_glViewport(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3){ glViewport(a0,a1,a2,a3); }
GLF rc_glTexStorage3D(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5){ glTexStorage3D(a0,a1,a2,a3,a4,a5); }
GLF rc_glDebugMessageControl(JNIEnv*, jclass, jint, jint, jint, jint, jboolean){ /* KHR_debug optional; no-op */ }
GLF rc_glClipControl(JNIEnv*, jclass, jint a0, jint a1){
    // Forward to EXT_clip_control if present; no-op otherwise (depth then stays standard [-1,1] — GEQUAL does NOT
    // emulate reverse-Z on its own). This path serves the base gpu plugin; 117HD/Zone enables + verifies reverse-Z
    // at context creation instead (rcSetupClipControl), since it never calls glClipControl itself.
    if (!pglClipControlEXT) pglClipControlEXT = (PFNGLCLIPCONTROLEXTPROC) eglGetProcAddress("glClipControlEXT");
    if (pglClipControlEXT) pglClipControlEXT((GLenum)a0, (GLenum)a1);
}

// =============================================================================================================
// AG3 — 117HD (RLHD) Zone GL-delta forwards. All GLES 3.1/3.2 core (gl32.h) and forwarded straight to GLESv3,
// EXCEPT a few desktop/EXT entry points the Zone path either gates off (GLCapabilities reports the ARB flags
// false -> RLHD takes the GLES-core fallback) or uses only in the dev perf overlay; those are no-op'd / shimmed
// so they resolve but never corrupt state. Compute/indirect/storage entries are registered (gl32.h core) but
// gated OFF on Zone — present so the class graph is fully bound.
// =============================================================================================================
GLF rc_glCullFace(JNIEnv*, jclass, jint a0){ glCullFace((GLenum)a0); }
GLF rc_glFinish(JNIEnv*, jclass){ glFinish(); }
GLF rc_glFlush(JNIEnv*, jclass){ glFlush(); }
GLF rc_glDrawBuffer(JNIEnv*, jclass, jint a0){ GLenum b=(GLenum)a0; glDrawBuffers(1,&b); }   // GLES has glDrawBuffers only
GLF rc_glTexBuffer(JNIEnv*, jclass, jint a0, jint a1, jint a2){ glTexBuffer((GLenum)a0,(GLenum)a1,(GLuint)a2); }
GLF rc_glVertexAttribDivisor(JNIEnv*, jclass, jint a0, jint a1){ glVertexAttribDivisor((GLuint)a0,(GLuint)a1); }
GLF rc_glFramebufferTexture(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3){ glFramebufferTexture((GLenum)a0,(GLenum)a1,(GLuint)a2,a3); }
GLF rc_glFramebufferTexture2D(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4){ glFramebufferTexture2D((GLenum)a0,(GLenum)a1,(GLenum)a2,(GLuint)a3,a4); }
GLF rc_glFramebufferTextureLayer(JNIEnv*, jclass, jint a0, jint a1, jint a2, jint a3, jint a4){ glFramebufferTextureLayer((GLenum)a0,(GLenum)a1,(GLuint)a2,a3,a4); }
GLF rc_glBindImageTexture(JNIEnv*, jclass, jint a0, jint a1, jint a2, jboolean a3, jint a4, jint a5, jint a6){ glBindImageTexture((GLuint)a0,(GLuint)a1,a2,a3,a4,(GLenum)a5,(GLenum)a6); }
GLF rc_glCopyBufferSubData(JNIEnv*, jclass, jint a0, jint a1, jlong a2, jlong a3, jlong a4){ glCopyBufferSubData((GLenum)a0,(GLenum)a1,(GLintptr)a2,(GLintptr)a3,(GLsizeiptr)a4); }
GLF rc_glInvalidateBufferData(JNIEnv*, jclass, jint){ /* desktop GL hint; GLES has no equivalent -> no-op */ }
static jlong JNICALL rc_glGetBufferParameteri64(JNIEnv*, jclass, jint a0, jint a1){ GLint64 v=0; glGetBufferParameteri64v((GLenum)a0,(GLenum)a1,&v); return (jlong)v; }
static jint JNICALL rc_glGetFramebufferAttachmentParameteri(JNIEnv*, jclass, jint a0, jint a1, jint a2){ GLint v=0; glGetFramebufferAttachmentParameteriv((GLenum)a0,(GLenum)a1,(GLenum)a2,&v); return (jint)v; }
GLF rc_glGetIntegerv_A(JNIEnv* e, jclass, jint a0, jintArray a1){ jint* p=e->GetIntArrayElements(a1,nullptr); glGetIntegerv((GLenum)a0,(GLint*)p); e->ReleaseIntArrayElements(a1,p,0); }
GLF rc_glGetIntegerv_B(JNIEnv* e, jclass, jint a0, jobject a1){ glGetIntegerv((GLenum)a0,(GLint*)e->GetDirectBufferAddress(a1)); }
GLF rc_glGetProgramiv_A(JNIEnv* e, jclass, jint a0, jint a1, jintArray a2){ jint* p=e->GetIntArrayElements(a2,nullptr); glGetProgramiv((GLuint)a0,(GLenum)a1,(GLint*)p); e->ReleaseIntArrayElements(a2,p,0); }
GLF rc_glGetProgramiv_B(JNIEnv* e, jclass, jint a0, jint a1, jobject a2){ glGetProgramiv((GLuint)a0,(GLenum)a1,(GLint*)e->GetDirectBufferAddress(a2)); }
GLF rc_glTexParameterfv_A(JNIEnv* e, jclass, jint a0, jint a1, jfloatArray a2){ jfloat* p=e->GetFloatArrayElements(a2,nullptr); glTexParameterfv((GLenum)a0,(GLenum)a1,p); e->ReleaseFloatArrayElements(a2,p,JNI_ABORT); }
GLF rc_glTexParameterfv_B(JNIEnv* e, jclass, jint a0, jint a1, jobject a2){ glTexParameterfv((GLenum)a0,(GLenum)a1,(const GLfloat*)e->GetDirectBufferAddress(a2)); }
GLF rc_glUniform2f(JNIEnv*, jclass, jint a0, jfloat a1, jfloat a2){ glUniform2f(a0,a1,a2); }
GLF rc_glUniform3f(JNIEnv*, jclass, jint a0, jfloat a1, jfloat a2, jfloat a3){ glUniform3f(a0,a1,a2,a3); }
GLF rc_glUniform2iv_A(JNIEnv* e, jclass, jint a0, jintArray a1){ jint* p=e->GetIntArrayElements(a1,nullptr); jsize n=e->GetArrayLength(a1); glUniform2iv(a0,n/2,(const GLint*)p); e->ReleaseIntArrayElements(a1,p,JNI_ABORT); }
GLF rc_glUniform2iv_B(JNIEnv* e, jclass, jint a0, jobject a1){ glUniform2iv(a0,(GLsizei)(e->GetDirectBufferCapacity(a1)/2),(const GLint*)e->GetDirectBufferAddress(a1)); }
GLF rc_glUniform3iv_A(JNIEnv* e, jclass, jint a0, jintArray a1){ jint* p=e->GetIntArrayElements(a1,nullptr); jsize n=e->GetArrayLength(a1); glUniform3iv(a0,n/3,(const GLint*)p); e->ReleaseIntArrayElements(a1,p,JNI_ABORT); }
GLF rc_glUniform3iv_B(JNIEnv* e, jclass, jint a0, jobject a1){ glUniform3iv(a0,(GLsizei)(e->GetDirectBufferCapacity(a1)/3),(const GLint*)e->GetDirectBufferAddress(a1)); }
GLF rc_glUniform4iv_A(JNIEnv* e, jclass, jint a0, jintArray a1){ jint* p=e->GetIntArrayElements(a1,nullptr); jsize n=e->GetArrayLength(a1); glUniform4iv(a0,n/4,(const GLint*)p); e->ReleaseIntArrayElements(a1,p,JNI_ABORT); }
GLF rc_glUniform4iv_B(JNIEnv* e, jclass, jint a0, jobject a1){ glUniform4iv(a0,(GLsizei)(e->GetDirectBufferCapacity(a1)/4),(const GLint*)e->GetDirectBufferAddress(a1)); }
GLF rc_glUniform3fv_A(JNIEnv* e, jclass, jint a0, jfloatArray a1){ jfloat* p=e->GetFloatArrayElements(a1,nullptr); jsize n=e->GetArrayLength(a1); glUniform3fv(a0,n/3,p); e->ReleaseFloatArrayElements(a1,p,JNI_ABORT); }
GLF rc_glUniform3fv_B(JNIEnv* e, jclass, jint a0, jobject a1){ glUniform3fv(a0,(GLsizei)(e->GetDirectBufferCapacity(a1)/3),(const GLfloat*)e->GetDirectBufferAddress(a1)); }
GLF rc_glUniform4fv_A(JNIEnv* e, jclass, jint a0, jfloatArray a1){ jfloat* p=e->GetFloatArrayElements(a1,nullptr); jsize n=e->GetArrayLength(a1); glUniform4fv(a0,n/4,p); e->ReleaseFloatArrayElements(a1,p,JNI_ABORT); }
GLF rc_glUniform4fv_B(JNIEnv* e, jclass, jint a0, jobject a1){ glUniform4fv(a0,(GLsizei)(e->GetDirectBufferCapacity(a1)/4),(const GLfloat*)e->GetDirectBufferAddress(a1)); }
// fence/sync (GLES 3.0 core) — GLsync is a pointer; carry it as a jlong handle.
static jlong JNICALL rc_glFenceSync(JNIEnv*, jclass, jint a0, jint a1){ return (jlong)(intptr_t)glFenceSync((GLenum)a0,(GLbitfield)a1); }
static jint JNICALL rc_glClientWaitSync(JNIEnv*, jclass, jlong a0, jint a1, jlong a2){ return (jint)glClientWaitSync((GLsync)(intptr_t)a0,(GLbitfield)a1,(GLuint64)a2); }
GLF rc_glDeleteSync(JNIEnv*, jclass, jlong a0){ glDeleteSync((GLsync)(intptr_t)a0); }
// queries: glGen/DeleteQueries are GLES 3.0 core; timer-query (QueryCounter/GetQueryObjectui64) is EXT, dev-overlay only.
static jint JNICALL rc_glGenQueries0(JNIEnv*, jclass){ GLuint q=0; glGenQueries(1,&q); return (jint)q; }
GLF rc_glGenQueries_A(JNIEnv* e, jclass, jintArray a0){ jsize n=e->GetArrayLength(a0); jint* p=e->GetIntArrayElements(a0,nullptr); glGenQueries(n,(GLuint*)p); e->ReleaseIntArrayElements(a0,p,0); }
GLF rc_glDeleteQueries1(JNIEnv*, jclass, jint a0){ GLuint q=(GLuint)a0; glDeleteQueries(1,&q); }
GLF rc_glDeleteQueries_A(JNIEnv* e, jclass, jintArray a0){ jsize n=e->GetArrayLength(a0); jint* p=e->GetIntArrayElements(a0,nullptr); glDeleteQueries(n,(GLuint*)p); e->ReleaseIntArrayElements(a0,p,JNI_ABORT); }
GLF rc_glQueryCounter(JNIEnv*, jclass, jint, jint){ /* EXT_disjoint_timer_query (dev perf overlay) -> no-op */ }
GLF rc_glGetQueryObjectiv(JNIEnv* e, jclass, jint a0, jint a1, jintArray a2){ jint* p=e->GetIntArrayElements(a2,nullptr); GLuint v=0; glGetQueryObjectuiv((GLuint)a0,(GLenum)a1,&v); if(p)p[0]=(jint)v; e->ReleaseIntArrayElements(a2,p,0); }
static jlong JNICALL rc_glGetQueryObjectui64(JNIEnv*, jclass, jint, jint){ return 0; }   // timer-query EXT -> dev overlay only
// debug groups (KHR_debug, optional) — no-op.
GLF rc_glObjectLabel(JNIEnv*, jclass, jint, jint, jobject){ }
GLF rc_glPushDebugGroup(JNIEnv*, jclass, jint, jint, jobject){ }
GLF rc_glPopDebugGroup(JNIEnv*, jclass){ }
// program-binary cache (GLES 3.0 core).
GLF rc_glGetProgramBinary_BB(JNIEnv* e, jclass, jint a0, jobject a1, jobject a2, jobject a3){
    GLsizei len=0; GLenum fmt=0; void* bin=e->GetDirectBufferAddress(a3); jlong cap=e->GetDirectBufferCapacity(a3);
    glGetProgramBinary((GLuint)a0,(GLsizei)cap,&len,&fmt,bin);
    if (a1){ GLint* lp=(GLint*)e->GetDirectBufferAddress(a1); if(lp)lp[0]=len; }
    if (a2){ GLint* fp=(GLint*)e->GetDirectBufferAddress(a2); if(fp)fp[0]=(GLint)fmt; }
}
GLF rc_glGetProgramBinary_AA(JNIEnv* e, jclass, jint a0, jintArray a1, jintArray a2, jobject a3){
    GLsizei len=0; GLenum fmt=0; void* bin=e->GetDirectBufferAddress(a3); jlong cap=e->GetDirectBufferCapacity(a3);
    glGetProgramBinary((GLuint)a0,(GLsizei)cap,&len,&fmt,bin);
    if (a1){ jint v=(jint)len; e->SetIntArrayRegion(a1,0,1,&v); }
    if (a2){ jint v=(jint)fmt; e->SetIntArrayRegion(a2,0,1,&v); }
}
// compute / indirect (GLES 3.1 core) — registered for full binding; gated OFF on Zone (never invoked).
GLF rc_glDispatchCompute(JNIEnv*, jclass, jint a0, jint a1, jint a2){ glDispatchCompute((GLuint)a0,(GLuint)a1,(GLuint)a2); }
GLF rc_glMemoryBarrier(JNIEnv*, jclass, jint a0){ glMemoryBarrier((GLbitfield)a0); }
GLF rc_glDrawArraysIndirect(JNIEnv*, jclass, jint a0, jlong a1){ if (sDrawCountOn) sDcIndirect++; glDrawArraysIndirect((GLenum)a0,(const void*)(intptr_t)a1); }
GLF rc_glDrawElementsIndirect(JNIEnv*, jclass, jint a0, jint a1, jlong a2){ if (sDrawCountOn) sDcIndirect++; glDrawElementsIndirect((GLenum)a0,(GLenum)a1,(const void*)(intptr_t)a2); }
GLF rc_glMultiDrawArraysIndirect(JNIEnv*, jclass, jint, jlong, jint, jint){ /* EXT_multi_draw_indirect; gated off -> no-op */ }
GLF rc_glBufferStorage_J(JNIEnv*, jclass, jint, jlong, jint){ /* EXT_buffer_storage; GL_ARB_buffer_storage reported false -> never called */ }
GLF rc_glBufferStorage_BB(JNIEnv*, jclass, jint, jobject, jint){ /* ditto */ }
GLF rc_glBufferSubData_BB(JNIEnv* e, jclass, jint a0, jlong a1, jobject a2){ glBufferSubData((GLenum)a0,(GLintptr)a1,(GLsizeiptr)e->GetDirectBufferCapacity(a2),e->GetDirectBufferAddress(a2)); }
GLF rc_glBufferSubData_IB(JNIEnv* e, jclass, jint a0, jlong a1, jobject a2){ glBufferSubData((GLenum)a0,(GLintptr)a1,(GLsizeiptr)(e->GetDirectBufferCapacity(a2)*4),e->GetDirectBufferAddress(a2)); }
GLF rc_glBufferSubData_FB(JNIEnv* e, jclass, jint a0, jlong a1, jobject a2){ glBufferSubData((GLenum)a0,(GLintptr)a1,(GLsizeiptr)(e->GetDirectBufferCapacity(a2)*4),e->GetDirectBufferAddress(a2)); }
// glTexSubImage3D from a direct Buffer (RLHD's TextureManager uploads the texture-array layers from an IntBuffer
// as GL_BGRA / GL_UNSIGNED_INT_8_8_8_8_REV — GLES has neither, so rewrite to RGBA/UNSIGNED_BYTE + set the per-array
// swizzle R<->B, the same recipe the base-gpu UI texture uses).
GLF rc_glTexSubImage3D_buf(JNIEnv* e, jclass, jint a0, jint a1, jint a2, jint a3, jint a4, jint a5, jint a6, jint a7, jint a8, jint a9, jobject a10){
    GLenum fmt=(GLenum)a8, typ=(GLenum)a9; bool bgra=(fmt==GL_BGRA);
    if (bgra){ fmt=GL_RGBA; if (typ==GL_UNSIGNED_INT_8_8_8_8_REV) typ=GL_UNSIGNED_BYTE; }
    glTexSubImage3D((GLenum)a0,a1,a2,a3,a4,a5,a6,a7,fmt,typ,e->GetDirectBufferAddress(a10));
    if (bgra){ glTexParameteri((GLenum)a0, GL_TEXTURE_SWIZZLE_R, GL_BLUE); glTexParameteri((GLenum)a0, GL_TEXTURE_SWIZZLE_B, GL_RED); }
}

// ---- MemoryUtil raw-pointer natives (org.lwjgl.system.MemoryUtil) — render-path off-heap arena (ModelCache). ---
static jlong JNICALL rc_mem_nmemAllocChecked(JNIEnv*, jclass, jlong sz){ return (jlong)(intptr_t)malloc((size_t)sz); }
static void  JNICALL rc_mem_nmemFree(JNIEnv*, jclass, jlong p){ free((void*)(intptr_t)p); }
static jlong JNICALL rc_mem_memAddress0(JNIEnv* e, jclass, jobject b){ return (jlong)(intptr_t)e->GetDirectBufferAddress(b); }
static jobject JNICALL rc_mem_nNewBuffer(JNIEnv* e, jclass, jlong addr, jint cap){ return rc_native_order(e, e->NewDirectByteBuffer((void*)(intptr_t)addr, cap)); }

// ---- AWTContext (kAWT) ---------------------------------------------------------------------------------------
static void JNICALL rc_AWT_configurePixelFormat(JNIEnv*, jobject, jint, jint, jint){ /* FBO format fixed in createGLContext */ }
static void JNICALL rc_AWT_createGLContext(JNIEnv* env, jobject){
    int w = 512, h = 512;   // fallback; prefer the live engine canvas (the gpu plugin renders at canvas size)
    LOGI("createGLContext ENTER thread=%p", (void*)pthread_self());
    if (!rcEglPrepareSurface(w, h) || !rcEglCreateContextCurrent()) { LOGE("createGLContext: EGL bring-up FAILED"); return; }
    rc_set_es_target();
    // Phase 0: resolve the GPU timer-query EXT (debug-gated probe) now that a context is current.
    pglGenQueriesEXT          = (PFNGENQEXT)      eglGetProcAddress("glGenQueriesEXT");
    pglBeginQueryEXT          = (PFNQEXT)         eglGetProcAddress("glBeginQueryEXT");
    pglEndQueryEXT            = (PFNENDQEXT)      eglGetProcAddress("glEndQueryEXT");
    pglGetQueryObjectuivEXT   = (PFNGETQUIVEXT)   eglGetProcAddress("glGetQueryObjectuivEXT");
    pglGetQueryObjectui64vEXT = (PFNGETQUI64VEXT) eglGetProcAddress("glGetQueryObjectui64vEXT");
    sTimerFns = pglGenQueriesEXT && pglBeginQueryEXT && pglEndQueryEXT && pglGetQueryObjectuivEXT && pglGetQueryObjectui64vEXT;
    LOGI("GPU timer (EXT_disjoint_timer_query): %s (set debug.routec.gputime=1 to enable [gpuprobe])",
         sTimerFns ? "available" : "absent");
    if (rc_jb_cache(env) && sJbCanvasW && sJbCanvasH) {
        jint cw = env->CallStaticIntMethod(sJbCls, sJbCanvasW);
        jint ch = env->CallStaticIntMethod(sJbCls, sJbCanvasH);
        if (env->ExceptionCheck()) env->ExceptionClear();
        if (cw > 0 && ch > 0) { w = cw; h = ch; }
    }
    bool fboOk = rcBuildFbo(w, h);
    LOGI("createGLContext DONE fbo=%u %dx%d complete=%d es=%s GL_VERSION=%s", sFbo, sFboW, sFboH, fboOk, sEsVer, (const char*)glGetString(GL_VERSION));
    { const char *ext = (const char*)glGetString(GL_EXTENSIONS);
      bool tb = ext && (strstr(ext,"texture_buffer")!=nullptr);
      LOGI("GL caps: texture_buffer=%d (EXT=%d OES=%d) io_blocks=%d geom=%d", tb,
          ext && strstr(ext,"GL_EXT_texture_buffer")!=nullptr, ext && strstr(ext,"GL_OES_texture_buffer")!=nullptr,
          ext && strstr(ext,"shader_io_blocks")!=nullptr, ext && strstr(ext,"geometry_shader")!=nullptr); }
    // Phase 1: complete reverse-Z by enabling the [0,1] clip range (the Zone renderer needs it but never sets it),
    // with the self-test fail-safe. Done after the FBO is built so the test has a depth-complete target.
    if (fboOk) rcSetupClipControl();
    // Phase 4: read-only extension probe — log whether the draw-batching / persistent-mapping levers are even
    // possible on this driver (gate prerequisite for the L-effort follow-ups). Never enables anything.
    rcProbePhase4Caps();
}
static void JNICALL rc_AWT_destroy(JNIEnv*, jobject){
    if (sDpy != EGL_NO_DISPLAY) {
        eglMakeCurrent(sDpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (sWinSurf != EGL_NO_SURFACE) { eglDestroySurface(sDpy, sWinSurf); sWinSurf = EGL_NO_SURFACE; }
        if (sWin && sCbReleaseWindow) { sCbReleaseWindow(sWin); sWin = nullptr; }
        if (sCtx != EGL_NO_CONTEXT) { eglDestroyContext(sDpy, sCtx); sCtx = EGL_NO_CONTEXT; }
        if (sSurf != EGL_NO_SURFACE) { eglDestroySurface(sDpy, sSurf); sSurf = EGL_NO_SURFACE; }
    }
}
static jint JNICALL rc_AWT_getBufferMode(JNIEnv*, jobject){ return (jint)GL_COLOR_ATTACHMENT0; }
// Per-frame (the gpu plugin calls getFramebuffer early each draw): re-bind the thread-affine context and, if the
// engine canvas resized, rebuild the offscreen FBO so the present blit covers exactly the composited canvas region.
// Phase 3 (Task A): the engine canvas only resizes when the Android Surface changes (orientation / window / fold) —
// and EVERY such change calls SurfaceHolder.surfaceChanged -> nativeSetSurface, which bumps the surface generation
// (jvm_bootstrap g_surfaceGen). So re-probe the canvas size (two JNI round-trips) on a surface-gen change instead
// of every frame. The engine's AWT canvas can lag the surface change by a frame or two, so after each gen bump we
// frame-probe for a short SETTLE window (until it stabilises) rather than probing once; plus a 1 Hz ultra-backstop
// covers any hypothetical resize path that never bumps the gen. Steady state is then a context re-bind + a clock
// read, no JNI. (rcResizeFbo updates sFboW/sFboH + glViewport, so the present blit always uses the live dims.)
static uint64_t sGfbSurfaceGen  = ~0ull;   // last surface gen we saw (sentinel: g_surfaceGen counts up from 0, so
                                           // the first call always differs -> probes; sFbo==0 also forces it)
static double   sGfbLastProbe   = 0;       // last wall-clock (ms) we probed the canvas size at
static double   sGfbSettleUntil = 0;       // frame-probe every frame until this time (catch a lagging canvas resize)
static jint JNICALL rc_AWT_getFramebuffer(JNIEnv* env, jobject, jboolean){
    rc_make_current();
    double now = rc_now_ms();
    bool probe = (sFbo == 0);   // never built yet
    if (sCbSurfaceGen) {
        uint64_t gen = sCbSurfaceGen();
        if (gen != sGfbSurfaceGen) { sGfbSurfaceGen = gen; sGfbSettleUntil = now + 500.0; }
    }
    if (now < sGfbSettleUntil) probe = true;            // settle window after a surface change
    if (now - sGfbLastProbe >= 1000.0) probe = true;    // ultra-backstop (no-gen-bump resize paths)
    if (probe) {
        sGfbLastProbe = now;
        if (rc_jb_cache(env) && sJbCanvasW && sJbCanvasH) {
            jint cw = env->CallStaticIntMethod(sJbCls, sJbCanvasW);
            jint ch = env->CallStaticIntMethod(sJbCls, sJbCanvasH);
            if (env->ExceptionCheck()) env->ExceptionClear();
            if (cw > 0 && ch > 0 && (cw != sFboW || ch != sFboH)) rcResizeFbo(cw, ch);
        }
    }
    return (jint)sFbo;
}
static void JNICALL rc_AWT_loadNatives(JNIEnv*, jobject){ /* no-op (the .so is already loaded + registered) */ }
// Store the plugin's requested swap interval and re-apply it on the next present (the boot prop can still override).
static jint JNICALL rc_AWT_setSwapInterval(JNIEnv*, jobject, jint a0){ sReqSwapInterval = a0; sSwapDirty = true; return a0; }

// ---- GPU timer-query probe (debug-gated, see globals above) ---------------------------------------------------
// End the query bracketing the frame just rendered (called before the present blit, so present is excluded).
static void rcTimerEndFrame() {
    if (sTQActive >= 0) { pglEndQueryEXT(GL_TIME_ELAPSED_EXT); sTQState[sTQActive] = 2; sTQActive = -1; }
}
// Read any finished results (non-blocking), emit [gpuprobe] once/sec, then begin the next frame's query.
static void rcTimerDrainAndBegin() {
    // Mali note: GL_GPU_DISJOINT_EXT is raised by GPU DVFS frequently under load. The spec calls a result spanning
    // a disjoint "undefined", but discarding EVERY result on disjoint yields ZERO data on a Mali tiler. So we keep
    // available results, reject only physically-impossible values (the garbage guard below), and report the disjoint
    // count as a caveat — relative A/B stays valid, absolute values carry the annotation.
    GLint disjoint = 0; glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);   // reading clears it
    if (disjoint) sGpuDisjoint++;
    for (int i = 0; i < RC_NQ; i++) {
        if (sTQState[i] != 2) continue;
        GLuint avail = 0; pglGetQueryObjectuivEXT(sTQId[i], GL_QUERY_RESULT_AVAILABLE_EXT, &avail);
        if (!avail) continue;
        GLuint64 ns = 0; pglGetQueryObjectui64vEXT(sTQId[i], GL_QUERY_RESULT_EXT, &ns);
        sTQState[i] = 0;
        sGpuAvailSeen++;
        double ms = ns / 1e6;
        // Drop ONLY disjoint overflow garbage (astronomically large) and zero/empty results — NOT real catastrophic
        // hitches: a multi-hundred-ms stall (shader compile, texture streaming, GC) is exactly what the probe must
        // catch, so it stays in the stats and is surfaced via the hitch counter below.
        if (ms <= 0.0 || ms > RC_GPU_GARBAGE_MS) continue;
        if (ms > RC_GPU_HITCH_MS) sGpuHitch++;
        sGpuSumMs += ms; sGpuFrames++;
        if (sGpuMinMs == 0 || ms < sGpuMinMs) sGpuMinMs = ms;
        if (ms > sGpuMaxMs) sGpuMaxMs = ms;
    }
    double now = rc_now_ms();
    if (sGpuLastLog == 0) sGpuLastLog = now;
    if (now - sGpuLastLog >= 1000.0) {
        if (sGpuFrames > 0) {
            LOGI("[gpuprobe] frames=%d avg=%.2f min=%.2f max=%.2f ms disjoint=%d hitch=%d",
                 sGpuFrames, sGpuSumMs / sGpuFrames, sGpuMinMs, sGpuMaxMs, sGpuDisjoint, sGpuHitch);
        } else {
            // No usable result this window — name the cause (availability wall vs all-disjoint-garbage) for diagnosis.
            LOGI("[gpuprobe] no usable GPU-time this window (availSeen=%d disjoint=%d)", sGpuAvailSeen, sGpuDisjoint);
        }
        sGpuSumMs = sGpuMinMs = sGpuMaxMs = 0; sGpuFrames = 0; sGpuDisjoint = 0; sGpuAvailSeen = 0; sGpuHitch = 0; sGpuLastLog = now;
    }
    int idx = -1;
    for (int i = 0; i < RC_NQ; i++) if (sTQState[i] == 0) { idx = i; break; }
    if (idx >= 0) { pglBeginQueryEXT(GL_TIME_ELAPSED_EXT, sTQId[idx]); sTQState[idx] = 1; sTQActive = idx; }
}
// jvm_bootstrap installs the window-borrow callbacks here (it owns libandroid). Their presence flips swapBuffers
// from the glReadPixels CPU path to the direct EGL window-surface present.
extern "C" void RouteC_setPresentCallbacks(void* (*acq)(uint64_t*), uint64_t (*gen)(void), void (*rel)(void*),
                                           void (*setDims)(int, int)) {
    sCbAcquireWindow = acq; sCbSurfaceGen = gen; sCbReleaseWindow = rel; sCbSetFrameDims = setDims;
    LOGI("present callbacks set — direct EGL window-surface present armed");
}

// Phase 3 (auto-GPU watchdog): frames presented so far on the direct path. jvm_bootstrap dlsym's this and exposes it
// to Kotlin (JvmLauncher.nativeGpuFramesPresented) so the first-boot fallback can tell "renderer activated" from
// "failed/black/crashed" without any per-frame plumbing.
extern "C" uint64_t RouteC_framesPresented() { return sFramesPresented.load(std::memory_order_relaxed); }

// Create/recreate the EGL window surface from the SurfaceView when the surface generation changes (background ->
// foreground recreates the Surface). Runs on the GL/draw thread (same thread the context is current on). Returns
// true iff a window surface is ready to present to.
static bool rcEnsureWindowSurface() {
    if (!sCbAcquireWindow || !sCbSurfaceGen || !sCbReleaseWindow) return false;
    uint64_t gen = sCbSurfaceGen();
    if (sWinSurf != EGL_NO_SURFACE && gen == sWinGen) return true;            // unchanged
    // Surface changed (or first use): destroy the old EGL surface BEFORE releasing its window ref.
    if (sWinSurf != EGL_NO_SURFACE) {
        eglMakeCurrent(sDpy, sSurf, sSurf, sCtx);                            // unbind window surface -> bring-up pbuffer
        eglDestroySurface(sDpy, sWinSurf);
        sWinSurf = EGL_NO_SURFACE;
    }
    if (sWin) { sCbReleaseWindow(sWin); sWin = nullptr; }
    uint64_t ng = 0;
    void* w = sCbAcquireWindow(&ng);
    sWinGen = ng;
    if (!w) return false;                                                    // no Surface yet (backgrounded) — skip present
    sWinSurf = eglCreateWindowSurface(sDpy, sCfg, (EGLNativeWindowType)w, nullptr);
    if (sWinSurf == EGL_NO_SURFACE) { LOGE("eglCreateWindowSurface failed 0x%x", eglGetError()); sCbReleaseWindow(w); return false; }
    sWin = w;
    sSwapDirty = true;   // re-apply the swap interval on each fresh surface (incl. background->foreground recreation)
    LOGI("direct-present: EGL window surface created gen=%llu", (unsigned long long)sWinGen);
    return true;
}

// swapBuffers — present the composited 117HD/gpu frame. Direct path (callbacks installed): blit the offscreen FBO
// to the window surface's default framebuffer + eglSwapBuffers (pure GPU, vsync-paced, no readback). Legacy path
// (no seam): glReadPixels the FBO into JavaBridge's double buffer for the CPU present thread.
static void JNICALL rc_AWT_swapBuffers(JNIEnv* env, jobject){
    rc_make_current();
    int w = sFboW, h = sFboH;
    if (w <= 0 || h <= 0) return;

    // GPU timer probe (debug.routec.gputime). The query is OPENED at the bottom of the previous swapBuffers (after
    // that frame's present) and CLOSED here, before this frame's present blit/readback below — so the begin->end
    // span is exactly the plugin's draw calls for one frame, with neither present path (direct blit nor legacy
    // glReadPixels) inside it. Prop re-checked ~1/sec to keep the play-path cost nil.
    static double sPropCheck = 0;
    if (sTimerFns) {
        double now = rc_now_ms();
        if (now - sPropCheck >= 1000.0) { sPropCheck = now; sTimerOn = rc_prop_int("debug.routec.gputime", 0) != 0; }
        if (sTimerOn) {
            if (!sTQGen) { pglGenQueriesEXT(RC_NQ, sTQId); sTQGen = true; LOGI("[gpuprobe] timer queries armed"); }
            rcTimerEndFrame();
        }
    }

    // Phase 4 draw-call probe (debug.routec.drawcount): swapBuffers is the frame boundary. Re-check the gate ~1/sec
    // and, when it was on for the whole window, log the per-frame draw-call profile + the predicted multi-draw saving.
    // The forwarders only tally while sDrawCountOn, so the play path stays free until the prop is set.
    {
        static double sDcCheck = 0;
        double now = rc_now_ms();
        if (now - sDcCheck >= 1000.0) {
            bool was = sDrawCountOn;
            sDrawCountOn = rc_prop_int("debug.routec.drawcount", 0) != 0;
            if (was && sDrawCountOn && sDcFrames > 0) {
                int currCalls = sDcDrawArrays + sDcDrawElements + sDcMultiRanges + sDcIndirect;   // GL draw calls today
                int potCalls  = sDcDrawArrays + sDcDrawElements + sDcMultiCalls  + sDcIndirect;   // with multi-draw-indirect
                LOGI("[drawcount] %d fps  per-frame: drawArrays=%.0f drawElements=%.0f mdaCalls=%.1f mdaRanges=%.0f "
                     "indirect=%.0f | glDrawCalls now=%.0f -> multiDrawIndirect=%.0f (save %.0f/frame)",
                     sDcFrames, (double)sDcDrawArrays/sDcFrames, (double)sDcDrawElements/sDcFrames,
                     (double)sDcMultiCalls/sDcFrames, (double)sDcMultiRanges/sDcFrames, (double)sDcIndirect/sDcFrames,
                     (double)currCalls/sDcFrames, (double)potCalls/sDcFrames, (double)(currCalls-potCalls)/sDcFrames);
            }
            sDcDrawArrays = sDcDrawElements = sDcMultiCalls = sDcMultiRanges = sDcIndirect = 0; sDcFrames = 0;
            sDcCheck = now;
        }
        if (sDrawCountOn) sDcFrames++;
    }

    if (sCbAcquireWindow) {
        // Publish the live canvas dims so touch->game mapping works (the CPU present thread that used to set them
        // is disabled in this mode).
        if (sCbSetFrameDims) sCbSetFrameDims(w, h);
        // Direct EGL present. If the Surface isn't ready yet, skip this frame (it stays in the FBO) — the CPU
        // present thread is disabled in this mode, so do NOT fall back to readback (nothing would consume it).
        if (rcEnsureWindowSurface()) {
            eglMakeCurrent(sDpy, sWinSurf, sWinSurf, sCtx);
            if (sSwapDirty) { rcApplySwapInterval(); sSwapDirty = false; }    // pin vsync/fps cap on the current draw surface
            EGLint sw = w, sh = h;
            eglQuerySurface(sDpy, sWinSurf, EGL_WIDTH, &sw);
            eglQuerySurface(sDpy, sWinSurf, EGL_HEIGHT, &sh);
            glBindFramebuffer(GL_READ_FRAMEBUFFER, sFbo);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);                       // the window surface's default framebuffer
            // Both src (FBO) and dst (window default fb) are GL bottom-left origin, so a 1:1 blit presents upright
            // (eglSwapBuffers maps GL bottom-left -> screen). If it shows inverted on device, swap the dst Y extents.
            glBlitFramebuffer(0, 0, w, h,  0, 0, sw, sh,  GL_COLOR_BUFFER_BIT, GL_LINEAR);
            eglSwapBuffers(sDpy, sWinSurf);
            sFramesPresented.fetch_add(1, std::memory_order_relaxed);   // Phase 3: success signal for the auto-GPU watchdog
        } else {
            // PERF-BATTERY-NETWORK-01: no window surface => the Surface was destroyed (app backgrounded). Without
            // a vsync-paced eglSwapBuffers this draw thread would spin unbounded, redrawing the whole scene into
            // the FBO and pinning the Mali GPU while screen-locked. Pace it to ~4 Hz so backgrounded GPU/117HD
            // work collapses ~15x; the frame stays in the FBO and presents normally the instant the Surface
            // returns (foreground). A rare transient surface-recreate just costs one ~250 ms hiccup.
            usleep(250000);
        }
        if (sTimerFns && sTimerOn) rcTimerDrainAndBegin();
        return;
    }

    // Legacy CPU-readback present (only when RouteC_setPresentCallbacks was never installed — e.g. a stale
    // librlawt.so missing the symbol). This is the slow glFinish + glReadPixels + per-pixel swizzle path the audit
    // killed; warn once so the regression isn't silent (Correctness #4).
    static bool sReadbackWarned = false;
    if (!sReadbackWarned) {
        sReadbackWarned = true;
        LOGE("PRESENT FALLBACK: direct-EGL present callbacks absent — using the slow glReadPixels+swizzle readback "
             "path (2x CPU/frame). Likely a stale librlawt.so missing RouteC_setPresentCallbacks; rebuild the .so.");
    }

    if (!rc_jb_cache(env)) return;
    jintArray arr = (jintArray) env->CallStaticObjectMethod(sJbCls, sJbBackBuf, (jint)w, (jint)h);
    if (!arr) { if (env->ExceptionCheck()) env->ExceptionClear(); return; }
    const size_t n = (size_t)w * (size_t)h;
    if (!sReadback || sReadbackN < n) { free(sReadback); sReadback = (uint32_t*)malloc(n * sizeof(uint32_t)); sReadbackN = sReadback ? n : 0; }
    glFinish();
    glBindFramebuffer(GL_READ_FRAMEBUFFER, sFbo);
    glReadBuffer(GL_COLOR_ATTACHMENT0);
    if (sReadback) {
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, sReadback);   // little-endian word = 0xAABBGGRR
        void* dst = env->GetPrimitiveArrayCritical(arr, nullptr);
        if (dst) {
            uint32_t* d = (uint32_t*)dst;
            for (int y = 0; y < h; y++) {
                const uint32_t* srow = sReadback + (size_t)(h - 1 - y) * w;   // flip: GL bottom-left -> top-left
                uint32_t* drow = d + (size_t)y * w;
                for (int x = 0; x < w; x++) {
                    uint32_t p = srow[x];                                     // 0xAABBGGRR
                    drow[x] = ((p & 0xFFu) << 16) | (p & 0xFF00u) | ((p >> 16) & 0xFFu);   // -> 0x00RRGGBB
                }
            }
            env->ReleasePrimitiveArrayCritical(arr, dst, 0);
        }
    }
    env->CallStaticVoidMethod(sJbCls, sJbPublish, (jint)w, (jint)h);
    env->DeleteLocalRef(arr);
    if (env->ExceptionCheck()) env->ExceptionClear();
    if (sTimerFns && sTimerOn) rcTimerDrainAndBegin();
}

// ---- GL.createCapabilities (kGL) -----------------------------------------------------------------------------
static jobject rc_make_caps(JNIEnv* env){
    jclass c = env->FindClass("org/lwjgl/opengl/GLCapabilities");
    if (!c) return nullptr;
    jmethodID ctor = env->GetMethodID(c, "<init>", "()V");
    jobject o = env->NewObject(c, ctor);
    env->SetBooleanField(o, env->GetFieldID(c, "OpenGL33", "Z"), JNI_TRUE);   // REQUIRED or GpuPlugin/ZoneRenderer aborts
    env->SetBooleanField(o, env->GetFieldID(c, "OpenGL45", "Z"), JNI_FALSE);
    env->SetLongField(o, env->GetFieldID(c, "glTexStorage3D", "J"), 1);
    env->SetLongField(o, env->GetFieldID(c, "glDebugMessageControl", "J"), 0);
    jboolean aniso = rc_gl_has_ext("GL_EXT_texture_filter_anisotropic") ? JNI_TRUE : JNI_FALSE;
    env->SetBooleanField(o, env->GetFieldID(c, "GL_EXT_texture_filter_anisotropic", "Z"), aniso);
    // AG3 (117HD): report the higher-GL / ARB fast-path flags FALSE so RLHD's Zone path takes the GLES-core
    // fallbacks our forwarders implement (glBufferData/glBufferSubData, no persistent storage, no image-load/store,
    // no indirect/multidraw). OpenGL33 alone gates the Zone renderer; these only pick fast vs portable paths.
    env->SetBooleanField(o, env->GetFieldID(c, "OpenGL31", "Z"), JNI_FALSE);
    env->SetBooleanField(o, env->GetFieldID(c, "OpenGL40", "Z"), JNI_FALSE);
    env->SetBooleanField(o, env->GetFieldID(c, "OpenGL43", "Z"), JNI_FALSE);
    env->SetBooleanField(o, env->GetFieldID(c, "GL_ARB_buffer_storage", "Z"), JNI_FALSE);
    env->SetBooleanField(o, env->GetFieldID(c, "GL_ARB_copy_buffer", "Z"), JNI_FALSE);
    // glMapBufferRange + glFlushMappedBufferRange are GLES 3.0 CORE (both forwarded here), so report this TRUE so
    // RLHD's GLMappedBuffer takes its RANGE path — the one that expresses invalidate/flush-explicit/unsynchronized
    // correctly per the caller's intent. The legacy glMapBuffer fallback (cap false) can't express that, which
    // raced the CPU write against the GPU draw on dynamic player-model buffers (the model-flashing bug).
    env->SetBooleanField(o, env->GetFieldID(c, "GL_ARB_map_buffer_range", "Z"), JNI_TRUE);
    env->SetBooleanField(o, env->GetFieldID(c, "GL_ARB_shader_image_load_store", "Z"), JNI_FALSE);
    return o;
}
static jobject JNICALL rc_GL_createCapabilities(JNIEnv* env, jclass){ return rc_make_caps(env); }
static jobject JNICALL rc_GL_getCapabilities(JNIEnv* env, jclass){ return rc_make_caps(env); }

// ---- RegisterNatives tables (signatures match GLALL.java / AWTContext.java / GL.java exactly) ----------------
static const JNINativeMethod kGLALL[] = {
    {"glActiveTexture","(I)V",(void*)rc_glActiveTexture},
    {"glAttachShader","(II)V",(void*)rc_glAttachShader},
    {"glBindBuffer","(II)V",(void*)rc_glBindBuffer},
    {"glBindBufferBase","(III)V",(void*)rc_glBindBufferBase},
    {"glBindFramebuffer","(II)V",(void*)rc_glBindFramebuffer},
    {"glBindRenderbuffer","(II)V",(void*)rc_glBindRenderbuffer},
    {"glBindTexture","(II)V",(void*)rc_glBindTexture},
    {"glBindVertexArray","(I)V",(void*)rc_glBindVertexArray},
    {"glBlendFunc","(II)V",(void*)rc_glBlendFunc},
    {"glBlendFuncSeparate","(IIII)V",(void*)rc_glBlendFuncSeparate},
    {"glBlitFramebuffer","(IIIIIIIIII)V",(void*)rc_glBlitFramebuffer},
    {"glBufferData","(IJI)V",(void*)rc_glBufferData_J},
    {"glBufferData","(ILjava/nio/FloatBuffer;I)V",(void*)rc_glBufferData_F},
    {"glBufferData","(ILjava/nio/IntBuffer;I)V",(void*)rc_glBufferData_I},
    {"glCheckFramebufferStatus","(I)I",(void*)rc_glCheckFramebufferStatus},
    {"glClear","(I)V",(void*)rc_glClear},
    {"glClearColor","(FFFF)V",(void*)rc_glClearColor},
    {"glClearDepth","(D)V",(void*)rc_glClearDepth},
    {"glColorMask","(ZZZZ)V",(void*)rc_glColorMask},
    {"glCompileShader","(I)V",(void*)rc_glCompileShader},
    {"glCreateProgram","()I",(void*)rc_glCreateProgram},
    {"glCreateShader","(I)I",(void*)rc_glCreateShader},
    {"glDeleteBuffers","(I)V",(void*)rc_glDeleteBuffers},
    {"glDeleteFramebuffers","(I)V",(void*)rc_glDeleteFramebuffers},
    {"glDeleteProgram","(I)V",(void*)rc_glDeleteProgram},
    {"glDeleteRenderbuffers","(I)V",(void*)rc_glDeleteRenderbuffers},
    {"glDeleteShader","(I)V",(void*)rc_glDeleteShader},
    {"glDeleteTextures","(I)V",(void*)rc_glDeleteTextures},
    {"glDeleteVertexArrays","(I)V",(void*)rc_glDeleteVertexArrays},
    {"glDepthFunc","(I)V",(void*)rc_glDepthFunc},
    {"glDepthMask","(Z)V",(void*)rc_glDepthMask},
    {"glDetachShader","(II)V",(void*)rc_glDetachShader},
    {"glDisable","(I)V",(void*)rc_glDisable},
    {"glDrawArrays","(III)V",(void*)rc_glDrawArrays},
    {"glDrawElements","(IIIJ)V",(void*)rc_glDrawElements},
    {"glEnable","(I)V",(void*)rc_glEnable},
    {"glEnableVertexAttribArray","(I)V",(void*)rc_glEnableVertexAttribArray},
    {"glFlushMappedBufferRange","(IJJ)V",(void*)rc_glFlushMappedBufferRange},
    {"glFramebufferRenderbuffer","(IIII)V",(void*)rc_glFramebufferRenderbuffer},
    {"glGenBuffers","()I",(void*)rc_glGenBuffers},
    {"glGenFramebuffers","()I",(void*)rc_glGenFramebuffers},
    {"glGenRenderbuffers","()I",(void*)rc_glGenRenderbuffers},
    {"glGenTextures","()I",(void*)rc_glGenTextures},
    {"glGenVertexArrays","()I",(void*)rc_glGenVertexArrays},
    {"glGenerateMipmap","(I)V",(void*)rc_glGenerateMipmap},
    {"glGetError","()I",(void*)rc_glGetError},
    {"glGetFloat","(I)F",(void*)rc_glGetFloat},
    {"glGetInteger","(I)I",(void*)rc_glGetInteger},
    {"glGetProgramInfoLog","(I)Ljava/lang/String;",(void*)rc_glGetProgramInfoLog},
    {"glGetProgrami","(II)I",(void*)rc_glGetProgrami},
    {"glGetShaderInfoLog","(I)Ljava/lang/String;",(void*)rc_glGetShaderInfoLog},
    {"glGetShaderi","(II)I",(void*)rc_glGetShaderi},
    {"glGetString","(I)Ljava/lang/String;",(void*)rc_glGetString},
    {"glGetUniformBlockIndex","(ILjava/lang/CharSequence;)I",(void*)rc_glGetUniformBlockIndex},
    {"glGetUniformLocation","(ILjava/lang/CharSequence;)I",(void*)rc_glGetUniformLocation},
    {"glLinkProgram","(I)V",(void*)rc_glLinkProgram},
    {"glMapBuffer","(II)Ljava/nio/ByteBuffer;",(void*)rc_glMapBuffer},
    {"glMapBuffer","(IILjava/nio/ByteBuffer;)Ljava/nio/ByteBuffer;",(void*)rc_glMapBuffer3},
    {"glMapBuffer","(IIJLjava/nio/ByteBuffer;)Ljava/nio/ByteBuffer;",(void*)rc_glMapBuffer4},
    {"glMapBufferRange","(IJJILjava/nio/ByteBuffer;)Ljava/nio/ByteBuffer;",(void*)rc_glMapBufferRange},
    {"glMultiDrawArrays","(ILjava/nio/IntBuffer;Ljava/nio/IntBuffer;)V",(void*)rc_glMultiDrawArrays},
    {"glReadBuffer","(I)V",(void*)rc_glReadBuffer},
    {"glReadPixels","(IIIIIILjava/nio/ByteBuffer;)V",(void*)rc_glReadPixels},
    {"glRenderbufferStorageMultisample","(IIIII)V",(void*)rc_glRenderbufferStorageMultisample},
    {"glShaderSource","(ILjava/lang/CharSequence;)V",(void*)rc_glShaderSource},
    {"glTexImage2D","(IIIIIIIIJ)V",(void*)rc_glTexImage2D},
    {"glTexImage3D","(IIIIIIIIIJ)V",(void*)rc_glTexImage3D},
    {"glTexParameterf","(IIF)V",(void*)rc_glTexParameterf},
    {"glTexParameteri","(III)V",(void*)rc_glTexParameteri},
    {"glTexSubImage2D","(IIIIIIIIJ)V",(void*)rc_glTexSubImage2D},
    {"glTexSubImage3D","(IIIIIIIIIILjava/nio/ByteBuffer;)V",(void*)rc_glTexSubImage3D},
    {"glUniform1f","(IF)V",(void*)rc_glUniform1f},
    {"glUniform1i","(II)V",(void*)rc_glUniform1i},
    {"glUniform2fv","(I[F)V",(void*)rc_glUniform2fv},
    {"glUniform2i","(III)V",(void*)rc_glUniform2i},
    {"glUniform3i","(IIII)V",(void*)rc_glUniform3i},
    {"glUniform4f","(IFFFF)V",(void*)rc_glUniform4f},
    {"glUniform4i","(IIIII)V",(void*)rc_glUniform4i},
    {"glUniformBlockBinding","(III)V",(void*)rc_glUniformBlockBinding},
    {"glUniformMatrix4fv","(IZ[F)V",(void*)rc_glUniformMatrix4fv},
    {"glUnmapBuffer","(I)Z",(void*)rc_glUnmapBuffer},
    {"glUseProgram","(I)V",(void*)rc_glUseProgram},
    {"glValidateProgram","(I)V",(void*)rc_glValidateProgram},
    {"glVertexAttribIPointer","(IIIIJ)V",(void*)rc_glVertexAttribIPointer},
    {"glVertexAttribPointer","(IIIZIJ)V",(void*)rc_glVertexAttribPointer},
    {"glViewport","(IIII)V",(void*)rc_glViewport},
    {"glTexStorage3D","(IIIIII)V",(void*)rc_glTexStorage3D},
    {"glDebugMessageControl","(IIIIZ)V",(void*)rc_glDebugMessageControl},
    {"glClipControl","(II)V",(void*)rc_glClipControl},
    // --- AG3 117HD (RLHD) Zone GL-delta (signatures match GLALL.java exactly) ---
    {"glCullFace","(I)V",(void*)rc_glCullFace},
    {"glFinish","()V",(void*)rc_glFinish},
    {"glFlush","()V",(void*)rc_glFlush},
    {"glDrawBuffer","(I)V",(void*)rc_glDrawBuffer},
    {"glTexBuffer","(III)V",(void*)rc_glTexBuffer},
    {"glVertexAttribDivisor","(II)V",(void*)rc_glVertexAttribDivisor},
    {"glFramebufferTexture","(IIII)V",(void*)rc_glFramebufferTexture},
    {"glFramebufferTexture2D","(IIIII)V",(void*)rc_glFramebufferTexture2D},
    {"glFramebufferTextureLayer","(IIIII)V",(void*)rc_glFramebufferTextureLayer},
    {"glBindImageTexture","(IIIZIII)V",(void*)rc_glBindImageTexture},
    {"glCopyBufferSubData","(IIJJJ)V",(void*)rc_glCopyBufferSubData},
    {"glInvalidateBufferData","(I)V",(void*)rc_glInvalidateBufferData},
    {"glGetBufferParameteri64","(II)J",(void*)rc_glGetBufferParameteri64},
    {"glGetFramebufferAttachmentParameteri","(III)I",(void*)rc_glGetFramebufferAttachmentParameteri},
    {"glGetIntegerv","(I[I)V",(void*)rc_glGetIntegerv_A},
    {"glGetIntegerv","(ILjava/nio/IntBuffer;)V",(void*)rc_glGetIntegerv_B},
    {"glGetProgramiv","(II[I)V",(void*)rc_glGetProgramiv_A},
    {"glGetProgramiv","(IILjava/nio/IntBuffer;)V",(void*)rc_glGetProgramiv_B},
    {"glTexParameterfv","(II[F)V",(void*)rc_glTexParameterfv_A},
    {"glTexParameterfv","(IILjava/nio/FloatBuffer;)V",(void*)rc_glTexParameterfv_B},
    {"glUniform2f","(IFF)V",(void*)rc_glUniform2f},
    {"glUniform3f","(IFFF)V",(void*)rc_glUniform3f},
    {"glUniform2iv","(I[I)V",(void*)rc_glUniform2iv_A},
    {"glUniform2iv","(ILjava/nio/IntBuffer;)V",(void*)rc_glUniform2iv_B},
    {"glUniform3iv","(I[I)V",(void*)rc_glUniform3iv_A},
    {"glUniform3iv","(ILjava/nio/IntBuffer;)V",(void*)rc_glUniform3iv_B},
    {"glUniform4iv","(I[I)V",(void*)rc_glUniform4iv_A},
    {"glUniform4iv","(ILjava/nio/IntBuffer;)V",(void*)rc_glUniform4iv_B},
    {"glUniform3fv","(I[F)V",(void*)rc_glUniform3fv_A},
    {"glUniform3fv","(ILjava/nio/FloatBuffer;)V",(void*)rc_glUniform3fv_B},
    {"glUniform4fv","(I[F)V",(void*)rc_glUniform4fv_A},
    {"glUniform4fv","(ILjava/nio/FloatBuffer;)V",(void*)rc_glUniform4fv_B},
    {"glFenceSync","(II)J",(void*)rc_glFenceSync},
    {"glClientWaitSync","(JIJ)I",(void*)rc_glClientWaitSync},
    {"glDeleteSync","(J)V",(void*)rc_glDeleteSync},
    {"glGenQueries","()I",(void*)rc_glGenQueries0},
    {"glGenQueries","([I)V",(void*)rc_glGenQueries_A},
    {"glDeleteQueries","(I)V",(void*)rc_glDeleteQueries1},
    {"glDeleteQueries","([I)V",(void*)rc_glDeleteQueries_A},
    {"glQueryCounter","(II)V",(void*)rc_glQueryCounter},
    {"glGetQueryObjectiv","(II[I)V",(void*)rc_glGetQueryObjectiv},
    {"glGetQueryObjectui64","(II)J",(void*)rc_glGetQueryObjectui64},
    {"glObjectLabel","(IILjava/lang/CharSequence;)V",(void*)rc_glObjectLabel},
    {"glPushDebugGroup","(IILjava/lang/CharSequence;)V",(void*)rc_glPushDebugGroup},
    {"glPopDebugGroup","()V",(void*)rc_glPopDebugGroup},
    {"glGetProgramBinary","(ILjava/nio/IntBuffer;Ljava/nio/IntBuffer;Ljava/nio/ByteBuffer;)V",(void*)rc_glGetProgramBinary_BB},
    {"glGetProgramBinary","(I[I[ILjava/nio/ByteBuffer;)V",(void*)rc_glGetProgramBinary_AA},
    {"glDispatchCompute","(III)V",(void*)rc_glDispatchCompute},
    {"glMemoryBarrier","(I)V",(void*)rc_glMemoryBarrier},
    {"glDrawArraysIndirect","(IJ)V",(void*)rc_glDrawArraysIndirect},
    {"glDrawElementsIndirect","(IIJ)V",(void*)rc_glDrawElementsIndirect},
    {"glMultiDrawArraysIndirect","(IJII)V",(void*)rc_glMultiDrawArraysIndirect},
    {"glBufferStorage","(IJI)V",(void*)rc_glBufferStorage_J},
    {"glBufferStorage","(ILjava/nio/ByteBuffer;I)V",(void*)rc_glBufferStorage_BB},
    {"glBufferSubData","(IJLjava/nio/ByteBuffer;)V",(void*)rc_glBufferSubData_BB},
    {"glBufferSubData","(IJLjava/nio/IntBuffer;)V",(void*)rc_glBufferSubData_IB},
    {"glBufferSubData","(IJLjava/nio/FloatBuffer;)V",(void*)rc_glBufferSubData_FB},
    {"glTexSubImage3D","(IIIIIIIIIILjava/nio/IntBuffer;)V",(void*)rc_glTexSubImage3D_buf},
};
static const JNINativeMethod kMEM[] = {
    {"nmemAllocChecked","(J)J",(void*)rc_mem_nmemAllocChecked},
    {"nmemFree","(J)V",(void*)rc_mem_nmemFree},
    {"memAddress0","(Ljava/nio/Buffer;)J",(void*)rc_mem_memAddress0},
    {"nNewBuffer","(JI)Ljava/nio/ByteBuffer;",(void*)rc_mem_nNewBuffer},
};
static const JNINativeMethod kAWT[] = {
    {"configurePixelFormat","(III)V",(void*)rc_AWT_configurePixelFormat},
    {"createGLContext","()V",(void*)rc_AWT_createGLContext},
    {"destroy","()V",(void*)rc_AWT_destroy},
    {"getBufferMode","()I",(void*)rc_AWT_getBufferMode},
    {"getFramebuffer","(Z)I",(void*)rc_AWT_getFramebuffer},
    {"loadNatives","()V",(void*)rc_AWT_loadNatives},
    {"setSwapInterval","(I)I",(void*)rc_AWT_setSwapInterval},
    {"swapBuffers","()V",(void*)rc_AWT_swapBuffers},
};
static const JNINativeMethod kGL[] = {
    {"createCapabilities","()Lorg/lwjgl/opengl/GLCapabilities;",(void*)rc_GL_createCapabilities},
    {"getCapabilities","()Lorg/lwjgl/opengl/GLCapabilities;",(void*)rc_GL_getCapabilities},
};

// Called by the host (jvm_bootstrap) once after JNI_CreateJavaVM, before the gpu plugin / smoke runs, with the
// facade classes on the classpath. Returns JNI_OK (0) on success.
extern "C" jint RouteC_registerGLNatives(JNIEnv *env) {
    jclass glall = env->FindClass("org/lwjgl/opengl/GLALL");
    jclass awt = env->FindClass("net/runelite/rlawt/AWTContext");
    jclass gl = env->FindClass("org/lwjgl/opengl/GL");
    if (!glall || !awt || !gl) { LOGE("FindClass FAIL glall=%p awt=%p gl=%p", glall, awt, gl); if (env->ExceptionCheck()) env->ExceptionClear(); return JNI_ERR; }
    jint rg = env->RegisterNatives(glall, kGLALL, (jint)(sizeof(kGLALL)/sizeof(kGLALL[0])));
    jint ra = env->RegisterNatives(awt, kAWT, (jint)(sizeof(kAWT)/sizeof(kAWT[0])));
    jint rl = env->RegisterNatives(gl, kGL, (jint)(sizeof(kGL)/sizeof(kGL[0])));
    // AG3: MemoryUtil raw-pointer natives (render path). Best-effort — a facade jar predating AG2.5-b lacks the
    // class; skip gracefully then (the base-gpu smoke doesn't use it). When present it must bind cleanly.
    jint rm = 0;
    jclass mem = env->FindClass("org/lwjgl/system/MemoryUtil");
    if (mem) rm = env->RegisterNatives(mem, kMEM, (jint)(sizeof(kMEM)/sizeof(kMEM[0])));
    else if (env->ExceptionCheck()) env->ExceptionClear();
    LOGI("RegisterNatives glall=%d awt=%d gl=%d mem=%d (0=OK)", rg, ra, rl, rm);
    if (env->ExceptionCheck()) env->ExceptionClear();
    return (rg < 0 || ra < 0 || rl < 0 || rm < 0) ? JNI_ERR : JNI_OK;
}
