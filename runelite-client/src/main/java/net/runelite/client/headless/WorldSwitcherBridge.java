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

import java.lang.reflect.Method;
import java.util.EnumSet;
import java.util.List;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.gameval.VarbitID;
import net.runelite.api.widgets.Widget;
import net.runelite.client.RuneLite;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.config.ConfigManager;
import net.runelite.client.game.WorldService;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginManager;
import net.runelite.client.plugins.worldhopper.WorldHopperPlugin;
import net.runelite.http.api.worlds.World;
import net.runelite.http.api.worlds.WorldResult;
import net.runelite.http.api.worlds.WorldType;

/**
 * Native-UI data bridge for <b>World Switcher</b>. Unlike {@link QuestHelperBridge}, the world data is part of
 * the client/API ({@link WorldService} → {@link World}), so reads are <b>direct</b> — no reflection. Only the
 * <em>hop</em> action reflects, because {@code WorldHopperPlugin.hop(int)} is private and lives in another
 * package; reflecting one private method is cheaper than re-implementing the world-hop handshake.
 *
 * <p>The world list snapshot is rebuilt on the {@link ClientThread} via {@link #tick(Client)} (current world +
 * favourites read live game state) and published as volatile JSON the native thread reads lock-free. A hop
 * queues onto the client thread. Refresh only runs while the native screen is open ({@link #setUiOpen}).
 */
@Slf4j
public final class WorldSwitcherBridge
{
	private static volatile Client client;
	private static volatile ClientThread clientThread;
	private static volatile PluginManager pluginManager;
	private static volatile WorldService worldService;
	private static volatile ConfigManager configManager;

	// The shared WorldHopper favourites config (worldhopper.favorite_<id>=true); same keys the desktop plugin uses.
	private static final String WORLDHOPPER_GROUP = "worldhopper";

	private static volatile boolean uiOpen;
	private static volatile String listJson = "{\"available\":false}";
	private static long lastRefresh;

	// Reflected hop(int) / hop(boolean) on the WorldHopper plugin (private; resolved lazily). hop(boolean) is used
	// only to let the plugin pick the next/prev quick-hop target (its filter logic); the actual world change goes
	// through the relog path below, because the engine's in-game hop (client.hopToWorld) is inert headless (Bug 4).
	private static Object worldHopper;
	private static Method hopMethod;
	private static Method hopDirMethod;
	// Reflected WorldHopperPlugin.quickHopTargetWorld — read after invoking hop(boolean) to learn the world the
	// plugin's filter selected, then cleared so the plugin's (inert) in-game onGameTick handshake doesn't run.
	private static java.lang.reflect.Field fQuickHopTarget;

	// Bug 4 — hop-via-relog. client.hopToWorld() is inert in the headless client (the in-game world-switcher
	// handshake completes but getWorld() never moves; root-caused 2026-06-22), so a world hop is done the one way
	// that IS known-good headless: WorldHopperPlugin.hop(World) line 702-706 changes the world directly via
	// client.changeWorld() WHEN ON THE LOGIN SCREEN (the same call HeadlessLogin uses for its initial F2P world
	// pick). So we drive a logout to the login screen, hand the target world to HeadlessLogin (which re-arms and
	// calls changeWorld(target) + Play Now), and let it relogin. driveRelog() runs the logout half each frame.
	private static volatile boolean relogPending;
	private static int relogAttempts;
	private static long relogNextMs;
	private static boolean loggedLogoutOps;   // Bug 4 diagnostic: log the logout button's ops once per process
	private static final int MAX_RELOG_ATTEMPTS = 12;   // ~7s of logout retries (driveRelog throttles to ~600ms)

	private WorldSwitcherBridge()
	{
	}

	public static void init(Client c, ClientThread ct, PluginManager pm)
	{
		client = c;
		clientThread = ct;
		pluginManager = pm;
	}

	private static WorldService worldService()
	{
		WorldService ws = worldService;
		if (ws == null)
		{
			try
			{
				ws = RuneLite.getInjector().getInstance(WorldService.class);
				worldService = ws;
			}
			catch (Throwable ignore)
			{
				BridgeFaults.note("WorldSwitcherBridge.worldService", ignore);
			}
		}
		return ws;
	}

	private static ConfigManager configManager()
	{
		ConfigManager cm = configManager;
		if (cm == null)
		{
			try
			{
				cm = RuneLite.getInjector().getInstance(ConfigManager.class);
				configManager = cm;
			}
			catch (Throwable ignore)
			{
				BridgeFaults.note("WorldSwitcherBridge.configManager", ignore);
			}
		}
		return cm;
	}

	public static boolean isAvailable()
	{
		final WorldService ws = worldService();
		return ws != null && ws.getWorlds() != null;
	}

	/** Whether {@code worldId} is a favourite — the shared {@code worldhopper.favorite_<id>} config or an in-game
	 *  favourite varbit. Matches the desktop {@code WorldHopperPlugin.isFavorite}. */
	private static boolean isFavourite(int worldId, int fav1, int fav2)
	{
		if (worldId == fav1 || worldId == fav2)
		{
			return true;
		}
		final ConfigManager cm = configManager();
		if (cm == null)
		{
			return false;
		}
		final String v = cm.getConfiguration(WORLDHOPPER_GROUP, "favorite_" + worldId);
		return "true".equals(v);
	}

	/** Mark/unmark {@code worldId} as a favourite via the shared config (WH-1). Persists; round-trips with desktop. */
	public static void setFavourite(int worldId, boolean favourite)
	{
		final ClientThread ct = clientThread;
		final ConfigManager cm = configManager();
		if (ct == null || cm == null)
		{
			return;
		}
		ct.invokeLater(() ->
		{
			try
			{
				if (favourite)
				{
					cm.setConfiguration(WORLDHOPPER_GROUP, "favorite_" + worldId, true);
				}
				else
				{
					cm.unsetConfiguration(WORLDHOPPER_GROUP, "favorite_" + worldId);
				}
				lastRefresh = 0; // re-emit the list with the new favourite flag promptly
			}
			catch (Throwable ex)
			{
				BridgeFaults.note("WorldSwitcherBridge.setFavourite", ex);
			}
		});
	}

	/** Quick-hop to the next/previous world in the configured filter (WH-3). The plugin's {@code hop(boolean)}
	 *  picks the target world (its filter logic), we read that selection, then hop to it via relog (Bug 4 — the
	 *  in-game engine hop is inert headless). */
	public static void hopDirection(boolean previous)
	{
		final ClientThread ct = clientThread;
		if (ct == null)
		{
			return;
		}
		ct.invokeLater(() ->
		{
			if (!resolveHop() || hopDirMethod == null)
			{
				log.info("[worldswitcher] quick-hop aborted: hop(boolean) unresolved");
				return;
			}
			final Client c = client;
			final WorldService ws = worldService();
			final WorldResult wr = ws == null ? null : ws.getWorlds();
			final int curWorld = c == null ? -1 : c.getWorld();
			final boolean curInList = wr != null && wr.findWorld(curWorld) != null;
			log.info("[worldswitcher] quick-hop {} gameState={} worlds={} curWorld={} curInList={}",
				previous ? "prev" : "next",
				c == null ? "?" : c.getGameState(),
				wr == null ? "null" : String.valueOf(wr.getWorlds().size()),
				curWorld, curInList);
			try
			{
				// Let the plugin select the next/prev world (it sets quickHopTargetWorld), then read + clear that
				// selection so its inert in-game onGameTick handshake never runs — we relog to the target instead.
				hopDirMethod.invoke(worldHopper, previous);
				final int target = takeQuickHopTarget();
				if (target <= 0)
				{
					log.info("[worldswitcher] quick-hop: plugin selected no target world", previous ? "prev" : "next");
					return;
				}
				log.info("[worldswitcher] quick-hop {} -> plugin selected W{}", previous ? "prev" : "next", target);
				beginRelog(c, target);
			}
			catch (Throwable ex)
			{
				log.warn("[worldswitcher] quick-hop failed", ex);
			}
		});
	}

	public static void setUiOpen(boolean open)
	{
		uiOpen = open;
		if (open)
		{
			final WorldService ws = worldService();
			if (ws != null)
			{
				ws.refresh(); // kick a fresh world-list fetch when the screen opens
			}
			lastRefresh = 0;
		}
	}

	public static String getWorldListJson()
	{
		return listJson;
	}

	/** Hop to {@code worldId} (client thread). Bug 4: the in-game engine hop is inert headless, so this hops via
	 *  relog (logout → changeWorld(target) → relogin). Requires being logged in with autologin enabled. */
	public static void hop(int worldId)
	{
		final ClientThread ct = clientThread;
		if (ct == null)
		{
			return;
		}
		ct.invokeLater(() ->
		{
			final Client c = client;
			log.info("[worldswitcher] hop {} -> gameState={}", worldId, c == null ? "?" : c.getGameState());
			beginRelog(c, worldId);
		});
	}

	public static void tick(Client c)
	{
		if (c == null)
		{
			return;
		}
		final long now = System.currentTimeMillis();
		driveRelog(c, now);   // runs regardless of uiOpen — a hop's logout may outlive the switcher screen being open
		if (!uiOpen)
		{
			return;
		}
		if (now - lastRefresh < 1500)
		{
			return;
		}
		lastRefresh = now;
		rebuild(c);
	}

	/** Read {@code WorldHopperPlugin.quickHopTargetWorld} (the world the plugin's filter just selected) and clear
	 *  it so the plugin's inert in-game onGameTick handshake never runs. Returns the selected world id, or -1.
	 *  Client thread (called straight after invoking hop(boolean)). */
	private static int takeQuickHopTarget()
	{
		try
		{
			if (fQuickHopTarget == null)
			{
				fQuickHopTarget = WorldHopperPlugin.class.getDeclaredField("quickHopTargetWorld");
				fQuickHopTarget.setAccessible(true);
			}
			final Object tgt = worldHopper == null ? null : fQuickHopTarget.get(worldHopper);
			final int id = tgt instanceof net.runelite.api.World ? ((net.runelite.api.World) tgt).getId() : -1;
			if (worldHopper != null)
			{
				fQuickHopTarget.set(worldHopper, null);   // abort the plugin's (inert) in-game hop attempt
			}
			return id;
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("WorldSwitcherBridge.takeQuickHopTarget", ex);
			return -1;
		}
	}

	/** Bug 4: start a hop-via-relog to {@code worldId}. Resolves the world's address/types from the world list,
	 *  hands the target to {@link HeadlessLogin} (which changes the world + reloging once we hit the login screen),
	 *  and arms {@link #driveRelog} to drive the logout. Client thread. */
	private static void beginRelog(Client c, int worldId)
	{
		if (c == null)
		{
			return;
		}
		if (!HeadlessLogin.isEnabled())
		{
			log.warn("[worldswitcher] relog: autologin disabled — cannot hop via relog (W{})", worldId);
			return;
		}
		final WorldService ws = worldService();
		final WorldResult wr = ws == null ? null : ws.getWorlds();
		final World w = wr == null ? null : wr.findWorld(worldId);
		if (w == null)
		{
			log.warn("[worldswitcher] relog: world {} not in the world list — aborting hop", worldId);
			return;
		}
		// Fail fast (don't arm HeadlessLogin) if we can't drive the logout: the logout button lives in the logout
		// side-panel, reachable only via the STONE10 tab of a resizable root. In FIXED (or before the toplevel is
		// built) neither stone resolves, so the hop can't proceed — abort cleanly rather than arm a relogin that
		// would strand HeadlessLogin waiting for a logout that never comes.
		if (logoutStoneId(c) == -1)
		{
			log.warn("[worldswitcher] relog: no resizable toplevel (FIXED/unbuilt) — cannot reach the logout button; aborting hop to W{}", worldId);
			return;
		}
		final boolean members = EnumSet.copyOf(w.getTypes()).contains(WorldType.MEMBERS);
		if (members)
		{
			log.info("[worldswitcher] relog: target W{} is a MEMBERS world — a free account will be bounced back", worldId);
		}
		HeadlessLogin.requestWorldHop(worldId, w.getAddress(), members);
		relogPending = true;
		relogAttempts = 0;
		relogNextMs = 0;
		log.info("[worldswitcher] relog: hopping to W{} ({}) via logout + relogin", worldId, w.getAddress());
	}

	/** Bug 4: the logout half of a hop-via-relog. While a hop is pending and we're still logged in, drive a clean
	 *  logout (open the logout side-panel via its tab stone, then invoke the logout button) so the game drops to the
	 *  login screen, where {@link HeadlessLogin} changes the world and relogins. No-op until {@link #beginRelog}
	 *  arms it; stops once the login screen is reached (HeadlessLogin owns the rest) or the attempt budget runs out. */
	private static void driveRelog(Client c, long now)
	{
		if (!relogPending || now < relogNextMs)
		{
			return;
		}
		relogNextMs = now + 600;
		final GameState gs = c.getGameState();
		if (gs == GameState.LOGIN_SCREEN)
		{
			log.info("[worldswitcher] relog: reached LOGIN_SCREEN — HeadlessLogin takes over the relogin");
			relogPending = false;
			return;
		}
		if (gs != GameState.LOGGED_IN)
		{
			return;   // LOGGING_OUT / LOADING — wait for a stable state
		}
		if (++relogAttempts > MAX_RELOG_ATTEMPTS)
		{
			log.warn("[worldswitcher] relog: still LOGGED_IN after {} logout attempt(s) — giving up", relogAttempts - 1);
			relogPending = false;
			HeadlessLogin.cancelWorldHop();   // disarm the relogin we armed, so HeadlessLogin isn't left waiting
			return;
		}
		try
		{
			final Widget logoutBtn = c.getWidget(InterfaceID.Logout.LOGOUT);
			if (logoutBtn == null)
			{
				// The logout side-panel isn't open yet, so the logout button widget doesn't exist — open the
				// logout tab first (STONE10 in both resizable roots) and retry next cycle once the panel builds.
				openLogoutTab(c);
				log.info("[worldswitcher] relog: opening the logout panel (attempt {}/{})", relogAttempts, MAX_RELOG_ATTEMPTS);
				return;
			}
			// Bug 4 diagnostic (once): which ops does the logout button actually carry? Confirms the id + op index.
			if (!loggedLogoutOps)
			{
				loggedLogoutOps = true;
				log.info("[worldswitcher] relog: logout widget id={} actions={} hasOpListener={}",
					logoutBtn.getId(), java.util.Arrays.toString(logoutBtn.getActions()),
					logoutBtn.getOnOpListener() != null);
			}
			// Invoke the logout button the way a real click does: the engine's CC_OP menu action for op 1. The raw
			// script-event replay (createScriptEventBuilder) was confirmed inert on device, so go through the full
			// menu-action path the engine uses for a genuine widget click (the same path TabInterface uses for
			// interface buttons), which is more likely to drive the engine's logout (packet) than a bare CS2 run.
			c.menuAction(-1, InterfaceID.Logout.LOGOUT, net.runelite.api.MenuAction.CC_OP, 1, -1, "Logout", "");
			log.info("[worldswitcher] relog: invoked logout menuAction (attempt {}/{})", relogAttempts, MAX_RELOG_ATTEMPTS);
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("WorldSwitcherBridge.driveRelog", ex);
		}
	}

	/** Open the logout side-panel so {@code Logout.LOGOUT} is built, by running the logout tab stone's op the same
	 *  way the chrome opens tabs ({@code createScriptEventBuilder}). STONE10 is the logout tab in BOTH resizable
	 *  roots (ToplevelPreEoc / ToplevelOsrsStretch); pick whichever toplevel is currently loaded. Client thread. */
	private static void openLogoutTab(Client c)
	{
		try
		{
			final int stoneId = logoutStoneId(c);
			if (stoneId == -1)
			{
				return;   // neither resizable toplevel loaded (e.g. FIXED) — can't resolve the logout tab
			}
			final Widget stone = c.getWidget(stoneId);
			final Object[] op = stone == null ? null : stone.getOnOpListener();
			if (op == null)
			{
				return;
			}
			c.createScriptEventBuilder(op).setSource(stone).setOp(1).build().run();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("WorldSwitcherBridge.openLogoutTab", ex);
		}
	}

	/** The logout tab stone id for the currently-loaded resizable toplevel (STONE10 in both ToplevelPreEoc and
	 *  ToplevelOsrsStretch), or -1 if neither is loaded (FIXED / not yet built). Client thread. */
	private static int logoutStoneId(Client c)
	{
		if (c.getWidget(InterfaceID.ToplevelPreEoc.STONE10) != null)
		{
			return InterfaceID.ToplevelPreEoc.STONE10;
		}
		if (c.getWidget(InterfaceID.ToplevelOsrsStretch.STONE10) != null)
		{
			return InterfaceID.ToplevelOsrsStretch.STONE10;
		}
		return -1;
	}

	private static void rebuild(Client c)
	{
		try
		{
			final WorldService ws = worldService();
			final WorldResult res = ws == null ? null : ws.getWorlds();
			if (res == null)
			{
				listJson = "{\"available\":false}";
				return;
			}
			final List<World> worlds = res.getWorlds();
			final int current = c.getWorld();
			// In-game favourite worlds (the two world-switcher favourite slots) — read once per rebuild.
			int fav1 = 0, fav2 = 0;
			try
			{
				fav1 = c.getVarbitValue(VarbitID.WORLDSWITCHER_FAVOURITE_1);
				fav2 = c.getVarbitValue(VarbitID.WORLDSWITCHER_FAVOURITE_2);
			}
			catch (Throwable ignore)
			{
				// not logged in / varbit not loaded yet — config favourites still apply
			}
			final StringBuilder sb = new StringBuilder(16384);
			sb.append("{\"available\":true,\"current\":").append(current).append(",\"worlds\":[");
			boolean first = true;
			for (World w : worlds)
			{
				final EnumSet<WorldType> types = EnumSet.copyOf(w.getTypes());
				if (!first)
				{
					sb.append(',');
				}
				first = false;
				sb.append('{')
					.append("\"id\":").append(w.getId()).append(',')
					.append("\"players\":").append(w.getPlayers()).append(',')
					.append("\"location\":").append(w.getLocation()).append(',')
					.append("\"favourite\":").append(isFavourite(w.getId(), fav1, fav2)).append(',')
					.append("\"members\":").append(types.contains(WorldType.MEMBERS)).append(',')
					.append("\"pvp\":").append(types.contains(WorldType.PVP)).append(',')
					.append("\"highRisk\":").append(types.contains(WorldType.HIGH_RISK)).append(',')
					.append("\"activity\":").append(BridgeJson.quoted(w.getActivity())).append(',')
					.append("\"types\":[");
				boolean ft = true;
				for (WorldType t : types)
				{
					if (!ft)
					{
						sb.append(',');
					}
					ft = false;
					sb.append(BridgeJson.quoted(t.name()));
				}
				sb.append("]}");
			}
			sb.append("]}");
			listJson = sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("WorldSwitcherBridge.rebuild", ex);
			listJson = "{\"available\":false}";
		}
	}

	private static boolean resolveHop()
	{
		if (hopMethod != null && worldHopper != null)
		{
			return true;
		}
		final PluginManager pm = pluginManager;
		if (pm == null)
		{
			return false;
		}
		try
		{
			for (Plugin p : pm.getPlugins())
			{
				if (p instanceof WorldHopperPlugin)
				{
					final Method m = WorldHopperPlugin.class.getDeclaredMethod("hop", int.class);
					m.setAccessible(true);
					worldHopper = p;
					hopMethod = m;
					try
					{
						final Method dir = WorldHopperPlugin.class.getDeclaredMethod("hop", boolean.class);
						dir.setAccessible(true);
						hopDirMethod = dir;
					}
					catch (Throwable ignore)
					{
						hopDirMethod = null; // quick-hop unavailable on an older plugin; row-tap hop still works
					}
					return true;
				}
			}
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("WorldSwitcherBridge.resolveHop", ex);
		}
		return false;
	}

}
