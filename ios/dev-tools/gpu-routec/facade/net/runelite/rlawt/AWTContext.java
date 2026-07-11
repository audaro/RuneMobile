// Route C facade — the iOS offscreen-context shim stands in for librlawt. On iOS: createGLContext() makes an
// EAGL ES3 context current; getFramebuffer(false) returns OUR offscreen FBO as "framebuffer 0"; swapBuffers()
// is a no-op (we glReadPixels into the int[] blit). Signatures match the base gpu plugin's call sites.
package net.runelite.rlawt;
import java.awt.Canvas;
public class AWTContext {
	public AWTContext(Canvas canvas) {}
	public static void loadNatives() {}
	public void configurePixelFormat(int alphaDepth, int depthDepth, int stencilDepth) {}
	public void setupGL() {}
	public void createGLContext() {}
	public void destroy() {}
	public int setSwapInterval(int interval) { return interval; }
	public int getFramebuffer(boolean read) { return 0; }
	public int getBufferMode() { return 0; }
	public void swapBuffers() {}
}
