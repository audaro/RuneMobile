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

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GrandExchangeOffer;
import net.runelite.api.GrandExchangeOfferState;
import net.runelite.api.ItemComposition;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginManager;

/**
 * Native-UI data bridge for the <b>Grand Exchange</b> panel — the shared-core data feed the mobile shell uses
 * to reflow the eight GE slots (and the saved trade history) into real native controls instead of rendering the
 * Swing side panel as a flat image. Unlike {@link QuestHelperBridge}, the live offers are part of the core
 * engine API ({@link Client#getGrandExchangeOffers()}), so the slot data is read with <b>direct typed access</b>
 * and only the plugin's private trade-history config (stored per-RS-profile) is reached by reflection.
 *
 * <p>GE offers must be read on the <b>client thread</b> — {@link #tick(Client)} (called from
 * {@code MobileUiBridge.tick}, already on the client thread) does the reads and caches a JSON snapshot into a
 * {@code volatile} field the native thread reads lock-free, the same pattern the rest of the mobile-UI facade
 * uses. Refresh only runs while the native GE screen is open ({@link #setUiOpen(boolean)}). Item names resolve
 * through {@link Client#getItemDefinition(int)} (also a client-thread read).
 *
 * <p>Every read is defensive: if an offer, item, or the reflected history shape is unavailable we skip it and
 * still publish whatever resolved, so the native side always gets a well-formed payload.
 */
@Slf4j
public final class GrandExchangeBridge
{
	private static final String PLUGIN_CLASS = "net.runelite.client.plugins.grandexchange.GrandExchangePlugin";
	private static final String CONFIG_GROUP = "grandexchange";
	private static final String TRADE_HISTORY_KEY = "tradeHistory";
	private static final int GE_SLOTS = 8;
	private static final int MAX_HISTORY = 50;

	private static final int MAX_SEARCH_RESULTS = 60;

	private static volatile PluginManager pluginManager;
	private static volatile ClientThread clientThread;

	// Resolved lazily from the injector the first time the native Search tab runs a query.
	private static volatile net.runelite.client.game.ItemManager itemManager;

	// Reflection handles for the plugin's private trade-history config. resolveState: 0 unknown, 1 ok, -1 absent.
	private static volatile int resolveState;
	private static Object plugin;
	private static Object configManager;
	private static Method mGetRSProfileConfiguration;

	// Cached snapshot (built on the client thread, read off-thread).
	private static volatile String geJson = "{\"available\":false}";
	private static volatile boolean uiOpen;
	private static long lastRefresh;

	private GrandExchangeBridge()
	{
	}

	public static void init(PluginManager pm, ClientThread ct)
	{
		pluginManager = pm;
		clientThread = ct;
	}

	/** Whether the native shell should offer the native Grand Exchange screen (the GE plugin is loaded). */
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
			lastRefresh = 0; // force an immediate refresh on next tick
		}
	}

	public static String getGeJson()
	{
		return geJson;
	}

	/**
	 * Tradeable-item name search for the native GE <b>Search</b> tab — the desktop plugin's search box only fires
	 * on Enter (no live filtering) and we cannot fork the plugin, so the native screen drives this directly. Returns
	 * {@code {"results":[{"id","name","price"}]}} (price = the GE guide price), capped at {@link #MAX_SEARCH_RESULTS}.
	 * Safe to call off the client thread: {@link net.runelite.client.game.ItemManager#search(String)} only scans the
	 * immutable price cache (no engine read). Empty/short queries and an unresolved cache both yield an empty list.
	 */
	public static String search(String query)
	{
		if (query == null)
		{
			return "{\"results\":[]}";
		}
		final String q = query.trim();
		if (q.length() < 2)
		{
			return "{\"results\":[]}";
		}
		try
		{
			final net.runelite.client.game.ItemManager im = ensureItemManager();
			if (im == null)
			{
				return "{\"results\":[]}";
			}
			final java.util.List<net.runelite.http.api.item.ItemPrice> hits = im.search(q);
			final StringBuilder sb = new StringBuilder(2048);
			sb.append("{\"results\":[");
			int n = 0;
			if (hits != null)
			{
				for (net.runelite.http.api.item.ItemPrice ip : hits)
				{
					if (ip == null)
					{
						continue;
					}
					if (n >= MAX_SEARCH_RESULTS)
					{
						break;
					}
					if (n > 0)
					{
						sb.append(',');
					}
					sb.append('{')
						.append("\"id\":").append(ip.getId()).append(',')
						.append("\"name\":").append(BridgeJson.quoted(ip.getName())).append(',')
						.append("\"price\":").append(ip.getPrice())
						.append('}');
					n++;
				}
			}
			sb.append("]}");
			return sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("GrandExchangeBridge.search", ex);
			return "{\"results\":[]}";
		}
	}

	private static net.runelite.client.game.ItemManager ensureItemManager()
	{
		net.runelite.client.game.ItemManager im = itemManager;
		if (im != null)
		{
			return im;
		}
		try
		{
			final com.google.inject.Injector inj = net.runelite.client.RuneLite.getInjector();
			if (inj != null)
			{
				im = inj.getInstance(net.runelite.client.game.ItemManager.class);
				itemManager = im;
			}
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("GrandExchangeBridge.ensureItemManager", ex);
		}
		return im;
	}

	/**
	 * Client-thread refresh (called each frame from {@code MobileUiBridge.tick}). Only works while the native
	 * screen is open; rebuilds the eight-slot snapshot (plus saved history) on a modest cadence.
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
			rebuild(client);
		}
	}

	// ---- snapshot (client thread) ----------------------------------------------------------------------

	private static void rebuild(Client client)
	{
		try
		{
			final StringBuilder sb = new StringBuilder(4096);
			sb.append("{\"available\":true,\"offers\":[");

			final GrandExchangeOffer[] offers = client.getGrandExchangeOffers();
			boolean first = true;
			final int count = offers == null ? 0 : Math.min(offers.length, GE_SLOTS);
			for (int slot = 0; slot < count; slot++)
			{
				final GrandExchangeOffer offer = offers[slot];
				if (offer == null)
				{
					continue;
				}
				try
				{
					final GrandExchangeOfferState state = offer.getState();
					if (state == null || state == GrandExchangeOfferState.EMPTY)
					{
						continue; // skip empty slots; the native side fills the grid from "slot"
					}
					final int itemId = offer.getItemId();
					final int qty = offer.getQuantitySold();
					final int total = offer.getTotalQuantity();
					final int price = offer.getPrice();
					final int spent = offer.getSpent();
					final double progress = total > 0 ? Math.max(0.0, Math.min(1.0, (double) qty / total)) : 0.0;

					if (!first)
					{
						sb.append(',');
					}
					first = false;
					sb.append('{')
						.append("\"slot\":").append(slot).append(',')
						.append("\"state\":").append(BridgeJson.quoted(state.name())).append(',')
						.append("\"itemId\":").append(itemId).append(',')
						.append("\"name\":").append(BridgeJson.quoted(itemName(client, itemId))).append(',')
						.append("\"qty\":").append(qty).append(',')
						.append("\"total\":").append(total).append(',')
						.append("\"price\":").append(price).append(',')
						.append("\"spent\":").append(spent).append(',')
						.append("\"progress\":").append(progress)
						.append('}');
				}
				catch (Throwable perOffer)
				{
					// one bad slot must not drop the whole snapshot
				}
			}
			sb.append(']');

			sb.append(",\"history\":[");
			appendHistory(sb, client);
			sb.append(']');

			sb.append('}');
			geJson = sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("GrandExchangeBridge.rebuild", ex);
			geJson = "{\"available\":false}";
		}
	}

	private static String itemName(Client client, int itemId)
	{
		try
		{
			final ItemComposition comp = client.getItemDefinition(itemId);
			if (comp != null)
			{
				final String name = comp.getMembersName();
				if (name != null && !name.isEmpty())
				{
					return name;
				}
			}
		}
		catch (Throwable ignore)
		{
		}
		return "";
	}

	// ---- saved trade history (reflected plugin config) -------------------------------------------------

	/**
	 * Append the plugin's saved trade history. The plugin stores it as a JSON array under the per-RS-profile
	 * config {@code grandexchange.tradeHistory} (key-abbreviated {@code Trade} records: b/buy, i/itemId,
	 * q/quantity, p/price, t/time). We read that raw string and parse the field-abbreviated records by hand so
	 * we do not depend on the package-private {@code Trade} type. If the config is absent we emit nothing.
	 */
	private static void appendHistory(StringBuilder sb, Client client)
	{
		final String raw = readTradeHistoryRaw();
		if (raw == null || raw.isEmpty())
		{
			return;
		}
		try
		{
			appendHistoryFromJson(sb, raw, client);
		}
		catch (Throwable ex)
		{
			log.debug("[grandexchange] history parse failed", ex);
		}
	}

	private static String readTradeHistoryRaw()
	{
		try
		{
			if (mGetRSProfileConfiguration == null || configManager == null)
			{
				return null;
			}
			final Object v = mGetRSProfileConfiguration.invoke(configManager, CONFIG_GROUP, TRADE_HISTORY_KEY);
			return v == null ? null : String.valueOf(v);
		}
		catch (Throwable ignore)
		{
			BridgeFaults.note("GrandExchangeBridge.readTradeHistoryRaw", ignore);
			return null;
		}
	}

	/**
	 * Minimal forward parser for the stored {@code List<Trade>} JSON. Each element is an object with the
	 * abbreviated keys {@code "b"} (buy), {@code "i"} (itemId), {@code "q"} (quantity), {@code "p"} (price) and
	 * {@code "t"} (ISO-8601 time). We extract those primitives and re-emit them in the public shape; on any
	 * malformed element we stop early with whatever we have. Newest records are last in storage, so we keep the
	 * trailing {@link #MAX_HISTORY}.
	 */
	private static void appendHistoryFromJson(StringBuilder out, String json, Client client)
	{
		// Collect parsed records first so we can keep only the most recent MAX_HISTORY.
		final java.util.ArrayDeque<String> records = new java.util.ArrayDeque<>();
		int i = 0;
		final int n = json.length();
		while (i < n)
		{
			// advance to the next object opener
			while (i < n && json.charAt(i) != '{')
			{
				i++;
			}
			if (i >= n)
			{
				break;
			}
			int depth = 0;
			final int objStart = i;
			while (i < n)
			{
				final char c = json.charAt(i);
				if (c == '"')
				{
					i = skipString(json, i);
					continue;
				}
				if (c == '{')
				{
					depth++;
				}
				else if (c == '}')
				{
					depth--;
					if (depth == 0)
					{
						i++;
						break;
					}
				}
				i++;
			}
			final String obj = json.substring(objStart, Math.min(i, n));
			final String rec = parseTradeObject(obj, client);
			if (rec != null)
			{
				records.addLast(rec);
				if (records.size() > MAX_HISTORY)
				{
					records.removeFirst();
				}
			}
		}

		boolean first = true;
		for (String rec : records)
		{
			if (!first)
			{
				out.append(',');
			}
			first = false;
			out.append(rec);
		}
	}

	/** Build one public history record from a single stored trade object, or {@code null} if unusable. */
	private static String parseTradeObject(String obj, Client client)
	{
		try
		{
			final String buy = rawValue(obj, "b");
			final String itemId = rawValue(obj, "i");
			final String qty = rawValue(obj, "q");
			final String price = rawValue(obj, "p");
			final String time = rawValue(obj, "t");
			if (itemId == null)
			{
				return null;
			}
			final long id = asLong(itemId, 0);
			final StringBuilder sb = new StringBuilder(96);
			sb.append('{')
				.append("\"buy\":").append("true".equals(buy)).append(',')
				.append("\"itemId\":").append(id).append(',')
				.append("\"name\":").append(BridgeJson.quoted(itemName(client, (int) id))).append(',')
				.append("\"qty\":").append(asLong(qty, 0)).append(',')
				.append("\"price\":").append(asLong(price, 0));
			if (time != null && !time.isEmpty())
			{
				sb.append(",\"time\":").append(BridgeJson.quoted(time));
			}
			sb.append('}');
			return sb.toString();
		}
		catch (Throwable ignore)
		{
			return null;
		}
	}

	/** Extract the raw token for {@code "key"} within a single flat JSON object (string contents unquoted). */
	private static String rawValue(String obj, String key)
	{
		final String needle = "\"" + key + "\"";
		int k = obj.indexOf(needle);
		if (k < 0)
		{
			return null;
		}
		int i = k + needle.length();
		// skip whitespace and the colon
		while (i < obj.length() && (obj.charAt(i) == ' ' || obj.charAt(i) == ':' || obj.charAt(i) == '\t'))
		{
			i++;
		}
		if (i >= obj.length())
		{
			return null;
		}
		if (obj.charAt(i) == '"')
		{
			final int end = skipString(obj, i);
			return unescapeSimple(obj.substring(i + 1, Math.max(i + 1, end - 1)));
		}
		final int start = i;
		while (i < obj.length())
		{
			final char c = obj.charAt(i);
			if (c == ',' || c == '}' || c == ' ' || c == '\t' || c == '\n' || c == '\r')
			{
				break;
			}
			i++;
		}
		return obj.substring(start, i);
	}

	/** Given an index at an opening quote, return the index just past the closing quote (escape-aware). */
	private static int skipString(String s, int quoteIndex)
	{
		int i = quoteIndex + 1;
		final int n = s.length();
		while (i < n)
		{
			final char c = s.charAt(i);
			if (c == '\\')
			{
				i += 2;
				continue;
			}
			if (c == '"')
			{
				return i + 1;
			}
			i++;
		}
		return n;
	}

	private static String unescapeSimple(String s)
	{
		if (s.indexOf('\\') < 0)
		{
			return s;
		}
		final StringBuilder sb = new StringBuilder(s.length());
		for (int i = 0; i < s.length(); i++)
		{
			final char c = s.charAt(i);
			if (c == '\\' && i + 1 < s.length())
			{
				final char d = s.charAt(++i);
				switch (d)
				{
					case 'n': sb.append('\n'); break;
					case 'r': sb.append('\r'); break;
					case 't': sb.append('\t'); break;
					default: sb.append(d);
				}
			}
			else
			{
				sb.append(c);
			}
		}
		return sb.toString();
	}

	private static long asLong(String s, long def)
	{
		if (s == null || s.isEmpty())
		{
			return def;
		}
		try
		{
			return Long.parseLong(s.trim());
		}
		catch (NumberFormatException ex)
		{
			return def;
		}
	}

	// ---- reflection resolution -------------------------------------------------------------------------

	private static boolean ensureResolved()
	{
		if (resolveState == 1)
		{
			return true;
		}
		// resolveState -1 means we looked and the plugin wasn't loaded; retry (plugins can load later).
		final PluginManager pm = pluginManager;
		if (pm == null)
		{
			return false;
		}
		try
		{
			Object found = null;
			for (Plugin p : pm.getPlugins())
			{
				if (PLUGIN_CLASS.equals(p.getClass().getName()))
				{
					found = p;
					break;
				}
			}
			if (found == null)
			{
				resolveState = -1;
				return false;
			}

			// The live slot data comes straight from the engine API, so the plugin only needs to yield its
			// injected ConfigManager for the (optional) saved trade history. If that read fails the bridge is
			// still "available" — we just omit history.
			try
			{
				final Object cm = readField(found, "configManager");
				if (cm != null)
				{
					final Method m = cm.getClass().getMethod("getRSProfileConfiguration", String.class, String.class);
					m.setAccessible(true);
					configManager = cm;
					mGetRSProfileConfiguration = m;
				}
			}
			catch (Throwable historyMiss)
			{
				log.debug("[grandexchange] trade-history config not reachable; offers only", historyMiss);
				configManager = null;
				mGetRSProfileConfiguration = null;
			}

			plugin = found;
			resolveState = 1;
			log.info("[grandexchange] native bridge resolved (history={})", mGetRSProfileConfiguration != null);
			return true;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("GrandExchangeBridge.ensureResolved", ex);
			resolveState = -1;
			return false;
		}
	}

	private static Object readField(Object target, String name) throws Exception
	{
		final Field f = target.getClass().getDeclaredField(name);
		f.setAccessible(true);
		return f.get(target);
	}

}
