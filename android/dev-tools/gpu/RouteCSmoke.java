// AG1a facade-bind EGL smoke (Android) — the cheapest GPU go/no-go. Assert that the base `gpu` plugin's hard
// requirement — GL.createCapabilities().OpenGL33 == true (GpuPlugin.java:317 aborts otherwise) — is satisfiable
// THROUGH THE FACADE on a LIVE Android EGL/GLES context, headless, and that a few real core GL calls work,
// BEFORE committing to the full plugin wiring. Mirrors the iOS Route-C L1 kill-test (RouteCL1Probe).
//
// Runs on its own thread (the embedded VM's main worker), so it does not depend on RuneLite's threading model.
// Booted ALONE on the facade-only gpu-smoke.jar (no shaded jar, no real LWJGL) when -Drunelite.routec.smoke=true,
// so the facade is provably the only provider; the host (jvm_bootstrap) RegisterNatives the GL bridge
// (librlawt.so) before this runs. The verdict line is grepped from logcat (jvm-stdout) + md5-gated.
//
// NOTE: emulator-GREEN != AG1-GREEN. SwiftShader is lenient; this proves the facade link + EGL context +
// RegisterNatives completeness (the ~75% AG1a part). It does NOT run under the real DeviceHeadlessBoot HotSpot
// render thread, compile a real shader, or touch the CACIO canvas — those are AG1b (device-only).
public class RouteCSmoke
{
	public static void main(String[] args)
	{
		System.out.println("==== ANDROID_AG1A smoke (Android EGL ES3 + facade + librlawt bridge) ====");
		try
		{
			// 1. EGL ES3 context + offscreen COLOR+DEPTH FBO, made current on THIS thread (native createGLContext
			//    -> rc_awt_create_context -> EGL pbuffer). No engine, so it uses the 512x512 default.
			net.runelite.rlawt.AWTContext ctx = new net.runelite.rlawt.AWTContext(null);
			ctx.loadNatives();
			ctx.configurePixelFormat(0, 0, 0);
			ctx.createGLContext();

			// 2. The plugin's gate: a GLCapabilities the unmodified plugin accepts as OpenGL33.
			org.lwjgl.opengl.GLCapabilities caps = org.lwjgl.opengl.GL.createCapabilities();
			boolean ogl33 = caps.OpenGL33;
			boolean aniso = caps.GL_EXT_texture_filter_anisotropic;
			long texStorage = caps.glTexStorage3D;

			// 3. Real core GL through the bridge: a program id (non-zero) + a clean error + the live FBO id + strings.
			int prog = org.lwjgl.opengl.GL33C.glCreateProgram();
			int errAfterProg = org.lwjgl.opengl.GL33C.glGetError();
			int fbo = ctx.getFramebuffer(false);
			int bufMode = ctx.getBufferMode();
			String glVersion = org.lwjgl.opengl.GL33C.glGetString(org.lwjgl.opengl.GL33C.GL_VERSION);
			String glRenderer = org.lwjgl.opengl.GL33C.glGetString(org.lwjgl.opengl.GL33C.GL_RENDERER);

			// 4. The 5 census shims must not throw (no-ops / trivial on GLES).
			org.lwjgl.opengl.GL33C.glClearDepth(0.0);
			org.lwjgl.opengl.GL45C.glClipControl(org.lwjgl.opengl.GL45C.GL_LOWER_LEFT,
				org.lwjgl.opengl.GL45C.GL_ZERO_TO_ONE);
			int errAfterShims = org.lwjgl.opengl.GL33C.glGetError();

			boolean pass = ogl33 && prog != 0 && errAfterProg == 0 && fbo != 0 && errAfterShims == 0;

			System.out.println("ANDROID_AG1A OpenGL33=" + ogl33
				+ " createProgram=" + prog
				+ " fbo=" + fbo
				+ " bufMode=" + bufMode
				+ " glErrAfterProg=" + errAfterProg
				+ " glErrAfterShims=" + errAfterShims
				+ " texStorage3D=" + texStorage
				+ " aniso=" + aniso
				+ " GL_VERSION=" + glVersion
				+ " GL_RENDERER=" + glRenderer);
			System.out.println("ANDROID_AG1A VERDICT=" + (pass ? "PASS" : "FAIL"));

			ctx.destroy();
		}
		catch (Throwable t)
		{
			System.out.println("ANDROID_AG1A EXCEPTION " + t);
			t.printStackTrace(System.out);
			System.out.println("ANDROID_AG1A VERDICT=FAIL");
		}
	}
}
