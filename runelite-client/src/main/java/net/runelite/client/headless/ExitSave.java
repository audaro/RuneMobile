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

import java.time.Duration;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import lombok.extern.slf4j.Slf4j;
import net.runelite.client.config.ConfigManager;
import net.runelite.client.eventbus.EventBus;
import net.runelite.client.events.ClientShutdown;

/**
 * What the desktop client does when its window closes, for a phone that is about to end the process.
 *
 * <p>Desktop {@code ClientUI.shutdownClient} posts {@code ClientShutdown} and waits up to 10 s for the tasks its
 * subscribers hand to {@code waitFor}. Plugins that keep data in memory save it there: Flipping Utilities' trades,
 * the XP Tracker's session, Loot Tracker's pending submission, and {@code ConfigManager} itself (priority -100, so
 * after the others). Neither port has that window, so before this every mobile exit dropped that data.
 *
 * <p>{@link #run} blocks its caller for {@code timeoutMs} plus {@link #FLUSH_GRACE_MS} at most. The post runs on
 * its own daemon thread, so a subscriber that hangs costs the wait and never the exit; config is then saved from
 * another daemon thread. Neither save runs on the caller's thread, because {@code sendConfig} can wait without limit:
 * a synced profile with a RuneLite account sends its changes with {@code configClient.patch(..).get()} before it
 * writes them to disk. The event goes out once per process: a second call (say, a logout path followed by another
 * exit) only saves config again.
 */
@Slf4j
final class ExitSave implements Runnable
{
	/** The desktop client's own limit for {@code ClientShutdown} consumers. */
	static final long MAX_WAIT_MS = 10_000;
	/** Extra time for the config save once the wait runs out, whichever thread is doing it. */
	static final long FLUSH_GRACE_MS = 1_000;
	private static final long RETRY_MS = 50;

	static final int POSTING = 0;
	static final int WAITING = 1;
	static final int FLUSHING = 2;
	static final int DONE = 3;

	private static final AtomicBoolean shutdownPosted = new AtomicBoolean();

	private final EventBus bus;        // null: ClientShutdown already went out on an earlier call
	private final ConfigManager cm;
	private final long deadline;       // System.nanoTime()
	private volatile int phase = POSTING;
	private volatile boolean flushed;
	// Exactly one side saves config: the worker once it gets past the event, or the caller when the wait runs out
	// first. Two saves at once would meet on the profile lock, and the loser's save would be lost.
	private final AtomicBoolean flushClaimed = new AtomicBoolean();

	private ExitSave(EventBus bus, ConfigManager cm, long deadline)
	{
		this.bus = bus;
		this.cm = cm;
		this.deadline = deadline;
	}

	/**
	 * Post {@code ClientShutdown} (first call only), wait for its subscribers and their tasks, then save config.
	 *
	 * @return JSON for the native log: {@code posted} (this call sent the event), {@code finished} (the worker
	 *     completed within the wait), {@code flushed} (a config save succeeded), {@code fallback} (the caller had
	 *     to save config itself) and {@code ms}
	 */
	static String run(EventBus bus, ConfigManager cm, int timeoutMs)
	{
		final long start = System.nanoTime();
		final long waitMs = Math.max(0, Math.min(timeoutMs, MAX_WAIT_MS));
		final long deadline = start + TimeUnit.MILLISECONDS.toNanos(waitMs);
		final boolean post = shutdownPosted.compareAndSet(false, true);
		final ExitSave save = new ExitSave(post ? bus : null, cm, deadline);
		final Thread t = new Thread(save, "RuneMobile Shutdown");
		t.setDaemon(true);
		t.start();

		boolean finished = join(t, deadline - System.nanoTime());
		boolean fallback = false;
		if (!finished)
		{
			if (save.flushClaimed.compareAndSet(false, true))
			{
				// Stuck in a subscriber or still waiting on a task one handed to waitFor: save config now. The worker
				// won't save after this. (ConfigManager's own subscriber could, if a hung one ahead of it came free in
				// this instant; one of the two saves would then fail on the lock, and the other still writes.) Not on
				// this thread: the caller can be the iOS main thread, and the save can wait on the network.
				fallback = true;
				final Thread f = new Thread(() -> save.flushed = flushOnce(cm), "RuneMobile Exit Save");
				f.setDaemon(true);
				f.start();
				join(f, TimeUnit.MILLISECONDS.toNanos(FLUSH_GRACE_MS));
			}
			else
			{
				// The worker is mid-save: let it land.
				finished = join(t, TimeUnit.MILLISECONDS.toNanos(FLUSH_GRACE_MS));
			}
		}
		final boolean flushed = save.flushed;
		final long ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);
		log.info("[mobileui] prepareExit: posted={} finished={} phase={} flushed={} fallback={} in {} ms",
			post, finished, save.phase, flushed, fallback, ms);
		return "{\"ok\":true,\"posted\":" + post + ",\"finished\":" + finished + ",\"flushed\":" + flushed
			+ ",\"fallback\":" + fallback + ",\"ms\":" + ms + "}";
	}

	@Override
	public void run()
	{
		try
		{
			if (bus != null)
			{
				final ClientShutdown ev = new ClientShutdown();
				bus.post(ev);
				phase = WAITING;
				ev.waitForAllConsumers(Duration.ofNanos(Math.max(0, deadline - System.nanoTime())));
			}
		}
		catch (Throwable t)
		{
			// EventBus catches what a subscriber throws, except an Error it doesn't know; config still gets saved.
			log.warn("[mobileui] ClientShutdown did not complete", t);
		}
		if (!flushClaimed.compareAndSet(false, true))
		{
			phase = DONE; // the caller stopped waiting and saved config itself
			return;
		}
		phase = FLUSHING;
		try
		{
			flushed = flushWithRetry(cm, deadline);
		}
		finally
		{
			phase = DONE;
		}
	}

	/**
	 * {@code sendConfig}, retried until {@code deadline} (always tried once). Another thread can be mid-save: the
	 * client-thread flush queued when the app went to the background, or the 5-minute timer. Both take the same file
	 * lock, which throws {@code OverlappingFileLockException} inside one JVM instead of waiting. ({@code Lock} is
	 * {@code @SneakyThrows}, so an {@code IOException} arrives unchecked: catch {@code Exception}.)
	 */
	private static boolean flushWithRetry(ConfigManager cm, long deadline)
	{
		for (;;)
		{
			try
			{
				cm.sendConfig();
				return true;
			}
			catch (Exception e)
			{
				if (System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(RETRY_MS) > deadline)
				{
					log.warn("[mobileui] prepareExit: config save failed", e);
					return false;
				}
			}
			try
			{
				Thread.sleep(RETRY_MS);
			}
			catch (InterruptedException ie)
			{
				Thread.currentThread().interrupt();
				return false;
			}
		}
	}

	private static boolean flushOnce(ConfigManager cm)
	{
		try
		{
			cm.sendConfig();
			return true;
		}
		catch (Exception e)
		{
			log.warn("[mobileui] prepareExit: fallback config save failed", e);
			return false;
		}
	}

	private static boolean join(Thread t, long nanos)
	{
		if (nanos > 0)
		{
			try
			{
				t.join(Math.max(1, TimeUnit.NANOSECONDS.toMillis(nanos)));
			}
			catch (InterruptedException ie)
			{
				Thread.currentThread().interrupt();
			}
		}
		return !t.isAlive();
	}

	/** Tests only: let the next call post the event again. */
	static void resetForTest()
	{
		shutdownPosted.set(false);
	}
}
