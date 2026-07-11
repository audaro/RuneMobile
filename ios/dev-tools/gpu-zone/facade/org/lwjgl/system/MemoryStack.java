package org.lwjgl.system;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.IntBuffer;
import java.nio.LongBuffer;
import org.lwjgl.PointerBuffer;

// Functional facade for org.lwjgl.system.MemoryStack: a per-thread bump-allocated arena of direct memory, scoped
// by try-with-resources. base-gpu's facade had no MemoryStack (the gpu plugin doesn't use one); RLHD uses it for
// short-lived scratch buffers (GL/CL query out-params, work-size arrays). A pure-Java direct-ByteBuffer arena is
// sufficient — the only consumers that would need a real native address are the cl* calls, which never run on Zone.
public class MemoryStack implements AutoCloseable {
	private static final int SIZE = 512 * 1024; // generous; RLHD frames are a handful of ints/pointers
	private static final ThreadLocal<MemoryStack> TLS = ThreadLocal.withInitial(MemoryStack::new);

	private final ByteBuffer arena = ByteBuffer.allocateDirect(SIZE).order(ByteOrder.nativeOrder());
	private final int[] frames = new int[256];
	private int frameIndex = 0;
	private int pointer = 0;

	public static MemoryStack stackGet() { return TLS.get(); }

	public static MemoryStack stackPush() { return TLS.get().push(); }

	public MemoryStack push() {
		frames[frameIndex++] = pointer;
		return this;
	}

	public MemoryStack pop() {
		pointer = frames[--frameIndex];
		return this;
	}

	@Override public void close() { pop(); }

	private int align(int p, int alignment) { return (p + (alignment - 1)) & ~(alignment - 1); }

	public ByteBuffer malloc(int size) {
		int start = align(pointer, 8);
		pointer = start + size;
		if (pointer > SIZE)
			throw new OutOfMemoryError("MemoryStack overflow: needed " + pointer + " of " + SIZE);
		ByteBuffer b = arena.duplicate();
		b.position(start).limit(start + size);
		return b.slice().order(ByteOrder.nativeOrder());
	}

	public ByteBuffer calloc(int size) {
		ByteBuffer b = malloc(size);
		for (int i = 0; i < size; i++) b.put(i, (byte) 0);
		return b;
	}

	public IntBuffer mallocInt(int n) { return malloc(n << 2).asIntBuffer(); }
	public IntBuffer callocInt(int n) { return calloc(n << 2).asIntBuffer(); }
	public LongBuffer mallocLong(int n) { return malloc(n << 3).asLongBuffer(); }
	public LongBuffer callocLong(int n) { return calloc(n << 3).asLongBuffer(); }
	public PointerBuffer mallocPointer(int n) { return new PointerBuffer(malloc(n << 3).asLongBuffer()); }
	public PointerBuffer callocPointer(int n) { return new PointerBuffer(calloc(n << 3).asLongBuffer()); }

	public PointerBuffer pointers(long... values) {
		PointerBuffer pb = mallocPointer(values.length);
		for (long v : values) pb.put(v);
		pb.flip();
		return pb;
	}
}
