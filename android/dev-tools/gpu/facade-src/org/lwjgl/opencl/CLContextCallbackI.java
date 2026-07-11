// Facade stub — the cl_context callback functional interface (matches the 4-arg lambda RLHD passes).
package org.lwjgl.opencl;

@FunctionalInterface
public interface CLContextCallbackI {
	void invoke(long errinfo, long private_info, long cb, long user_data);
}
