// Route C DEVICE facade — native; backed by rc_GL_createCapabilities (RegisterNatives), returns a GLCapabilities
// with OpenGL33=true (REQUIRED or the plugin aborts at GpuPlugin.java:317).
package org.lwjgl.opengl;
public class GL {
	public static native GLCapabilities createCapabilities();
	public static native GLCapabilities getCapabilities();
}
