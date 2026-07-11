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

import java.util.ArrayList;
import java.util.List;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.MessageNode;
import net.runelite.api.NPC;
import net.runelite.api.Player;
import net.runelite.api.Skill;
import net.runelite.api.WorldView;
import net.runelite.api.coords.WorldPoint;
import net.runelite.api.gameval.VarPlayerID;
import net.runelite.api.gameval.VarbitID;

/**
 * W3 Feature-A phase A2: the <b>read-only</b> HUD <em>data</em> snapshot the native HUD veneers consume each
 * display tick. Whereas {@link MobileChromeBridge} publishes desktop HUD <em>geometry</em> (where the engine
 * minimap/orbs/chat live, for cover-and-proxy), this publishes the <em>content</em> the native chat / minimap /
 * orbs reproduce: chat lines (type/name/value/timestamp), orb values (HP/prayer/run/spec + poison/stamina), and
 * minimap state (local player world position, compass angle, and nearby actor dots as tile offsets).
 *
 * <p>A0 settled that a clean edge-to-edge scene needs the engine HUD {@code setHidden} (the only clean remover),
 * so the native side must redraw the HUD from data — which this bridge supplies. The data is entirely
 * rendering-path-agnostic (it reads {@code Client} / world-view APIs, not the framebuffer), so it is unaffected
 * by a future GPU renderer.
 *
 * <p>Thread model mirrors {@link MobileChromeBridge} / {@link MobileUiBridge}: {@link #tick(Client)} runs on the
 * client thread (from {@code Hooks.draw}), where messages, varps and actor positions are safe to read, and
 * publishes an escaped-JSON snapshot into a volatile; {@link #getSnapshot()} / {@link #getSeq()} are read
 * lock-free from the native JNI thread. <b>Never mutates anything.</b> Inert unless {@code -Drunelite.huddata=true}.
 *
 * <p>For the desktop de-risk it also emits, once, a single bash-parseable line ({@code [huddata] HUDDATA_READ …})
 * so a harness can md5-gate that the snapshot is faithful (the login "Welcome to Old School RuneScape" message is
 * present, orb values are plausible, the local player resolved) and live (the fingerprint changed over the window).
 */
@Slf4j
public final class HudDataBridge
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.huddata");
	// The HUDDATA_READ verdict (counts only) is always safe; the full SNAPSHOT dumps the recent chat lines
	// including private-message text, so it is opt-in (off by default) — arm with -Drunelite.huddata.dumpSnapshot.
	private static final boolean DUMP_SNAPSHOT = Boolean.getBoolean("runelite.huddata.dumpSnapshot");

	private static final int CHAT_MAX = 40;     // most-recent chat lines published
	private static final int DOT_MAX = 24;      // minimap dots (nearby actors) published
	private static final int DOT_RANGE = 32;    // only actors within +/- this many tiles become dots
	private static final int VERDICT_FRAME = 120;   // ~2.4s of LOGGED_IN frames — long enough to observe liveness

	private static final String WELCOME = "Welcome to Old School RuneScape";

	private static volatile String snapshotJson = "{\"enabled\":false}";
	private static volatile int seq;

	// Desktop de-risk accumulators.
	private static int loggedInFrames;
	private static boolean verdictEmitted;
	private static boolean sawWelcome;
	private static long firstFingerprint = Long.MIN_VALUE;
	private static boolean live;

	private HudDataBridge()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/** Latest read-only HUD-data snapshot as escaped JSON (native reads this each display tick). */
	public static String getSnapshot()
	{
		return snapshotJson;
	}

	/** Monotonic counter bumped each publish; native skips re-parsing when unchanged. */
	public static int getSeq()
	{
		return seq;
	}

	public static void tick(Client c)
	{
		try
		{
			tickImpl(c);
		}
		catch (RuntimeException e)
		{
			BridgeFaults.note("HudDataBridge.tick", e);
		}
	}

	private static void tickImpl(Client c)
	{
		if (!ENABLED || c == null)
		{
			return;
		}

		if (c.getGameState() != GameState.LOGGED_IN)
		{
			snapshotJson = "{\"enabled\":true,\"loggedIn\":false}";
			return;
		}

		// ---- orbs ----
		final int hp = safeBoosted(c, Skill.HITPOINTS);
		final int hpMax = safeReal(c, Skill.HITPOINTS);
		final int pray = safeBoosted(c, Skill.PRAYER);
		final int prayMax = safeReal(c, Skill.PRAYER);
		final int energy = clampPct(safeEnergy(c) / 100);
		final int spec = clampPct(safeVarp(c, VarPlayerID.SA_ENERGY) / 10);
		final int run = safeVarp(c, VarPlayerID.OPTION_RUN);
		final int specEnabled = safeVarp(c, VarPlayerID.SA_ATTACK);
		final int poison = safeVarp(c, VarPlayerID.POISON);
		final int stamina = safeVarbit(c, VarbitID.STAMINA_ACTIVE);

		// ---- minimap (local player + compass + nearby actor dots) ----
		int px = Integer.MIN_VALUE;
		int py = Integer.MIN_VALUE;
		int plane = -1;
		final Player self = c.getLocalPlayer();
		if (self != null)
		{
			final WorldPoint wp = self.getWorldLocation();
			if (wp != null)
			{
				px = wp.getX();
				py = wp.getY();
				plane = wp.getPlane();
			}
		}
		final int mapAngle = safeMapAngle(c);

		int playerCount = 0;
		int npcCount = 0;
		final List<int[]> dots = new ArrayList<>();   // {type(1=npc,2=player), dx, dy}
		final WorldView wv = safeWorldView(c);
		if (wv != null && px != Integer.MIN_VALUE)
		{
			try
			{
				for (final Player p : wv.players())
				{
					if (p == null || p == self)
					{
						continue;
					}
					playerCount++;
					addDot(dots, 2, p, px, py);
				}
			}
			catch (RuntimeException ignore)
			{
				BridgeFaults.note("HudDataBridge.tickImpl.players", ignore);
			}
			try
			{
				for (final NPC n : wv.npcs())
				{
					if (n == null)
					{
						continue;
					}
					npcCount++;
					addDot(dots, 1, n, px, py);
				}
			}
			catch (RuntimeException ignore)
			{
				BridgeFaults.note("HudDataBridge.tickImpl.npcs", ignore);
			}
		}

		// ---- chat (most-recent CHAT_MAX lines, oldest-first) ----
		final List<MessageNode> all = new ArrayList<>();
		try
		{
			for (final MessageNode node : c.getMessages())
			{
				if (node != null)
				{
					all.add(node);
				}
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudDataBridge.tickImpl", ignore);
		}
		final int from = Math.max(0, all.size() - CHAT_MAX);

		// ---- build snapshot ----
		final StringBuilder sb = new StringBuilder(2048);
		sb.append("{\"enabled\":true,\"loggedIn\":true,\"seq\":").append(seq + 1);
		sb.append(",\"orbs\":{\"hp\":").append(hp).append(",\"hpMax\":").append(hpMax)
			.append(",\"pray\":").append(pray).append(",\"prayMax\":").append(prayMax)
			.append(",\"energy\":").append(energy).append(",\"spec\":").append(spec)
			.append(",\"run\":").append(run).append(",\"specEnabled\":").append(specEnabled)
			.append(",\"poison\":").append(poison).append(",\"stamina\":").append(stamina).append('}');
		sb.append(",\"minimap\":{\"plane\":").append(plane).append(",\"px\":").append(px).append(",\"py\":").append(py)
			.append(",\"mapAngle\":").append(mapAngle)
			.append(",\"players\":").append(playerCount).append(",\"npcs\":").append(npcCount)
			.append(",\"dots\":[");
		for (int i = 0; i < dots.size(); i++)
		{
			final int[] d = dots.get(i);
			if (i > 0)
			{
				sb.append(',');
			}
			sb.append('[').append(d[0]).append(',').append(d[1]).append(',').append(d[2]).append(']');
		}
		sb.append("]}");
		sb.append(",\"chat\":[");
		boolean welcomeThisFrame = false;
		for (int i = from; i < all.size(); i++)
		{
			final MessageNode node = all.get(i);
			final String type = node.getType() == null ? "" : node.getType().name();
			final String name = node.getName();
			final String value = node.getValue();
			if (value != null && value.contains(WELCOME))
			{
				welcomeThisFrame = true;
			}
			if (i > from)
			{
				sb.append(',');
			}
			sb.append("{\"type\":\"").append(type).append("\",\"name\":");
			appendEscaped(sb, name);
			sb.append(",\"value\":");
			appendEscaped(sb, value);
			sb.append(",\"ts\":").append(safeTs(node)).append('}');
		}
		sb.append("]}");

		snapshotJson = sb.toString();
		seq++;

		// ---- desktop de-risk: liveness + one-shot faithful/structural verdict ----
		loggedInFrames++;
		sawWelcome |= welcomeThisFrame;
		// Fingerprint folds in actor DOT positions + chat size, not just counts — so a wandering NPC, an arriving
		// chat line, or the player moving all register as "live" (count-only would miss NPCs moving in place).
		final long fp = fingerprint(px, py, plane, mapAngle, dotsHash(dots), all.size());
		if (firstFingerprint == Long.MIN_VALUE)
		{
			firstFingerprint = fp;
		}
		else if (fp != firstFingerprint)
		{
			live = true;
		}

		if (!verdictEmitted && loggedInFrames >= VERDICT_FRAME)
		{
			verdictEmitted = true;
			log.info("[huddata] HUDDATA_READ chatN={} welcomeMsg={} hp={} hpMax={} pray={} prayMax={} energy={} "
					+ "spec={} run={} specEnabled={} plane={} px={} py={} mapAngle={} players={} npcs={} dots={} live={}",
				all.size(), b01(sawWelcome), hp, hpMax, pray, prayMax, energy,
				spec, run, specEnabled, plane, px, py, mapAngle, playerCount, npcCount, dots.size(), b01(live));
			if (DUMP_SNAPSHOT)
			{
				log.info("[huddata] SNAPSHOT {}", snapshotJson);
			}
		}
	}

	// ---- internals ----------------------------------------------------------------------------------------

	private static void addDot(List<int[]> dots, int type, net.runelite.api.Actor a, int px, int py)
	{
		if (dots.size() >= DOT_MAX)
		{
			return;
		}
		final WorldPoint wp = a.getWorldLocation();
		if (wp == null)
		{
			return;
		}
		final int dx = wp.getX() - px;
		final int dy = wp.getY() - py;
		if (Math.abs(dx) <= DOT_RANGE && Math.abs(dy) <= DOT_RANGE)
		{
			dots.add(new int[]{type, dx, dy});
		}
	}

	private static long fingerprint(int px, int py, int plane, int mapAngle, long dotsHash, int chatSize)
	{
		long h = 1125899906842597L;
		h = 31 * h + px;
		h = 31 * h + py;
		h = 31 * h + plane;
		h = 31 * h + mapAngle;
		h = 31 * h + dotsHash;
		h = 31 * h + chatSize;
		return h;
	}

	private static long dotsHash(List<int[]> dots)
	{
		long h = 17;
		for (final int[] d : dots)
		{
			h = 31 * h + d[0];
			h = 31 * h + d[1];
			h = 31 * h + d[2];
		}
		return h;
	}

	private static void appendEscaped(StringBuilder sb, String s)
	{
		sb.append('"');
		if (s != null)
		{
			for (int i = 0; i < s.length(); i++)
			{
				final char ch = s.charAt(i);
				switch (ch)
				{
					case '"':
						sb.append("\\\"");
						break;
					case '\\':
						sb.append("\\\\");
						break;
					case '\n':
						sb.append("\\n");
						break;
					case '\r':
						sb.append("\\r");
						break;
					case '\t':
						sb.append("\\t");
						break;
					default:
						if (ch < 0x20)
						{
							sb.append(String.format("\\u%04x", (int) ch));
						}
						else
						{
							sb.append(ch);
						}
						break;
				}
			}
		}
		sb.append('"');
	}

	private static int clampPct(int v)
	{
		return v < 0 ? 0 : Math.min(v, 100);
	}

	private static int safeBoosted(Client c, Skill s)
	{
		try
		{
			return c.getBoostedSkillLevel(s);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudDataBridge.safeBoosted", ex);
			return -1;
		}
	}

	private static int safeReal(Client c, Skill s)
	{
		try
		{
			return c.getRealSkillLevel(s);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudDataBridge.safeReal", ex);
			return -1;
		}
	}

	private static int safeEnergy(Client c)
	{
		try
		{
			return c.getEnergy();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudDataBridge.safeEnergy", ex);
			return 0;
		}
	}

	private static int safeVarp(Client c, int id)
	{
		try
		{
			return c.getVarpValue(id);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudDataBridge.safeVarp", ex);
			return -1;
		}
	}

	private static int safeVarbit(Client c, int id)
	{
		try
		{
			return c.getVarbitValue(id);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudDataBridge.safeVarbit", ex);
			return -1;
		}
	}

	private static int safeMapAngle(Client c)
	{
		try
		{
			// upstream rev239 removed the deprecated getMapAngle() alias AND widened the camera yaw from 11-bit
			// (JAU, 0-2047) to 14-bit (JAU14, 0-16383). The old getMapAngle() returned the 11-bit value the native
			// minimap "mapAngle" contract expects, so shift the 14-bit yaw back down by 3 (16384/2048 = 8) to keep
			// the published value byte-identical to before the merge.
			return c.getCameraYaw() >> 3;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudDataBridge.safeMapAngle", ex);
			return -1;
		}
	}

	private static WorldView safeWorldView(Client c)
	{
		try
		{
			return c.getTopLevelWorldView();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudDataBridge.safeWorldView", ex);
			return null;
		}
	}

	private static int safeTs(MessageNode node)
	{
		try
		{
			return node.getTimestamp();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudDataBridge.safeTs", ex);
			return 0;
		}
	}

	private static int b01(boolean v)
	{
		return v ? 1 : 0;
	}
}
