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

import java.nio.channels.OverlappingFileLockException;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import net.runelite.client.config.ConfigManager;
import net.runelite.client.eventbus.EventBus;
import net.runelite.client.eventbus.Subscribe;
import net.runelite.client.events.ClientShutdown;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import org.junit.Before;
import org.junit.Test;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;

/**
 * A phone exit posts the {@code ClientShutdown} desktop posts when its window closes, so plugins that keep data in
 * memory (Flipping Utilities' trades) save it, then saves config. The wait is bounded whatever a plugin does.
 */
public class ExitSaveTest
{
	private final List<String> order = new CopyOnWriteArrayList<>();
	private final ConfigManager cm = mock(ConfigManager.class);

	public static class SavingPlugin
	{
		private final List<String> order;
		int shutdowns;

		SavingPlugin(List<String> order)
		{
			this.order = order;
		}

		@Subscribe
		public void onClientShutdown(ClientShutdown e)
		{
			shutdowns++;
			order.add("plugin");
		}
	}

	/** Hands the shutdown a 200 ms upload, the way Loot Tracker hands it its pending submission. */
	public static class UploadingPlugin
	{
		private final List<String> order;

		UploadingPlugin(List<String> order)
		{
			this.order = order;
		}

		@Subscribe
		public void onClientShutdown(ClientShutdown e)
		{
			final CompletableFuture<Void> upload = new CompletableFuture<>();
			new Thread(() ->
			{
				sleep(200);
				order.add("task");
				upload.complete(null);
			}).start();
			e.waitFor(upload);
		}
	}

	public static class HungPlugin
	{
		private final CountDownLatch release;

		HungPlugin(CountDownLatch release)
		{
			this.release = release;
		}

		@Subscribe
		public void onClientShutdown(ClientShutdown e) throws InterruptedException
		{
			release.await();
		}
	}

	@Before
	public void setUp()
	{
		ExitSave.resetForTest();
		doAnswer(inv ->
		{
			order.add("config");
			return null;
		}).when(cm).sendConfig();
	}

	@Test
	public void postsClientShutdownOnceThenSavesConfig()
	{
		final EventBus bus = new EventBus();
		final SavingPlugin plugin = new SavingPlugin(order);
		bus.register(plugin);

		final String first = ExitSave.run(bus, cm, 2000);
		assertTrue(first, first.contains("\"posted\":true") && first.contains("\"finished\":true"));
		assertTrue(first, first.contains("\"flushed\":true") && first.contains("\"fallback\":false"));
		assertEquals(List.of("plugin", "config"), order);

		final String second = ExitSave.run(bus, cm, 2000);
		assertTrue(second, second.contains("\"posted\":false") && second.contains("\"flushed\":true"));
		assertEquals("the event goes out once per process", 1, plugin.shutdowns);
		assertEquals(List.of("plugin", "config", "config"), order);
	}

	@Test
	public void waitsForTheTasksSubscribersHandToWaitFor()
	{
		final EventBus bus = new EventBus();
		bus.register(new UploadingPlugin(order));

		final String r = ExitSave.run(bus, cm, 2000);
		assertTrue(r, r.contains("\"finished\":true"));
		assertEquals(List.of("task", "config"), order);
	}

	@Test
	public void aHungSubscriberCostsTheWaitNotTheExit()
	{
		final CountDownLatch release = new CountDownLatch(1);
		final EventBus bus = new EventBus();
		bus.register(new HungPlugin(release));

		final long t0 = System.nanoTime();
		final String r = ExitSave.run(bus, cm, 300);
		final long ms = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
		release.countDown();

		assertTrue("returned in " + ms + " ms", ms < 1500);
		assertTrue(r, r.contains("\"finished\":false") && r.contains("\"fallback\":true"));
		assertTrue("the caller saved config itself: " + r, r.contains("\"flushed\":true"));
		assertEquals(List.of("config"), order);
	}

	@Test
	public void retriesAConfigSaveThatMeetsTheProfileLock()
	{
		doThrow(new OverlappingFileLockException()).doAnswer(inv ->
		{
			order.add("config");
			return null;
		}).when(cm).sendConfig();

		final String r = ExitSave.run(new EventBus(), cm, 2000);
		assertTrue(r, r.contains("\"flushed\":true") && r.contains("\"finished\":true"));
		verify(cm, times(2)).sendConfig();
	}

	@Test
	public void aZeroWaitStillSavesConfig()
	{
		final String r = ExitSave.run(new EventBus(), cm, 0);
		assertTrue(r, r.contains("\"flushed\":true"));
		assertEquals(List.of("config"), order);
	}

	private static void sleep(long ms)
	{
		try
		{
			Thread.sleep(ms);
		}
		catch (InterruptedException e)
		{
			Thread.currentThread().interrupt();
		}
	}
}
