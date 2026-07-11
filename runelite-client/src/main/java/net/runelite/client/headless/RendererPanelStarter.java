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
import net.runelite.api.Client;
import net.runelite.api.GameState;

/**
 * iOS "renderers as plugins": surface the GPU and 117HD renderer plugins in the native plugin panel even when
 * they are NOT the active renderer, so the user can see + configure + (via the launch-time preference) switch to
 * them — like enabling a plugin on desktop. Neither is auto-discovered by {@code PluginManager.loadCorePlugins}
 * (the Guava {@code ClassPath} scan misses the staged gpu package; HdPlugin lives in {@code rs117.hd}), so this
 * loads both explicitly WITHOUT starting ({@link MobileUiBridge#loadPluginNoStart}). The renderer that is
 * actually active is started separately by {@link RouteCGpuStarter} / {@link RLHDStarter} per the launch
 * preference, and {@code loadPluginNoStart} is idempotent (a no-op if that starter already loaded it).
 *
 * <p>One-shot per session, in-world. Inert unless {@code -Drunelite.rendererpanel=true}. Each load is
 * try/caught inside the bridge so a renderer that can't instantiate just doesn't appear — it never breaks boot.
 */
@Slf4j
public final class RendererPanelStarter
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.rendererpanel");
	private static final String GPU_PLUGIN = "net.runelite.client.plugins.gpu.GpuPlugin";
	private static final String HD_PLUGIN = "rs117.hd.HdPlugin";

	private static boolean done;

	private RendererPanelStarter()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/** Per {@code Hooks.draw}: once in-world, load both renderer plugins (no-start) into the panel, once. */
	public static void tick(Client client)
	{
		if (!ENABLED || done || client == null)
		{
			return;
		}
		final GameState gs = client.getGameState();
		if (gs != GameState.LOGGED_IN && gs != GameState.LOGIN_SCREEN)
		{
			return;   // wait until the injector + plugin manager are live (same gate the other starters use)
		}
		done = true;
		final String g = MobileUiBridge.loadPluginNoStart(GPU_PLUGIN);
		final String h = MobileUiBridge.loadPluginNoStart(HD_PLUGIN);
		log.info("[rendererpanel] loaded for the panel: GPU -> {} | 117HD -> {}", g, h);
	}
}
