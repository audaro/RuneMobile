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

import java.io.ByteArrayInputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioInputStream;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.Clip;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.FloatControl;
import javax.sound.sampled.LineEvent;
import javax.sound.sampled.Mixer;
import javax.sound.sampled.SourceDataLine;
import org.junit.After;
import org.junit.Assert;
import org.junit.Before;
import org.junit.Test;

public class HeadlessAudioTest
{
	private static final AudioFormat ENGINE_FORMAT = new AudioFormat(22050f, 16, 2, true, false);

	/** Reads a ring the way the native callbacks do, on demand. */
	private static final class FakeSink implements HeadlessAudio.Sink
	{
		final List<Long> closed = new ArrayList<>();
		ByteBuffer ring;
		int capacity;
		int sampleRate;
		int opens;
		boolean refuse;
		long read;

		@Override
		public synchronized long open(ByteBuffer buffer, int size, int rate, int channels)
		{
			opens++;
			if (refuse)
			{
				return 0;
			}
			ring = buffer.duplicate().order(ByteOrder.nativeOrder());
			capacity = size;
			sampleRate = rate;
			read = ring.getLong(HeadlessAudioLine.READ_POS);
			return opens;
		}

		@Override
		public synchronized void close(long handle)
		{
			closed.add(handle);
			ring = null;
		}

		synchronized byte[] consume(int bytes)
		{
			if (ring == null)
			{
				return new byte[0];
			}
			read = Math.max(read, ring.getLong(HeadlessAudioLine.FLUSH_POS));
			int count = (int) Math.min(bytes, ring.getLong(HeadlessAudioLine.WRITE_POS) - read);
			byte[] out = new byte[count];
			for (int i = 0; i < count; i++)
			{
				out[i] = ring.get(HeadlessAudioLine.DATA + (int) ((read + i) % capacity));
			}
			read += count;
			ring.putLong(HeadlessAudioLine.READ_POS, read);
			return out;
		}
	}

	private FakeSink sink;

	@Before
	public void setUp()
	{
		sink = new FakeSink();
		HeadlessAudio.resetForTest(sink);
	}

	@After
	public void tearDown()
	{
		HeadlessAudio.resetForTest(null);
	}

	private static byte[] frames(int count, int seed)
	{
		byte[] bytes = new byte[count * 4];
		for (int i = 0; i < bytes.length; i++)
		{
			bytes[i] = (byte) (seed + i);
		}
		return bytes;
	}

	private SourceDataLine engineLine(int bytes) throws Exception
	{
		// Exactly what the engine does: the format and size in the Info, then the no-argument open.
		DataLine.Info info = new DataLine.Info(SourceDataLine.class, ENGINE_FORMAT, bytes);
		SourceDataLine line = (SourceDataLine) new HeadlessMixerProvider().getMixer(null).getLine(info);
		line.open();
		line.start();
		return line;
	}

	@Test
	public void providerOffersNothingWithoutASink()
	{
		HeadlessAudio.resetForTest(null);
		Assert.assertEquals(0, new HeadlessMixerProvider().getMixerInfo().length);
	}

	@Test
	public void audioSystemFindsTheLineTheEngineAsksFor() throws Exception
	{
		DataLine.Info info = new DataLine.Info(SourceDataLine.class, ENGINE_FORMAT, 16384);
		Mixer.Info[] mixers = new HeadlessMixerProvider().getMixerInfo();
		Assert.assertEquals(1, mixers.length);
		Assert.assertTrue(AudioSystem.getLine(info) instanceof HeadlessAudioLine);
	}

	@Test
	public void lineHonoursTheRequestedSizeOrTheEnginesPositionDrifts() throws Exception
	{
		SourceDataLine line = engineLine(16384);
		Assert.assertEquals(16384, line.getBufferSize());
		Assert.assertEquals(16384, line.available());
		Assert.assertEquals(22050, sink.sampleRate);
		line.write(frames(256, 1), 0, 1024);
		Assert.assertEquals(16384 - 1024, line.available());
		line.close();
	}

	@Test
	public void samplesSurviveTheRingWrapping() throws Exception
	{
		SourceDataLine line = engineLine(1024);
		line.write(frames(200, 3), 0, 800);
		Assert.assertEquals(800, sink.consume(800).length);
		byte[] wrapped = frames(100, 9); // 400 bytes from offset 800 of a 1024-byte ring
		line.write(wrapped, 0, 400);
		Assert.assertArrayEquals(wrapped, sink.consume(400));
		Assert.assertEquals(1024, line.available());
		line.close();
	}

	@Test
	public void flushDropsWhatIsQueued() throws Exception
	{
		SourceDataLine line = engineLine(4096);
		line.write(frames(256, 1), 0, 1024);
		line.flush();
		Assert.assertEquals(4096, line.available());
		Assert.assertEquals(0, sink.consume(1024).length);
		line.close();
	}

	@Test(timeout = 5000)
	public void flushLeavesWhatTheReaderMayBeCopyingAlone() throws Exception
	{
		// The reader takes its positions, then copies. A flush can land between the two, so until it stores readPos
		// again the bytes it started on aren't free, whatever the line reports to the engine.
		SourceDataLine line = engineLine(1024);
		byte[] queued = frames(256, 5);
		line.write(queued, 0, 1024);
		line.flush();
		Assert.assertEquals("the engine sees an empty line", 1024, line.available());

		Assert.assertEquals("nothing may be overwritten yet", 0, line.write(frames(256, 90), 0, 1024));
		for (int i = 0; i < queued.length; i++)
		{
			Assert.assertEquals(queued[i], sink.ring.get(HeadlessAudioLine.DATA + i));
		}

		Assert.assertEquals("the reader skips what was flushed", 0, sink.consume(4096).length);
		byte[] fresh = frames(256, 90);
		Assert.assertEquals(1024, line.write(fresh, 0, 1024));
		Assert.assertArrayEquals(fresh, sink.consume(4096));
		line.close();
	}

	@Test
	public void flushWithNoReaderFreesTheLineAtOnce() throws Exception
	{
		SourceDataLine line = engineLine(1024);
		line.stop(); // the output is closed by the time stop returns, so nothing can be mid-copy
		Assert.assertEquals(1024, line.write(frames(256, 1), 0, 2048));
		line.flush();
		Assert.assertEquals(1024, line.available());
		Assert.assertEquals(1024, line.write(frames(256, 2), 0, 2048));
		line.close();
	}

	@Test
	public void aFullLineWithADeadOutputStopsBlockingTheEngine() throws Exception
	{
		SourceDataLine line = engineLine(1024);
		long started = System.nanoTime();
		int wrote = line.write(frames(512, 1), 0, 2048);
		Assert.assertEquals(1024, wrote);
		Assert.assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 3000);
		line.close();
	}

	@Test
	public void writesToAStoppedLineReturnWhatFit() throws Exception
	{
		SourceDataLine line = engineLine(1024);
		line.stop();
		Assert.assertEquals(1024, line.write(frames(512, 1), 0, 2048));
		line.close();
	}

	@Test(timeout = 5000)
	public void aLineWithNoOutputKeepsTime() throws Exception
	{
		sink.refuse = true;
		SourceDataLine line = engineLine(4096);
		line.write(frames(1024, 1), 0, 4096);
		// 4096 bytes is 93 ms at 22050 Hz stereo: the engine's clock has to carry on with nobody reading.
		while (line.available() < 4096)
		{
			Thread.sleep(5);
		}
		line.close();
	}

	@Test(timeout = 5000)
	public void outputFollowsForegroundAndMute() throws Exception
	{
		SourceDataLine line = engineLine(4096);
		Assert.assertEquals(1, sink.opens);

		HeadlessAudio.setForeground(false);
		waitFor(() -> sink.closed.size() == 1);
		HeadlessAudio.setMuted(true);
		HeadlessAudio.setForeground(true);
		Thread.sleep(50);
		Assert.assertEquals("still muted", 1, sink.opens);

		HeadlessAudio.setMuted(false);
		waitFor(() -> sink.opens == 2);
		line.close();
	}

	@Test
	public void gainScalesSamples() throws Exception
	{
		SourceDataLine line = engineLine(1024);
		((FloatControl) line.getControl(FloatControl.Type.MASTER_GAIN)).setValue(-6.0206f);
		ByteBuffer pcm = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putShort((short) 20000)
			.putShort((short) -20000);
		line.write(pcm.array(), 0, 4);
		ByteBuffer out = ByteBuffer.wrap(sink.consume(4)).order(ByteOrder.LITTLE_ENDIAN);
		Assert.assertEquals(10000, out.getShort(), 2);
		Assert.assertEquals(-10000, out.getShort(), 2);
		line.close();
	}

	@Test
	public void reportTellsSilenceFromAMissingOutput() throws Exception
	{
		SourceDataLine line = engineLine(1024);
		line.write(new byte[64], 0, 64);
		assertReportContains("playing");
		line.stop();
		assertReportContains("stopped");
		sink.refuse = true;
		line.start();
		assertReportContains("no output");
		line.close();
	}

	@Test
	public void audioSystemGetClipOpensAndConvertsAWav() throws Exception
	{
		byte[] bigEndian = new byte[]{0x40, 0, 0x40, 0, 0x40, 0, 0x40, 0};
		AudioFormat format = new AudioFormat(44100f, 16, 2, true, true);
		Clip clip = AudioSystem.getClip();
		Assert.assertTrue(clip instanceof HeadlessAudioClip);
		clip.open(new AudioInputStream(new ByteArrayInputStream(bigEndian), format, 2));
		Assert.assertEquals(2, clip.getFrameLength());
		Assert.assertFalse(clip.getFormat().isBigEndian());
		clip.close();
	}

	@Test(timeout = 5000)
	public void clipPlaysToTheEndThenReportsStop() throws Exception
	{
		HeadlessAudioClip clip = new HeadlessAudioClip(new DataLine.Info(Clip.class, ENGINE_FORMAT));
		clip.open(ENGINE_FORMAT, frames(64, 1), 0, 256);
		CountDownLatch stopped = new CountDownLatch(1);
		clip.addLineListener(event ->
		{
			if (event.getType() == LineEvent.Type.STOP)
			{
				stopped.countDown();
			}
		});
		clip.start();
		waitFor(() -> sink.ring != null);
		waitFor(() -> sink.consume(4096).length == 0 && clip.getFramePosition() == 64);
		Assert.assertTrue(stopped.await(3, TimeUnit.SECONDS));
		Assert.assertFalse(clip.isRunning());
		clip.close();
	}

	@Test(timeout = 5000)
	public void aSoundingClipClosesFromItsOwnStopEvent() throws Exception
	{
		// AudioPlayer keeps its last clip open and closes the one before it from this listener.
		HeadlessAudioClip clip = new HeadlessAudioClip(new DataLine.Info(Clip.class, ENGINE_FORMAT));
		clip.open(ENGINE_FORMAT, frames(16, 1), 0, 64);
		CountDownLatch closed = new CountDownLatch(1);
		clip.addLineListener(event ->
		{
			if (event.getType() == LineEvent.Type.STOP)
			{
				clip.close();
			}
			else if (event.getType() == LineEvent.Type.CLOSE)
			{
				closed.countDown();
			}
		});
		clip.start();
		waitFor(() -> sink.ring != null);
		while (closed.getCount() > 0)
		{
			if (sink.ring != null)
			{
				sink.consume(4096);
			}
			Thread.sleep(2);
		}
	}

	@Test(timeout = 5000)
	public void clipLoopsThenPlaysOut() throws Exception
	{
		HeadlessAudioClip clip = new HeadlessAudioClip(new DataLine.Info(Clip.class, ENGINE_FORMAT));
		clip.open(ENGINE_FORMAT, frames(8, 1), 0, 32);
		clip.loop(2);
		waitFor(() -> sink.ring != null);
		int total = 0;
		while (clip.isRunning())
		{
			FakeSink live = sink;
			if (live.ring != null)
			{
				total += live.consume(4096).length;
			}
			Thread.sleep(1);
		}
		Assert.assertEquals("3 passes", 96, total);
		clip.close();
	}

	@Test(timeout = 5000)
	public void anEmptyClipSetToLoopForeverEnds() throws Exception
	{
		HeadlessAudioClip clip = new HeadlessAudioClip(new DataLine.Info(Clip.class, ENGINE_FORMAT));
		clip.open(ENGINE_FORMAT, new byte[0], 0, 0);
		clip.loop(Clip.LOOP_CONTINUOUSLY);
		waitFor(() -> !clip.isRunning());
		clip.close();
	}

	@Test(timeout = 10000)
	public void stoppingStraightAwayLeavesNoOutputBehind() throws Exception
	{
		HeadlessAudioClip clip = new HeadlessAudioClip(new DataLine.Info(Clip.class, ENGINE_FORMAT));
		clip.open(ENGINE_FORMAT, frames(4096, 1), 0, 16384);
		for (int i = 0; i < 200; i++)
		{
			clip.start();
			clip.stop();
		}
		clip.close();
		waitFor(() ->
		{
			synchronized (sink)
			{
				return sink.ring == null;
			}
		});
		Thread.sleep(50);
		synchronized (sink)
		{
			Assert.assertNull("a late start reopened the output", sink.ring);
		}
	}

	@Test
	public void reportShowsTheLoudestSampleOnce() throws Exception
	{
		SourceDataLine line = engineLine(1024);
		ByteBuffer pcm = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putShort((short) 16384)
			.putShort((short) -32768);
		line.write(pcm.array(), 0, 4);
		assertReportContains("peak 1.000");
		assertReportContains("peak 0.000");
		line.close();
	}

	private static void assertReportContains(String text)
	{
		String report = HeadlessAudio.report();
		Assert.assertTrue(report, report.contains(text));
	}

	private interface Condition
	{
		boolean holds() throws Exception;
	}

	private static void waitFor(Condition condition) throws Exception
	{
		while (!condition.holds())
		{
			Thread.sleep(2);
		}
	}
}
