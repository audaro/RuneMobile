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

import java.awt.Canvas;
import javax.swing.SwingUtilities;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GameState;

/**
 * Track G AG3-b — bring up the 117HD (RLHD) plugin (Zone renderer) on the device. Sibling of
 * {@link RouteCGpuStarter}, but RLHD is NOT a built-in plugin: it lives in the staged {@code client-<ver>-rlhd.jar}
 * on the classpath (package {@code rs117.hd.*}), OUTSIDE the {@code net.runelite.client.plugins} package
 * {@code PluginManager.loadCorePlugins()} scans — so it is never auto-discovered. This helper, armed by
 * {@code -Drunelite.routecrlhd=true} and run per {@code Hooks.draw} once there is a drawing canvas, loads it via
 * the public {@code PluginManager.loadPlugins(List<Class>)} path ({@link MobileUiBridge#loadAndStartPlugin}) and
 * starts it. {@code HdPlugin} declares {@code conflicts="GPU"}, so {@code startPlugin} disables the base gpu plugin
 * automatically (do NOT also arm {@link RouteCGpuStarter} in this mode). {@code HdPlugin.startUp} defers the GL work
 * onto the client thread and retries until {@code textureManager.vanillaTexturesAvailable()} and the canvas is
 * valid — so the load is issued ONCE and we then just force the canvas valid + watch for {@code client.isGpu()}.
 * Inert (mutates nothing) unless the flag is set.
 */
@Slf4j
public final class RLHDStarter
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.routecrlhd");
	// PROD-COMPAT-01 bring-up: once 117HD is up, force-compile the dev ShaderOverlay shaders on the live driver so a
	// strict-GLSL-ES typing regression in an overlay surfaces in a device/matrix run (the overlays are
	// dev-toggle-gated and never compile in a default login run). Armed by a pushed marker on Android; off by default.
	private static final boolean OVERLAY_SELFTEST = Boolean.getBoolean("runelite.rlhdOverlaySelfTest");
	private static final String HD_PLUGIN = "rs117.hd.HdPlugin";
	private static final int MAX_ATTEMPTS = 40;     // RLHD's own startUp retry needs the game cache; allow ~a minute
	// Sentinel (custom key in the "hd" group) marking that the user-tunable graphics defaults were seeded once.
	// Present -> a later launch respects the persisted values (the user's 117HD plugin-config edits) instead of
	// re-forcing the defaults. Not a real ConfigItem, so it never shows in the panel.
	private static final String GFX_SEEDED_KEY = "iosGfxSeeded";
	// Separate one-shot sentinel for the shadow-map-resolution fps default, so applying it doesn't re-seed (reset)
	// the user's other tunable picks.
	private static final String GFX_SHADOWRES_KEY = "iosGfxShadowRes1k";

	private static boolean done;
	private static boolean configForced;
	private static boolean loadIssued;
	private static boolean selfTestDone;
	private static int attempts;
	private static long lastActionMs;

	private RLHDStarter()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/** Per {@code Hooks.draw}: load + start 117HD once in-world, then force the canvas valid until it activates. */
	public static void tick(Client client)
	{
		if (!ENABLED || done || client == null)
		{
			return;
		}
		if (client.isGpu())
		{
			// 117HD is up + the overlays are injected — force-compile the dev ShaderOverlay shaders once (queues each
			// overlay's compile on the client thread). Diagnostic only; any failure is logged, never fatal.
			if (OVERLAY_SELFTEST && !selfTestDone)
			{
				selfTestDone = true;
				try
				{
					log.info("[routecrlhd] overlay self-test -> {}", MobileUiBridge.rlhdOverlaySelfTest());
				}
				catch (Throwable t)
				{
					log.warn("[routecrlhd] overlay self-test threw", t);
				}
			}
			done = true;
			log.info("[routecrlhd] GPU renderer active (isGpu=true) — 117HD up after {} attempt(s)", attempts);
			return;
		}

		// Engage once there is a drawing canvas — LOGGED_IN (the 3D world) OR the OSRS LOGIN_SCREEN.
		final GameState gs = client.getGameState();
		if (gs != GameState.LOGGED_IN && gs != GameState.LOGIN_SCREEN)
		{
			return;
		}

		// Throttle so we don't hammer the EDT/client thread every frame while startUp comes up.
		final long now = System.currentTimeMillis();
		if (lastActionMs != 0 && now - lastActionMs < 1500)
		{
			return;
		}
		lastActionMs = now;

		// Phase 0: BEFORE loading the plugin, force the simplest GLSL-ES paths so HdPlugin.startUp's shader compile
		// uses them. RLHDStarter is shared by iOS (Route C / EAGL, full feature port) AND Android (real-HW,
		// mobile-sane) — both armed by -Drunelite.routecrlhd — but they need different 117HD config. The iOS shell
		// sets -Drunelite.gfxIos=true; without it (Android) we apply Android's mobile config. Config writes queue on
		// the client thread; returning lets them commit before the load on the next tick. (Group "hd" per HdPluginConfig.)
		if (!configForced)
		{
			if (!Boolean.getBoolean("runelite.gfxIos"))
			{
			// ANDROID (real-HW, mobile-sane). SAFETY-CRITICAL (forced EVERY launch, NOT user-tunable): each MUST stay
			// or the plugin breaks. asyncModelProcessing=false (our EGL/GL bridge has ONE thread-affine context; RLHD's
			// multithreaded path has worker threads touch GL buffers concurrently -> races corrupt animated models);
			// uiScalingMode=LINEAR (HYBRID/xBR pull in scale/*.glsl not yet validated on Android GLES; also the
			// client-thread-readiness probe); tiledLighting=false (the tiled-lighting GLSL is not ported to the Android
			// overlay yet -> feature-gated off until Phase 5; the scene renders correctly without it). uiScalingMode is
			// forced FIRST and used as the readiness probe — if the client thread isn't up yet, retry next tick.
			final String probe = MobileUiBridge.setConfig("hd", "uiScalingMode", "LINEAR");
			if (!probe.contains("\"ok\":true"))
				return;   // client thread not ready yet — retry next tick before seeding/committing
			MobileUiBridge.setConfig("hd", "asyncModelProcessing", "false");
			MobileUiBridge.setConfig("hd", "tiledLighting", "false");

			// USER-TUNABLE mobile defaults — seeded ONCE (first launch, gated on the GFX_SEEDED_KEY sentinel) then
			// PERSISTED, so the user's 117HD plugin-config edits survive relaunch. THIS FIXES THE SEED-GAP: the old
			// Android path re-FORCED these every launch (wiping panel edits) and left the rest at RLHD's desktop
			// defaults — which crush a mobile GPU (MSAA_8, 100% scale, aniso 16, 50-tile draw, and POM / wind /
			// character-displacement all ON). The seed below establishes the mobile floor; quality levers above it
			// (MSAA, sceneScale, aniso, lights) are A/B'd and raised in later Phase-2 tasks. All reversible in-panel.
			final boolean seed = !"1".equals(MobileUiBridge.getConfig("hd", GFX_SEEDED_KEY));
			if (seed)
			{
				// Quality floor (mobile-sane; Phase-2 device A/B on Mali-G710, uncapped, drift-corrected):
				MobileUiBridge.setConfig("hd", "antiAliasingMode", "MSAA_4");              // ~+1.5 ms GPU — MSAA is tile-memory-cheap here (2x≈4x); 10-min soak held >50 fps, no throttle
				MobileUiBridge.setConfig("hd", "sceneResolutionScale", "85");              // 85% scene FBO, blit-upscale — 100 costs ~+4 ms (quadratic fill), would break the 50 fps floor
				MobileUiBridge.setConfig("hd", "anisotropicFilteringLevel", "16");         // distance sharpness; measured ~free (within thermal noise) on this tiler
				MobileUiBridge.setConfig("hd", "drawDistance", "30");                      // desktop 50; keeps the open-world view
				MobileUiBridge.setConfig("hd", "shadowResolution", "RES_1024");            // 1K shadow map — shadow pass is bandwidth-bound
				MobileUiBridge.setConfig("hd", "parallaxOcclusionMappingToggle", "false"); // Phase 1 device A/B: ~10 fps / ~2.7 ms GPU uncapped
				MobileUiBridge.setConfig("hd", "windDisplacement", "false");               // compute grass sway — GPU cost on a fill-bound GPU
				MobileUiBridge.setConfig("hd", "characterDisplacement", "false");          // same; both user-reenableable in-panel
				// HD look kept (low / no perf cost):
				MobileUiBridge.setConfig("hd", "normalMapping", "true");                   // surface relief; "barely impacts performance" (RLHD)
				MobileUiBridge.setConfig("hd", "dynamicLights", "SOME");                   // 50 dynamic lights (RLHD default)
				MobileUiBridge.setConfig("hd", "shadowMode", "DETAILED");                  // dappled shadows
				MobileUiBridge.setConfig("hd", "shadowFiltering", "SMOOTH");               // smooth shadow edges
				MobileUiBridge.setConfig("hd", "sceneScalingMode", "LINEAR");              // smooth downsample of the 85% scene FBO
				MobileUiBridge.setConfig("hd", GFX_SEEDED_KEY, "1");
				MobileUiBridge.flushConfigQueued();   // persist the seed + sentinel (queued AFTER the writes above)
			}
			configForced = true;
			log.info("[routecrlhd] Android config applied — safety forced (uiScaling LINEAR, async OFF, tiledLighting OFF); "
				+ "tunables {}", seed
				? "SEEDED (first launch: MSAA_4, scale 85, aniso 16, draw 30, shadows 1K, POM/wind/char OFF, normal/lights SOME/shadows kept)"
				: "from persisted 117HD plugin config");
			return;
			}
			// SAFETY-CRITICAL (forced EVERY launch, NOT user-tunable): each MUST stay or RLHD recompiles an unported
			// shader / hits an iOS bridge limit and stops the plugin. uiScalingMode=LINEAR (HYBRID/xBR pull in unported
			// scale/*.glsl); shadowFiltering=SMOOTH (DITHERED/PIXELATED unported); wind/characterDisplacement off
			// (compute-only no-ops); asyncModelProcessing off (single thread-affine EAGL ctx can't do RLHD multithreaded
			// GL -> player flashing); sceneScalingMode=LINEAR (smooth downsample). These are kept OUT of the native
			// graphics panel. (POM is now ported -> it's a user-tunable, seeded off below.) uiScalingMode is also the
			// client-thread-readiness probe.
			final String probe = MobileUiBridge.setConfig("hd", "uiScalingMode", "LINEAR");
			if (!probe.contains("\"ok\":true"))
				return;   // client thread not ready yet — retry next tick before seeding/committing
			MobileUiBridge.setConfig("hd", "shadowFiltering", "SMOOTH");
			MobileUiBridge.setConfig("hd", "windDisplacement", "false");
			MobileUiBridge.setConfig("hd", "characterDisplacement", "false");
			MobileUiBridge.setConfig("hd", "asyncModelProcessing", "false");
			MobileUiBridge.setConfig("hd", "sceneScalingMode", "LINEAR");

			// USER-TUNABLE graphics defaults — seeded ONCE (first launch, gated on the GFX_SEEDED_KEY sentinel) then
			// PERSISTED. After the first launch the user owns these via the 117HD plugin config; we no longer force
			// them, so their edits survive relaunch (RLHD loads the persisted values). All values here are the
			// iOS-ported set the native panel exposes (each safe to change live): tiledLighting (whole-scene lighting),
			// dynamicLights=SOME (50 lights), normalMapping (surface relief), shadowMode=DETAILED + transparency (dappled
			// foliage shadows), antiAliasingMode=MSAA_4 (device max), sceneResolutionScale=100 (native, no SSAA — the fps
			// pick; raise for sharpness). MAX_LIGHT_COUNT/UBO sizing + the tiled FBO/shader notes are in project memory.
			final boolean seed = !"1".equals(MobileUiBridge.getConfig("hd", GFX_SEEDED_KEY));
			if (seed)
			{
				MobileUiBridge.setConfig("hd", "tiledLighting", "true");
				MobileUiBridge.setConfig("hd", "dynamicLights", "SOME");
				MobileUiBridge.setConfig("hd", "normalMapping", "true");
				MobileUiBridge.setConfig("hd", "shadowMode", "DETAILED");
				MobileUiBridge.setConfig("hd", "enableShadowTransparency", "true");
				MobileUiBridge.setConfig("hd", "antiAliasingMode", "MSAA_4");
				MobileUiBridge.setConfig("hd", "sceneResolutionScale", "100");
				MobileUiBridge.setConfig("hd", "parallaxOcclusionMappingToggle", "false"); // POM ported + available, off by default (it ADDS GPU cost)
				MobileUiBridge.setConfig("hd", GFX_SEEDED_KEY, "1");
				MobileUiBridge.flushConfigQueued();   // persist the seed + sentinel (queued AFTER the writes above)
			}
			// fps one-shot (independent sentinel so it doesn't reset the user's other picks): lower the shadow map to
			// 1K once. The shadow pass (full scene rendered from the light's POV) is the heaviest GPU cost after the
			// main scene; 1K vs 2K is barely visible at the mobile present scale but a real fps win. Reversible in the
			// 117HD plugin config (shadowResolution).
			if (!"1".equals(MobileUiBridge.getConfig("hd", GFX_SHADOWRES_KEY)))
			{
				MobileUiBridge.setConfig("hd", "shadowResolution", "RES_1024");
				MobileUiBridge.setConfig("hd", GFX_SHADOWRES_KEY, "1");
				MobileUiBridge.flushConfigQueued();
			}
			configForced = true;
			log.info("[routecrlhd] iOS config applied — safety forced (uiScaling/shadowFiltering/scaling LINEAR/SMOOTH; "
				+ "POM/wind/char-disp/async OFF); tunables {}", seed ? "SEEDED (first launch)" : "from persisted 117HD plugin config");
			return;
		}

		final Canvas canvas = client.getCanvas();
		final boolean valid = canvas != null && canvas.isValid();
		attempts++;
		log.info("[routecrlhd] {} 117HD not yet active (attempt {}/{}): canvas={} valid={} loadIssued={}",
			gs, attempts, MAX_ATTEMPTS, canvas == null ? "null" : "present", valid, loadIssued);

		// Force the canvas valid so HdPlugin.startUp's canvas.isValid() retry can pass (EDT, under the tree lock).
		if (canvas != null && !valid)
		{
			SwingUtilities.invokeLater(() ->
			{
				try
				{
					synchronized (canvas.getTreeLock())
					{
						canvas.validate();
					}
					log.info("[routecrlhd] canvas.validate() -> valid={}", canvas.isValid());
				}
				catch (Throwable t)
				{
					log.warn("[routecrlhd] canvas.validate() failed", t);
				}
			});
		}

		// Load + start HdPlugin exactly ONCE (loadPlugins is not idempotent — a second call would double-load).
		// Its own clientThread retry then waits for the game cache + valid canvas; we just keep validating above.
		if (!loadIssued)
		{
			final String r = MobileUiBridge.loadAndStartPlugin(HD_PLUGIN);
			loadIssued = true;
			log.info("[routecrlhd] loadAndStartPlugin({}) -> {}", HD_PLUGIN, r);
		}

		if (attempts >= MAX_ATTEMPTS)
		{
			done = true;
			log.warn("[routecrlhd] giving up after {} attempts — 117HD did not become active", attempts);
		}
	}
}
