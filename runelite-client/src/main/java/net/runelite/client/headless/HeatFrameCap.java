/*
 * Copyright (c) 2026, Jordan Simpson
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that
 * the conditions of the BSD 2-clause license are met (see the project headers).
 */
package net.runelite.client.headless;

import java.util.concurrent.locks.LockSupport;

/**
 * A frame-rate limit the app sets while the phone is hot or saving power, on top of any Frame-rate cap the player
 * chose. It holds each frame back after the frame is drawn, where FPS Control's limiter does, so the engine keeps
 * running its game cycles and audio, and on every renderer: all three end their frames in
 * {@code DrawManager.processDrawComplete}.
 * <p>
 * It is not FPS Control's setting because that is saved to the player's profile: a session that died hot would
 * leave the phone's limit behind as the player's own, and the profile syncs to their other machines. This one lives
 * in memory and dies with the session.
 */
final class HeatFrameCap implements Runnable
{
	private static final long SECOND_NS = 1_000_000_000L;

	private volatile int fps;

	// Only the drawing thread touches these.
	private boolean pacing;
	private long nextFrameNs;

	/** The limit in frames per second. 0 or less lifts it. */
	void setFps(int fps)
	{
		this.fps = Math.max(0, fps);
	}

	@Override
	public void run()
	{
		final long wait = waitNs(System.nanoTime());
		if (wait > 0)
		{
			LockSupport.parkNanos(wait);
		}
	}

	/**
	 * How long to hold back a frame that finished at {@code now}. A frame that ran a little late takes the time back
	 * from the next, so the average stays on the limit; one a whole frame late starts the count again, so a stall
	 * isn't followed by a burst of frames running unlimited.
	 */
	long waitNs(long now)
	{
		final int limit = fps;
		if (limit <= 0)
		{
			pacing = false;
			return 0;
		}
		final long frameNs = SECOND_NS / limit;
		if (!pacing || now - nextFrameNs >= frameNs)
		{
			pacing = true;
			nextFrameNs = now + frameNs;
			return 0;
		}
		final long wait = nextFrameNs - now;
		nextFrameNs += frameNs;
		return Math.max(0, wait);
	}
}
