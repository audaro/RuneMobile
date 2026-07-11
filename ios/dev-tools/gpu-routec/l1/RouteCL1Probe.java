// Route C — L1 on-device kill-test. The CHEAPEST device gate: assert that the base `gpu` plugin's hard
// requirement — GL.createCapabilities().OpenGL33 == true (GpuPlugin.java:317 aborts otherwise) — is satisfiable
// THROUGH THE FACADE on a live EAGL ES3 context, and that a few real core GL calls work, BEFORE committing to the
// full plugin wiring. Runs entirely on its own thread (the JVM main worker), so it does not depend on RuneLite's
// threading model — it isolates the bridge: facade classes load, RegisterNatives bound them, the EAGL context is
// current, glCreateProgram returns non-zero, glGetError is clean, the 5 shims don't throw.
//
// Classpath = routec-l1.jar ONLY (facade-native + facade support + this class). No shaded jar, no LWJGL — so the
// facade is provably the only provider. Booted by the shell when -Drunelite.routec.l1=true (instead of
// DeviceHeadlessBoot). The verdict line is parsed from the devicectl-pulled jvm-stdio.log and md5-gated.
public class RouteCL1Probe
{
	public static void main(String[] args)
	{
		System.out.println("==== ROUTEC_L1 probe (EAGL ES3 + facade + JNI bridge) ====");
		try
		{
			// 1. EAGL ES3 context + offscreen COLOR+DEPTH FBO, made current on THIS thread (native createGLContext
			//    -> rc_awt_create_context -> RouteCBridge). No engine, so it uses the 512x512 default.
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

			// 4. The 5 census shims must not throw (no-ops / trivial on iOS GLES).
			org.lwjgl.opengl.GL33C.glClearDepth(0.0);
			org.lwjgl.opengl.GL45C.glClipControl(org.lwjgl.opengl.GL45C.GL_LOWER_LEFT,
				org.lwjgl.opengl.GL45C.GL_ZERO_TO_ONE);
			int errAfterShims = org.lwjgl.opengl.GL33C.glGetError();

			boolean pass = ogl33 && prog != 0 && errAfterProg == 0 && fbo != 0 && errAfterShims == 0;

			System.out.println("ROUTEC_L1 OpenGL33=" + ogl33
				+ " createProgram=" + prog
				+ " fbo=" + fbo
				+ " bufMode=" + bufMode
				+ " glErrAfterProg=" + errAfterProg
				+ " glErrAfterShims=" + errAfterShims
				+ " texStorage3D=" + texStorage
				+ " aniso=" + aniso
				+ " GL_VERSION=" + glVersion
				+ " GL_RENDERER=" + glRenderer);
			System.out.println("ROUTEC_L1 VERDICT=" + (pass ? "PASS" : "FAIL"));

			ctx.destroy();
		}
		catch (Throwable t)
		{
			System.out.println("ROUTEC_L1 EXCEPTION " + t);
			t.printStackTrace(System.out);
			System.out.println("ROUTEC_L1 VERDICT=FAIL");
		}
	}
}
