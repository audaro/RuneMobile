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
import java.time.Instant;
import java.util.Collection;
import java.util.List;
import java.util.Map;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginManager;
import net.runelite.client.plugins.timetracking.SummaryState;
import net.runelite.client.plugins.timetracking.Tab;
import net.runelite.client.plugins.timetracking.clocks.ClockManager;
import net.runelite.client.plugins.timetracking.farming.FarmingContractManager;
import net.runelite.client.plugins.timetracking.farming.FarmingTracker;
import net.runelite.client.plugins.timetracking.hunter.BirdHouseTracker;

/**
 * Native-UI data bridge for the <b>Time Tracking</b> core plugin — the panel whose dense grid of farming
 * patches, bird houses, timers and stopwatches reads poorly when rendered as a flat image on mobile, so the
 * native shell reflows it into real countdowns. Unlike {@link QuestHelperBridge} (an external, reflection-only
 * plugin), Time Tracking ships <em>inside</em> this client, so we access its public model with <b>direct typed
 * calls</b> ({@link FarmingTracker}, {@link BirdHouseTracker}, {@link FarmingContractManager},
 * {@link ClockManager}) and fall back to reflection only for the few package-private corners (the per-clock and
 * per-bird-house detail). The plugin instance itself, and the trackers it {@code @Inject}s, are reached once by
 * reflecting the plugin's private fields and then cached.
 *
 * <p>The trackers expose completion as <em>absolute epoch-seconds</em> (or {@code 0} = ready now, {@code -1} =
 * unknown). We pass both that epoch and a derived {@code remainingSec} so the native side can render either an
 * absolute time or a live countdown. Reads run on the {@link ClientThread} via {@link #tick(Client)} (called
 * from {@code MobileUiBridge.tick}, already on the client thread — the trackers touch live varbit/varp state)
 * and are cached into volatile JSON the native thread reads lock-free. Refresh only runs while the native Time
 * Tracking screen is open ({@link #setUiOpen(boolean)}). Every read is defensive: one bad entry must not drop
 * the whole list, and if the plugin is disabled/absent we report {@code available:false}.
 */
@Slf4j
public final class TimeTrackingBridge
{
	private static final String PLUGIN_CLASS = "net.runelite.client.plugins.timetracking.TimeTrackingPlugin";

	// Only the actual farming patch tabs (skips OVERVIEW/CLOCK/BIRD_HOUSE/TIME_OFFSET, which aren't patches).
	private static final Tab[] FARMING_TABS = Tab.FARMING_TABS;

	private static volatile PluginManager pluginManager;
	private static volatile ClientThread clientThread;

	// Resolved handles (cached once the plugin is found). resolveState: 0 unknown, 1 ok, -1 absent.
	private static volatile int resolveState;
	private static Object plugin;
	private static FarmingTracker farmingTracker;
	private static BirdHouseTracker birdHouseTracker;
	private static FarmingContractManager farmingContractManager;
	private static ClockManager clockManager;

	// Reflection for the package-private corners (resolved lazily, may stay null on a shape change).
	private static Method mClockGetName, mClockIsActive, mClockGetDisplayTime, mClockIsLoop, mClockGetDuration;
	private static Method mBirdHouseData, mBirdHouseGetVarp, mBirdHouseGetTimestamp, mBirdHouseSpaceGetName;
	private static Method mBirdHouseStateFromVarp;
	private static boolean clockReflectTried, birdHouseReflectTried;
	private static final int BIRD_HOUSE_DURATION_SEC = 50 * 60; // average harvest time, mirrors BirdHouseTracker

	// Cached snapshot (built on the client thread, read off-thread).
	private static volatile String json = "{\"available\":false}";
	private static volatile boolean uiOpen;
	private static long lastRefresh;

	private TimeTrackingBridge()
	{
	}

	public static void init(PluginManager pm, ClientThread ct)
	{
		pluginManager = pm;
		clientThread = ct;
	}

	/** Whether the native shell should offer the native Time Tracking screen (plugin present + enabled). */
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

	public static String getTimeTrackingJson()
	{
		return json;
	}

	/**
	 * Client-thread refresh (called each frame from {@code MobileUiBridge.tick}). Only works while the native
	 * screen is open; rebuilds the snapshot on a ~1s cadence (countdowns are second-resolution).
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
			final long nowSec = Instant.now().getEpochSecond();
			final StringBuilder sb = new StringBuilder(4096);
			sb.append("{\"available\":true");

			sb.append(",\"farming\":[");
			appendFarming(sb, nowSec);
			sb.append(']');

			sb.append(",\"contract\":");
			appendContract(sb, nowSec);

			sb.append(",\"birdhouses\":[");
			appendBirdHouses(sb, nowSec);
			sb.append(']');

			sb.append(",\"timers\":[");
			appendTimers(sb);
			sb.append(']');

			sb.append(",\"stopwatches\":[");
			appendStopwatches(sb);
			sb.append(']');

			sb.append('}');
			json = sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("TimeTrackingBridge.rebuild", ex);
			json = "{\"available\":false}";
		}
	}

	// ---- farming (per-tab summary; the Overview granularity) -------------------------------------------

	private static void appendFarming(StringBuilder sb, long nowSec)
	{
		boolean first = true;
		for (Tab tab : FARMING_TABS)
		{
			try
			{
				final SummaryState summary = farmingTracker.getSummary(tab);
				final long completion = farmingTracker.getCompletionTime(tab);
				if (!first)
				{
					sb.append(',');
				}
				first = false;
				sb.append('{')
					.append("\"tab\":").append(BridgeJson.quoted(tab.name())).append(',')
					.append("\"name\":").append(BridgeJson.quoted(tab.getName())).append(',')
					.append("\"state\":").append(BridgeJson.quoted(enumName(summary))).append(',')
					.append("\"readyTime\":").append(epochOf(completion)).append(',')
					.append("\"remainingSec\":").append(remainingOf(completion, nowSec))
					.append('}');
			}
			catch (Throwable perTab)
			{
				// one bad tab must not drop the whole list
			}
		}
	}

	private static void appendContract(StringBuilder sb, long nowSec)
	{
		try
		{
			if (!farmingContractManager.hasContract())
			{
				sb.append("{\"active\":false}");
				return;
			}
			final long completion = farmingContractManager.getCompletionTime();
			sb.append('{')
				.append("\"active\":true,")
				.append("\"name\":").append(BridgeJson.quoted(farmingContractManager.getContractName())).append(',')
				.append("\"state\":").append(BridgeJson.quoted(enumName(farmingContractManager.getSummary()))).append(',')
				.append("\"cropState\":").append(BridgeJson.quoted(enumName(farmingContractManager.getContractCropState()))).append(',')
				.append("\"readyTime\":").append(epochOf(completion)).append(',')
				.append("\"remainingSec\":").append(remainingOf(completion, nowSec))
				.append('}');
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("TimeTrackingBridge.appendContract", ex);
			sb.append("{\"active\":false}");
		}
	}

	// ---- bird houses ----------------------------------------------------------------------------------

	private static void appendBirdHouses(StringBuilder sb, long nowSec)
	{
		// Per-house detail (state + per-house ready time) lives behind package-private types, so reflect it
		// defensively; the overall summary is always available from the public tracker API below.
		final Map<?, ?> data = birdHouseDataMap();
		if (data != null && !data.isEmpty())
		{
			boolean first = true;
			for (Map.Entry<?, ?> e : data.entrySet())
			{
				try
				{
					final Object space = e.getKey();
					final Object houseData = e.getValue();
					final int varp = (Integer) mBirdHouseGetVarp.invoke(houseData);
					final long timestamp = (Long) mBirdHouseGetTimestamp.invoke(houseData);
					final String spaceName = String.valueOf(mBirdHouseSpaceGetName.invoke(space));
					final Object state = mBirdHouseStateFromVarp.invoke(null, varp);

					// SEEDED houses finish BIRD_HOUSE_DURATION after they were seeded; others have no countdown.
					final boolean seeded = "SEEDED".equals(enumName(state));
					final long completion = seeded ? timestamp + BIRD_HOUSE_DURATION_SEC : 0;
					if (!first)
					{
						sb.append(',');
					}
					first = false;
					sb.append('{')
						.append("\"name\":").append(BridgeJson.quoted(spaceName)).append(',')
						.append("\"state\":").append(BridgeJson.quoted(enumName(state))).append(',')
						.append("\"readyTime\":").append(seeded ? completion : 0).append(',')
						.append("\"remainingSec\":").append(seeded ? Math.max(0, completion - nowSec) : 0)
						.append('}');
				}
				catch (Throwable perHouse)
				{
					// one bad bird house must not drop the rest
				}
			}
			return;
		}

		// Fallback: no per-house detail reachable — emit a single overall summary entry from the public API.
		try
		{
			final SummaryState summary = birdHouseTracker.getSummary();
			final long completion = birdHouseTracker.getCompletionTime();
			sb.append('{')
				.append("\"name\":").append(BridgeJson.quoted("Bird Houses")).append(',')
				.append("\"state\":").append(BridgeJson.quoted(enumName(summary))).append(',')
				.append("\"readyTime\":").append(epochOf(completion)).append(',')
				.append("\"remainingSec\":").append(remainingOf(completion, nowSec))
				.append('}');
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("TimeTrackingBridge.appendBirdHouses", ex);
			// nothing reachable; leave the array empty
		}
	}

	// ---- timers / stopwatches (public ClockManager, package-private element types via reflection) ------

	private static void appendTimers(StringBuilder sb)
	{
		final Collection<?> timers = clockListVia("getTimers");
		if (timers == null || !ensureClockReflection(timers))
		{
			return;
		}
		boolean first = true;
		for (Object timer : timers)
		{
			try
			{
				final String name = String.valueOf(mClockGetName.invoke(timer));
				final boolean active = (Boolean) mClockIsActive.invoke(timer);
				final long remaining = ((Number) mClockGetDisplayTime.invoke(timer)).longValue();
				final long duration = mClockGetDuration != null ? ((Number) mClockGetDuration.invoke(timer)).longValue() : 0;
				final boolean loop = mClockIsLoop != null && (Boolean) mClockIsLoop.invoke(timer);
				if (!first)
				{
					sb.append(',');
				}
				first = false;
				sb.append('{')
					.append("\"name\":").append(BridgeJson.quoted(name)).append(',')
					.append("\"active\":").append(active).append(',')
					.append("\"remainingSec\":").append(remaining).append(',')
					.append("\"durationSec\":").append(duration).append(',')
					.append("\"loop\":").append(loop)
					.append('}');
			}
			catch (Throwable perTimer)
			{
				// one bad timer must not drop the rest
			}
		}
	}

	private static void appendStopwatches(StringBuilder sb)
	{
		final Collection<?> stopwatches = clockListVia("getStopwatches");
		if (stopwatches == null || !ensureClockReflection(stopwatches))
		{
			return;
		}
		boolean first = true;
		for (Object sw : stopwatches)
		{
			try
			{
				final String name = String.valueOf(mClockGetName.invoke(sw));
				final boolean active = (Boolean) mClockIsActive.invoke(sw);
				final long elapsed = ((Number) mClockGetDisplayTime.invoke(sw)).longValue();
				if (!first)
				{
					sb.append(',');
				}
				first = false;
				sb.append('{')
					.append("\"name\":").append(BridgeJson.quoted(name)).append(',')
					.append("\"active\":").append(active).append(',')
					.append("\"elapsedSec\":").append(elapsed)
					.append('}');
			}
			catch (Throwable perSw)
			{
				// one bad stopwatch must not drop the rest
			}
		}
	}

	private static Collection<?> clockListVia(String getter)
	{
		try
		{
			final Object v = ClockManager.class.getMethod(getter).invoke(clockManager);
			if (v instanceof Collection)
			{
				return (Collection<?>) v;
			}
		}
		catch (Throwable ignore)
		{
			BridgeFaults.note("TimeTrackingBridge.clockListVia", ignore);
		}
		return null;
	}

	/** Resolve the package-private Clock accessors from a live element (Timer or Stopwatch). */
	private static boolean ensureClockReflection(Collection<?> sample)
	{
		if (mClockGetName != null)
		{
			return true;
		}
		if (clockReflectTried)
		{
			return mClockGetName != null;
		}
		clockReflectTried = true;
		try
		{
			// The base Clock type (carries name/active/getDisplayTime) — walk up from a concrete element if any.
			Object element = null;
			for (Object o : sample)
			{
				element = o;
				break;
			}
			final Class<?> clockBase = element != null
				? findClockBase(element.getClass())
				: Class.forName("net.runelite.client.plugins.timetracking.clocks.Clock");
			mClockGetName = accessible(clockBase, "getName");
			mClockIsActive = accessible(clockBase, "isActive");
			mClockGetDisplayTime = accessible(clockBase, "getDisplayTime");
			// Timer-only extras (resolved against the concrete element type when present).
			if (element != null)
			{
				mClockGetDuration = optionalAccessible(element.getClass(), "getDuration");
				mClockIsLoop = optionalAccessible(element.getClass(), "isLoop");
			}
			return mClockGetName != null && mClockIsActive != null && mClockGetDisplayTime != null;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("TimeTrackingBridge.ensureClockReflection", ex);
			return false;
		}
	}

	private static Class<?> findClockBase(Class<?> concrete)
	{
		Class<?> c = concrete;
		while (c != null && !"Clock".equals(c.getSimpleName()))
		{
			c = c.getSuperclass();
		}
		return c != null ? c : concrete;
	}

	@SuppressWarnings("unchecked")
	private static Map<?, ?> birdHouseDataMap()
	{
		if (!ensureBirdHouseReflection())
		{
			return null;
		}
		try
		{
			final Object v = mBirdHouseData.invoke(birdHouseTracker);
			if (v instanceof Map)
			{
				return (Map<?, ?>) v;
			}
		}
		catch (Throwable ignore)
		{
			BridgeFaults.note("TimeTrackingBridge.birdHouseDataMap", ignore);
		}
		return null;
	}

	private static boolean ensureBirdHouseReflection()
	{
		if (mBirdHouseData != null)
		{
			return true;
		}
		if (birdHouseReflectTried)
		{
			return mBirdHouseData != null;
		}
		birdHouseReflectTried = true;
		try
		{
			mBirdHouseData = accessible(BirdHouseTracker.class, "getBirdHouseData");
			final ClassLoader cl = BirdHouseTracker.class.getClassLoader();
			final Class<?> dataClass = Class.forName("net.runelite.client.plugins.timetracking.hunter.BirdHouseData", false, cl);
			final Class<?> spaceClass = Class.forName("net.runelite.client.plugins.timetracking.hunter.BirdHouseSpace", false, cl);
			final Class<?> stateClass = Class.forName("net.runelite.client.plugins.timetracking.hunter.BirdHouseState", false, cl);
			mBirdHouseGetVarp = accessible(dataClass, "getVarp");
			mBirdHouseGetTimestamp = accessible(dataClass, "getTimestamp");
			mBirdHouseSpaceGetName = accessible(spaceClass, "getName");
			mBirdHouseStateFromVarp = stateClass.getDeclaredMethod("fromVarpValue", int.class);
			mBirdHouseStateFromVarp.setAccessible(true);
			return mBirdHouseData != null && mBirdHouseGetVarp != null && mBirdHouseGetTimestamp != null
				&& mBirdHouseSpaceGetName != null && mBirdHouseStateFromVarp != null;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("TimeTrackingBridge.ensureBirdHouseReflection", ex);
			return false;
		}
	}

	// ---- resolution -----------------------------------------------------------------------------------

	private static boolean ensureResolved()
	{
		if (resolveState == 1)
		{
			return true;
		}
		// resolveState -1 means we looked and the plugin wasn't enabled; retry (it can be toggled on later).
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

			final FarmingTracker ft = (FarmingTracker) readField(found, "farmingTracker", FarmingTracker.class);
			final BirdHouseTracker bht = (BirdHouseTracker) readField(found, "birdHouseTracker", BirdHouseTracker.class);
			final FarmingContractManager fcm = (FarmingContractManager) readField(found, "farmingContractManager", FarmingContractManager.class);
			final ClockManager cm = (ClockManager) readField(found, "clockManager", ClockManager.class);

			if (ft == null || bht == null || fcm == null || cm == null)
			{
				resolveState = -1;
				return false;
			}

			plugin = found;
			farmingTracker = ft;
			birdHouseTracker = bht;
			farmingContractManager = fcm;
			clockManager = cm;
			resolveState = 1;
			log.info("[timetracking] native bridge resolved");
			return true;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("TimeTrackingBridge.ensureResolved", ex);
			resolveState = -1;
			return false;
		}
	}

	/** Read a private {@code @Inject} field of the plugin, matching by declared type (name is a hint only). */
	private static Object readField(Object target, String name, Class<?> type)
	{
		try
		{
			final Field f = target.getClass().getDeclaredField(name);
			f.setAccessible(true);
			final Object v = f.get(target);
			if (type.isInstance(v))
			{
				return v;
			}
		}
		catch (Throwable ignore)
		{
		}
		// Field renamed? Fall back to a type scan over all declared fields.
		for (Field f : target.getClass().getDeclaredFields())
		{
			if (!type.isAssignableFrom(f.getType()))
			{
				continue;
			}
			try
			{
				f.setAccessible(true);
				final Object v = f.get(target);
				if (type.isInstance(v))
				{
					return v;
				}
			}
			catch (Throwable ignore)
			{
			}
		}
		return null;
	}

	private static Method accessible(Class<?> c, String name)
	{
		if (c == null)
		{
			return null;
		}
		try
		{
			final Method m = c.getDeclaredMethod(name);
			m.setAccessible(true);
			return m;
		}
		catch (Throwable ignore)
		{
			return optionalAccessible(c, name);
		}
	}

	private static Method optionalAccessible(Class<?> c, String name)
	{
		if (c == null)
		{
			return null;
		}
		// search the type hierarchy for a public/inherited accessor
		Class<?> cursor = c;
		while (cursor != null)
		{
			try
			{
				final Method m = cursor.getDeclaredMethod(name);
				m.setAccessible(true);
				return m;
			}
			catch (Throwable ignore)
			{
				cursor = cursor.getSuperclass();
			}
		}
		return null;
	}

	// ---- json helpers ---------------------------------------------------------------------------------

	/** Absolute completion epoch-seconds passthrough: -1 unknown, 0 ready now, else the epoch. */
	private static long epochOf(long completionTime)
	{
		return completionTime < 0 ? 0 : completionTime;
	}

	/** Seconds until done: 0 if ready/unknown, else the positive delta from now. */
	private static long remainingOf(long completionTime, long nowSec)
	{
		if (completionTime <= 0)
		{
			return 0;
		}
		return Math.max(0, completionTime - nowSec);
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
