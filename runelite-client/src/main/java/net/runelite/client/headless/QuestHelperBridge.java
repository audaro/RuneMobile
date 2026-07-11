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
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginManager;

/**
 * Native-UI data bridge for the <b>Quest Helper</b> hub plugin — the one panel whose dense, interactive Swing
 * UI does not survive being rendered as a flat image on mobile, so the native shell reflows it into real UIKit
 * controls. Quest Helper is an <em>external</em> plugin (loaded by a child class loader, not a compile
 * dependency of this client), so every access here is <b>reflection</b>, and <b>every call is defensive</b>:
 * if the plugin is absent, a different version, or the reflected shape has moved, we report
 * {@code available:false} and the native side silently falls back to the generic rendered-panel surface.
 *
 * <p>Reads that touch live game state (a quest's {@code getState(Client)}, the active quest's current step)
 * run on the {@link ClientThread} via {@link #tick(Client)} (called from {@code MobileUiBridge.tick}, already
 * on the client thread) and are cached into volatile JSON the native thread reads lock-free — the same
 * snapshot pattern the rest of the mobile-UI facade uses. Writes (start/stop a quest) queue onto the client
 * thread. Refresh only runs while the native Quest Helper screen is open ({@link #setUiOpen(boolean)}).
 */
@Slf4j
public final class QuestHelperBridge
{
	private static final String PLUGIN_CLASS = "com.questhelper.QuestHelperPlugin";
	private static final String[] QUEST_ENUM_CLASSES =
	{
		"com.questhelper.questinfo.QuestHelperQuest",
		"com.questhelper.QuestHelperQuest",
	};

	// Quest Helper's QuestDetails.Type enum (reflected as a String across the plugin's class loader) also covers
	// non-quest helpers — skill trainers (Agility/Woodcutting/Mining), generic helpers and achievement diaries.
	// Those must not leak into the native quest list. Deny the known non-quest types; anything outside the known
	// universe is logged once and shown (fail-safe — never silently hide a genuine quest if the enum grows).
	private static final Set<String> NON_QUEST_TYPES = new HashSet<>(Arrays.asList(
		"SKILL", "SKILL_F2P", "SKILL_P2P", "GENERIC", "ACHIEVEMENT_DIARY"));
	private static final Set<String> KNOWN_QUEST_TYPES = new HashSet<>(Arrays.asList(
		"F2P", "P2P", "MINIQUEST", "PLAYER_QUEST"));
	private static final Set<String> loggedUnknownTypes = ConcurrentHashMap.newKeySet();

	private static volatile PluginManager pluginManager;
	private static volatile ClientThread clientThread;

	// Resolved reflection handles (cached once the plugin is found). resolveState: 0 unknown, 1 ok, -1 absent.
	private static volatile int resolveState;
	private static Object plugin;
	private static Object[] questConstants;       // QuestHelperQuest enum constants
	private static Method mGetName, mGetDifficulty, mGetQuestType, mGetState, mIsDev;
	private static Method mGetSelectedQuest, mGetDisplayedName, mGetCurrentStep, mGetItemReqs, mGetGeneralReqs;
	private static Method mStepGetText;

	// Cached snapshots (built on the client thread, read off-thread).
	private static volatile String listJson = "{\"available\":false}";
	private static volatile String activeJson = "{\"available\":false}";
	private static volatile boolean uiOpen;
	private static long lastListRefresh;
	private static long lastActiveRefresh;

	private QuestHelperBridge()
	{
	}

	public static void init(PluginManager pm, ClientThread ct)
	{
		pluginManager = pm;
		clientThread = ct;
	}

	/** Whether the native shell should offer the native Quest Helper screen (plugin present + reflectable). */
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
			lastListRefresh = 0;
			lastActiveRefresh = 0; // force an immediate refresh on next tick
		}
	}

	public static String getQuestListJson()
	{
		return listJson;
	}

	public static String getQuestActiveJson()
	{
		return activeJson;
	}

	/** Start the helper for {@code questName} (client thread — it reads/writes live quest state). */
	public static void startQuest(String questName)
	{
		final ClientThread ct = clientThread;
		if (questName == null || ct == null || !ensureResolved())
		{
			return;
		}
		ct.invokeLater(() ->
		{
			if (!invokeNamedString(plugin, "startUpQuest", questName))
			{
				// Newer Quest Helper delegates to an inner manager/handler — find it and forward the call.
				invokeOnFieldString("startUpQuest", questName);
			}
			lastActiveRefresh = 0;
		});
	}

	/** Stop/clear the active helper (client thread). */
	public static void stopQuest()
	{
		final ClientThread ct = clientThread;
		if (ct == null || !ensureResolved())
		{
			return;
		}
		ct.invokeLater(() ->
		{
			if (!invokeNamedBool(plugin, "shutDownQuest", true))
			{
				invokeOnFieldBool("shutDownQuest", true);
			}
			lastActiveRefresh = 0;
		});
	}

	/**
	 * Client-thread refresh (called each frame from {@code MobileUiBridge.tick}). Only works while the native
	 * screen is open; rebuilds the (heavier) quest list on a slow cadence and the active-quest snapshot faster.
	 */
	public static void tick(Client client)
	{
		if (!uiOpen || client == null || !ensureResolved())
		{
			return;
		}
		final long now = System.currentTimeMillis();
		if (now - lastListRefresh > 2500)
		{
			lastListRefresh = now;
			rebuildList(client);
		}
		if (now - lastActiveRefresh > 700)
		{
			lastActiveRefresh = now;
			rebuildActive();
		}
	}

	// ---- snapshots (client thread) ---------------------------------------------------------------------

	private static void rebuildList(Client client)
	{
		try
		{
			final StringBuilder sb = new StringBuilder(8192);
			sb.append("{\"available\":true,\"quests\":[");
			boolean first = true;
			for (Object q : questConstants)
			{
				try
				{
					if (mIsDev != null && Boolean.TRUE.equals(mIsDev.invoke(q)))
					{
						continue; // skip developer-only quests, like the desktop panel default
					}
					final String name = String.valueOf(mGetName.invoke(q));
					final String diff = enumName(mGetDifficulty.invoke(q));
					final String type = enumName(mGetQuestType.invoke(q));
					if (isNonQuestType(type))
					{
						continue; // skill trainers / generic helpers / diaries — not quests
					}
					final String state = enumName(mGetState.invoke(q, client));
					if (!first)
					{
						sb.append(',');
					}
					first = false;
					sb.append('{')
						.append("\"name\":").append(BridgeJson.quoted(name)).append(',')
						.append("\"difficulty\":").append(BridgeJson.quoted(diff)).append(',')
						.append("\"type\":").append(BridgeJson.quoted(type)).append(',')
						.append("\"state\":").append(BridgeJson.quoted(state))
						.append('}');
				}
				catch (Throwable perQuest)
				{
					// one bad quest constant must not drop the whole list
				}
			}
			sb.append("]}");
			listJson = sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("QuestHelperBridge.rebuildList", ex);
			listJson = "{\"available\":false}";
		}
	}

	private static void rebuildActive()
	{
		try
		{
			final Object sel = mGetSelectedQuest.invoke(plugin);
			if (sel == null)
			{
				activeJson = "{\"available\":true,\"active\":false}";
				return;
			}
			final StringBuilder sb = new StringBuilder(2048);
			sb.append("{\"available\":true,\"active\":true,\"name\":")
				.append(BridgeJson.quoted(String.valueOf(mGetDisplayedName.invoke(sel))));

			sb.append(",\"steps\":[");
			appendTextLines(sb, currentStepText(sel));
			sb.append(']');

			sb.append(",\"items\":[");
			appendReqList(sb, mGetItemReqs != null ? mGetItemReqs.invoke(sel) : null);
			sb.append(']');

			sb.append(",\"general\":[");
			appendReqList(sb, mGetGeneralReqs != null ? mGetGeneralReqs.invoke(sel) : null);
			sb.append(']');

			sb.append('}');
			activeJson = sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("QuestHelperBridge.rebuildActive", ex);
			activeJson = "{\"available\":true,\"active\":false}";
		}
	}

	@SuppressWarnings("unchecked")
	private static List<String> currentStepText(Object questHelper)
	{
		try
		{
			final Object step = mGetCurrentStep.invoke(questHelper);
			if (step == null || mStepGetText == null)
			{
				return null;
			}
			final Object text = mStepGetText.invoke(step);
			if (text instanceof List)
			{
				return (List<String>) text;
			}
		}
		catch (Throwable ignore)
		{
			BridgeFaults.note("QuestHelperBridge.currentStepText", ignore);
		}
		return null;
	}

	private static void appendTextLines(StringBuilder sb, List<String> lines)
	{
		if (lines == null)
		{
			return;
		}
		boolean first = true;
		for (Object line : lines)
		{
			if (line == null)
			{
				continue;
			}
			if (!first)
			{
				sb.append(',');
			}
			first = false;
			sb.append(BridgeJson.quoted(String.valueOf(line)));
		}
	}

	private static void appendReqList(StringBuilder sb, Object reqs)
	{
		if (!(reqs instanceof List))
		{
			return;
		}
		boolean first = true;
		for (Object r : (List<?>) reqs)
		{
			if (r == null)
			{
				continue;
			}
			final String text = reqText(r);
			if (text == null || text.isEmpty())
			{
				continue;
			}
			if (!first)
			{
				sb.append(',');
			}
			first = false;
			sb.append(BridgeJson.quoted(text));
		}
	}

	/** Best-effort human text for a requirement object across Quest Helper versions. */
	private static String reqText(Object req)
	{
		final String[] getters = {"getName", "getDisplayText", "getRequirementText"};
		for (String g : getters)
		{
			try
			{
				final Method m = req.getClass().getMethod(g);
				final Object v = m.invoke(req);
				if (v instanceof String && !((String) v).isEmpty())
				{
					return (String) v;
				}
			}
			catch (Throwable ignore)
			{
			}
		}
		try
		{
			return String.valueOf(req);
		}
		catch (Throwable ignore)
		{
			return null;
		}
	}

	// ---- reflection resolution -------------------------------------------------------------------------

	private static boolean ensureResolved()
	{
		if (resolveState == 1)
		{
			return true;
		}
		// resolveState -1 means we looked and the plugin wasn't loaded; retry (it can be hub-installed later).
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
			final ClassLoader cl = found.getClass().getClassLoader();
			Class<?> questEnum = null;
			for (String cn : QUEST_ENUM_CLASSES)
			{
				try
				{
					questEnum = Class.forName(cn, false, cl);
					break;
				}
				catch (ClassNotFoundException ignore)
				{
				}
			}
			if (questEnum == null || !questEnum.isEnum())
			{
				resolveState = -1;
				return false;
			}

			mGetName = questEnum.getMethod("getName");
			mGetDifficulty = questEnum.getMethod("getDifficulty");
			mGetQuestType = questEnum.getMethod("getQuestType");
			mGetState = questEnum.getMethod("getState", Client.class);
			mIsDev = optionalMethod(questEnum, "isDeveloperQuest");

			mGetSelectedQuest = found.getClass().getMethod("getSelectedQuest");
			final Class<?> helperClass = mGetSelectedQuest.getReturnType();
			mGetDisplayedName = optionalMethod(helperClass, "getDisplayedQuestName");
			if (mGetDisplayedName == null)
			{
				mGetDisplayedName = optionalMethod(helperClass, "getQuest"); // fallback path
			}
			mGetCurrentStep = optionalMethod(helperClass, "getCurrentStep");
			mGetItemReqs = optionalMethod(helperClass, "getItemRequirements");
			mGetGeneralReqs = optionalMethod(helperClass, "getGeneralRequirements");
			if (mGetCurrentStep != null)
			{
				mStepGetText = optionalMethod(mGetCurrentStep.getReturnType(), "getText");
			}

			questConstants = questEnum.getEnumConstants();
			plugin = found;
			resolveState = 1;
			log.info("[questhelper] native bridge resolved: {} quests", questConstants.length);
			return true;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("QuestHelperBridge.ensureResolved", ex);
			resolveState = -1;
			return false;
		}
	}

	private static Method optionalMethod(Class<?> c, String name)
	{
		if (c == null)
		{
			return null;
		}
		try
		{
			return c.getMethod(name);
		}
		catch (Throwable ignore)
		{
			return null;
		}
	}

	private static boolean invokeNamedString(Object target, String method, String arg)
	{
		try
		{
			final Method m = target.getClass().getMethod(method, String.class);
			m.invoke(target, arg);
			return true;
		}
		catch (Throwable ignore)
		{
			return false;
		}
	}

	private static boolean invokeNamedBool(Object target, String method, boolean arg)
	{
		try
		{
			final Method m = target.getClass().getMethod(method, boolean.class);
			m.invoke(target, arg);
			return true;
		}
		catch (Throwable ignore)
		{
			return false;
		}
	}

	private static void invokeOnFieldString(String method, String arg)
	{
		final Object p = plugin;
		if (p == null)
		{
			return;
		}
		for (Field f : p.getClass().getDeclaredFields())
		{
			try
			{
				f.setAccessible(true);
				final Object v = f.get(p);
				if (v != null && invokeNamedString(v, method, arg))
				{
					return;
				}
			}
			catch (Throwable ignore)
			{
			}
		}
	}

	private static void invokeOnFieldBool(String method, boolean arg)
	{
		final Object p = plugin;
		if (p == null)
		{
			return;
		}
		for (Field f : p.getClass().getDeclaredFields())
		{
			try
			{
				f.setAccessible(true);
				final Object v = f.get(p);
				if (v != null && invokeNamedBool(v, method, arg))
				{
					return;
				}
			}
			catch (Throwable ignore)
			{
			}
		}
	}

	/** True for Quest Helper helper types that are not real quests (skill/generic/diary). Unknown types log once and show. */
	private static boolean isNonQuestType(String type)
	{
		if (type == null || type.isEmpty())
		{
			return false;
		}
		if (NON_QUEST_TYPES.contains(type))
		{
			return true;
		}
		if (!KNOWN_QUEST_TYPES.contains(type) && loggedUnknownTypes.add(type))
		{
			log.info("[questhelper] unknown questType '{}' — showing as a quest (add to allow/deny set if wrong)", type);
		}
		return false;
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
