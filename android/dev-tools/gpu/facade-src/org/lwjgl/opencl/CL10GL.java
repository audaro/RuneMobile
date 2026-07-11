// Facade stub for org.lwjgl.opencl.CL10GL — symbols only (Zone never enqueues GL-shared CL objects).
package org.lwjgl.opencl;

import java.nio.IntBuffer;
import org.lwjgl.PointerBuffer;

public class CL10GL {
	private static RuntimeException ni() {
		return new UnsupportedOperationException("OpenCL is not available on this platform (Zone renderer)");
	}
	public static long clCreateFromGLBuffer(long context, long flags, int bufobj, IntBuffer errcode_ret) { throw ni(); }
	public static int clEnqueueAcquireGLObjects(long command_queue, PointerBuffer mem_objects, PointerBuffer event_wait_list, PointerBuffer event) { throw ni(); }
	public static int clEnqueueReleaseGLObjects(long command_queue, PointerBuffer mem_objects, PointerBuffer event_wait_list, PointerBuffer event) { throw ni(); }
}
