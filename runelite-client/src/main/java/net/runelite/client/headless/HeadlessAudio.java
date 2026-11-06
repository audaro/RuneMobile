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

import java.nio.ByteBuffer;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import lombok.extern.slf4j.Slf4j;

/**
 * Game audio on the phones. The engine renders music, sound effects and area sounds itself and writes one
 * 16-bit PCM stream to a {@link javax.sound.sampled.SourceDataLine}. Neither port has a Java Sound device to
 * take it: the Android JRE ships no libjsound, and the iOS one reports no output line, so the engine's sound
 * init used to fail and it ran silent.
 *
 * <p>{@link HeadlessMixerProvider} supplies those lines instead. Each started line owns a ring in a direct
 * buffer (see {@link HeadlessAudioLine}) that a {@link Sink} reads from: the port's own output stream, reached
 * through {@link #nOpen}, whose real-time callback only ever copies from that memory, so it never enters the VM.
 * The system mixes the streams and converts their rate.
 *
 * <p>Where no port registered the natives (desktop), there is no sink and the provider offers no mixers, so
 * RuneLite keeps using the machine's real audio devices.
 *
 * <p>Threads: lines are driven by the engine's sound thread; {@link #setForeground} and {@link #setMuted} come
 * from the hosts' UI threads and return at once. Each line guards itself, so the switches only walk the open lines.
 */
@Slf4j
public final class HeadlessAudio
{
	/** Reads a line's ring while the line is started. */
	interface Sink
	{
		/** @return a handle for {@link #close}, or 0 if the output can't start right now (it is retried). */
		long open(ByteBuffer ring, int capacity, int sampleRate, int channels);

		void close(long handle);
	}

	private static final Sink NATIVE = new Sink()
	{
		@Override
		public long open(ByteBuffer ring, int capacity, int sampleRate, int channels)
		{
			return nOpen(ring, capacity, sampleRate, channels);
		}

		@Override
		public void close(long handle)
		{
			nClose(handle);
		}
	};

	private static final Set<HeadlessAudioLine> LINES = ConcurrentHashMap.newKeySet();
	/** Starting and stopping outputs can take a moment, and the switches come from the hosts' UI threads. */
	private static final ExecutorService SWITCHES = Executors.newSingleThreadExecutor(task ->
	{
		Thread thread = new Thread(task, "audio-switches");
		thread.setDaemon(true);
		return thread;
	});
	private static final boolean STATS = Boolean.getBoolean("runelite.audio.stats");
	private static final long STATS_PERIOD_NANOS = 5_000_000_000L;
	private static long lastStatsNanos = System.nanoTime();
	private static volatile boolean foreground = true;
	private static volatile boolean muted = Boolean.getBoolean("runelite.audio.muted");
	private static volatile Sink sink;
	private static boolean sinkResolved;

	private HeadlessAudio()
	{
	}

	/**
	 * Starts the port's output for a line's ring. The layout is in {@link HeadlessAudioLine}, and
	 * {@code rm_audio_ring.h} is its native half. Registered by each host with RegisterNatives.
	 */
	private static native long nOpen(ByteBuffer ring, int capacity, int sampleRate, int channels);

	/** Stops the output and returns only once its callback can no longer touch the ring. 0 is a no-op. */
	private static native void nClose(long handle);

	/** The app came to the front or went behind something. Game audio doesn't play from the background. */
	public static void setForeground(boolean inForeground)
	{
		foreground = inForeground;
		SWITCHES.execute(HeadlessAudio::outputChanged);
	}

	/** The player's master switch for game audio, kept by the host. */
	public static void setMuted(boolean isMuted)
	{
		muted = isMuted;
		SWITCHES.execute(HeadlessAudio::outputChanged);
	}

	static boolean outputEnabled()
	{
		return foreground && !muted;
	}

	private static void outputChanged()
	{
		log.debug("[audio] output {} ({} line(s))", outputEnabled() ? "on" : "off", LINES.size());
		for (HeadlessAudioLine line : LINES)
		{
			line.outputChanged();
		}
	}

	static void lineOpened(HeadlessAudioLine line)
	{
		LINES.add(line);
	}

	static void lineClosed(HeadlessAudioLine line)
	{
		LINES.remove(line);
	}

	/** One line for the bug report, and for {@code -Drunelite.audio.stats=true}. */
	static String report()
	{
		if (sink() == null)
		{
			return "no output";
		}
		StringBuilder report = new StringBuilder(foreground ? "foreground" : "background")
			.append(muted ? ", muted" : "");
		for (HeadlessAudioLine line : LINES)
		{
			report.append(" | ").append(line.report());
		}
		return report.toString();
	}

	/** Called on the sound thread, which ticks while anything is open. */
	static void statsTick()
	{
		if (STATS && System.nanoTime() - lastStatsNanos > STATS_PERIOD_NANOS)
		{
			lastStatsNanos = System.nanoTime();
			log.info("[audio] {}", report());
		}
	}

	/** Where lines write, or null where this device has no output of ours. */
	static synchronized Sink sink()
	{
		if (!sinkResolved)
		{
			sinkResolved = true;
			sink = resolveSink();
		}
		return sink;
	}

	private static Sink resolveSink()
	{
		String capture = System.getProperty("runelite.audio.capture");
		if (capture != null)
		{
			return new HeadlessAudioCapture(capture);
		}
		try
		{
			nClose(0L); // does nothing, but throws until a host has registered the natives
			return NATIVE;
		}
		catch (UnsatisfiedLinkError e)
		{
			return null;
		}
	}

	/** Tests: forces the sink, and clears what the last test left. */
	static synchronized void resetForTest(Sink testSink)
	{
		sink = testSink;
		sinkResolved = true;
		foreground = true;
		muted = false;
		LINES.clear();
	}
}
