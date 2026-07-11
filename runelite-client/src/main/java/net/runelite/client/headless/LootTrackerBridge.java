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
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginManager;

/**
 * Native-UI data bridge for the <b>Loot Tracker</b> panel — the shared-core data feed the mobile shell uses to
 * reflow the per-source loot logs into real native controls instead of rendering the Swing side panel as a flat
 * image. Loot Tracker is a <em>core</em> plugin (a compile dependency of this client), so unlike
 * {@link QuestHelperBridge} we would prefer direct typed access — but the data we need lives in package-private
 * classes ({@code LootTrackerPanel}, {@code LootTrackerRecord}, {@code LootTrackerItem}) with no public getter,
 * so the records are read by <b>reflection</b> into the plugin's private {@code panel} field and the panel's
 * private {@code aggregateRecords} map. Only the plugin instance itself ({@code LootTrackerPlugin}, public) is
 * located via {@link PluginManager#getPlugins()}, matched by class.
 *
 * <p>The {@code aggregateRecords} map already holds the panel's grouped-by-source aggregation (one record per
 * NPC/event, items merged by id and kills summed by {@code LootTrackerRecord.merge}), so this bridge just
 * snapshots that model — it does not re-implement the aggregation. Reads run on the <b>client thread</b>
 * ({@link #tick(Client)}, called from {@code MobileUiBridge.tick}, already on the client thread) and are cached
 * into a {@code volatile} field the native thread reads lock-free, the same snapshot pattern the rest of the
 * mobile-UI facade uses. Refresh only runs while the native Loot Tracker screen is open
 * ({@link #setUiOpen(boolean)}).
 *
 * <p>Every read is defensive: if the plugin is absent, a panel/record shape has moved, or a single record/item
 * is malformed, we skip just that entry and still publish whatever resolved, so the native side always gets a
 * well-formed payload (or {@code available:false} when nothing can be read).
 */
@Slf4j
public final class LootTrackerBridge
{
	private static final String PLUGIN_CLASS = "net.runelite.client.plugins.loottracker.LootTrackerPlugin";

	// Cap output so a long session can't produce an unbounded payload for the native side.
	private static final int MAX_SOURCES = 200;
	private static final int MAX_ITEMS_PER_SOURCE = 128;

	private static volatile PluginManager pluginManager;
	private static volatile ClientThread clientThread;

	// Reflection handles for the plugin's private panel + record/item model. resolveState: 0 unknown, 1 ok, -1 absent.
	private static volatile int resolveState;
	private static Object plugin;
	private static Field fPanel;            // LootTrackerPlugin.panel
	private static Field fAggregateRecords; // LootTrackerPanel.aggregateRecords
	private static Field fRecordTitle, fRecordSubTitle, fRecordType, fRecordItems, fRecordKills;
	private static Field fItemId, fItemName, fItemQuantity, fItemGePrice, fItemHaPrice;
	// Reset action: panel.clearRecords() (empties the in-memory model) + plugin.removeAllLoot() (deletes the
	// persisted RS-profile drops_* config so it doesn't reappear next boot) — mirrors the desktop "Reset All".
	private static Method mClearRecords, mRemoveAllLoot;

	// Cached snapshot (built on the client thread, read off-thread).
	private static volatile String lootJson = "{\"available\":false}";
	private static volatile boolean uiOpen;
	private static long lastRefresh;

	private LootTrackerBridge()
	{
	}

	public static void init(PluginManager pm, ClientThread ct)
	{
		pluginManager = pm;
		clientThread = ct;
	}

	/** Whether the native shell should offer the native Loot Tracker screen (plugin present + reflectable). */
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

	public static String getLootJson()
	{
		return lootJson;
	}

	/**
	 * Clear the entire loot log — the native equivalent of the desktop panel's "Reset All" (no detailed view):
	 * empties the in-memory aggregate/session records and deletes the persisted {@code drops_*} config so it
	 * does not reappear on the next boot. Runs on the client thread (matches the other write-bridges); the next
	 * {@link #tick(Client)} re-snapshots the now-empty model for the native side. Returns a JSON ack.
	 */
	public static String resetAll()
	{
		final ClientThread ct = clientThread;
		if (ct == null || !ensureResolved())
		{
			return ack(false, "unavailable");
		}
		ct.invokeLater(() ->
		{
			try
			{
				final Object p = plugin;
				final Object panel = p == null ? null : fPanel.get(p);
				if (panel != null)
				{
					mClearRecords.invoke(panel);
				}
				if (p != null)
				{
					mRemoveAllLoot.invoke(p);
				}
				lastRefresh = 0; // force an immediate re-snapshot on the next tick
			}
			catch (Throwable ex)
			{
				BridgeFaults.note("LootTrackerBridge.resetAll", ex);
			}
		});
		return ack(true, null);
	}

	/**
	 * Client-thread refresh (called each frame from {@code MobileUiBridge.tick}). Only works while the native
	 * screen is open; rebuilds the per-source snapshot on a slow cadence (the loot model only changes on a kill).
	 */
	public static void tick(Client client)
	{
		if (!uiOpen || client == null || !ensureResolved())
		{
			return;
		}
		final long now = System.currentTimeMillis();
		if (now - lastRefresh > 1500)
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
			final Collection<?> records = records();
			if (records == null)
			{
				lootJson = "{\"available\":false}";
				return;
			}

			final StringBuilder sb = new StringBuilder(16384);
			sb.append("{\"available\":true,\"sources\":[");
			boolean first = true;
			int sourceCount = 0;
			boolean cappedSources = false;
			for (Object record : records)
			{
				if (record == null)
				{
					continue;
				}
				if (sourceCount >= MAX_SOURCES)
				{
					cappedSources = true;
					break;
				}
				try
				{
					if (appendSource(sb, record, !first))
					{
						first = false;
						sourceCount++;
					}
				}
				catch (Throwable perRecord)
				{
					// one bad record must not drop the whole list
				}
			}
			sb.append("]}");
			lootJson = sb.toString();

			if (cappedSources)
			{
				log.debug("[loottracker] capped sources at {}", MAX_SOURCES);
			}
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("LootTrackerBridge.rebuild", ex);
			lootJson = "{\"available\":false}";
		}
	}

	/** Append one loot source (NPC/event) as a JSON object; returns false if nothing usable was read. */
	private static boolean appendSource(StringBuilder sb, Object record, boolean needComma) throws Exception
	{
		final String title = String.valueOf(fRecordTitle.get(record));
		final Object subTitleObj = fRecordSubTitle.get(record);
		final String subTitle = subTitleObj == null ? "" : String.valueOf(subTitleObj);
		final int kills = ((Number) fRecordKills.get(record)).intValue();
		final Object itemsObj = fRecordItems.get(record);
		if (!(itemsObj instanceof Object[]))
		{
			return false;
		}
		final Object[] items = (Object[]) itemsObj;

		// Merge duplicate item ids (sum quantities) the way the panel's box does, preserving first-seen order.
		final Map<Integer, long[]> merged = new LinkedHashMap<>(); // id -> [qty, gePrice, haPrice]
		final Map<Integer, String> names = new LinkedHashMap<>();
		for (Object item : items)
		{
			if (item == null)
			{
				continue;
			}
			try
			{
				final int id = ((Number) fItemId.get(item)).intValue();
				final int qty = ((Number) fItemQuantity.get(item)).intValue();
				final int ge = ((Number) fItemGePrice.get(item)).intValue();
				final int ha = ((Number) fItemHaPrice.get(item)).intValue();
				final Object nameObj = fItemName.get(item);
				final String name = nameObj == null ? "" : String.valueOf(nameObj);

				long[] agg = merged.get(id);
				if (agg == null)
				{
					merged.put(id, new long[]{qty, ge, ha});
					names.put(id, name);
				}
				else
				{
					long q = agg[0] + qty;
					if (q < 0 || q > Integer.MAX_VALUE)
					{
						q = Integer.MAX_VALUE;
					}
					agg[0] = q;
					agg[1] = ge; // unit prices are identical across a stacked id
					agg[2] = ha;
				}
			}
			catch (Throwable perItem)
			{
				// one bad item must not drop the source
			}
		}

		// Build the item array + per-source total value (sum of stacked GE prices, matching the panel default).
		final List<Integer> ids = new ArrayList<>(merged.keySet());
		long totalValue = 0;
		final StringBuilder itemsSb = new StringBuilder(merged.size() * 48);
		boolean firstItem = true;
		int emitted = 0;
		boolean cappedItems = false;
		for (Integer id : ids)
		{
			if (emitted >= MAX_ITEMS_PER_SOURCE)
			{
				cappedItems = true;
				break;
			}
			final long[] agg = merged.get(id);
			final long qty = agg[0];
			final long ge = agg[1];
			final long ha = agg[2];
			totalValue += ge * qty;

			if (!firstItem)
			{
				itemsSb.append(',');
			}
			firstItem = false;
			itemsSb.append('{')
				.append("\"id\":").append(id).append(',')
				.append("\"name\":").append(BridgeJson.quoted(names.get(id))).append(',')
				.append("\"qty\":").append(qty).append(',')
				.append("\"ge\":").append(ge * qty).append(',')
				.append("\"ha\":").append(ha * qty)
				.append('}');
			emitted++;
		}

		if (cappedItems)
		{
			log.debug("[loottracker] capped items for \"{}\" at {}", title, MAX_ITEMS_PER_SOURCE);
		}

		if (needComma)
		{
			sb.append(',');
		}
		sb.append('{')
			.append("\"name\":").append(BridgeJson.quoted(title)).append(',')
			.append("\"subTitle\":").append(BridgeJson.quoted(subTitle)).append(',')
			.append("\"type\":").append(BridgeJson.quoted(enumName(fRecordType.get(record)))).append(',')
			.append("\"kills\":").append(kills).append(',')
			.append("\"totalValue\":").append(totalValue).append(',')
			.append("\"items\":[").append(itemsSb).append(']')
			.append('}');
		return true;
	}

	/** The panel's aggregate-by-source records (one per NPC/event), or null if unreadable. */
	private static Collection<?> records() throws Exception
	{
		final Object p = plugin;
		if (p == null)
		{
			return null;
		}
		final Object panel = fPanel.get(p);
		if (panel == null)
		{
			return null;
		}
		final Object agg = fAggregateRecords.get(panel);
		if (agg instanceof Map)
		{
			return ((Map<?, ?>) agg).values();
		}
		return null;
	}

	// ---- reflection resolution -------------------------------------------------------------------------

	private static boolean ensureResolved()
	{
		if (resolveState == 1)
		{
			return true;
		}
		// resolveState -1 means we looked and the plugin wasn't loaded; retry (plugins can start later).
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

			fPanel = field(found.getClass(), "panel");
			final Class<?> panelClass = fPanel.getType();
			fAggregateRecords = field(panelClass, "aggregateRecords");

			// LootTrackerRecord is package-private; reach it via the declared type of the panel's records map
			// value, or fall back to loading it through the plugin's class loader.
			final ClassLoader cl = found.getClass().getClassLoader();
			final Class<?> recordClass = Class.forName(
				"net.runelite.client.plugins.loottracker.LootTrackerRecord", false, cl);
			fRecordTitle = field(recordClass, "title");
			fRecordSubTitle = field(recordClass, "subTitle");
			fRecordType = field(recordClass, "type");
			fRecordItems = field(recordClass, "items");
			fRecordKills = field(recordClass, "kills");

			final Class<?> itemClass = Class.forName(
				"net.runelite.client.plugins.loottracker.LootTrackerItem", false, cl);
			fItemId = field(itemClass, "id");
			fItemName = field(itemClass, "name");
			fItemQuantity = field(itemClass, "quantity");
			fItemGePrice = field(itemClass, "gePrice");
			fItemHaPrice = field(itemClass, "haPrice");

			mClearRecords = method(panelClass, "clearRecords");
			mRemoveAllLoot = method(found.getClass(), "removeAllLoot");

			plugin = found;
			resolveState = 1;
			log.info("[loottracker] native bridge resolved");
			return true;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("LootTrackerBridge.ensureResolved", ex);
			resolveState = -1;
			return false;
		}
	}

	private static Field field(Class<?> c, String name) throws NoSuchFieldException
	{
		final Field f = c.getDeclaredField(name);
		f.setAccessible(true);
		return f;
	}

	private static Method method(Class<?> c, String name) throws NoSuchMethodException
	{
		final Method m = c.getDeclaredMethod(name);
		m.setAccessible(true);
		return m;
	}

	private static String ack(boolean ok, String error)
	{
		final StringBuilder sb = new StringBuilder(48);
		sb.append("{\"ok\":").append(ok);
		if (error != null)
		{
			sb.append(",\"error\":").append(BridgeJson.quoted(error));
		}
		sb.append('}');
		return sb.toString();
	}

	private static String enumName(Object enumValue)
	{
		if (enumValue instanceof Enum)
		{
			return ((Enum<?>) enumValue).name();
		}
		return enumValue == null ? "" : String.valueOf(enumValue);
	}

}
