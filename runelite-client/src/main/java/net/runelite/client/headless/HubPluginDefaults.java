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

import lombok.extern.slf4j.Slf4j;
import net.runelite.client.config.ConfigManager;
import net.runelite.client.config.RuneLiteConfig;
import net.runelite.client.util.Text;

/**
 * Settings a Plugin Hub plugin needs to work on a phone, written once per profile before the plugin first starts.
 *
 * <p>Flipping Utilities keeps a session's trades in memory and writes them to disk only on an in-game logout, when
 * the plugin is turned off, on {@code ClientShutdown}, or on its own auto-save timer, which is off by default. A
 * phone session usually ends with the app closed from the app switcher or killed in the background, where nothing
 * runs, so players lost every trade from a session. With auto-save on, a kill costs at most one interval (10
 * minutes unless the player changes it).
 *
 * <p>The plugin reads the setting in {@code startUp}, so the write lands before that: at boot, after plugins load
 * and before they start, and on the client thread just before a hub install registers the plugin. A write after
 * {@code startUp} would race the plugin's own deferred start and could leave two auto-save timers running.
 *
 * <p>Only the marker decides whether to write. RuneLite stores every plugin default in the profile when the plugin
 * loads, so an existing install always reads an explicit {@code false} and the player's choice can't be told apart
 * from the default. After the one write the setting is the player's: turning it off keeps it off.
 */
@Slf4j
final class HubPluginDefaults
{
	static final String FLIPPING_UTILITIES = "flipping-utilities";
	static final String FLIPPING_GROUP = "flipping";
	static final String AUTO_SAVE_KEY = "autoSaveEnabled";
	static final String SEEDED_KEY = "mobileAutoSaveSeeded";
	private static final String PLUGIN_LIST_KEY = "externalPlugins"; // ExternalPluginManager's installed list

	private HubPluginDefaults()
	{
	}

	/** Boot: plugins are loaded but not started. Covers a plugin that was installed before this build. */
	static void onBoot(ConfigManager cm)
	{
		final String installed = cm.getConfiguration(RuneLiteConfig.GROUP_NAME, PLUGIN_LIST_KEY);
		if (installed != null && Text.fromCSV(installed).contains(FLIPPING_UTILITIES))
		{
			seedFlippingAutoSave(cm, "installed before this launch");
		}
	}

	/** A hub install of {@code internalName} is about to be registered; the plugin starts after this returns. */
	static void beforeInstall(ConfigManager cm, String internalName)
	{
		if (FLIPPING_UTILITIES.equals(internalName))
		{
			seedFlippingAutoSave(cm, "hub install");
		}
	}

	/** @return true when this call turned auto-save on, false when the profile already had the marker */
	static boolean seedFlippingAutoSave(ConfigManager cm, String why)
	{
		if (cm.getConfiguration(FLIPPING_GROUP, SEEDED_KEY) != null)
		{
			return false;
		}
		cm.setConfiguration(FLIPPING_GROUP, AUTO_SAVE_KEY, true);
		cm.setConfiguration(FLIPPING_GROUP, SEEDED_KEY, true);
		log.info("[mobileui] Flipping Utilities: auto-save turned on once ({})", why);
		return true;
	}
}
