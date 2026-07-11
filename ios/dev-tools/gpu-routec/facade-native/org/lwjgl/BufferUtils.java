package org.lwjgl;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.IntBuffer;
import java.nio.FloatBuffer;
public class BufferUtils {
	public static IntBuffer createIntBuffer(int capacity) {
		return ByteBuffer.allocateDirect(capacity << 2).order(ByteOrder.nativeOrder()).asIntBuffer();
	}
	public static FloatBuffer createFloatBuffer(int capacity) {
		return ByteBuffer.allocateDirect(capacity << 2).order(ByteOrder.nativeOrder()).asFloatBuffer();
	}
}
