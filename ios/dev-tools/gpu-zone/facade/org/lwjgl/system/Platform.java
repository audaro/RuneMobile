// Facade for org.lwjgl.system.Platform. RLHD only compares Platform.get() against Platform.WINDOWS (to special-case
// Windows path handling); on Android we report LINUX, so those Windows-only branches are skipped.
package org.lwjgl.system;

public enum Platform {
	LINUX,
	MACOSX,
	WINDOWS;

	public static Platform get() { return LINUX; }
}
