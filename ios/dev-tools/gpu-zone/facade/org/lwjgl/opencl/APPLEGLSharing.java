// Facade stub for org.lwjgl.opencl.APPLEGLSharing — symbols only (the Apple cl/gl-sharing path is out on Android).
package org.lwjgl.opencl;

import org.lwjgl.PointerBuffer;

public class APPLEGLSharing {
	public static final int CL_CONTEXT_PROPERTY_USE_CGL_SHAREGROUP_APPLE = 0x10000000;
	public static final int CL_CGL_DEVICE_FOR_CURRENT_VIRTUAL_SCREEN_APPLE = 0x10000002;
	public static int clGetGLContextInfoAPPLE(long context, long gl_context, int param_name,
		PointerBuffer param_value, PointerBuffer param_value_size_ret) {
		throw new UnsupportedOperationException("OpenCL is not available on this platform (Zone renderer)");
	}
}
