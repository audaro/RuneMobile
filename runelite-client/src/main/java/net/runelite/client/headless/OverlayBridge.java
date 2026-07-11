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

import java.awt.Point;
import java.awt.Rectangle;
import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.client.RuneLite;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.plugins.PluginManager;
import net.runelite.client.ui.overlay.Overlay;
import net.runelite.client.ui.overlay.OverlayManager;
import net.runelite.client.ui.overlay.OverlayPosition;

/**
 * Native-UI bridge that drives an overlay <b>edit mode</b> for the mobile ports. On desktop, overlays are
 * repositioned by Alt-dragging them around the canvas and dropping them onto snap corners; touch has no
 * Alt-drag, so the native shell instead presents an explicit edit mode and calls into this bridge to enumerate
 * the movable overlays, push a new preferred location / snap corner, and reset an overlay to its default.
 *
 * <p>Unlike the plugin-hub bridges, {@link OverlayManager} and {@link Overlay} are <em>core</em> client
 * classes, so reads and mutations use direct typed calls. The single exception is enumerating the live overlay
 * collection: {@code OverlayManager.getOverlays()} is package-private to {@code net.runelite.client.ui.overlay},
 * so we read that one field reflectively (cached once). Everything else is a normal compile-time call.
 *
 * <p>{@link OverlayManager} is not injected into bridges, so it is resolved lazily from the Guice injector the
 * same way {@code MobileUiBridge.ensureHubInjected} resolves the plugin-hub services, and cached once startup
 * has progressed far enough for the injector to exist.
 *
 * <p>Reads run on the {@link ClientThread} via {@link #tick(Client)} (called from {@code MobileUiBridge.tick},
 * already on the client thread) while the native edit screen is open ({@link #setUiOpen(boolean)}), caching a
 * {@code volatile} JSON snapshot the native thread reads lock-free. Writes (move / snap / reset, all of which
 * mutate overlay state and persist it through {@code ConfigManager}) are queued onto the client thread.
 */
@Slf4j
public final class OverlayBridge
{
	private static volatile ClientThread clientThread;

	// Resolved lazily from the injector once startup is far enough along; cached after the first success.
	private static volatile OverlayManager overlayManager;
	// OverlayManager.overlays is package-private; read it reflectively (cached).
	private static volatile Field overlaysField;

	// Cached snapshot (built on the client thread, read off-thread).
	private static volatile String overlaysJson = "{\"available\":false}";
	private static volatile boolean uiOpen;
	private static long lastRefresh;

	private OverlayBridge()
	{
	}

	/**
	 * Wired the same way as the other mobile bridges. Only the {@link ClientThread} is stored here; the
	 * {@link OverlayManager} is resolved lazily (it is not available this early). {@code pm} is accepted to
	 * match the bridge wiring convention even though this bridge does not need it.
	 */
	public static void init(PluginManager pm, ClientThread ct)
	{
		clientThread = ct;
	}

	/** Whether the native shell should offer overlay edit mode (the overlay manager has been resolved). */
	public static boolean isAvailable()
	{
		return ensureResolved();
	}

	/** The native screen tells us when it is on-screen so we only pay the client-thread refresh while shown. */
	public static void setUiOpen(boolean open)
	{
		uiOpen = open;
		if (open)
		{
			lastRefresh = 0; // force an immediate refresh on the next tick
		}
	}

	/**
	 * Snapshot of the overlays the user can reposition, as JSON:
	 * <pre>
	 * {"available":true,"overlays":[
	 *   {"name":"XpInfoBoxOverlay","bounds":[x,y,w,h],"position":"TOP_LEFT",
	 *    "movable":true,"snappable":true,"resizable":false,"dynamic":false}, ...]}
	 * </pre>
	 * Only overlays that are movable and have a real name and non-empty bounds are listed. Refreshed on
	 * {@link #tick(Client)} while the native edit screen is open.
	 */
	public static String getOverlaysJson()
	{
		return overlaysJson;
	}

	/**
	 * Move {@code name} to an explicit pixel location and persist it. Setting a preferred location also implies
	 * a free (non-snapped) position, so the preferred snap position is cleared. Runs on the client thread.
	 */
	public static String setOverlayPreferredLocation(String name, int x, int y)
	{
		final ClientThread ct = clientThread;
		if (name == null || ct == null || !ensureResolved())
		{
			return ack(name, false, "unavailable");
		}
		ct.invokeLater(() ->
		{
			final Overlay overlay = findOverlay(name);
			if (overlay == null || !overlay.isMovable())
			{
				return;
			}
			try
			{
				overlay.setPreferredPosition(null);
				overlay.setPreferredLocation(new Point(x, y));
				overlayManager.saveOverlay(overlay);
				lastRefresh = 0;
			}
			catch (Throwable ex)
			{
				BridgeFaults.note("OverlayBridge.setOverlayPreferredLocation", ex);
				log.debug("[overlay] setPreferredLocation failed for {}", name, ex);
			}
		});
		return ack(name, true, null);
	}

	/**
	 * Snap {@code name} to a corner by {@link OverlayPosition} name (e.g. {@code "TOP_LEFT"}) and persist it.
	 * Snapping to a corner clears any free preferred location. Runs on the client thread.
	 */
	public static String setOverlayPreferredPosition(String name, String positionName)
	{
		final ClientThread ct = clientThread;
		if (name == null || positionName == null || ct == null || !ensureResolved())
		{
			return ack(name, false, "unavailable");
		}
		final OverlayPosition position = parsePosition(positionName);
		if (position == null)
		{
			return ack(name, false, "bad-position");
		}
		ct.invokeLater(() ->
		{
			final Overlay overlay = findOverlay(name);
			if (overlay == null || !overlay.isSnappable())
			{
				return;
			}
			try
			{
				overlay.setPreferredLocation(null);
				overlay.setPreferredPosition(position);
				overlayManager.saveOverlay(overlay);
				lastRefresh = 0;
			}
			catch (Throwable ex)
			{
				BridgeFaults.note("OverlayBridge.setOverlayPreferredPosition", ex);
				log.debug("[overlay] setPreferredPosition failed for {}", name, ex);
			}
		});
		return ack(name, true, null);
	}

	/** Reset {@code name} to its default position / size / location and persist the reset. Client thread. */
	public static String resetOverlay(String name)
	{
		final ClientThread ct = clientThread;
		if (name == null || ct == null || !ensureResolved())
		{
			return ack(name, false, "unavailable");
		}
		ct.invokeLater(() ->
		{
			final Overlay overlay = findOverlay(name);
			if (overlay == null)
			{
				return;
			}
			try
			{
				overlayManager.resetOverlay(overlay);
				lastRefresh = 0;
			}
			catch (Throwable ex)
			{
				BridgeFaults.note("OverlayBridge.resetOverlay", ex);
				log.debug("[overlay] resetOverlay failed for {}", name, ex);
			}
		});
		return ack(name, true, null);
	}

	/**
	 * Returns the name of the nearest snap-corner {@link OverlayPosition} for a dropped point, so native edit
	 * mode can show a snap preview while the finger drags. The canvas is divided into a 2x3 grid of corners
	 * (top / bottom rows x left / center / right columns); we pick the row by which half of the height the
	 * point is in, and the column by which third of the width it is in. This mirrors the five real snap
	 * corners the desktop renderer uses (TOP_LEFT / TOP_CENTER / TOP_RIGHT / BOTTOM_LEFT / BOTTOM_RIGHT);
	 * BOTTOM_CENTER is not a snap corner, so the bottom-center third also resolves to BOTTOM_LEFT to match.
	 *
	 * @param x        dropped point x in canvas pixels
	 * @param y        dropped point y in canvas pixels
	 * @param canvasW  canvas width in pixels
	 * @param canvasH  canvas height in pixels
	 * @return the {@link OverlayPosition} name, defaulting to {@code TOP_LEFT} for a degenerate canvas
	 */
	public static String snapPositionForPoint(int x, int y, int canvasW, int canvasH)
	{
		if (canvasW <= 0 || canvasH <= 0)
		{
			return OverlayPosition.TOP_LEFT.name();
		}
		final boolean top = y < canvasH / 2;
		// Column: left third / center third / right third.
		final int third = canvasW / 3;
		final boolean left = x < third;
		final boolean right = x >= third * 2;

		if (top)
		{
			if (left)
			{
				return OverlayPosition.TOP_LEFT.name();
			}
			if (right)
			{
				return OverlayPosition.TOP_RIGHT.name();
			}
			return OverlayPosition.TOP_CENTER.name();
		}
		// Bottom row: only left and right are real snap corners.
		return right ? OverlayPosition.BOTTOM_RIGHT.name() : OverlayPosition.BOTTOM_LEFT.name();
	}

	/**
	 * Client-thread refresh (called each frame from {@code MobileUiBridge.tick}). Only rebuilds while the
	 * native edit screen is open, on a slow cadence (bounds change as the user moves overlays).
	 */
	public static void tick(Client client)
	{
		if (!uiOpen || client == null || !ensureResolved())
		{
			return;
		}
		final long now = System.currentTimeMillis();
		if (now - lastRefresh > 700)
		{
			lastRefresh = now;
			rebuild();
		}
	}

	// ---- snapshot (client thread) ----------------------------------------------------------------------

	private static void rebuild()
	{
		try
		{
			final StringBuilder sb = new StringBuilder(4096);
			sb.append("{\"available\":true,\"overlays\":[");
			boolean first = true;
			for (Overlay overlay : currentOverlays())
			{
				try
				{
					if (overlay == null || !overlay.isMovable())
					{
						continue;
					}
					final String name = overlay.getName();
					if (name == null || name.isEmpty())
					{
						continue;
					}
					final Rectangle b = overlay.getBounds();
					if (b == null || (b.width <= 0 && b.height <= 0))
					{
						continue; // no real bounds yet (e.g. overlay not currently rendered)
					}
					final OverlayPosition pos = overlay.getPreferredPosition() != null
						? overlay.getPreferredPosition()
						: overlay.getPosition();
					if (!first)
					{
						sb.append(',');
					}
					first = false;
					sb.append('{')
						.append("\"name\":").append(BridgeJson.quoted(name)).append(',')
						.append("\"bounds\":[").append(b.x).append(',').append(b.y).append(',')
						.append(b.width).append(',').append(b.height).append("],")
						.append("\"position\":").append(BridgeJson.quoted(pos == null ? "" : pos.name())).append(',')
						.append("\"movable\":").append(overlay.isMovable()).append(',')
						.append("\"snappable\":").append(overlay.isSnappable()).append(',')
						.append("\"resizable\":").append(overlay.isResizable()).append(',')
						.append("\"dynamic\":").append(pos == OverlayPosition.DYNAMIC || pos == OverlayPosition.DETACHED)
						.append('}');
				}
				catch (Throwable perOverlay)
				{
					// one bad overlay must not drop the whole list
				}
			}
			sb.append("]}");
			overlaysJson = sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("OverlayBridge.rebuild", ex);
			overlaysJson = "{\"available\":false}";
		}
	}

	private static Overlay findOverlay(String name)
	{
		if (name == null)
		{
			return null;
		}
		for (Overlay overlay : currentOverlays())
		{
			try
			{
				if (overlay != null && name.equals(overlay.getName()))
				{
					return overlay;
				}
			}
			catch (Throwable ignore)
			{
			}
		}
		return null;
	}

	// ---- resolution ------------------------------------------------------------------------------------

	private static boolean ensureResolved()
	{
		if (overlayManager != null)
		{
			return true;
		}
		try
		{
			final com.google.inject.Injector inj = RuneLite.getInjector();
			if (inj == null)
			{
				return false; // startup hasn't reached the injector yet; retry on the next call
			}
			final OverlayManager om = inj.getInstance(OverlayManager.class);
			if (om == null)
			{
				return false;
			}
			final Field f = OverlayManager.class.getDeclaredField("overlays");
			f.setAccessible(true);
			overlaysField = f;
			overlayManager = om;
			log.info("[overlay] native bridge resolved");
			return true;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("OverlayBridge.ensureResolved", ex);
			return false;
		}
	}

	/**
	 * The manager's live overlay list. {@code OverlayManager.getOverlays()} is package-private, so the backing
	 * field is read reflectively. A defensive copy is returned so the caller never iterates the manager's list
	 * without its lock.
	 */
	@SuppressWarnings("unchecked")
	private static List<Overlay> currentOverlays()
	{
		final OverlayManager om = overlayManager;
		final Field f = overlaysField;
		if (om == null || f == null)
		{
			return new ArrayList<>();
		}
		try
		{
			synchronized (om)
			{
				final Object value = f.get(om);
				if (value instanceof List)
				{
					return new ArrayList<>((List<Overlay>) value);
				}
			}
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("OverlayBridge.currentOverlays", ex);
		}
		return new ArrayList<>();
	}

	private static OverlayPosition parsePosition(String name)
	{
		try
		{
			return OverlayPosition.valueOf(name.trim().toUpperCase());
		}
		catch (Throwable ignore)
		{
			return null;
		}
	}

	// ---- json ------------------------------------------------------------------------------------------

	private static String ack(String name, boolean ok, String error)
	{
		final StringBuilder sb = new StringBuilder(64);
		sb.append("{\"ok\":").append(ok).append(",\"name\":").append(BridgeJson.quoted(name));
		if (error != null)
		{
			sb.append(",\"error\":").append(BridgeJson.quoted(error));
		}
		sb.append('}');
		return sb.toString();
	}

}
