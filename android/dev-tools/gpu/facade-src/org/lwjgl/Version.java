// Facade for org.lwjgl.Version — RLHD only logs Version.getVersion() at startup.
package org.lwjgl;

public class Version {
	public static String getVersion() { return "3.3.x-facade (Android EGL bridge)"; }
}
