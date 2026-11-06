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
import java.io.IOException;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import javax.sound.sampled.AudioFormat;
import javax.sound.sampled.AudioInputStream;
import javax.sound.sampled.AudioSystem;
import javax.sound.sampled.Clip;
import javax.sound.sampled.Control;
import javax.sound.sampled.DataLine;
import javax.sound.sampled.LineEvent;
import javax.sound.sampled.LineListener;
import javax.sound.sampled.LineUnavailableException;

/**
 * A {@link Clip} played through a {@link HeadlessAudioLine} by a thread of its own, for
 * {@link net.runelite.client.audio.AudioPlayer} and the plugins that bring their own sounds. Each playing clip is one
 * more output, and the system mixes it with the game's.
 */
final class HeadlessAudioClip implements Clip
{
	private static final int CHUNK_FRAMES = 1024;
	private static final int BUFFER_FRAMES = 4096;

	private final DataLine.Info info;
	private final HeadlessAudioLine line;
	private final List<LineListener> listeners = new CopyOnWriteArrayList<>();

	private AudioFormat format;
	private byte[] data;
	private int frames;
	private int position;
	private int loopStart;
	private int loopEnd = -1;
	private int loopsLeft;
	private boolean open;
	private boolean running;
	/** Each start bumps this, so a pump thread left over from before a stop can tell it's finished. */
	private long playback;
	private Thread lastPump;

	HeadlessAudioClip(DataLine.Info info)
	{
		this.info = info;
		line = new HeadlessAudioLine(info, new AudioFormat(22050f, 16, 2, true, false));
	}

	@Override
	public void open(AudioInputStream stream) throws LineUnavailableException, IOException
	{
		AudioFormat source = stream.getFormat();
		AudioFormat target = source;
		if (!HeadlessMixerProvider.isPlayable(source))
		{
			target = new AudioFormat(source.getSampleRate(), 16, Math.min(source.getChannels(), 2), true, false);
		}
		try (AudioInputStream playable = target == source ? stream : AudioSystem.getAudioInputStream(target, stream))
		{
			openPcm(target, playable.readAllBytes());
		}
	}

	@Override
	public void open(AudioFormat audioFormat, byte[] bytes, int offset, int length) throws LineUnavailableException
	{
		try
		{
			open(new AudioInputStream(new ByteArrayInputStream(bytes, offset, length), audioFormat,
				length / audioFormat.getFrameSize()));
		}
		catch (IOException e)
		{
			throw new IllegalArgumentException(e); // reading memory
		}
	}

	private void openPcm(AudioFormat audioFormat, byte[] bytes) throws LineUnavailableException
	{
		synchronized (this)
		{
			if (open)
			{
				throw new IllegalStateException("already open");
			}
			int frameSize = audioFormat.getFrameSize();
			line.open(audioFormat, BUFFER_FRAMES * frameSize);
			format = audioFormat;
			data = bytes;
			frames = bytes.length / frameSize;
			position = 0;
			loopStart = 0;
			loopEnd = -1;
			loopsLeft = 0;
			open = true;
		}
		notifyListeners(LineEvent.Type.OPEN);
	}

	@Override
	public void start()
	{
		play(0);
	}

	@Override
	public void loop(int count)
	{
		play(count);
	}

	private void play(int loops)
	{
		synchronized (this)
		{
			if (!open || running)
			{
				return;
			}
			running = true;
			loopsLeft = loops;
			long current = ++playback;
			Thread previous = lastPump;
			lastPump = new Thread(() -> pump(current, previous), "audio-clip");
			lastPump.setDaemon(true);
			lastPump.start();
		}
		notifyListeners(LineEvent.Type.START);
	}

	/** One pump at a time: a stopped one can still be on its way out, and it stops the line as it goes. */
	private void pump(long mine, Thread previous)
	{
		try
		{
			if (previous != null)
			{
				previous.join();
			}
		}
		catch (InterruptedException e)
		{
			Thread.currentThread().interrupt();
			return;
		}
		line.start();
		synchronized (this)
		{
			if (playback != mine)
			{
				// Stopped or closed before the line was up, and stop() found nothing to stop yet.
				line.stop();
				return;
			}
		}
		while (true)
		{
			int from;
			int count;
			synchronized (this)
			{
				if (playback != mine)
				{
					return;
				}
				int end = loopsLeft != 0 ? lastLoopFrame() + 1 : frames;
				if (position >= end)
				{
					if (loopsLeft == 0 || frames == 0)
					{
						break;
					}
					loopsLeft -= loopsLeft > 0 ? 1 : 0; // LOOP_CONTINUOUSLY is negative, and stays
					position = loopStart;
					continue;
				}
				from = position;
				count = Math.min(CHUNK_FRAMES, end - position);
				position += count;
			}
			line.write(data, from * format.getFrameSize(), count * format.getFrameSize());
		}
		line.drain();
		synchronized (this)
		{
			if (playback != mine)
			{
				return;
			}
			running = false;
		}
		line.stop();
		notifyListeners(LineEvent.Type.STOP);
	}

	private int lastLoopFrame()
	{
		return loopEnd < 0 ? frames - 1 : Math.min(loopEnd, frames - 1);
	}

	@Override
	public void stop()
	{
		synchronized (this)
		{
			if (!running)
			{
				return;
			}
			running = false;
			playback++;
		}
		line.stop();
		line.flush();
		notifyListeners(LineEvent.Type.STOP);
	}

	@Override
	public void close()
	{
		stop();
		synchronized (this)
		{
			if (!open)
			{
				return;
			}
			open = false;
			data = null;
		}
		line.close();
		notifyListeners(LineEvent.Type.CLOSE);
	}

	@Override
	public synchronized void setFramePosition(int frame)
	{
		position = Math.max(0, Math.min(frame, frames));
	}

	@Override
	public void setMicrosecondPosition(long microseconds)
	{
		setFramePosition((int) (microseconds * getFormat().getFrameRate() / 1e6));
	}

	@Override
	public synchronized void setLoopPoints(int start, int end)
	{
		if (start < 0 || start >= frames || end >= frames || (end != -1 && end < start))
		{
			throw new IllegalArgumentException("bad loop points: " + start + ", " + end);
		}
		loopStart = start;
		loopEnd = end;
	}

	@Override
	public synchronized int getFrameLength()
	{
		return open ? frames : AudioSystem.NOT_SPECIFIED;
	}

	@Override
	public synchronized long getMicrosecondLength()
	{
		return open ? (long) (frames * 1e6 / format.getFrameRate()) : AudioSystem.NOT_SPECIFIED;
	}

	@Override
	public synchronized int getFramePosition()
	{
		return position;
	}

	@Override
	public synchronized long getLongFramePosition()
	{
		return position;
	}

	@Override
	public synchronized long getMicrosecondPosition()
	{
		return open ? (long) (position * 1e6 / format.getFrameRate()) : 0;
	}

	@Override
	public void drain()
	{
		line.drain();
	}

	@Override
	public void flush()
	{
		line.flush();
	}

	@Override
	public int available()
	{
		return 0; // a clip is written once, at open
	}

	@Override
	public synchronized int getBufferSize()
	{
		return open ? data.length : AudioSystem.NOT_SPECIFIED;
	}

	@Override
	public synchronized AudioFormat getFormat()
	{
		return format != null ? format : line.getFormat();
	}

	@Override
	public float getLevel()
	{
		return AudioSystem.NOT_SPECIFIED;
	}

	@Override
	public synchronized boolean isRunning()
	{
		return running;
	}

	@Override
	public synchronized boolean isActive()
	{
		return running;
	}

	@Override
	public synchronized boolean isOpen()
	{
		return open;
	}

	@Override
	public void open()
	{
		throw new IllegalArgumentException("a clip opens with its audio");
	}

	@Override
	public DataLine.Info getLineInfo()
	{
		return info;
	}

	@Override
	public Control[] getControls()
	{
		return line.getControls();
	}

	@Override
	public boolean isControlSupported(Control.Type control)
	{
		return line.isControlSupported(control);
	}

	@Override
	public Control getControl(Control.Type control)
	{
		return line.getControl(control);
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
