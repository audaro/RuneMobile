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

import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import lombok.extern.slf4j.Slf4j;

/**
 * Stands in for a port's output: {@code -Drunelite.audio.capture=<file>} consumes each line's ring at the sample
 * rate, as the real stream would, and keeps what it read as a WAV. It lets a desktop run prove the engine really
 * renders audio through {@link HeadlessAudioLine}, by measuring the samples instead of listening to them. A file
 * holds one line's stream; a later line starts it over.
 */
@Slf4j
final class HeadlessAudioCapture implements HeadlessAudio.Sink
{
	private static final int WAV_HEADER = 44;
	private static final long PERIOD_MS = 10;

	private final String path;
	private long nextHandle = 1;
	private volatile long activeHandle;

	HeadlessAudioCapture(String path)
	{
		this.path = path;
	}

	@Override
	public synchronized long open(ByteBuffer ring, int capacity, int sampleRate, int channels)
	{
		long handle = nextHandle++;
		activeHandle = handle;
		Thread reader = new Thread(() -> run(handle, ring, capacity, sampleRate, channels), "audio-capture");
		reader.setDaemon(true);
		reader.start();
		log.info("[audio-capture] line open: {} Hz, {} channels, {} byte ring", sampleRate, channels, capacity);
		return handle;
	}

	@Override
	public void close(long handle)
	{
		if (activeHandle == handle)
		{
			activeHandle = 0;
		}
	}

	private void run(long handle, ByteBuffer ring, int capacity, int sampleRate, int channels)
	{
		ByteBuffer positions = ring.duplicate().order(ByteOrder.nativeOrder());
		int bytesPerSecond = sampleRate * channels * 2;
		long read = positions.getLong(HeadlessAudioLine.READ_POS);
		long lastTick = System.nanoTime();
		try (RandomAccessFile out = new RandomAccessFile(path, "rw"))
		{
			out.setLength(0);
			out.write(new byte[WAV_HEADER]);
			long total = 0;
			byte[] chunk = new byte[capacity];
			while (activeHandle == handle)
			{
				Thread.sleep(PERIOD_MS);
				long now = System.nanoTime();
				int budget = (int) ((now - lastTick) / 1e9 * bytesPerSecond) & -(channels * 2);
				lastTick += (long) (budget * 1e9 / bytesPerSecond);
				read = Math.max(read, positions.getLong(HeadlessAudioLine.FLUSH_POS));
				int length = (int) Math.min(budget, positions.getLong(HeadlessAudioLine.WRITE_POS) - read);
				for (int i = 0; i < length; i++)
				{
					chunk[i] = ring.get(HeadlessAudioLine.DATA + (int) ((read + i) % capacity));
				}
				out.write(chunk, 0, length);
				total += length;
				read += length;
				positions.putLong(HeadlessAudioLine.READ_POS, read);
				writeHeader(out, total, sampleRate, channels);
			}
		}
		catch (IOException | InterruptedException e)
		{
			log.warn("[audio-capture] stopped: {}", e.toString());
		}
	}

	private static void writeHeader(RandomAccessFile out, long dataBytes, int sampleRate, int channels)
		throws IOException
	{
		ByteBuffer header = ByteBuffer.allocate(WAV_HEADER).order(ByteOrder.LITTLE_ENDIAN);
		header.put("RIFF".getBytes(StandardCharsets.US_ASCII)).putInt((int) dataBytes + WAV_HEADER - 8);
		header.put("WAVEfmt ".getBytes(StandardCharsets.US_ASCII)).putInt(16);
		header.putShort((short) 1).putShort((short) channels).putInt(sampleRate);
		header.putInt(sampleRate * channels * 2).putShort((short) (channels * 2)).putShort((short) 16);
		header.put("data".getBytes(StandardCharsets.US_ASCII)).putInt((int) dataBytes);
		long end = out.getFilePointer();
		out.seek(0);
		out.write(header.array());
		out.seek(end);
	}
}
