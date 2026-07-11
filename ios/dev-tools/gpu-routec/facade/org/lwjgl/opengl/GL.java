// Route C facade — org.lwjgl.opengl.GL. iOS bridge: createCapabilities() probes the live GLES context.
package org.lwjgl.opengl;
public class GL {
	public static GLCapabilities createCapabilities() { return new GLCapabilities(); }
	public static GLCapabilities getCapabilities() { return new GLCapabilities(); }
}
