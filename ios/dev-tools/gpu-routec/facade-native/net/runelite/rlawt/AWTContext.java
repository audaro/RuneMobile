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
}
