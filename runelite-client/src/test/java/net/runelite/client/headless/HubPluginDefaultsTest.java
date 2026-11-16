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

import net.runelite.client.config.ConfigManager;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import org.junit.Test;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Flipping Utilities writes its trades to disk only at logout, on shutdown or on its own auto-save timer (off by
 * default), so a phone session that ends in a kill lost them. Auto-save is turned on once per profile, before the
 * plugin's first start, and never again after that.
 */
public class HubPluginDefaultsTest
{
	private final ConfigManager cm = mock(ConfigManager.class);

	@Test
	public void turnsAutoSaveOnAtBootForAnExistingInstall()
	{
		when(cm.getConfiguration("runelite", "externalPlugins")).thenReturn("quest-helper,flipping-utilities");
		// What RuneLite leaves in the profile once the plugin has loaded: its default, stored explicitly.
		when(cm.getConfiguration("flipping", "autoSaveEnabled")).thenReturn("false");

		HubPluginDefaults.onBoot(cm);

		verify(cm).setConfiguration("flipping", "autoSaveEnabled", true);
		verify(cm).setConfiguration("flipping", "mobileAutoSaveSeeded", true);
	}

	@Test
	public void turnsAutoSaveOnBeforeAHubInstall()
	{
		HubPluginDefaults.beforeInstall(cm, "flipping-utilities");

		verify(cm).setConfiguration("flipping", "autoSaveEnabled", true);
		verify(cm).setConfiguration("flipping", "mobileAutoSaveSeeded", true);
	}

	@Test
	public void leavesThePlayersChoiceAloneOnceSeeded()
	{
		when(cm.getConfiguration("runelite", "externalPlugins")).thenReturn("flipping-utilities");
		when(cm.getConfiguration("flipping", "mobileAutoSaveSeeded")).thenReturn("true");
		when(cm.getConfiguration("flipping", "autoSaveEnabled")).thenReturn("false");

		HubPluginDefaults.onBoot(cm);
		HubPluginDefaults.beforeInstall(cm, "flipping-utilities"); // reinstall after a remove
		assertFalse(HubPluginDefaults.seedFlippingAutoSave(cm, "test"));

		verify(cm, never()).setConfiguration(anyString(), anyString(), any(Object.class));
		verify(cm, never()).setConfiguration(anyString(), anyString(), anyString());
	}

	@Test
	public void touchesNothingWithoutThePlugin()
	{
		when(cm.getConfiguration("runelite", "externalPlugins")).thenReturn("quest-helper,flipping-copilot");
		HubPluginDefaults.onBoot(cm);
		HubPluginDefaults.beforeInstall(cm, "flipping-copilot");
		HubPluginDefaults.beforeInstall(cm, null);

		when(cm.getConfiguration("runelite", "externalPlugins")).thenReturn(null);
		HubPluginDefaults.onBoot(cm);

		verify(cm, never()).setConfiguration(anyString(), anyString(), any(Object.class));
		verify(cm, never()).setConfiguration(anyString(), anyString(), anyString());
	}

	@Test
	public void reportsWhetherItWrote()
	{
		assertTrue(HubPluginDefaults.seedFlippingAutoSave(cm, "test"));
	}
}
