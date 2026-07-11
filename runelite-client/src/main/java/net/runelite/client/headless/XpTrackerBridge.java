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
import net.runelite.api.Skill;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginManager;

/**
 * Native-UI data bridge for the core <b>XP Tracker</b> plugin — exposing its per-skill session data as JSON so
 * the native mobile shell can reflow it into real UIKit/Android controls instead of rendering the Swing
 * {@code XpPanel} as a flat image. Unlike the hub plugins, XP Tracker ships <em>inside</em> this client, so its
 * service/snapshot types are on the same class loader and we can access them with typed precision — but the
 * useful shape ({@code XpSnapshotSingle}, {@code XpTrackerPlugin#getSkillSnapshot} and {@code XpState}) is
 * <b>package-private</b>, so the actual reads still go through reflection. <b>Every call is defensive</b>: if the
 * plugin is absent or the reflected shape has moved, we report {@code available:false} and the native side falls
 * back to the generic rendered-panel surface.
 *
 * <p>Reads run on the {@link ClientThread} via {@link #tick(Client)} (called from {@code MobileUiBridge.tick},
 * already on the client thread) and are cached into a {@code volatile} JSON string the native thread reads
 * lock-free — the same snapshot pattern the rest of the mobile-UI facade uses. Refresh only runs while the
 * native XP Tracker screen is open ({@link #setUiOpen(boolean)}). This bridge is read-only; XP Tracker resets
 * are driven by the user in-game, not from the native shell.
 */
@Slf4j
public final class XpTrackerBridge
{
	private static final String PLUGIN_CLASS = "net.runelite.client.plugins.xptracker.XpTrackerPlugin";

	private static volatile PluginManager pluginManager;

	// Resolved reflection handles (cached once the plugin is found). resolveState: 0 unknown, 1 ok, -1 absent.
	private static volatile int resolveState;
	private static Object plugin;
	private static Method mGetSkillSnapshot;   // XpTrackerPlugin#getSkillSnapshot(Skill) -> XpSnapshotSingle
	private static Object xpState;             // XpTrackerPlugin#xpState (XpState instance)
	private static Method mGetTotalSnapshot;   // XpState#getTotalSnapshot() -> XpSnapshotSingle

	// XpSnapshotSingle getters (Lombok @Value on a package-private class — reachable only by reflection).
	private static Method snStartLevel, snEndLevel, snXpGained, snXpRemaining, snXpHr, snProgress;
	private static Method snActions, snActionsLeft, snActionsHr, snTimeShort;

	// Cached snapshot (built on the client thread, read off-thread).
	private static volatile String xpJson = "{\"available\":false}";
	private static volatile boolean uiOpen;
	private static long lastRefresh;

	private XpTrackerBridge()
	{
	}

	public static void init(PluginManager pm, ClientThread ct)
	{
		pluginManager = pm;
		// XP Tracker reads run on the client thread inside tick(); no queued writes, so the ClientThread
		// handle is intentionally unused here. Signature kept uniform with the rest of the mobile bridges.
	}

	/** Whether the native shell should offer the native XP Tracker screen (plugin present + reflectable). */
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

	public static String getXpJson()
	{
		return xpJson;
	}

	/**
	 * Client-thread refresh (called each frame from {@code MobileUiBridge.tick}). Only works while the native
	 * screen is open; rebuilds the per-skill snapshot on a steady cadence (XP/hr ticks once a second in-engine).
	 */
	public static void tick(Client client)
	{
		if (!uiOpen || client == null || !ensureResolved())
		{
			return;
		}
		final long now = System.currentTimeMillis();
		if (now - lastRefresh > 1000)
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
			sb.append("{\"available\":true,\"skills\":[");
			boolean first = true;
			for (Skill skill : Skill.values())
			{
				try
				{
					final Object snap = mGetSkillSnapshot.invoke(plugin, skill);
					if (snap == null || asInt(snXpGained, snap) <= 0)
					{
						continue; // only skills currently being tracked (gained xp this session)
					}
					if (!first)
					{
						sb.append(',');
					}
					first = false;
					sb.append('{').append("\"skill\":").append(BridgeJson.quoted(skill.name())).append(',');
					appendSnapshotFields(sb, snap);
					sb.append('}');
				}
				catch (Throwable perSkill)
				{
					// one bad skill must not drop the whole list
				}
			}
			sb.append(']');

			final Object total = totalSnapshot();
			if (total != null)
			{
				sb.append(",\"overall\":{");
				appendSnapshotFields(sb, total);
				sb.append('}');
			}

			sb.append('}');
			xpJson = sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("XpTrackerBridge.rebuild", ex);
			xpJson = "{\"available\":false}";
		}
	}

	/** Append the shared snapshot fields (everything after the leading "skill" key) for one XpSnapshotSingle. */
	private static void appendSnapshotFields(StringBuilder sb, Object snap) throws Exception
	{
		final int xpGained = asInt(snXpGained, snap);
		final int xpHr = asInt(snXpHr, snap);
		final int xpLeft = asInt(snXpRemaining, snap);
		final int actionsLeft = asInt(snActionsLeft, snap);
		final int actionsHr = asInt(snActionsHr, snap);
		final int startLevel = asInt(snStartLevel, snap);
		final int endLevel = asInt(snEndLevel, snap);
		final int timeToGoalSec = parseDuration(asString(snTimeShort, snap));
		final double progressPct = asDouble(snProgress, snap);

		sb.append("\"xpGained\":").append(xpGained).append(',')
			.append("\"xpHr\":").append(xpHr).append(',')
			.append("\"xpLeft\":").append(xpLeft).append(',')
			.append("\"actions\":").append(asInt(snActions, snap)).append(',')
			.append("\"actionsLeft\":").append(actionsLeft).append(',')
			.append("\"actionsHr\":").append(actionsHr).append(',')
			.append("\"timeToLevelSec\":").append(timeToGoalSec).append(',')
			.append("\"timeToGoalSec\":").append(timeToGoalSec).append(',')
			.append("\"startLevel\":").append(startLevel).append(',')
			.append("\"endLevel\":").append(endLevel).append(',')
			.append("\"progress\":").append(clampProgress(progressPct));
	}

	private static Object totalSnapshot()
	{
		try
		{
			if (xpState != null && mGetTotalSnapshot != null)
			{
				return mGetTotalSnapshot.invoke(xpState);
			}
		}
		catch (Throwable ignore)
		{
			BridgeFaults.note("XpTrackerBridge.totalSnapshot", ignore);
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
		// resolveState -1 means we looked and the plugin wasn't loaded; retry (it can be toggled on later).
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

			mGetSkillSnapshot = found.getClass().getDeclaredMethod("getSkillSnapshot", Skill.class);
			mGetSkillSnapshot.setAccessible(true);
			final Class<?> snapClass = mGetSkillSnapshot.getReturnType();

			snStartLevel = snapGetter(snapClass, "getStartLevel");
			snEndLevel = snapGetter(snapClass, "getEndLevel");
			snXpGained = snapGetter(snapClass, "getXpGainedInSession");
			snXpRemaining = snapGetter(snapClass, "getXpRemainingToGoal");
			snXpHr = snapGetter(snapClass, "getXpPerHour");
			snProgress = snapGetter(snapClass, "getSkillProgressToGoal");
			snActions = snapGetter(snapClass, "getActionsInSession");
			snActionsLeft = snapGetter(snapClass, "getActionsRemainingToGoal");
			snActionsHr = snapGetter(snapClass, "getActionsPerHour");
			snTimeShort = snapGetter(snapClass, "getTimeTillGoalShort");

			// Overall row: reflect the plugin's private XpState and its package-private getTotalSnapshot().
			final Field stateField = found.getClass().getDeclaredField("xpState");
			stateField.setAccessible(true);
			xpState = stateField.get(found);
			if (xpState != null)
			{
				mGetTotalSnapshot = xpState.getClass().getDeclaredMethod("getTotalSnapshot");
				mGetTotalSnapshot.setAccessible(true);
			}

			plugin = found;
			resolveState = 1;
			log.info("[xptracker] native bridge resolved");
			return true;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("XpTrackerBridge.ensureResolved", ex);
			resolveState = -1;
			return false;
		}
	}

	private static Method snapGetter(Class<?> c, String name) throws NoSuchMethodException
	{
		final Method m = c.getDeclaredMethod(name);
		m.setAccessible(true);
		return m;
	}

	// ---- value helpers ---------------------------------------------------------------------------------

	private static int asInt(Method getter, Object target) throws Exception
	{
		final Object v = getter.invoke(target);
		return v instanceof Number ? ((Number) v).intValue() : 0;
	}

	private static double asDouble(Method getter, Object target) throws Exception
	{
		final Object v = getter.invoke(target);
		return v instanceof Number ? ((Number) v).doubleValue() : 0.0;
	}

	private static String asString(Method getter, Object target) throws Exception
	{
		final Object v = getter.invoke(target);
		return v == null ? null : String.valueOf(v);
	}

	/** XpSnapshotSingle exposes progress as a 0..100 percentage; the native contract wants a 0..1 fraction. */
	private static String clampProgress(double pct)
	{
		double frac = pct / 100.0;
		if (Double.isNaN(frac) || Double.isInfinite(frac) || frac < 0.0)
		{
			frac = 0.0;
		}
		else if (frac > 1.0)
		{
			frac = 1.0;
		}
		return String.format("%.4f", frac);
	}

	/**
	 * The snapshot only carries the time-till-goal as a preformatted string ("h:mm:ss" / "mm:ss", or the
	 * infinity glyph when no rate is known). The native contract wants whole seconds, so parse it back; an
	 * unparseable / infinite value becomes {@code -1} (the native side renders that as "&infin;").
	 */
	private static int parseDuration(String s)
	{
		if (s == null || s.isEmpty())
		{
			return -1;
		}
		final String[] parts = s.split(":");
		try
		{
			int seconds = 0;
			for (String part : parts)
			{
				seconds = seconds * 60 + Integer.parseInt(part.trim());
			}
			return parts.length >= 2 ? seconds : -1;
		}
		catch (NumberFormatException ex)
		{
			return -1; // e.g. the "∞" infinity glyph
		}
	}

}
