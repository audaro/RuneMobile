package org.lwjgl;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.LongBuffer;

// Functional facade for org.lwjgl.PointerBuffer: a NIO-style cursor over 64-bit pointers, backed by a direct
// LongBuffer. base-gpu never called any methods on it (empty stub sufficed); RLHD uses the full put/get/flip
// cursor API (building OpenCL context-property and work-size arrays). On the Zone path the buffers it fills are
// only consumed by cl* calls that never run (OpenCLManager.context == 0), so a pure-Java backing is sufficient.
public class PointerBuffer {
	private final LongBuffer buf;

	public PointerBuffer(LongBuffer backing) { this.buf = backing; }

	public PointerBuffer(int capacity) {
		this(ByteBuffer.allocateDirect(capacity << 3).order(ByteOrder.nativeOrder()).asLongBuffer());
	}

	public static PointerBuffer allocateDirect(int capacity) { return new PointerBuffer(capacity); }

	public int capacity() { return buf.capacity(); }
	public int position() { return buf.position(); }
	public PointerBuffer position(int p) { buf.position(p); return this; }
	public int limit() { return buf.limit(); }
	public PointerBuffer limit(int l) { buf.limit(l); return this; }
	public int remaining() { return buf.remaining(); }
	public boolean hasRemaining() { return buf.hasRemaining(); }
	public PointerBuffer flip() { buf.flip(); return this; }
	public PointerBuffer clear() { buf.clear(); return this; }
	public PointerBuffer rewind() { buf.rewind(); return this; }

	public PointerBuffer put(long value) { buf.put(value); return this; }
	public PointerBuffer put(int index, long value) { buf.put(index, value); return this; }
	public PointerBuffer put(PointerBuffer src) { buf.put(src.buf); return this; }

	public long get() { return buf.get(); }
	public long get(int index) { return buf.get(index); }

	public LongBuffer getLongBuffer() { return buf; }
}
