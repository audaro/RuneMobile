package rs117.hd.utils.buffer;

import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.util.ArrayDeque;
import java.util.ArrayList;
import lombok.Getter;
import lombok.RequiredArgsConstructor;
import org.lwjgl.BufferUtils;
import rs117.hd.utils.Destructible;
import rs117.hd.utils.DestructibleHandler;

import static rs117.hd.utils.buffer.GLBuffer.MAP_INVALIDATE;
import static rs117.hd.utils.buffer.GLBuffer.MAP_UNSYNCHRONIZED;
import static rs117.hd.utils.buffer.GLBuffer.MAP_WRITE;

/*
 * ===========================================================================================================
 * iOS OVERRIDE (gpu-zone B0.5, dynamic-model TBO). Verbatim copy of
 * rs117/hd/utils/buffer/GLMappedBufferIntWriter.java @ RLHD 7dded59 with ONE iOS-GLES-3.0 delta in flush():
 * the two unmap calls go through buffer.unmap() (the polymorphic GLBuffer) instead of mappedBuffer.unmap()
 * (the GLMappedBuffer directly).
 *
 * WHY: the animated NPC/player geometry streams its per-face data through this writer wrapping the
 * DynamicModelVAO's textureFaces GLTextureBuffer. On iOS the TBO has no real texture-buffer backing
 * (GL_TEXTURE_BUFFER is ES 3.2); the bridge fakes it by COPYING the buffer's bytes into a 2D RGB32I texture
 * at glTexBuffer time. GLTextureBuffer.unmap() (iOS override) re-runs that copy AFTER the data is written so
 * the texture captures the real per-face colours. The static scene gets it because Zone.unmap() calls
 * tboF.unmap() (-> GLTextureBuffer.unmap()). But this writer flushed via mappedBuffer.unmap() (a
 * GLMappedBuffer), which bypasses the GLTextureBuffer override entirely -> the 2D colour texture kept the
 * empty snapshot from initialize() -> every animated model rendered as a BLACK silhouette (geometry correct,
 * colour zero). buffer == mappedBuffer.getOwner() and buffer.mappedBuffer == this.mappedBuffer (map() returns
 * the owner's own field), so buffer.unmap() unmaps the same GLMappedBuffer and additionally re-runs the
 * repack. For the plain VBO/EBO writers buffer.unmap() is identical to mappedBuffer.unmap() (no override) =>
 * no behaviour change there. This is inert on desktop (real texture buffers alias the storage, no repack).
 *
 * RE-MERGE on RLHD rev bumps.
 * ===========================================================================================================
 */
@RequiredArgsConstructor
public class GLMappedBufferIntWriter implements Destructible {
	public static final boolean DEBUG_STAGING = false;

	private final GLBuffer buffer;
	private GLBuffer stagingBuffer;

	private final ArrayDeque<ReservedView> freeViews = new ArrayDeque<>();
	private final ArrayDeque<ReservedView> usedStagingViews = new ArrayDeque<>();
	private final ArrayList<ReservedView> usedMappedViews = new ArrayList<>();

	private GLMappedBuffer mappedBuffer;
	private int writtenMappedInts;
	private int writtenStagingInts;

	public int getWrittenInts() {
		return writtenMappedInts + writtenStagingInts;
	}

	public void map(boolean sync) {
		mappedBuffer = buffer.map(MAP_WRITE | MAP_INVALIDATE | (sync ? 0 : MAP_UNSYNCHRONIZED));
	}

	public synchronized ReservedView reserve(int sizeInts) {
		assert mappedBuffer.isMapped();

		// Need staging if we've already staged or mapped buffer has no space
		if (writtenStagingInts > 0 || mappedBuffer.intView().remaining() < sizeInts || DEBUG_STAGING) {
			ReservedView view = new ReservedView();
			view.buffer = BufferUtils.createIntBuffer(sizeInts);
			view.bufferOffsetInts = writtenMappedInts + writtenStagingInts;
			writtenStagingInts += sizeInts;
			usedStagingViews.add(view);
			return view;
		}

		ReservedView view = freeViews.poll();
		if (view == null)
			view = new ReservedView();

		if (view.backing != mappedBuffer.byteView()) {
			view.backing = mappedBuffer.byteView();
			view.buffer = view.backing.asIntBuffer();
		}

		view.buffer.clear();
		view.buffer.position(writtenMappedInts);
		view.buffer.limit(writtenMappedInts + sizeInts);
		view.bufferOffsetInts = writtenMappedInts;

		writtenMappedInts += sizeInts;
		mappedBuffer.intView().position(writtenMappedInts);

		usedMappedViews.add(view);
		return view;
	}

	@Override
	@SuppressWarnings("deprecation")
	protected void finalize() {
		if (!usedStagingViews.isEmpty() || !usedMappedViews.isEmpty() || !freeViews.isEmpty())
			DestructibleHandler.queueLeakedDestruction(this);
	}

	@Override
	public void destroy() {
		if (mappedBuffer != null && mappedBuffer.isMapped())
			mappedBuffer.unmap();
		mappedBuffer = null;

		if (stagingBuffer != null)
			stagingBuffer.destroy();
		stagingBuffer = null;

		for (ReservedView view : freeViews) {
			view.backing = null;
			view.buffer = null;
		}
		freeViews.clear();

		for (ReservedView view : usedMappedViews) {
			view.backing = null;
			view.buffer = null;
		}
		usedMappedViews.clear();

		for (ReservedView view : usedStagingViews) {
			view.backing = null;
			view.buffer = null;
		}
		usedStagingViews.clear();
	}

	public synchronized long flush() {
		mappedBuffer.setPositionBytes(writtenMappedInts * Integer.BYTES);
		// iOS: unmap through the owning GLBuffer (not the GLMappedBuffer) so GLTextureBuffer.unmap() re-runs the
		// TBO->2D repack now that the per-face data is written. See the class header.
		buffer.unmap();

		if (!usedStagingViews.isEmpty()) {
			final GLBuffer owner = mappedBuffer.getOwner();
			final long mappedSize = (long) writtenMappedInts * Integer.BYTES;
			final long stagingCapacity = (long) writtenStagingInts * Integer.BYTES;

			owner.ensureCapacity(mappedSize, stagingCapacity);
			mappedBuffer = owner.map(MAP_WRITE, mappedSize, stagingCapacity);

			final IntBuffer intView = owner.mapped().intView().clear();
			ReservedView view;
			while ((view = usedStagingViews.poll()) != null) {
				view.buffer.flip();
				intView.put(view.buffer);
				view.buffer = null;
			}

			mappedBuffer.syncViews();
			// iOS: same as above — re-attach the full buffer (mapped + staging) to the 2D texture.
			owner.unmap();
		}

		freeViews.addAll(usedMappedViews);
		usedMappedViews.clear();

		long writtenBytes = (long) (writtenMappedInts + writtenStagingInts) * Integer.BYTES;
		writtenMappedInts = 0;
		writtenStagingInts = 0;
		return writtenBytes;
	}

	public static final class ReservedView {
		private ByteBuffer backing;
		@Getter
		private IntBuffer buffer;
		@Getter
		private int bufferOffsetInts;

		public int getEndOffsetInts() {
			return (backing == null ? bufferOffsetInts : 0) + buffer.position();
		}
	}
}
