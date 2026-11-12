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

import java.util.ArrayList;
import java.util.List;
import net.runelite.api.AmbientSoundEffect;
import net.runelite.api.RandomSound;
import net.runelite.client.eventbus.EventBus;
import net.runelite.client.eventbus.Subscribe;
import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import org.junit.Test;

/**
 * Plugin Hub plugins are built for the RuneLite release the hub is pinned to, and this tree's API can be newer.
 * A 1.13.6 hub plugin that calls a changed API member must not take the game down with it: with Visual Sounds'
 * ambient option on, its {@code GameStateChanged} handler threw {@code NoSuchMethodError} at every login, the error
 * left the event bus, and the game loop stopped at "Connecting to server...".
 */
public class HubPluginLinkageTest
{
	public static class Ping
	{
	}

	public static class BrokenPlugin
	{
		@Subscribe(priority = 1)
		public void onPing(Ping ping)
		{
			throw new NoSuchMethodError("'int[] net.runelite.api.AmbientSoundEffect.getBackgroundSoundEffectIds()'");
		}
	}

	public static class LaterPlugin
	{
		int seen;

		@Subscribe
		public void onPing(Ping ping)
		{
			seen++;
		}
	}

	@Test
	public void linkageErrorInSubscriberStaysInTheEventBus()
	{
		final List<Throwable> handled = new ArrayList<>();
		final EventBus bus = new EventBus(handled::add);
		final LaterPlugin later = new LaterPlugin();
		bus.register(new BrokenPlugin());
		bus.register(later);

		bus.post(new Ping()); // throws out of post() without the LinkageError catch

		assertEquals(1, handled.size());
		assertTrue(handled.get(0) instanceof NoSuchMethodError);
		assertEquals("the subscribers after the broken one still run", 1, later.seen);
	}

	@Test
	public void backgroundSoundEffectIdsComeFromTheRandomSound()
	{
		final int[] ids = {2425, 2426, 2427};
		assertArrayEquals(ids, ambient(sound(ids)).getBackgroundSoundEffectIds());
		assertSame(ids, ambient(sound(ids)).getBackgroundSoundEffectIds());
		assertNull(ambient(null).getBackgroundSoundEffectIds());
	}

	private static RandomSound sound(int[] ids)
	{
		return new RandomSound()
		{
			@Override
			public int[] getSoundEffectIds()
			{
				return ids;
			}

			@Override
			public void setSoundEffectIds(int[] ignored)
			{
			}
		};
	}

	private static AmbientSoundEffect ambient(RandomSound sound)
	{
		return new AmbientSoundEffect()
		{
			@Override
			public int getSoundEffectId()
			{
				return -1;
			}

			@Override
			public RandomSound getRandomSound()
			{
				return sound;
			}

			@Override
			public int getPlane()
			{
				return 0;
			}
		};
	}
}
