/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
package net.runelite.client.headless;

import java.util.Arrays;
import net.runelite.api.MainBufferProvider;
import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertTrue;
import org.junit.Test;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link JavaBridge}'s frame-publish seam — the native shells (iOS + Android) pull
 * {@link JavaBridge#getFramePixels()}/{@link JavaBridge#getFrameSeq()} every display refresh, so the
 * double-buffering and the GPU load-in warmup hold are a hard behavioural contract that the shared-contract
 * signature diff cannot see. The two invariants under test:
 * <ul>
 *   <li><b>Stable snapshot, not the live backing store.</b> {@link JavaBridge#snapshot} must copy the
 *       composited pixels into an alternating buffer and bump {@code frameSeq} last, so an off-thread native
 *       reader always copies out a <em>whole</em> frame and the frame it is mid-copy on is never scribbled
 *       over by the next publish (the anti-tearing reason the double buffer exists).</li>
 *   <li><b>GPU sky-flash hold.</b> {@link JavaBridge#gpuPublish} must withhold publishing (no seq bump) until
 *       {@code SCENE_WARMUP} scene draws have rendered, so the bare sky/fog frame that RLHD clears to during
 *       region upload never flashes through on login/hop.</li>
 * </ul>
 * Pure: {@link MainBufferProvider} is mocked, no engine boot. {@code ENABLED} is read once at class load from
 * {@code -Drunelite.bridge}; the static initialiser sets it before the class loads (reliable — no other test
 * in the module references the headless bridges). The shared static frame state means assertions are made
 * <em>relative</em> to a captured baseline (seq deltas), never against absolute values.
 */
public class JavaBridgeTest
{
	static
	{
		System.setProperty("runelite.bridge", "true");
	}

	@Test
	public void enabledFlagIsSet()
	{
		assertTrue("runelite.bridge must be enabled before JavaBridge loads", JavaBridge.isEnabled());
	}

	@Test
	public void snapshotPublishesACopyAndBumpsSeq()
	{
		final int[] src = filled(4 * 2, 7);
		final int seqBefore = JavaBridge.getFrameSeq();

		JavaBridge.snapshot(bufferProvider(src, 4, 2));

		assertEquals("width published", 4, JavaBridge.getFrameWidth());
		assertEquals("height published", 2, JavaBridge.getFrameHeight());
		assertEquals("seq bumped exactly once", seqBefore + 1, JavaBridge.getFrameSeq());

		final int[] published = JavaBridge.getFramePixels();
		assertArrayEquals("published pixels equal the source", src, published);
		assertNotSame("published frame is a copy, not the live backing store", src, published);

		// Mutating the engine's live buffer after the snapshot must not change the already-published frame.
		Arrays.fill(src, 99);
		assertFalse("published copy is independent of the source array", Arrays.equals(src, published));
	}

	@Test
	public void snapshotIgnoresNullAndDegenerateBuffers()
	{
		final int seqBefore = JavaBridge.getFrameSeq();

		JavaBridge.snapshot(null);                                  // null provider
		JavaBridge.snapshot(bufferProvider(filled(8, 1), 0, 2));    // zero width
		JavaBridge.snapshot(bufferProvider(filled(8, 1), 4, 0));    // zero height
		JavaBridge.snapshot(bufferProvider(filled(3, 1), 4, 2));    // pixel array smaller than w*h

		assertEquals("no degenerate buffer may publish a frame", seqBefore, JavaBridge.getFrameSeq());
	}

	@Test
	public void consecutiveSnapshotsAlternateBuffersSoAPublishedFrameStaysStable()
	{
		final int[] src1 = filled(4 * 2, 1);
		JavaBridge.snapshot(bufferProvider(src1, 4, 2));
		final int[] pub1 = JavaBridge.getFramePixels();
		final int seq1 = JavaBridge.getFrameSeq();

		final int[] src2 = filled(4 * 2, 2);
		JavaBridge.snapshot(bufferProvider(src2, 4, 2));
		final int[] pub2 = JavaBridge.getFramePixels();
		final int seq2 = JavaBridge.getFrameSeq();

		assertNotSame("the two frames use different (alternating) buffers", pub1, pub2);
		assertTrue("seq advances each publish", seq2 > seq1);
		assertArrayEquals("the new frame holds the new pixels", filled(8, 2), pub2);
		// The crux: the frame an off-thread reader may still be copying (pub1) is NOT overwritten by pub2.
		assertArrayEquals("the previous frame is untouched by the next publish", filled(8, 1), pub1);
	}

	@Test
	public void sceneWarmupGatesPresentReady()
	{
		JavaBridge.armSceneHold();                       // reset the counter to 0
		assertFalse("not ready immediately after a hold re-arm", JavaBridge.presentReady());

		for (int i = 0; i < 5; i++)
		{
			JavaBridge.noteSceneDraw();
		}
		assertFalse("still warming up at 5 of 6 scene draws", JavaBridge.presentReady());

		JavaBridge.noteSceneDraw();                      // 6th == SCENE_WARMUP
		assertTrue("ready once SCENE_WARMUP scene draws have rendered", JavaBridge.presentReady());
	}

	@Test
	public void gpuPublishWithholdsFramesUntilWarmedUp()
	{
		JavaBridge.armSceneHold();                       // counter = 0: still in the load-in hold
		final int seqBefore = JavaBridge.getFrameSeq();

		JavaBridge.gpuFrameBackBuffer(4, 2);
		JavaBridge.gpuPublish(4, 2);
		assertEquals("a GPU frame during warmup must be held back (no seq bump)", seqBefore, JavaBridge.getFrameSeq());

		for (int i = 0; i < 6; i++)
		{
			JavaBridge.noteSceneDraw();                  // reach SCENE_WARMUP
		}
		JavaBridge.gpuFrameBackBuffer(4, 2);
		JavaBridge.gpuPublish(4, 2);
		assertEquals("once warmed up the GPU frame publishes", seqBefore + 1, JavaBridge.getFrameSeq());
	}

	// ---- helpers ---------------------------------------------------------------------------------------

	private static int[] filled(int n, int value)
	{
		final int[] a = new int[n];
		Arrays.fill(a, value);
		return a;
	}

	private static MainBufferProvider bufferProvider(int[] pixels, int w, int h)
	{
		final MainBufferProvider bp = mock(MainBufferProvider.class);
		when(bp.getPixels()).thenReturn(pixels);
		when(bp.getWidth()).thenReturn(w);
		when(bp.getHeight()).thenReturn(h);
		return bp;
	}
}
