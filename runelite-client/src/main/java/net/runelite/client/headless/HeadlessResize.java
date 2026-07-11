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

import java.awt.Component;
import java.awt.Container;
import java.awt.Dimension;
import java.awt.EventQueue;
import java.awt.Frame;
import java.awt.Insets;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GameState;

/**
 * Phase-5 (W3) resizable de-risk: drive the headless gamepack {@code Component} to an arbitrary
 * {@code WxH} after login so we can verify the CACIO CTC canvas + {@code MainBufferProvider} resize to
 * that size (the one unproven step on the road to a full-screen landscape render).
 *
 * <p>The classic OSRS canvas is {@code 765x503}. To fill a wide phone screen we render at the screen's
 * aspect; the open question (flagged in the Phase-5 review) is whether CTC supports a live canvas resize
 * headless at all. This helper isolates exactly that: when {@code -Drunelite.headless.resize=WxH} is set,
 * once the client reaches {@link GameState#LOGGED_IN} it resizes the gamepack {@code Component} (and its
 * realized ancestors) to {@code WxH} a single time, then logs the canvas + framebuffer dimensions for the
 * following frames so we can see (against verbatim device/desktop logs) whether the buffer actually grew.
 *
 * <p>Resizing the <em>canvas</em> is independent of the gamepack's fixed-vs-resizable display mode: in
 * fixed mode the engine centres the 765x503 viewport in the larger buffer (brown border); in resizable
 * mode it fills it. Either way {@code MainBufferProvider} should become {@code WxH} — which is what this
 * proves. Entirely inert unless the property is set.
 */
@Slf4j
public final class HeadlessResize
{
	private static final String SIZE = System.getProperty("runelite.headless.resize");
	private static final boolean ENABLED = SIZE != null && SIZE.contains("x");

	private static int targetW;
	private static int targetH;
	private static boolean applied;
	private static int logFrames;

	static
	{
		if (ENABLED)
		{
			int w = 0;
			int h = 0;
			try
			{
				final String[] parts = SIZE.split("x", 2);
				w = Integer.parseInt(parts[0].trim());
				h = Integer.parseInt(parts[1].trim());
			}
			catch (RuntimeException ex)
			{
				log.warn("[headless-resize] bad runelite.headless.resize '{}' (want WxH)", SIZE);
			}
			targetW = w;
			targetH = h;
			log.info("[headless-resize] ENABLED target={}x{}", targetW, targetH);
		}
	}

	private HeadlessResize()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/** Called once per {@code Hooks.draw} (only when enabled). Resizes once on reaching LOGGED_IN. */
	public static void tick(Client client, GameState state)
	{
		if (!ENABLED || targetW <= 0 || targetH <= 0)
		{
			return;
		}
		if (!applied)
		{
			if (state != GameState.LOGGED_IN)
			{
				return;
			}
			applied = true;
			final Component comp = (Component) client;
			final Dimension d = new Dimension(targetW, targetH);
			EventQueue.invokeLater(() ->
			{
				try
				{
					// The gamepack Component sits in the Frame's BorderLayout.CENTER, so on validate the
					// layout stretches it to the Frame's content area (frame size minus insets) — NOT to
					// comp.setSize(). To land the canvas EXACTLY on targetW x targetH (so its aspect matches
					// the screen and the blit fills with no bars), size the FRAME to target + insets.
					comp.setMinimumSize(d);
					comp.setPreferredSize(d);
					Container top = comp.getParent();
					while (top != null && top.getParent() != null)
					{
						top = top.getParent();
					}
					if (top instanceof Frame)
					{
						final Insets ins = top.getInsets();
						top.setSize(targetW + ins.left + ins.right, targetH + ins.top + ins.bottom);
						top.validate();
						log.info("[headless-resize] requested {}x{}: frame insets {},{},{},{} -> component now {}x{}, canvas {}",
							targetW, targetH, ins.top, ins.left, ins.bottom, ins.right,
							comp.getWidth(), comp.getHeight(), client.getCanvas());
					}
					else
					{
						comp.setSize(d);
						log.info("[headless-resize] requested {}x{}: no Frame ancestor, comp set to {}x{}, canvas {}",
							targetW, targetH, comp.getWidth(), comp.getHeight(), client.getCanvas());
					}
				}
				catch (RuntimeException ex)
				{
					log.warn("[headless-resize] resize failed", ex);
				}
			});
		}
		else if (logFrames < 8)
		{
			logFrames++;
			log.info("[headless-resize] post-resize frame {}: canvas={}x{} viewport={}x{}",
				logFrames, client.getCanvas() != null ? client.getCanvas().getWidth() : -1,
				client.getCanvas() != null ? client.getCanvas().getHeight() : -1,
				client.getViewportWidth(), client.getViewportHeight());
		}
	}
}
