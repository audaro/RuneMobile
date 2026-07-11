// Facade stub for org.lwjgl.opencl.CLImageFormat — symbols only (Zone never builds a CL image).
package org.lwjgl.opencl;

import org.lwjgl.system.MemoryStack;

public class CLImageFormat {
	public static CLImageFormat calloc(MemoryStack stack) { return new CLImageFormat(); }
	public CLImageFormat image_channel_order(int v) { return this; }
	public CLImageFormat image_channel_data_type(int v) { return this; }
}
