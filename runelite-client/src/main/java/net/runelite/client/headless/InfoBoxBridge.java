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

import java.util.List;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.client.RuneLite;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.eventbus.EventBus;
import net.runelite.client.events.InfoBoxMenuClicked;
import net.runelite.client.plugins.PluginManager;
import net.runelite.client.ui.overlay.OverlayMenuEntry;
import net.runelite.client.ui.overlay.infobox.InfoBox;
import net.runelite.client.ui.overlay.infobox.InfoBoxManager;

/**
 * Native-UI bridge that gives the mobile shell a way to <b>right-click an infobox</b> — touch has no
 * right mouse button, so the native shell long-presses an infobox to bring up its menu (the generic
 * {@code Detach}/{@code Flip}/{@code Delete} options the {@link InfoBoxManager} attaches, plus any
 * plugin-specific options an infobox adds to its own menu) and invokes one. Audit finding #20.
 *
 * <p>These are <b>core</b> classes (the infobox subsystem ships with this client), so access is by
 * direct typed calls. The one thing the bridge cannot get by construction is the {@link InfoBoxManager}
 * singleton at {@code init} time without changing the shared init signature, so it is resolved lazily
 * from the Guice injector and cached (the {@link WorldSwitcherBridge} pattern).
 *
 * <p><b>Bounds vs index.</b> Per-infobox screen bounds are computed at render time inside
 * {@code InfoBoxOverlay.render()} (it builds transient {@code InfoBoxComponent}s, reads their bounds
 * for tooltip hit-testing, then calls {@code panelComponent.getChildren().clear()} at the end of the
 * frame). Bounds are never stored on the {@link InfoBox} itself and the component list is wiped every
 * frame, so there is no clean, lock-free way to retrieve per-infobox screen bounds off the client
 * thread. We therefore <b>scope down to index-based</b>: the bridge exposes the ordered infobox list
 * (the same order {@link InfoBoxManager#getInfoBoxes()} returns) each with its menu options, and the
 * native side — which already knows where it drew each infobox row and which one the user long-pressed
 * — renders the menu and calls back with the chosen {@code (index, option)}. No
 * {@code infoBoxAtPoint(x,y)} is exposed.
 *
 * <p>Reads run on the {@link ClientThread} via {@link #tick(Client)} (called from
 * {@code MobileUiBridge.tick}, already on the client thread) and are cached into volatile JSON the
 * native thread reads lock-free, only while the native menu is shown ({@link #setUiOpen(boolean)}).
 * The invoke action queues onto the client thread and replicates exactly what the desktop right-click
 * does: it posts an {@link InfoBoxMenuClicked} on the {@link EventBus} (so {@code InfoBoxManager} and
 * any subscribing plugin handle it identically) and, for entries that carry one, fires the
 * {@link OverlayMenuEntry} callback.
 */
@Slf4j
public final class InfoBoxBridge
{
	private static volatile PluginManager pluginManager;
	private static volatile ClientThread clientThread;
	private static volatile InfoBoxManager infoBoxManager;
	private static volatile EventBus eventBus;

	// Cached snapshot (built on the client thread, read off-thread).
	private static volatile String json = "{\"available\":false}";
	private static volatile boolean uiOpen;
	private static long lastRefresh;

	private InfoBoxBridge()
	{
	}

	public static void init(PluginManager pm, ClientThread ct)
	{
		pluginManager = pm;
		clientThread = ct;
	}

	/** Lazily resolve (and cache) the {@link InfoBoxManager} singleton from the Guice injector. */
	private static InfoBoxManager infoBoxManager()
	{
		InfoBoxManager m = infoBoxManager;
		if (m == null)
		{
			try
			{
				m = RuneLite.getInjector().getInstance(InfoBoxManager.class);
				infoBoxManager = m;
			}
			catch (Throwable ignore)
			{
				BridgeFaults.note("InfoBoxBridge.infoBoxManager", ignore);
			}
		}
		return m;
	}

	/** Lazily resolve (and cache) the {@link EventBus} from the Guice injector. */
	private static EventBus eventBus()
	{
		EventBus eb = eventBus;
		if (eb == null)
		{
			try
			{
				eb = RuneLite.getInjector().getInstance(EventBus.class);
				eventBus = eb;
			}
			catch (Throwable ignore)
			{
				BridgeFaults.note("InfoBoxBridge.eventBus", ignore);
			}
		}
		return eb;
	}

	/** Whether the native shell can offer the infobox long-press menu (manager resolvable). */
	public static boolean isAvailable()
	{
		return infoBoxManager() != null;
	}

	/** The native menu tells us when it is on-screen so we only pay the client-thread refresh while shown. */
	public static void setUiOpen(boolean open)
	{
		uiOpen = open;
		if (open)
		{
			lastRefresh = 0; // force an immediate refresh on next tick
		}
	}

	/**
	 * The live infoboxes (ordered as {@link InfoBoxManager#getInfoBoxes()}), each with its menu-entry
	 * option texts:
	 * {@code {"available":true,"infoboxes":[{"index":N,"name":..,"text":..,"tooltip":..,"menu":["Detach",..]}]}}.
	 * Refreshed on tick while the native menu is open.
	 */
	public static String getInfoBoxesJson()
	{
		return json;
	}

	/**
	 * Fire the infobox menu action the native shell selected after a long-press — the touch equivalent of
	 * clicking that right-click menu entry on desktop. Runs on the client thread; resolves the infobox by
	 * its current list index, matches the {@link OverlayMenuEntry} by option text, posts an
	 * {@link InfoBoxMenuClicked} (handled by {@code InfoBoxManager} and any subscribing plugin exactly as on
	 * desktop), and fires the entry callback if it carries one. Returns a JSON ack.
	 *
	 * @return {@code {"ok":true}} once queued, or {@code {"ok":false,"error":..}} if it cannot be queued
	 */
	public static String invokeInfoBoxMenu(int index, String option)
	{
		final ClientThread ct = clientThread;
		if (ct == null)
		{
			return "{\"ok\":false,\"error\":\"no client thread\"}";
		}
		if (option == null)
		{
			return "{\"ok\":false,\"error\":\"no option\"}";
		}
		ct.invokeLater(() -> doInvoke(index, option));
		lastRefresh = 0; // the action may add/remove/move infoboxes — refresh promptly
		return "{\"ok\":true}";
	}

	// ---- client thread -----------------------------------------------------------------------------------

	private static void doInvoke(int index, String option)
	{
		try
		{
			final InfoBoxManager mgr = infoBoxManager();
			if (mgr == null)
			{
				return;
			}
			final List<InfoBox> boxes = mgr.getInfoBoxes();
			if (boxes == null || index < 0 || index >= boxes.size())
			{
				log.debug("[infobox] invoke: stale index {} (size {})", index, boxes == null ? -1 : boxes.size());
				return;
			}
			final InfoBox box = boxes.get(index);
			final OverlayMenuEntry entry = findEntry(box, option);
			if (entry == null)
			{
				log.debug("[infobox] invoke: option '{}' not on infobox {}", option, index);
				return;
			}

			// Replicate the desktop right-click path exactly: for a RUNELITE_INFOBOX entry,
			// InfoBoxOverlay.onMenuOptionClicked posts this event, which InfoBoxManager (Detach/Flip/Delete)
			// and any subscribing plugin handle. Infobox menu entries are routed via this event (not via the
			// OverlayMenuEntry callback, which is only used for non-infobox overlay menus), so posting the
			// event is the complete equivalent.
			final EventBus eb = eventBus();
			if (eb != null)
			{
				eb.post(new InfoBoxMenuClicked(entry, box));
			}
			else
			{
				log.debug("[infobox] invoke: no event bus");
			}
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("InfoBoxBridge.doInvoke", ex);
		}
	}

	private static OverlayMenuEntry findEntry(InfoBox box, String option)
	{
		final List<OverlayMenuEntry> entries = box.getMenuEntries();
		if (entries == null)
		{
			return null;
		}
		for (OverlayMenuEntry e : entries)
		{
			if (e != null && option.equals(e.getOption()))
			{
				return e;
			}
		}
		return null;
	}

	/**
	 * Client-thread refresh (called each frame from {@code MobileUiBridge.tick}). Only works while the
	 * native menu is open; rebuilds the infobox snapshot on a light cadence.
	 */
	public static void tick(Client client)
	{
		if (!uiOpen || client == null)
		{
			return;
		}
		final long now = System.currentTimeMillis();
		if (now - lastRefresh > 500)
		{
			lastRefresh = now;
			rebuild();
		}
	}

	private static void rebuild()
	{
		final InfoBoxManager mgr = infoBoxManager();
		if (mgr == null)
		{
			json = "{\"available\":false}";
			return;
		}
		try
		{
			final List<InfoBox> boxes = mgr.getInfoBoxes();
			final StringBuilder sb = new StringBuilder(2048);
			sb.append("{\"available\":true,\"infoboxes\":[");
			boolean first = true;
			for (int i = 0; i < boxes.size(); i++)
			{
				final InfoBox box = boxes.get(i);
				if (box == null)
				{
					continue;
				}
				try
				{
					if (!first)
					{
						sb.append(',');
					}
					first = false;
					sb.append("{\"index\":").append(i)
						.append(",\"name\":").append(BridgeJson.quoted(safe(box.getName())))
						.append(",\"text\":").append(BridgeJson.quoted(safe(box.getText())))
						.append(",\"tooltip\":").append(BridgeJson.quoted(safe(box.getTooltip())))
						.append(",\"menu\":[");
					appendMenu(sb, box.getMenuEntries());
					sb.append("]}");
				}
				catch (Throwable perBox)
				{
					// one bad infobox must not drop the whole list
				}
			}
			sb.append("]}");
			json = sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("InfoBoxBridge.rebuild", ex);
			json = "{\"available\":false}";
		}
	}

	private static void appendMenu(StringBuilder sb, List<OverlayMenuEntry> entries)
	{
		if (entries == null)
		{
			return;
		}
		boolean first = true;
		for (OverlayMenuEntry e : entries)
		{
			if (e == null)
			{
				continue;
			}
			final String option = e.getOption();
			if (option == null || option.isEmpty())
			{
				continue;
			}
			if (!first)
			{
				sb.append(',');
			}
			first = false;
			sb.append(BridgeJson.quoted(option));
		}
	}

	private static String safe(String s)
	{
		return s == null ? "" : s;
	}

}
