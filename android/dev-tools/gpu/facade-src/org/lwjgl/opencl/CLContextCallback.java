// Facade stub for org.lwjgl.opencl.CLContextCallback — extends the system Callback so .free()/.close() resolve.
package org.lwjgl.opencl;

import org.lwjgl.system.Callback;

public class CLContextCallback extends Callback {
	public static CLContextCallback create(CLContextCallbackI i) { return new CLContextCallback(); }
}
