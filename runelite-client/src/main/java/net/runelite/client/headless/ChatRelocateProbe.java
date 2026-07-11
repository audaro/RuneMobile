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
import java.awt.image.BufferedImage;
import java.io.File;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.BufferProvider;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.gameval.VarbitID;
import net.runelite.api.widgets.Widget;

/**
 * W3 Feature-A (A3) decision probe — can the engine's OWN chatbox be RELOCATED to the top and still render
 * there (not occluded by the 3D viewport)? If yes, the native chat-at-top can be the engine's pixel-perfect OSRS
 * chat moved up (nearly free exact skin) rather than a from-scratch native reproduction. This is the A-ALT
 * question (flagged "likely dead" for tab STONES, never tested for the CHATBOX specifically).
 *
 * <p>Each frame in-world it {@code setForcedPosition}s {@code CHAT_CONTAINER} to the top-left and revalidates,
 * then captures a PNG. The PNG is the ground truth: is the chat now drawn at the top, or did it stay put / get
 * occluded? Mutates widget position; desktop de-risk only. Inert unless {@code -Drunelite.chatreloc=true}.
 */
@Slf4j
public final class ChatRelocateProbe
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.chatreloc");

	private static final File DIR;

	static
	{
		String dir = System.getProperty("runelite.chatreloc.dir");
		if (dir == null || dir.isEmpty())
		{
			dir = System.getProperty("runelite.headless.capture.dir");
		}
		DIR = (dir == null || dir.isEmpty()) ? null : new File(dir);
		if (ENABLED && DIR != null)
		{
			//noinspection ResultOfMethodCallIgnored
			DIR.mkdirs();
		}
	}

	private static final int TARGET_X = 8;
	private static final int TARGET_Y = 6;
	private static final int F_SETTLE = 25;
	private static final int F_VERDICT = 45;

	private static int frame;
	private static boolean started;
	private static boolean verdictEmitted;
	private static int chatId;
	private static String rootName = "?";
	private static int[] origBounds;
	private static boolean focused;

	private ChatRelocateProbe()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	public static void tick(Client c, GameState state)
	{
		if (!ENABLED || c == null || state != GameState.LOGGED_IN || verdictEmitted)
		{
			return;
		}

		if (welcomeUp(c))
		{
			if ((frame++ % 20) == 5)
			{
				synthClickCentre(c);
			}
			return;
		}

		if (!started)
		{
			if (!resolveChat(c))
			{
				return;
			}
			final Rectangle b = boundsOf(c, chatId);
			origBounds = b == null ? null : new int[]{b.x, b.y, b.width, b.height};
			started = true;
			frame = 0;
			log.info("[chatreloc] in-world root={} chatOrigBounds={} -> forcing to {},{}",
				rootName, rect(origBounds), TARGET_X, TARGET_Y);
		}

		// Force the chatbox to the top-left each frame (survive TOPLEVEL_REDRAW), then revalidate so children follow.
		try
		{
			final Widget w = c.getWidget(chatId);
			if (w != null)
			{
				w.setForcedPosition(TARGET_X, TARGET_Y);
				w.revalidate();
			}
		}
		catch (RuntimeException ignore)
		{
		}
		frame++;

		if (frame == F_SETTLE)
		{
			capture(c, "chat-top");
		}

		if (frame >= F_VERDICT)
		{
			verdictEmitted = true;
			final Rectangle nb = boundsOf(c, chatId);
			final int[] now = nb == null ? null : new int[]{nb.x, nb.y, nb.width, nb.height};
			// "moved" = the chat's reported canvas bounds are now near the top. The PNG confirms it actually renders.
			final boolean movedTop = now != null && now[1] <= TARGET_Y + 40;
			log.info("[chatreloc] CHATRELOC root={} origBounds={} nowBounds={} movedToTop={} (PNG = whether it renders there)",
				rootName, rect(origBounds), rect(now), movedTop);
		}
	}

	private static boolean resolveChat(Client c)
	{
		try
		{
			if (!c.isResized())
			{
				rootName = "FIXED(unsupported)";
				return false;
			}
			final boolean preEoc = c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT) == 1;
			chatId = preEoc ? InterfaceID.ToplevelPreEoc.CHAT_CONTAINER : InterfaceID.ToplevelOsrsStretch.CHAT_CONTAINER;
			rootName = preEoc ? "PreEoc" : "OsrsStretch";
			return boundsOf(c, chatId) != null;
		}
		catch (RuntimeException ex)
		{
			return false;
		}
	}

	private static Rectangle boundsOf(Client c, int id)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w == null)
			{
				return null;
			}
			return w.getBounds();
		}
		catch (RuntimeException ex)
		{
			return null;
		}
	}

	private static String rect(int[] b)
	{
		return b == null ? "null" : "[" + b[0] + "," + b[1] + "," + b[2] + "," + b[3] + "]";
	}

	private static boolean welcomeUp(Client c)
	{
		try
		{
			final Widget w = c.getWidget(InterfaceID.WelcomeScreen.UNIVERSE);
			return w != null && !w.isHidden();
		}
		catch (RuntimeException ex)
		{
			return false;
		}
	}

	private static void capture(Client c, String mode)
	{
		if (DIR == null)
		{
			return;
		}
		try
		{
			final BufferProvider bp = c.getBufferProvider();
			final int[] px = bp.getPixels();
			final int w = bp.getWidth();
			final int h = bp.getHeight();
			if (px == null || w <= 0 || h <= 0 || px.length < w * h)
			{
				return;
			}
			final BufferedImage img = new BufferedImage(w, h, BufferedImage.TYPE_INT_RGB);
			img.setRGB(0, 0, w, h, px, 0, w);
			final File out = new File(DIR, String.format("chatreloc-%s-%dx%d.png", mode, w, h));
			javax.imageio.ImageIO.write(img, "png", out);
			log.info("[chatreloc] captured {} ({}x{})", out.getName(), w, h);
		}
		catch (Exception ex)
		{
			log.warn("[chatreloc] capture failed: {}", String.valueOf(ex));
		}
	}

	private static void synthClickCentre(Client c)
	{
		final Canvas canvas = c.getCanvas();
		if (canvas == null)
		{
			return;
		}
		final int x = c.getCanvasWidth() / 2;
		final int y = c.getCanvasHeight() / 2;
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		if (!focused)
		{
			q.postEvent(new FocusEvent(canvas, FocusEvent.FOCUS_GAINED, false, null));
			q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_ENTERED, t, 0, x, y, 0, false));
			focused = true;
		}
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, t + 1, 0, x, y, 0, false));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_PRESSED, t + 2,
			InputEvent.BUTTON1_DOWN_MASK, x, y, 1, false, MouseEvent.BUTTON1));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_RELEASED, t + 3, 0, x, y, 1, false, MouseEvent.BUTTON1));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_CLICKED, t + 4, 0, x, y, 1, false, MouseEvent.BUTTON1));
	}
}
