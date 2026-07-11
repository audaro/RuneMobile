// Facade stub for org.lwjgl.opencl.CL — symbols only (Zone never calls CL.create()).
package org.lwjgl.opencl;

public class CL {
	private static RuntimeException ni() {
		return new UnsupportedOperationException("OpenCL is not available on this platform (Zone renderer)");
	}
	public static void create() { throw ni(); }
	public static void destroy() { throw ni(); }
	public static CLCapabilities createPlatformCapabilities(long platform) { throw ni(); }
	public static CLCapabilities createDeviceCapabilities(long device, CLCapabilities platformCaps) { throw ni(); }
}
