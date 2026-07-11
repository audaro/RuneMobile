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
import java.awt.EventQueue;
import java.awt.Rectangle;
import java.awt.Toolkit;
import java.awt.event.FocusEvent;
import java.awt.event.InputEvent;
import java.awt.event.MouseEvent;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.widgets.Widget;

/**
 * GPU Route C — post-login welcome-screen dismissal.
 *
 * <p>{@link HeadlessLogin} only crosses {@code LOGIN_SCREEN → LOGGED_IN} (it clicks "Play Now" on the
 * authenticated login screen, then stops). But once {@code LOGGED_IN}, the gamepack parks on the
 * <strong>"Welcome to Gielinor / Click here to play"</strong> screen ({@link InterfaceID#WELCOME_SCREEN}, 378)
 * overlaid on the in-game toplevel — the 3D world is NOT per-frame-rendered until that screen is dismissed. With
 * nothing clicking it, the headless harness sits on the welcome screen forever: viewport stays 0x0, the engine
 * never enters the world render, and the gpu plugin's {@code preSceneDraw}/{@code drawZone*} never fire. That
 * looked like a "GPU scene-render gap" but is really "never entered the world".
 *
 * <p>This probe synthesizes the "Click here to play" click. It targets the REAL widget bounds
 * ({@link InterfaceID.WelcomeScreen#PLAY}) so it is resolution-robust, falling back to a configurable pixel
 * point. It re-arms with a cooldown until the welcome screen widget is gone (we are in the world), then is inert.
 *
 * <p>Same posted-AWT-event mechanism as {@link HeadlessLogin} (a UIKit-touch → AWT bridge analogue). Mutates
 * (posts input). Inert unless {@code -Drunelite.headless.welcomeplay=true}.
 */
@Slf4j
public final class WelcomePlayProbe
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.headless.welcomeplay");
	private static final int WARMUP_DRAWS = Integer.getInteger("runelite.headless.welcomeplay.warmup", 15);
	private static final int COOLDOWN_DRAWS = Integer.getInteger("runelite.headless.welcomeplay.cooldown", 40);
	private static final int MAX_ATTEMPTS = Integer.getInteger("runelite.headless.welcomeplay.maxAttempts", 8);

	// Fallback pixel point (765x503 fixed welcome layout): centre of the "CLICK HERE TO PLAY" red button.
	private static final int FALLBACK_X;
	private static final int FALLBACK_Y;

	private static int loggedInDraws;
	private static int attempts;
	private static int lastAttemptDraw;
	private static boolean done;

	static
	{
		int fx = 382;
		int fy = 337;
		final String p = System.getProperty("runelite.headless.welcomeplay.point");
		if (p != null && p.contains(","))
		{
			try
			{
				final String[] parts = p.split(",", 2);
				fx = Integer.parseInt(parts[0].trim());
				fy = Integer.parseInt(parts[1].trim());
			}
			catch (NumberFormatException ignore)
			{
				// keep defaults
			}
		}
		FALLBACK_X = fx;
		FALLBACK_Y = fy;
		if (ENABLED)
		{
			log.info("[welcomeplay] ENABLED fallbackPoint={},{} maxAttempts={}", FALLBACK_X, FALLBACK_Y, MAX_ATTEMPTS);
		}
	}

	private WelcomePlayProbe()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/** Per {@code Hooks.draw} — clicks "Click here to play" once LOGGED_IN, until the welcome screen is gone. */
	public static void tick(Client client, GameState state)
	{
		if (!ENABLED || done || client == null)
		{
			return;
		}
		if (state != GameState.LOGGED_IN)
		{
			return;
		}

		loggedInDraws++;
		if (loggedInDraws < WARMUP_DRAWS)
		{
			return;
		}

		// Already dismissed? The welcome screen root widget is gone once we are in the world.
		final Widget root = safeWidget(client, InterfaceID.WELCOME_SCREEN << 16);
		final Widget play = safeWidget(client, InterfaceID.WelcomeScreen.PLAY);
		final boolean welcomeUp = (root != null && !root.isHidden()) || (play != null && !play.isHidden());
		if (!welcomeUp)
		{
			if (attempts > 0)
			{
				log.info("[welcomeplay] welcome screen dismissed after {} attempt(s) — should be in the world now", attempts);
			}
			done = true;
			return;
		}

		if (attempts >= MAX_ATTEMPTS)
		{
			log.warn("[welcomeplay] welcome screen STILL up after {} click attempt(s) — giving up (wrong target?)", attempts);
			done = true;
			return;
		}
		if (attempts > 0 && loggedInDraws - lastAttemptDraw < COOLDOWN_DRAWS)
		{
			return;
		}

		final Canvas canvas = client.getCanvas();
		if (canvas == null)
		{
			return;
		}

		int x = FALLBACK_X;
		int y = FALLBACK_Y;
		String via = "fallback-point";
		if (play != null)
		{
			final Rectangle b = play.getBounds();
			if (b != null && b.width > 0 && b.height > 0)
			{
				x = b.x + b.width / 2;
				y = b.y + b.height / 2;
				via = "widget-bounds " + b.x + "," + b.y + " " + b.width + "x" + b.height;
			}
		}

		attempts++;
		lastAttemptDraw = loggedInDraws;
		log.info("[welcomeplay] attempt {}/{}: click 'play' at {},{} ({}) canvas={}x{}",
			attempts, MAX_ATTEMPTS, x, y, via, canvas.getWidth(), canvas.getHeight());
		synthesizeClick(canvas, x, y);
	}

	private static Widget safeWidget(Client client, int componentId)
	{
		try
		{
			return client.getWidget(componentId);
		}
		catch (Throwable t)
		{
			return null;
		}
	}

	private static void synthesizeClick(Canvas canvas, int x, int y)
	{
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		q.postEvent(new FocusEvent(canvas, FocusEvent.FOCUS_GAINED, false, null));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_ENTERED, t, 0, x, y, 0, false));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, t + 1, 0, x, y, 0, false));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_PRESSED, t + 2,
			InputEvent.BUTTON1_DOWN_MASK, x, y, 1, false, MouseEvent.BUTTON1));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_RELEASED, t + 3,
			0, x, y, 1, false, MouseEvent.BUTTON1));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_CLICKED, t + 4,
			0, x, y, 1, false, MouseEvent.BUTTON1));
	}
}
