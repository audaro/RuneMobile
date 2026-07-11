package dev.audaro.glesrecon

import android.app.Activity
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES30
import android.opengl.GLES31
import android.os.Bundle
import android.util.Log
import kotlin.concurrent.thread

/**
 * Track G AG0 — GLES tier recon on a REAL device (the emulator is ANGLE→SwiftShader and INVALID for this). On
 * launch it brings up a headless EGL ES3 context (highest of 3.2/3.1/3.0 the driver gives) and queries the
 * facts the GPU track rides on: ES tier, compute (GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS), EXT_clip_control
 * (reverse-Z), EXT_texture_format_BGRA8888, GL_MAX_SAMPLES (MSAA), RGBA16UI 2D-array color-renderability,
 * DEPTH_COMPONENT24/32F renderability, and an offscreen FBO + glReadPixels round-trip. Logs `ANDROID_AG0 …` +
 * a VERDICT to logcat — gated by android/dev-tools/firebase/fb-gate.sh recon. Pure Kotlin (android.opengl.*):
 * no embedded JVM, no NDK, so Firebase Robo runs it by just launching the default activity.
 */
class ReconActivity : Activity() {
    private val tag = "AG0"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        thread(name = "gles-recon") { runRecon() }
    }

    private fun runRecon() {
        var dpy: EGLDisplay? = null
        var ctx: EGLContext = EGL14.EGL_NO_CONTEXT
        var surf: EGLSurface = EGL14.EGL_NO_SURFACE
        try {
            dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            if (dpy == EGL14.EGL_NO_DISPLAY) {
                fail("eglGetDisplay -> NO_DISPLAY")
                return
            }
            val ver = IntArray(2)
            if (!EGL14.eglInitialize(dpy, ver, 0, ver, 1)) {
                fail("eglInitialize failed 0x${err()}")
                return
            }

            // ES3-renderable pbuffer config (RGBA8 + DEPTH24).
            val cfgAttr =
                intArrayOf(
                    EGL14.EGL_RENDERABLE_TYPE,
                    0x0040, // EGL_OPENGL_ES3_BIT_KHR
                    EGL14.EGL_SURFACE_TYPE,
                    EGL14.EGL_PBUFFER_BIT,
                    EGL14.EGL_RED_SIZE,
                    8,
                    EGL14.EGL_GREEN_SIZE,
                    8,
                    EGL14.EGL_BLUE_SIZE,
                    8,
                    EGL14.EGL_ALPHA_SIZE,
                    8,
                    EGL14.EGL_DEPTH_SIZE,
                    24,
                    EGL14.EGL_NONE,
                )
            val cfgs = arrayOfNulls<EGLConfig>(1)
            val nCfg = IntArray(1)
            if (!EGL14.eglChooseConfig(dpy, cfgAttr, 0, cfgs, 0, 1, nCfg, 0) || nCfg[0] < 1) {
                fail("eglChooseConfig failed")
                return
            }

            // Request the HIGHEST ES context the driver supports: 3.2 -> 3.1 -> 3.0 (EGL_BAD_MATCH falls through).
            @Suppress("ktlint:standard:property-naming") // EGL/C constant name, intentionally
            val EGL_CONTEXT_MINOR_VERSION = 0x30FB
            // EGL14 has no EGL_CONTEXT_MAJOR_VERSION constant; it's the same value as EGL_CONTEXT_CLIENT_VERSION.
            var reqMinor = 2
            for (mn in intArrayOf(2, 1, 0)) {
                val ctxAttr = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, mn, EGL14.EGL_NONE)
                ctx = EGL14.eglCreateContext(dpy, cfgs[0], EGL14.EGL_NO_CONTEXT, ctxAttr, 0)
                if (ctx != EGL14.EGL_NO_CONTEXT) {
                    reqMinor = mn
                    break
                }
            }
            if (ctx == EGL14.EGL_NO_CONTEXT) {
                fail("eglCreateContext failed for ES 3.x 0x${err()}")
                return
            }

            val pbAttr = intArrayOf(EGL14.EGL_WIDTH, 16, EGL14.EGL_HEIGHT, 16, EGL14.EGL_NONE)
            surf = EGL14.eglCreatePbufferSurface(dpy, cfgs[0], pbAttr, 0)
            if (surf == EGL14.EGL_NO_SURFACE) {
                fail("eglCreatePbufferSurface failed 0x${err()}")
                return
            }
            if (!EGL14.eglMakeCurrent(dpy, surf, surf, ctx)) {
                fail("eglMakeCurrent failed 0x${err()}")
                return
            }

            // ---- strings ----
            val glVer = GLES30.glGetString(GLES30.GL_VERSION) ?: ""
            val glVendor = GLES30.glGetString(GLES30.GL_VENDOR) ?: ""
            val glRenderer = GLES30.glGetString(GLES30.GL_RENDERER) ?: ""
            val glsl = GLES30.glGetString(GLES30.GL_SHADING_LANGUAGE_VERSION) ?: ""
            val exts = GLES30.glGetString(GLES30.GL_EXTENSIONS) ?: ""
            // Parse "OpenGL ES X.Y" (the real context version the driver gave).
            val m = Regex("OpenGL ES (\\d)\\.(\\d)").find(glVer)
            val esMajor = m?.groupValues?.get(1)?.toIntOrNull() ?: 3
            val esMinor = m?.groupValues?.get(2)?.toIntOrNull() ?: 0
            val esTier = esMajor * 10 + esMinor // 30 / 31 / 32

            // ---- compute (ES 3.1) ----
            val tmp = IntArray(1)
            drainGlErrors()
            GLES30.glGetIntegerv(GLES31.GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, tmp, 0)
            val computeErr = GLES30.glGetError()
            val maxComputeInvocations = if (computeErr == GLES30.GL_NO_ERROR) tmp[0] else -1
            // Compute work-group count limits (x), if compute present.
            var maxComputeGroupsX = -1
            if (maxComputeInvocations > 0) {
                drainGlErrors()
                GLES31.glGetIntegeri_v(GLES31.GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, tmp, 0)
                if (GLES30.glGetError() == GLES30.GL_NO_ERROR) maxComputeGroupsX = tmp[0]
            }

            // ---- extensions ----
            val clipControl = exts.contains("GL_EXT_clip_control")
            val bgra = exts.contains("GL_EXT_texture_format_BGRA8888")
            val aniso = exts.contains("GL_EXT_texture_filter_anisotropic")
            val computeShaderExt = exts.contains("GL_ARB_compute_shader") || esTier >= 31

            // ---- MSAA ----
            drainGlErrors()
            GLES30.glGetIntegerv(GLES30.GL_MAX_SAMPLES, tmp, 0)
            val maxSamples = if (GLES30.glGetError() == 0) tmp[0] else -1

            // ---- offscreen RGBA8 FBO + glReadPixels round-trip ----
            val readbackOk = probeReadback()
            // ---- RGBA16UI 2D-array color-renderable (117HD's TBO-replacement atlas) ----
            val rgba16uiArray = probeRgba16uiArray()
            // ---- depth renderbuffer formats ----
            val depth24 = probeDepthRenderbuffer(GLES30.GL_DEPTH_COMPONENT24)
            val depth32f = probeDepthRenderbuffer(GLES30.GL_DEPTH_COMPONENT32F)

            // base `gpu` needs ES≥3.0 (OpenGL33-equiv) + MSAA + readback; the CLEAN 117HD compute path needs ES≥3.1.
            val baseGpuOk = esTier >= 30 && maxSamples >= 1 && readbackOk
            val hd117Clean = esTier >= 31 && maxComputeInvocations > 0
            val verdict =
                if (baseGpuOk && hd117Clean) {
                    "PASS"
                } else if (baseGpuOk) {
                    "PASS_BASE_GPU_ONLY"
                } else {
                    "FAIL"
                }

            Log.i(
                tag,
                "ANDROID_AG0 esTier=$esTier(reqMinor=$reqMinor) GL_VERSION=\"$glVer\" GLSL=\"$glsl\" vendor=\"$glVendor\" renderer=\"$glRenderer\"",
            )
            Log.i(
                tag,
                "ANDROID_AG0 compute=${maxComputeInvocations > 0} maxComputeInvocations=$maxComputeInvocations maxComputeGroupsX=$maxComputeGroupsX computeShader=$computeShaderExt",
            )
            Log.i(tag, "ANDROID_AG0 clipControl=$clipControl bgra8888=$bgra anisotropic=$aniso maxSamples=$maxSamples")
            Log.i(tag, "ANDROID_AG0 readback=$readbackOk rgba16uiArrayRenderable=$rgba16uiArray depth24=$depth24 depth32f=$depth32f")
            Log.i(tag, "ANDROID_AG0 baseGpuOk=$baseGpuOk hd117CleanComputePath=$hd117Clean")
            Log.i(tag, "ANDROID_AG0 VERDICT=$verdict")

            // AG1b — the real coin-flip: do the unmodified base `gpu` shaders compile/link/glValidateProgram on
            // THIS real driver (after the 330->ES downport)? The load-bearing GPU go/no-go (Shader.java treats a
            // validate failure as fatal; the iOS proof never ran this on a real GLES driver). Same EGL context.
            validateBaseGpuShaders(esTier)
        } catch (t: Throwable) {
            Log.e(tag, "ANDROID_AG0 EXCEPTION $t", t)
            Log.i(tag, "ANDROID_AG0 VERDICT=FAIL")
        } finally {
            if (dpy != null && dpy != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                if (surf != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(dpy, surf)
                if (ctx != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(dpy, ctx)
                EGL14.eglTerminate(dpy)
            }
        }
    }

    private fun err() = Integer.toHexString(EGL14.eglGetError())

    private fun drainGlErrors() {
        var n = 0
        while (GLES30.glGetError() != GLES30.GL_NO_ERROR && n < 16) n++
    }

    private fun fail(why: String) {
        Log.e(tag, "ANDROID_AG0 EGL_FAIL $why")
        Log.i(tag, "ANDROID_AG0 VERDICT=FAIL")
    }

    /** Render to an offscreen RGBA8 FBO + read one pixel back (the base-gpu Phase-1 present path). */
    private fun probeReadback(): Boolean =
        try {
            val fbo = IntArray(1)
            GLES30.glGenFramebuffers(1, fbo, 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo[0])
            val rbo = IntArray(1)
            GLES30.glGenRenderbuffers(1, rbo, 0)
            GLES30.glBindRenderbuffer(GLES30.GL_RENDERBUFFER, rbo[0])
            GLES30.glRenderbufferStorage(GLES30.GL_RENDERBUFFER, GLES30.GL_RGBA8, 16, 16)
            GLES30.glFramebufferRenderbuffer(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_RENDERBUFFER, rbo[0])
            val complete = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) == GLES30.GL_FRAMEBUFFER_COMPLETE
            GLES30.glClearColor(0.25f, 0.5f, 0.75f, 1f)
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
            val px = java.nio.ByteBuffer.allocateDirect(16 * 16 * 4)
            GLES30.glReadPixels(0, 0, 16, 16, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, px)
            val r = px.get(0).toInt() and 0xFF
            GLES30.glDeleteFramebuffers(1, fbo, 0)
            GLES30.glDeleteRenderbuffers(1, rbo, 0)
            complete && GLES30.glGetError() == GLES30.GL_NO_ERROR && r in 0x30..0x60 // ~0.25*255
        } catch (e: Exception) {
            false
        }

    /** RGBA16UI 2D-array, one layer attached to an FBO — color-renderable? (117HD's integer texture-array atlas.) */
    private fun probeRgba16uiArray(): Boolean {
        return try {
            drainGlErrors()
            val tex = IntArray(1)
            GLES30.glGenTextures(1, tex, 0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D_ARRAY, tex[0])
            GLES30.glTexStorage3D(GLES30.GL_TEXTURE_2D_ARRAY, 1, GLES30.GL_RGBA16UI, 16, 16, 2)
            if (GLES30.glGetError() != GLES30.GL_NO_ERROR) {
                GLES30.glDeleteTextures(1, tex, 0)
                return false
            }
            val fbo = IntArray(1)
            GLES30.glGenFramebuffers(1, fbo, 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo[0])
            GLES30.glFramebufferTextureLayer(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, tex[0], 0, 0)
            val ok = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) == GLES30.GL_FRAMEBUFFER_COMPLETE
            GLES30.glDeleteFramebuffers(1, fbo, 0)
            GLES30.glDeleteTextures(1, tex, 0)
            ok
        } catch (e: Exception) {
            false
        }
    }

    private fun probeDepthRenderbuffer(fmt: Int): Boolean =
        try {
            drainGlErrors()
            val rbo = IntArray(1)
            GLES30.glGenRenderbuffers(1, rbo, 0)
            GLES30.glBindRenderbuffer(GLES30.GL_RENDERBUFFER, rbo[0])
            GLES30.glRenderbufferStorage(GLES30.GL_RENDERBUFFER, fmt, 16, 16)
            val ok = GLES30.glGetError() == GLES30.GL_NO_ERROR
            GLES30.glDeleteRenderbuffers(1, rbo, 0)
            ok
        } catch (e: Exception) {
            false
        }

    // ===== AG1b — real base-gpu shader compile/link/validate on the live driver ==============================
    // Reproduces RuneLite's Template (recursive #include + the 3 macro #defines from GpuPlugin.createTemplate)
    // on the bundled shader source, applies the 330->ES downport (strip the pre-#version license, re-version,
    // add precision), then compiles vert+frag (scene PROGRAM) and vertui+fragui (UI_PROGRAM), links, and
    // glValidateProgram's each — exactly the gate GpuPlugin.initProgram drives. Logs ANDROID_AG1B + the driver's
    // info log on any failure (which is the diagnostic for what a Mali/Adreno downport still needs).
    private fun validateBaseGpuShaders(esTier: Int) {
        val esVer =
            when {
                esTier >= 32 -> "320 es"
                esTier >= 31 -> "310 es"
                else -> "300 es"
            }
        // GpuPlugin.createTemplate's macro includes (default config: TEXTURE_COUNT=256, LINEAR scaling, no colorblind).
        val macros =
            mapOf(
                "texture_config" to "#define TEXTURE_COUNT 256\n",
                "sampling_mode" to "#define SAMPLING_MODE 1\n",
                "colorblind_mode" to "#define COLORBLIND_MODE 0\n",
            )
        try {
            // A VAO must be bound for glValidateProgram (GpuPlugin.initProgram notes this) — bind one.
            val vao = IntArray(1)
            GLES30.glGenVertexArrays(1, vao, 0)
            GLES30.glBindVertexArray(vao[0])
            val sceneVs = compileStage(GLES30.GL_VERTEX_SHADER, "vert.glsl", macros, esVer, "scene.vert")
            val sceneFs = compileStage(GLES30.GL_FRAGMENT_SHADER, "frag.glsl", macros, esVer, "scene.frag")
            val uiVs = compileStage(GLES30.GL_VERTEX_SHADER, "vertui.glsl", macros, esVer, "ui.vert")
            val uiFs = compileStage(GLES30.GL_FRAGMENT_SHADER, "fragui.glsl", macros, esVer, "ui.frag")
            val sceneProg = if (sceneVs.second && sceneFs.second) linkValidate(sceneVs.first, sceneFs.first, "scene") else false
            val uiProg = if (uiVs.second && uiFs.second) linkValidate(uiVs.first, uiFs.first, "ui") else false
            val pass = sceneVs.second && sceneFs.second && uiVs.second && uiFs.second && sceneProg && uiProg
            Log.i(
                tag,
                "ANDROID_AG1B esVer=$esVer sceneVert=${sceneVs.second} sceneFrag=${sceneFs.second} uiVert=${uiVs.second} uiFrag=${uiFs.second} sceneLink+Validate=$sceneProg uiLink+Validate=$uiProg",
            )
            Log.i(tag, "ANDROID_AG1B VERDICT=${if (pass) "PASS" else "FAIL"}")
        } catch (t: Throwable) {
            Log.e(tag, "ANDROID_AG1B EXCEPTION $t", t)
            Log.i(tag, "ANDROID_AG1B VERDICT=FAIL")
        }
    }

    /** RuneLite Template.process: recursive #include (file from assets, or a macro #define), passthrough else. */
    private fun loadTemplate(
        filename: String,
        macros: Map<String, String>,
    ): String {
        val sb = StringBuilder()
        val raw = assets.open("gpu-shaders/$filename").bufferedReader().use { it.readText() }
        for (line in raw.split(Regex("\r?\n"))) {
            if (line.startsWith("#include ")) {
                var res = line.substring(9).trim()
                if (res.startsWith("\"") && res.endsWith("\"")) res = res.substring(1, res.length - 1)
                val macro = macros[res]
                if (macro != null) sb.append(macro) else sb.append(loadTemplate(res, macros))
            } else {
                sb.append(line).append('\n')
            }
        }
        return sb.toString()
    }

    /** 330 -> ES downport — RuneLite base-gpu shaders to GLSL ES. The proven "5 B1 edits" (ported from the iOS
     *  Route-C downportShaderSource, gpu branch), since GLSL ES does NO implicit numeric conversion and reserves
     *  some desktop qualifiers: (1+2) drop the pre-#version license + re-version + precision; (3) strip
     *  `noperspective`; (4) strip the float-literal `f` suffix; (5) explicit int->float / ivec->vec casts at the
     *  exact scene-vertex sites that mix integer engine uniforms/attributes with floats (vertex-only strings, so
     *  applying to both stages is a no-op on the fragment shader). */
    @Suppress("ktlint:standard:property-naming") // intentional constant table
    private val SCENE_VERTEX_CASTS =
        mapOf(
            "vec4(vertf + base, 1)" to "vec4(vertf + vec3(base), 1)",
            "hsl += ((entityTint.xyz - hsl) * entityTint.w) / 128;" to
                "hsl += ((vec3(entityTint.xyz) - hsl) * float(entityTint.w)) / 128.0;",
            "((-expandedMapLoadingChunks * 8 + 1) * TILE_SIZE)" to "(float(-expandedMapLoadingChunks * 8 + 1) * TILE_SIZE)",
            "((104 + expandedMapLoadingChunks * 8 - 1) * TILE_SIZE)" to "(float(104 + expandedMapLoadingChunks * 8 - 1) * TILE_SIZE)",
            "cameraX - drawDistance" to "cameraX - float(drawDistance)",
            "cameraX + drawDistance" to "cameraX + float(drawDistance)",
            "cameraZ - drawDistance" to "cameraZ - float(drawDistance)",
            "cameraZ + drawDistance" to "cameraZ + float(drawDistance)",
            "fogDepth * TILE_SIZE) * useFog" to "float(fogDepth) * TILE_SIZE) * float(useFog)",
        )

    private fun downport(
        src: String,
        esVer: String,
    ): String {
        val idx = src.indexOf("#version")
        var body = if (idx >= 0) src.substring(idx) else src
        body = body.substringAfter('\n', "") // drop the original #version line
        body = Regex("\\bnoperspective\\b").replace(body, "") // (3) reserved word in ES
        body = Regex("(\\d*\\.\\d+|\\d+\\.\\d*)[fF]").replace(body, "$1") // (4) ES forbids the float `f` suffix
        for ((from, to) in SCENE_VERTEX_CASTS) body = body.replace(from, to) // (5) explicit int->float casts
        val precision =
            "precision highp float;\nprecision highp int;\n" +
                "precision highp sampler2DArray;\nprecision highp usampler2DArray;\nprecision highp sampler2D;\n"
        return "#version $esVer\n$precision$body"
    }

    private fun compileStage(
        type: Int,
        file: String,
        macros: Map<String, String>,
        esVer: String,
        label: String,
    ): Pair<Int, Boolean> {
        val src = downport(loadTemplate(file, macros), esVer)
        val id = GLES30.glCreateShader(type)
        GLES30.glShaderSource(id, src)
        GLES30.glCompileShader(id)
        val st = IntArray(1)
        GLES30.glGetShaderiv(id, GLES30.GL_COMPILE_STATUS, st, 0)
        val ok = st[0] != 0
        if (!ok) Log.e(tag, "ANDROID_AG1B compile FAIL $label: ${GLES30.glGetShaderInfoLog(id).take(500)}")
        return Pair(id, ok)
    }

    private fun linkValidate(
        vs: Int,
        fs: Int,
        label: String,
    ): Boolean {
        val p = GLES30.glCreateProgram()
        GLES30.glAttachShader(p, vs)
        GLES30.glAttachShader(p, fs)
        GLES30.glLinkProgram(p)
        val ls = IntArray(1)
        GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ls, 0)
        if (ls[0] == 0) {
            Log.e(tag, "ANDROID_AG1B link FAIL $label: ${GLES30.glGetProgramInfoLog(p).take(500)}")
            return false
        }
        GLES30.glValidateProgram(p)
        val vsRes = IntArray(1)
        GLES30.glGetProgramiv(p, GLES30.GL_VALIDATE_STATUS, vsRes, 0)
        if (vsRes[0] == 0) {
            Log.e(tag, "ANDROID_AG1B validate FAIL $label: ${GLES30.glGetProgramInfoLog(p).take(500)}")
            return false
        }
        return true
    }
}
