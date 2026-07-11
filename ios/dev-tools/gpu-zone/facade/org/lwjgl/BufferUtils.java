package org.lwjgl;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.IntBuffer;
import java.nio.FloatBuffer;
import java.nio.ShortBuffer;
public class BufferUtils {
	public static ByteBuffer createByteBuffer(int capacity) {
		return ByteBuffer.allocateDirect(capacity).order(ByteOrder.nativeOrder());
	}
	public static ShortBuffer createShortBuffer(int capacity) {
		return ByteBuffer.allocateDirect(capacity << 1).order(ByteOrder.nativeOrder()).asShortBuffer();
	}
	public static IntBuffer createIntBuffer(int capacity) {
		return ByteBuffer.allocateDirect(capacity << 2).order(ByteOrder.nativeOrder()).asIntBuffer();
	}
	public static FloatBuffer createFloatBuffer(int capacity) {
		return ByteBuffer.allocateDirect(capacity << 2).order(ByteOrder.nativeOrder()).asFloatBuffer();
	}
}
