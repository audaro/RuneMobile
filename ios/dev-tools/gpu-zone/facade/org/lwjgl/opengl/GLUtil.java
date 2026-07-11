// Route C facade — debug callback is a no-op on GLES (KHR_debug optional).
package org.lwjgl.opengl;
import org.lwjgl.system.Callback;
public class GLUtil {
	public static Callback setupDebugMessageCallback() { return null; }
}
