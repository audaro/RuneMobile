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

import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.locks.LockSupport;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.Control;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.FloatControl;
import javax.sound.sampled.LineEvent;
import javax.sound.sampled.LineListener;
import javax.sound.sampled.LineUnavailableException;
import javax.sound.sampled.SourceDataLine;

/**
 * A {@link SourceDataLine} over a single-producer, single-consumer ring in a direct buffer, read by a
 * {@link HeadlessAudio.Sink}. The native half of the layout is {@code rm_audio_ring.h}:
 * <pre>
 *   0  int64 writePos   total bytes written; only this class stores it
 *   8  int64 readPos    total bytes consumed; the sink stores it, or this class while no sink is attached
 *  16  int64 flushPos   bytes before this are discarded; the reader skips them
 *  64  the samples
 * </pre>
 * The positions never wrap, and a byte lives at {@code DATA + pos % capacity}.
 *
 * <p>Only readPos frees bytes, because the reader stores it after it has copied them. A flush empties the line as
 * far as the engine can tell, but the reader may be partway through copying what it discards, so writes wait for it
 * to move past: one callback at most, and only for a write that needs those bytes.
 *
 * <p>The engine works out how far ahead it is from {@link #available} alone, so a line that isn't being read
 * must still drain or the engine stops mixing and everything it queued comes out at once later. While a started
 * line has no sink (the app is behind something, the output is muted, or it failed to start) this class
 * consumes the ring itself at the sample rate, and the samples go nowhere.
 */
final class HeadlessAudioLine implements SourceDataLine
{
	static final int WRITE_POS = 0;
	static final int READ_POS = 8;
	static final int FLUSH_POS = 16;
	static final int DATA = 64;

	/** The engine asks for 4 KiB frames and grows to 16; this fits a line opened without a size. */
	private static final int DEFAULT_BUFFER_BYTES = 16384;
	private static final long SINK_RETRY_NANOS = 2_000_000_000L;
	/** A write this far past when the ring should have had room has lost its reader. */
	private static final long WRITE_STALL_NANOS = 500_000_000L;
	private static final long WRITE_WAIT_NANOS = 2_000_000L;
	private static final float MIN_GAIN_DB = -80f;
	private static final float MAX_GAIN_DB = 6.0206f;

	private static final VarHandle POSITION =
		MethodHandles.byteBufferViewVarHandle(long[].class, ByteOrder.nativeOrder());

	private final DataLine.Info info;
	private final AudioFormat defaultFormat;
	private final List<LineListener> listeners = new CopyOnWriteArrayList<>();
	private final FloatControl gain = new FloatControl(FloatControl.Type.MASTER_GAIN, MIN_GAIN_DB, MAX_GAIN_DB,
		0.01f, 0, 0f, "dB")
	{
	};

	private AudioFormat format;
	private int capacity;
	private ByteBuffer ring;
	private ByteBuffer samples;
	private long writePos;
	private boolean open;
	private boolean started;

	private HeadlessAudio.Sink sink;
	private long sinkHandle;
	private long drainedToNanos;
	private long nextSinkTryNanos;
	private int peak;

	HeadlessAudioLine(DataLine.Info info, AudioFormat defaultFormat)
	{
		this.info = info;
		this.defaultFormat = defaultFormat;
	}

	@Override
	public void open() throws LineUnavailableException
	{
		open(defaultFormat, AudioSystem.NOT_SPECIFIED);
	}

	@Override
	public void open(AudioFormat audioFormat) throws LineUnavailableException
	{
		open(audioFormat, AudioSystem.NOT_SPECIFIED);
	}

	@Override
	public void open(AudioFormat audioFormat, int bufferSize) throws LineUnavailableException
	{
		if (!HeadlessMixerProvider.isPlayable(audioFormat))
		{
			throw new IllegalArgumentException("unsupported format: " + audioFormat);
		}
		synchronized (this)
		{
			if (open)
			{
				return;
			}
			// The engine derives its position as requested size minus available(), so a size we didn't honour
			// would read as a permanent backlog: use exactly what was asked for, on a whole frame.
			int frameSize = audioFormat.getFrameSize();
			int requested = bufferSize != AudioSystem.NOT_SPECIFIED ? bufferSize : requestedBufferSize();
			capacity = Math.max(frameSize, requested - requested % frameSize);
			ring = ByteBuffer.allocateDirect(DATA + capacity + Long.BYTES).alignedSlice(Long.BYTES);
			samples = ring.duplicate();
			samples.position(DATA);
			samples = samples.slice();
			format = audioFormat;
			writePos = 0;
			open = true;
		}
		HeadlessAudio.lineOpened(this);
		notifyListeners(LineEvent.Type.OPEN);
	}

	private int requestedBufferSize()
	{
		int max = info.getMaxBufferSize();
		return max != AudioSystem.NOT_SPECIFIED ? max : DEFAULT_BUFFER_BYTES;
	}

	@Override
	public void start()
	{
		synchronized (this)
		{
			if (!open || started)
			{
				return;
			}
			started = true;
			drainedToNanos = System.nanoTime();
			nextSinkTryNanos = drainedToNanos;
			service();
		}
		notifyListeners(LineEvent.Type.START);
	}

	@Override
	public void stop()
	{
		synchronized (this)
		{
			if (!started)
			{
				return;
			}
			started = false;
			detachSink();
		}
		notifyListeners(LineEvent.Type.STOP);
	}

	@Override
	public void close()
	{
		boolean wasStarted;
		synchronized (this)
		{
			if (!open)
			{
				return;
			}
			wasStarted = started;
			started = false;
			detachSink();
			open = false;
			ring = null;
			samples = null;
		}
		HeadlessAudio.lineClosed(this);
		if (wasStarted)
		{
			notifyListeners(LineEvent.Type.STOP);
		}
		notifyListeners(LineEvent.Type.CLOSE);
	}

	void outputChanged()
	{
		synchronized (this)
		{
			if (!started)
			{
				return;
			}
			if (!HeadlessAudio.outputEnabled())
			{
				detachSink();
			}
			else if (sinkHandle == 0)
			{
				nextSinkTryNanos = System.nanoTime();
				service();
			}
		}
	}

	private void detachSink()
	{
		if (sinkHandle != 0)
		{
			// Returns once the reader is gone, so the ring stays ours and time resumes from here.
			sink.close(sinkHandle);
			sinkHandle = 0;
			drainedToNanos = System.nanoTime();
		}
	}

	/** While a started line has no sink: passes the time, and tries for a sink. Holds the line's lock. */
	private void service()
	{
		if (!started || sinkHandle != 0)
		{
			return;
		}
		long now = System.nanoTime();
		int frameSize = format.getFrameSize();
		long frames = (long) ((now - drainedToNanos) / 1e9 * format.getSampleRate());
		if (frames > 0)
		{
			long read = Math.max(position(READ_POS), position(FLUSH_POS));
			setPosition(READ_POS, Math.min(writePos, read + frames * frameSize));
			drainedToNanos += (long) (frames * 1e9 / format.getSampleRate());
		}
		if (HeadlessAudio.outputEnabled() && now - nextSinkTryNanos >= 0)
		{
			nextSinkTryNanos = now + SINK_RETRY_NANOS;
			sink = HeadlessAudio.sink();
			sinkHandle = sink == null ? 0
				: sink.open(ring, capacity, Math.round(format.getSampleRate()), format.getChannels());
		}
	}

	@Override
	public int write(byte[] bytes, int offset, int length)
	{
		if (length % frameSizeOrOne() != 0)
		{
			throw new IllegalArgumentException("not a whole frame: " + length);
		}
		int written = 0;
		long waitedSince = 0;
		while (written < length)
		{
			int wrote;
			synchronized (this)
			{
				if (!open)
				{
					return written;
				}
				service();
				wrote = Math.min(length - written, writableBytes());
				if (wrote > 0)
				{
					copyIn(bytes, offset + written, wrote);
				}
				else if (!started)
				{
					return written; // the contract: a stopped line fills, then write gives back what fit
				}
			}
			if (wrote > 0)
			{
				written += wrote;
				waitedSince = 0;
				continue;
			}
			long now = System.nanoTime();
			if (waitedSince == 0)
			{
				waitedSince = now;
			}
			else if (now - waitedSince > WRITE_STALL_NANOS)
			{
				return written; // the output died under us; the engine reopens the line when it sees no progress
			}
			LockSupport.parkNanos(WRITE_WAIT_NANOS);
		}
		return written;
	}

	private int frameSizeOrOne()
	{
		synchronized (this)
		{
			return format != null ? format.getFrameSize() : 1;
		}
	}

	private void copyIn(byte[] bytes, int offset, int length)
	{
		byte[] source = bytes;
		int from = offset;
		float linear = gain.getValue() == 0f ? 1f : (float) Math.pow(10, gain.getValue() / 20);
		if (linear != 1f)
		{
			source = applyGain(bytes, offset, length, linear);
			from = 0;
		}
		peak = Math.max(peak, peakOf(source, from, length));
		int at = (int) (writePos % capacity);
		int first = Math.min(length, capacity - at);
		samples.position(at);
		samples.put(source, from, first);
		samples.position(0);
		samples.put(source, from + first, length - first);
		writePos += length;
		setPosition(WRITE_POS, writePos);
	}

	private static int peakOf(byte[] bytes, int offset, int length)
	{
		int peak = 0;
		for (int i = offset; i + 1 < offset + length; i += 2)
		{
			peak = Math.max(peak, Math.abs((short) ((bytes[i] & 0xff) | bytes[i + 1] << 8)));
		}
		return peak;
	}

	private static byte[] applyGain(byte[] bytes, int offset, int length, float linear)
	{
		byte[] out = new byte[length];
		for (int i = 0; i + 1 < length; i += 2)
		{
			int sample = (short) ((bytes[offset + i] & 0xff) | bytes[offset + i + 1] << 8);
			int scaled = Math.max(Short.MIN_VALUE, Math.min(Short.MAX_VALUE, Math.round(sample * linear)));
			out[i] = (byte) scaled;
			out[i + 1] = (byte) (scaled >> 8);
		}
		return out;
	}

	/** How empty the line is, as the engine should see it: a flush counts at once. */
	private int freeBytes()
	{
		return capacity - (int) (writePos - Math.max(position(READ_POS), position(FLUSH_POS)));
	}

	/** How much can be overwritten, which is only what the reader has finished with. */
	private int writableBytes()
	{
		return capacity - (int) (writePos - position(READ_POS));
	}

	private long position(int field)
	{
		return (long) POSITION.getAcquire(ring, field);
	}

	private void setPosition(int field, long value)
	{
		POSITION.setRelease(ring, field, value);
	}

	@Override
	public synchronized int available()
	{
		if (!open)
		{
			return 0;
		}
		service();
		HeadlessAudio.statsTick();
		return freeBytes();
	}

	@Override
	public synchronized void flush()
	{
		if (open)
		{
			setPosition(FLUSH_POS, writePos);
			if (sinkHandle == 0)
			{
				setPosition(READ_POS, writePos); // closing a sink ends its reads, so nothing can be mid-copy
			}
		}
	}

	@Override
	public void drain()
	{
		while (true)
		{
			synchronized (this)
			{
				if (!open || !started || freeBytes() == capacity)
				{
					return;
				}
				service();
			}
			LockSupport.parkNanos(WRITE_WAIT_NANOS);
		}
	}

	/**
	 * For the bug report: whether this line reaches an output, and the loudest sample since the last report. That
	 * tells "the game's own volumes are off" (a peak of 0) from "the output is broken" (sound, but no sink).
	 */
	synchronized String report()
	{
		if (!open)
		{
			return "closed";
		}
		int since = peak;
		peak = 0;
		return String.format("%.0f Hz %dch, %s, played %.1f s, peak %.3f", format.getSampleRate(),
			format.getChannels(), !started ? "stopped" : sinkHandle != 0 ? "playing" : "no output",
			getLongFramePosition() / format.getFrameRate(), since / 32768f);
	}

	@Override
	public synchronized boolean isOpen()
	{
		return open;
	}

	@Override
	public synchronized boolean isRunning()
	{
		return started;
	}

	@Override
	public synchronized boolean isActive()
	{
		return started;
	}

	@Override
	public synchronized AudioFormat getFormat()
	{
		return format != null ? format : defaultFormat;
	}

	@Override
	public synchronized int getBufferSize()
	{
		return open ? capacity : requestedBufferSize();
	}

	@Override
	public synchronized int getFramePosition()
	{
		return (int) getLongFramePosition();
	}

	@Override
	public synchronized long getLongFramePosition()
	{
		return open ? Math.max(position(READ_POS), position(FLUSH_POS)) / format.getFrameSize() : 0;
	}

	@Override
	public synchronized long getMicrosecondPosition()
	{
		return open ? (long) (getLongFramePosition() * 1e6 / format.getFrameRate()) : 0;
	}

	@Override
	public float getLevel()
	{
		return AudioSystem.NOT_SPECIFIED;
	}

	@Override
	public DataLine.Info getLineInfo()
	{
		return info;
	}

	@Override
	public Control[] getControls()
	{
		return new Control[]{gain};
	}

	@Override
	public boolean isControlSupported(Control.Type control)
	{
		return FloatControl.Type.MASTER_GAIN.equals(control);
	}

	@Override
	public Control getControl(Control.Type control)
	{
		if (isControlSupported(control))
		{
			return gain;
		}
		throw new IllegalArgumentException("unsupported control: " + control);
	}

	@Override
	public void addLineListener(LineListener listener)
	{
		listeners.add(listener);
	}

	@Override
	public void removeLineListener(LineListener listener)
	{
		listeners.remove(listener);
	}

	private void notifyListeners(LineEvent.Type type)
	{
		LineEvent event = new LineEvent(this, type, AudioSystem.NOT_SPECIFIED);
		for (LineListener listener : listeners)
		{
			listener.update(event);
		}
	}
}
