// Facade stub for org.lwjgl.opencl.CLCapabilities — only the fields RLHD's OpenCLManager reads. All false on the
// Zone path (the device-capability query never runs), which short-circuits the Legacy/Apple gl-sharing branches.
package org.lwjgl.opencl;

public class CLCapabilities {
	public boolean OpenCL12;
	public boolean cl_khr_gl_sharing;
	public boolean cl_APPLE_gl_sharing;
}
