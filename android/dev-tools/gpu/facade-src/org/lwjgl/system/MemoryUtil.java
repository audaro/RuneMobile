package org.lwjgl.system;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.nio.charset.StandardCharsets;

// Functional facade for org.lwjgl.system.MemoryUtil. base-gpu's facade had none (the gpu plugin doesn't use it);
// RLHD uses it for heap-managed scratch (GpuIntBuffer/GpuFloatBuffer) and one big off-heap model-cache arena
// (ModelCache). The heap-style helpers are pure Java; the raw-pointer helpers (nmemAllocChecked / memAddress0 /
// wrap-address-as-buffer) are native, backed by librlawt's RegisterNatives (malloc/free/NewDirectByteBuffer/
// GetDirectBufferAddress) — those are only exercised on the render path, not at loader init.
public class MemoryUtil {
	public static final long NULL = 0L;

	public static ByteBuffer memAlloc(int size) {
		return ByteBuffer.allocateDirect(size).order(ByteOrder.nativeOrder());
	}

	public static ByteBuffer memRealloc(ByteBuffer old, int size) {
		ByteBuffer b = memAlloc(size);
		if (old != null) {
			old.rewind();
			int n = Math.min(size, old.remaining());
			ByteBuffer src = old.duplicate();
			src.limit(src.position() + n);
			b.put(src);
			b.rewind();
		}
		return b;
	}

	public static IntBuffer memAllocInt(int n) { return memAlloc(n << 2).asIntBuffer(); }
	public static FloatBuffer memAllocFloat(int n) { return memAlloc(n << 2).asFloatBuffer(); }

	// Direct buffers are reclaimed by the GC; an explicit free is a no-op here. (A real free is an AG3 perf item.)
	public static void memFree(java.nio.Buffer buffer) { }

	public static IntBuffer memIntBuffer(long address, int capacity) {
		return nNewBuffer(address, capacity << 2).order(ByteOrder.nativeOrder()).asIntBuffer();
	}

	public static FloatBuffer memFloatBuffer(long address, int capacity) {
		return nNewBuffer(address, capacity << 2).order(ByteOrder.nativeOrder()).asFloatBuffer();
	}

	public static String memUTF8(java.nio.ByteBuffer buffer, int length) {
		byte[] b = new byte[length];
		ByteBuffer dup = buffer.duplicate();
		dup.get(b, 0, length);
		return new String(b, StandardCharsets.UTF_8);
	}

	public static String memASCII(java.nio.ByteBuffer buffer, int length) {
		byte[] b = new byte[length];
		ByteBuffer dup = buffer.duplicate();
		dup.get(b, 0, length);
		return new String(b, StandardCharsets.US_ASCII);
	}

	// Reads a NUL-terminated UTF-8 string from a raw address. Only invoked from the OpenCL context callback, which
	// never fires on the Zone path (no CL context is created) — kept resolvable, returns empty if reached.
	public static String memUTF8(long address) { return ""; }

	// Raw-pointer ops — native, backed by librlawt (render path only; never hit at loader init).
	public static native long nmemAllocChecked(long size);
	public static native void nmemFree(long ptr);
	public static native long memAddress0(java.nio.Buffer buffer);
	static native ByteBuffer nNewBuffer(long address, int capacity);
}
