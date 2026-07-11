// Facade stub for org.lwjgl.opencl.CL10 — symbols only. On the Android Zone path OpenCLManager.context is
// always 0 (CL.create() runs only on the Legacy/Apple compute path), so none of these methods is ever invoked;
// they exist purely so RLHD compiles and class-loads (no NoClassDefFound). Constants carry placeholder values
// (the audit confirmed the exact values are irrelevant on Zone). Methods throw if ever called.
package org.lwjgl.opencl;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.nio.LongBuffer;
import org.lwjgl.PointerBuffer;

public class CL10 {
	// errors
	public static final int CL_SUCCESS = 0;
	public static final int CL_INVALID_DEVICE_TYPE = -31;

	// context properties
	public static final int CL_CONTEXT_PLATFORM = 0x1084;

	// device types (cl_device_type bitfield)
	public static final int CL_DEVICE_TYPE_GPU = 0x4;
	public static final int CL_DEVICE_TYPE_ALL = 0xFFFFFFFF;

	// platform info
	public static final int CL_PLATFORM_PROFILE = 0x0900;
	public static final int CL_PLATFORM_VERSION = 0x0901;
	public static final int CL_PLATFORM_NAME = 0x0902;
	public static final int CL_PLATFORM_VENDOR = 0x0903;
	public static final int CL_PLATFORM_EXTENSIONS = 0x0904;

	// device info
	public static final int CL_DEVICE_TYPE = 0x1000;
	public static final int CL_DEVICE_VENDOR_ID = 0x1001;
	public static final int CL_DEVICE_MAX_COMPUTE_UNITS = 0x1002;
	public static final int CL_DEVICE_MAX_WORK_ITEM_DIMENSIONS = 0x1003;
	public static final int CL_DEVICE_MAX_WORK_GROUP_SIZE = 0x1004;
	public static final int CL_DEVICE_MAX_CLOCK_FREQUENCY = 0x100C;
	public static final int CL_DEVICE_ADDRESS_BITS = 0x100D;
	public static final int CL_DEVICE_QUEUE_PROPERTIES = 0x102A;
	public static final int CL_DEVICE_AVAILABLE = 0x1027;
	public static final int CL_DEVICE_COMPILER_AVAILABLE = 0x1028;
	public static final int CL_DEVICE_NAME = 0x102B;
	public static final int CL_DEVICE_VENDOR = 0x102C;
	public static final int CL_DRIVER_VERSION = 0x102D;
	public static final int CL_DEVICE_PROFILE = 0x102E;
	public static final int CL_DEVICE_VERSION = 0x102F;
	public static final int CL_DEVICE_EXTENSIONS = 0x1030;

	// command queue
	public static final int CL_QUEUE_OUT_OF_ORDER_EXEC_MODE_ENABLE = 0x1;

	// mem flags (cl_mem_flags)
	public static final int CL_MEM_READ_ONLY = 0x4;
	public static final int CL_MEM_WRITE_ONLY = 0x2;
	public static final int CL_MEM_COPY_HOST_PTR = 0x20;

	// channel order / type
	public static final int CL_R = 0x10B0;
	public static final int CL_SIGNED_INT16 = 0x10D8;

	// program build info
	public static final int CL_PROGRAM_BUILD_STATUS = 0x1181;
	public static final int CL_PROGRAM_BUILD_OPTIONS = 0x1182;
	public static final int CL_PROGRAM_BUILD_LOG = 0x1183;

	private static RuntimeException ni() {
		return new UnsupportedOperationException("OpenCL is not available on this platform (Zone renderer)");
	}

	public static int clGetPlatformIDs(PointerBuffer platforms, IntBuffer num_platforms) { throw ni(); }
	public static String clGetPlatformInfo(long platform, int param_name) { throw ni(); }
	public static int clGetPlatformInfo(long platform, int param_name, ByteBuffer param_value, PointerBuffer param_value_size_ret) { throw ni(); }
	public static int clGetDeviceIDs(long platform, long device_type, PointerBuffer devices, IntBuffer num_devices) { throw ni(); }
	public static int clGetDeviceInfo(long device, int param_name, ByteBuffer param_value, PointerBuffer param_value_size_ret) { throw ni(); }
	public static int clGetDeviceInfo(long device, int param_name, IntBuffer param_value, PointerBuffer param_value_size_ret) { throw ni(); }
	public static int clGetDeviceInfo(long device, int param_name, LongBuffer param_value, PointerBuffer param_value_size_ret) { throw ni(); }
	public static int clGetDeviceInfo(long device, int param_name, PointerBuffer param_value, PointerBuffer param_value_size_ret) { throw ni(); }
	public static int clGetDeviceInfo(long device, int param_name, long[] param_value, PointerBuffer param_value_size_ret) { throw ni(); }
	public static long clCreateContext(PointerBuffer properties, long device, CLContextCallback pfn_notify, long user_data, IntBuffer errcode_ret) { throw ni(); }
	public static int clReleaseContext(long context) { throw ni(); }
	public static long clCreateCommandQueue(long context, long device, long properties, int[] errcode_ret) { throw ni(); }
	public static int clReleaseCommandQueue(long command_queue) { throw ni(); }
	public static long clCreateProgramWithSource(long context, CharSequence string, IntBuffer errcode_ret) { throw ni(); }
	public static int clBuildProgram(long program, long device, CharSequence options, CLProgramCallback pfn_notify, long user_data) { throw ni(); }
	public static int clGetProgramBuildInfo(long program, long device, int param_name, IntBuffer param_value, PointerBuffer param_value_size_ret) { throw ni(); }
	public static int clGetProgramBuildInfo(long program, long device, int param_name, ByteBuffer param_value, PointerBuffer param_value_size_ret) { throw ni(); }
	public static int clReleaseProgram(long program) { throw ni(); }
	public static long clCreateKernel(long program, CharSequence kernel_name, IntBuffer errcode_ret) { throw ni(); }
	public static int clReleaseKernel(long kernel) { throw ni(); }
	public static int clSetKernelArg(long kernel, int arg_index, long arg_size) { throw ni(); }
	public static int clSetKernelArg1p(long kernel, int arg_index, long arg_value) { throw ni(); }
	public static long clCreateImage3D(long context, long flags, CLImageFormat image_format,
		long image_width, long image_height, long image_depth, long image_row_pitch, long image_slice_pitch,
		java.nio.ShortBuffer host_ptr, IntBuffer errcode_ret) { throw ni(); }
	public static int clReleaseMemObject(long memobj) { throw ni(); }
	public static int clEnqueueNDRangeKernel(long command_queue, long kernel, int work_dim,
		PointerBuffer global_work_offset, PointerBuffer global_work_size, PointerBuffer local_work_size,
		PointerBuffer event_wait_list, PointerBuffer event) { throw ni(); }
	public static int clReleaseEvent(long event) { throw ni(); }
	public static int clFinish(long command_queue) { throw ni(); }
}
