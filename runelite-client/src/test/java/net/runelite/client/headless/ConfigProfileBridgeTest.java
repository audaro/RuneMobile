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
import net.runelite.client.config.ConfigManager;
import net.runelite.client.config.ConfigProfile;
import net.runelite.client.config.ProfileManager;
import static org.junit.Assert.assertTrue;
import org.junit.Test;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import org.mockito.InOrder;

/**
 * {@code ConfigManager#load} starts the client in the profile saved as active, so a switch that does not save that
 * flag lasts one session. The desktop profile panel saves it before switching, and the bridge has to as well.
 */
public class ConfigProfileBridgeTest
{
	private final ConfigManager configManager = mock(ConfigManager.class);
	private final ProfileManager profileManager = mock(ProfileManager.class);
	private final ProfileManager.Lock lock = mock(ProfileManager.Lock.class);
	private final ConfigProfile current = mock(ConfigProfile.class);
	private final ConfigProfile chosen = mock(ConfigProfile.class);

	private void wire()
	{
		when(current.getId()).thenReturn(1L);
		when(chosen.getId()).thenReturn(2L);
		when(configManager.getProfile()).thenReturn(current);
		when(profileManager.lock()).thenReturn(lock);
		when(lock.findProfile(2L)).thenReturn(chosen);
		when(lock.getProfiles()).thenReturn(Arrays.asList(current, chosen));
		ConfigProfileBridge.init(configManager, profileManager, null);
	}

	@Test
	public void aSwitchSavesTheChoiceForTheNextLaunch()
	{
		wire();
		assertTrue(ConfigProfileBridge.switchProfile(2L).contains("\"ok\":true"));

		final InOrder saved = inOrder(current, chosen, lock);
		saved.verify(current).setActive(false);
		saved.verify(chosen).setActive(true);
		saved.verify(lock).dirty();
		saved.verify(lock).close();
	}

	@Test
	public void anUnknownProfileChangesNothing()
	{
		wire();
		ConfigProfileBridge.switchProfile(3L);
		verify(current, never()).setActive(false);
		verify(lock, never()).dirty();
	}
}
