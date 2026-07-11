// Route C DEVICE facade — native; backed by the kAWT RegisterNatives table -> RouteCBridge EAGL analogue.
package net.runelite.rlawt;
import java.awt.Canvas;
public class AWTContext {
	public AWTContext(Canvas canvas) {}
	public static native void loadNatives();
	public native void configurePixelFormat(int alphaDepth, int depthDepth, int stencilDepth);
	public native void createGLContext();
	public native void destroy();
	public native int setSwapInterval(int interval);
	public native int getFramebuffer(boolean read);
	public native int getBufferMode();
	public native void swapBuffers();
	// Platform GL/CL-interop handles — read only by RLHD's OpenCLManager (Legacy/Apple compute path), which never
	// runs on the Android Zone path (no CL context). Present so RLHD compiles; return 0 (unused).
	public long getGLContext() { return 0L; }
	public long getWGLHDC() { return 0L; }
	public long getGLXDisplay() { return 0L; }
	public long getCGLShareGroup() { return 0L; }
}
