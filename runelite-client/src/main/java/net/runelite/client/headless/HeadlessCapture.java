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

import java.awt.Graphics;
import java.awt.image.BufferedImage;
import java.io.File;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;
import javax.imageio.ImageIO;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.GameState;
import net.runelite.api.MainBufferProvider;

/**
 * Gate 1c instrumentation for the headless RuneLite render seam.
 *
 * <p>This is the decisive settling experiment for the "kill risk": does the real OSRS engine drive
 * {@code Hooks.draw} with a non-null {@link Graphics} when there is no real Swing window, and does the
 * composited frame actually land in {@code mainBufferProvider}? Two gated hooks are wired into
 * {@code net.runelite.client.callback.Hooks#draw}:
 * <ul>
 *   <li>{@link #onDraw(Graphics)} at the top of the callback — counts every invocation and how many
 *       arrive with a null Graphics (the engine's "no realized canvas" signal).</li>
 *   <li>{@link #capture(MainBufferProvider)} after the overlays composite — periodically dumps the
 *       engine buffer to PNG via the toolkit-independent {@code int[]} pixels.</li>
 * </ul>
 *
 * <p>Entirely inert unless {@code -Drunelite.headless.capture.dir=<dir>} is set, so it adds nothing to
 * the stock desktop client beyond a method call that returns immediately.
 */
@Slf4j
public final class HeadlessCapture
{
	private static final String DIR_PROP = "runelite.headless.capture.dir";
	private static final String INTERVAL_PROP = "runelite.headless.capture.interval";
	private static final String MAX_PROP = "runelite.headless.capture.max";
	private static final String PRELOGIN_MAX_PROP = "runelite.headless.capture.preLoginMax";

	private static final File DIR;
	private static final boolean ENABLED;
	private static final int INTERVAL;
	private static final int MAX_FRAMES;
	private static final int PRELOGIN_MAX_FRAMES;

	private static final AtomicInteger drawCount = new AtomicInteger();
	private static final AtomicInteger nullGraphicsCount = new AtomicInteger();
	private static final AtomicInteger capturedFrames = new AtomicInteger();
	private static final AtomicInteger loggedInFrames = new AtomicInteger();

	// Latest observed game state, written by observe() each draw and read by capture() to tag frames
	// and decide which capture budget applies. Volatile because the engine's render thread and the
	// (same) caller are the only writers, but keep memory visibility honest.
	private static volatile GameState lastState;
	// Latest observed login sub-state; logged on change so the EULA→welcome progression (e.g. 12→10) is
	// visible even while gameState stays LOGIN_SCREEN. -2 = "never observed" (loginIndex is -1 in-game).
	private static int lastLoginIndex = -2;

	static
	{
		final String dir = System.getProperty(DIR_PROP);
		ENABLED = dir != null && !dir.isEmpty();
		DIR = ENABLED ? new File(dir) : null;
		INTERVAL = Integer.getInteger(INTERVAL_PROP, 50);
		MAX_FRAMES = Integer.getInteger(MAX_PROP, 20);
		// Cap how many login-screen frames we keep, so a long pre-login wait (cache download, world
		// hop) doesn't exhaust the budget before we ever reach an in-game frame — the whole point of 1c-ii.
		PRELOGIN_MAX_FRAMES = Integer.getInteger(PRELOGIN_MAX_PROP, 6);
		if (ENABLED)
		{
			//noinspection ResultOfMethodCallIgnored
			DIR.mkdirs();
			log.info("[headless-capture] ENABLED dir={} interval={} maxFrames={} preLoginMax={}",
				DIR, INTERVAL, MAX_FRAMES, PRELOGIN_MAX_FRAMES);
		}
	}

	private HeadlessCapture()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/**
	 * Called at the very top of {@code Hooks.draw}, before the {@code graphics == null} guard.
	 * Counts total draw callbacks and how many arrive without a Graphics.
	 */
	public static void onDraw(Graphics graphics)
	{
		if (!ENABLED)
		{
			return;
		}

		final int n = drawCount.incrementAndGet();
		if (graphics == null)
		{
			nullGraphicsCount.incrementAndGet();
		}

		// First call, then once per second of frames-ish, log the running tally so the experiment is
		// readable from the console even without inspecting the PNGs.
		if (n == 1 || n % INTERVAL == 0)
		{
			log.info("[headless-capture] draw#{} nullGraphics={} capturedFrames={} state={}",
				n, nullGraphicsCount.get(), capturedFrames.get(), lastState);
		}
	}

	/**
	 * Called once per {@code Hooks.draw} (only when capture is enabled) with the live login state. Logs
	 * every game-state transition so the console shows the login progression
	 * (LOGIN_SCREEN → LOGGING_IN → LOGGED_IN) without inspecting PNGs — the decisive 1c-ii observation:
	 * does the {@code JX_*} launcher handoff carry the client all the way to LOGGED_IN, or stall at the
	 * authenticated login screen (which would mean a synthesized click is needed).
	 *
	 * @param state               the current {@code client.getGameState()}
	 * @param loginIndex          the current {@code client.getLoginIndex()} (login form sub-state)
	 * @param launcherDisplayName {@code client.getLauncherDisplayName()} — non-null iff the gamepack
	 *                            picked up the Jagex-launcher env vars
	 */
	public static void observe(GameState state, int loginIndex, String launcherDisplayName)
	{
		if (!ENABLED)
		{
			return;
		}

		final GameState prev = lastState;
		lastState = state;
		if (state != prev)
		{
			log.info("[headless-capture] gameState {} -> {} (draw#{} loginIndex={} launcher={})",
				prev, state, drawCount.get(), loginIndex, launcherDisplayName != null);
		}

		// Log loginIndex transitions too — they advance (e.g. EULA 12 → welcome 10) while gameState stays
		// LOGIN_SCREEN, so without this the EULA-accept handoff is invisible in the log.
		final int prevLoginIndex = lastLoginIndex;
		lastLoginIndex = loginIndex;
		if (loginIndex != prevLoginIndex && state == GameState.LOGIN_SCREEN)
		{
			log.info("[headless-capture] loginIndex {} -> {} (draw#{} state={} launcher={})",
				prevLoginIndex, loginIndex, drawCount.get(), state, launcherDisplayName != null);
		}
	}

	/**
	 * Called after overlays composite, only on the non-null-Graphics path. Dumps the engine buffer to
	 * PNG every {@code INTERVAL} draws, up to {@code MAX_FRAMES} files.
	 */
	public static void capture(MainBufferProvider mainBufferProvider)
	{
		if (!ENABLED || mainBufferProvider == null)
		{
			return;
		}

		final int n = drawCount.get();
		if (n % INTERVAL != 0)
		{
			return;
		}

		// Two budgets so a long login wait can't starve the in-game capture: LOGGED_IN frames get the
		// full MAX_FRAMES; every other state shares a small PRELOGIN budget (enough to prove the login
		// screen still renders, no more). This is what makes 1c-ii's in-game frame reliably land.
		final GameState state = lastState;
		final boolean loggedIn = state == GameState.LOGGED_IN;
		final AtomicInteger budget = loggedIn ? loggedInFrames : capturedFrames;
		final int cap = loggedIn ? MAX_FRAMES : PRELOGIN_MAX_FRAMES;
		if (budget.get() >= cap)
		{
			return;
		}

		try
		{
			final int[] pixels = mainBufferProvider.getPixels();
			final int w = mainBufferProvider.getWidth();
			final int h = mainBufferProvider.getHeight();
			if (pixels == null || w <= 0 || h <= 0 || pixels.length < w * h)
			{
				log.warn("[headless-capture] skipped: pixels={} w={} h={}",
					pixels == null ? "null" : pixels.length, w, h);
				return;
			}

			final BufferedImage img = new BufferedImage(w, h, BufferedImage.TYPE_INT_RGB);
			img.setRGB(0, 0, w, h, pixels, 0, w);

			final int frame = budget.incrementAndGet();
			final String stateTag = state == null ? "NULL" : state.name();
			final File out = new File(DIR, String.format("frame-%s-%03d-draw%05d.png", stateTag, frame, n));
			ImageIO.write(img, "png", out);
			log.info("[headless-capture] wrote {} ({}x{})", out.getName(), w, h);
		}
		catch (IOException | RuntimeException ex)
		{
			log.warn("[headless-capture] capture failed", ex);
		}
	}

	public static int getDrawCount()
	{
		return drawCount.get();
	}

	public static int getNullGraphicsCount()
	{
		return nullGraphicsCount.get();
	}

	public static int getCapturedFrames()
	{
		return capturedFrames.get();
	}

	public static int getLoggedInFrames()
	{
		return loggedInFrames.get();
	}

	public static GameState getLastState()
	{
		return lastState;
	}
}
