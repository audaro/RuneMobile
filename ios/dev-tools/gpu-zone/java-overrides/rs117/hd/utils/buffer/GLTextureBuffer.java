package rs117.hd.utils.buffer;

import lombok.Getter;

import static org.lwjgl.opengl.GL33C.*;

/*
 * ===========================================================================================================
 * iOS OVERRIDE (gpu-zone B0.5, textureFaces TBO). Verbatim copy of rs117/hd/utils/buffer/GLTextureBuffer.java
 * @ RLHD 7dded59 with iOS-GLES-3.0 deltas:
 *
 *  1) The BUFFER OBJECT can't live on GL_TEXTURE_BUFFER. That target is OpenGL ES 3.2 (texture buffers); on
 *     iOS GLES 3.0 every buffer-object call against it (glBufferData / glBindBuffer / glGetBufferParameteriv /
 *     glMapBufferRange) raises GL_INVALID_ENUM, so the buffer never gets a data store and the zone upload's
 *     map fails ("Failed to map buffer", size 0 / GL_INVALID_ENUM — proven on device). So the GLBuffer target
 *     is GL_COPY_WRITE_BUFFER (a valid ES3 scratch target with no vertex-array interaction); the texture-side
 *     calls stay GL_TEXTURE_BUFFER explicitly — the Route C bridge repacks those to a 2D RGB32I texture
 *     (z_glBindTexture remaps the target to GL_TEXTURE_2D; z_glTexBuffer reads the buffer by id via
 *     GL_COPY_READ_BUFFER, so the buffer's home target is irrelevant to it).
 *
 *  2) The repack is a COPY, not a view. On desktop a texture buffer aliases the buffer's memory, so filling the
 *     buffer is enough. The iOS repack snapshots the bytes into a 2D texture at glTexBuffer time — but RLHD calls
 *     glTexBuffer in initialize()/ensureCapacity(), BEFORE the upload workers map+fill the buffer, so the 2D
 *     texture would capture an empty buffer. We re-run the attach on unmap(), once the per-face data is in.
 *
 *  3) The bridge repack uploads to the GL_TEXTURE_2D bound on the ACTIVE texture unit (desktop glTexBuffer needs
 *     no bound unit). So attachTextureBuffer() saves+restores that unit's 2D binding, otherwise it would clobber
 *     a persistent binding (e.g. the materialStore texture, which is bound once, not per-draw).
 *
 * RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
public class GLTextureBuffer extends GLBuffer {
	// iOS: a valid ES3 buffer-object target for the backing store (GL_TEXTURE_BUFFER is ES 3.2-only). The
	// texture-buffer semantics are reconstructed by the bridge from the GL_TEXTURE_BUFFER texture calls below.
	private static final int IOS_BUFFER_TARGET = GL_COPY_WRITE_BUFFER;
	private static final int GL_TEXTURE_BINDING_2D = 0x8069; // not in the facade constant set

	@Getter
	private int texId;

	public GLTextureBuffer(String name, int usage) {
		this(name, usage, 0);
	}

	public GLTextureBuffer(String name, int usage, int storageFlags) {
		super(name, IOS_BUFFER_TARGET, usage, storageFlags);
	}

	// Repack the backing buffer into the texId 2D texture (bridge: GL_TEXTURE_BUFFER -> 2D RGB32I), without
	// disturbing the active unit's existing 2D binding.
	private void attachTextureBuffer() {
		int prev2d = glGetInteger(GL_TEXTURE_BINDING_2D);
		glBindTexture(GL_TEXTURE_BUFFER, texId);
		glTexBuffer(GL_TEXTURE_BUFFER, GL_RGB32I, id);
		glBindTexture(GL_TEXTURE_2D, prev2d);
	}

	@Override
	public GLTextureBuffer initialize(long initialCapacity) {
		super.initialize(initialCapacity);
		texId = glGenTextures();
		attachTextureBuffer();
		return this;
	}

	@Override
	public boolean ensureCapacity(long byteOffset, long numBytes) {
		int oldId = id;
		boolean resized = super.ensureCapacity(byteOffset, numBytes);
		if (oldId != id)
			attachTextureBuffer();
		return resized;
	}

	@Override
	public void unmap() {
		super.unmap();
		// iOS: the TBO->2D repack ran while the buffer was still empty; now that the upload workers have filled
		// it, re-attach so the 2D texture captures the real per-face data.
		if (texId != 0)
			attachTextureBuffer();
	}

	@Override
	public void destroy() {
		if (texId != 0) {
			glDeleteTextures(texId);
			texId = 0;
		}

		super.destroy();
	}
}
