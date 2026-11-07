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

import java.lang.management.LockInfo;
import java.lang.management.ManagementFactory;
import java.lang.management.MonitorInfo;
import java.lang.management.ThreadInfo;
import java.lang.management.ThreadMXBean;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.Player;
import net.runelite.client.RuneLiteProperties;
import net.runelite.client.externalplugins.ExternalPluginManager;
import net.runelite.client.externalplugins.PluginHubManifest;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginDescriptor;
import net.runelite.client.plugins.PluginManager;

/**
 * The engine's half of the in-app "Share logs" report, plus a freeze watchdog that leaves a thread dump in
 * {@code client.log}.
 *
 * <p>{@link #engineReport()} is called by the native shells while they build the report file. It returns the
 * RuneLite version, game state, heap, the plugins that are on (Plugin Hub plugins with their version) and a dump of
 * every thread. It never waits on the client thread, so a frozen engine still answers; the shells call it off their
 * UI thread with a time limit anyway.
 *
 * <p>The watchdog covers the case where the player has to close the app to get out of a freeze: the live thread
 * state is gone by the time they can share anything. When the client cycle stops advancing for
 * {@link #FREEZE_AFTER_MS} it writes one thread dump to {@code client.log}, which survives the restart and is in the
 * next report. When the cause is the game thread itself having ended (an error escaped the game loop), the log line
 * and the report's "Client cycle" line say so.
 */
@Slf4j
public final class DiagnosticsBridge
{
	/** How long the client cycle has to stand still before the watchdog logs a thread dump. */
	static final long FREEZE_AFTER_MS = 20_000;
	private static final long POLL_MS = 2_000;
	/** Freeze dumps written per session at most, so a recurring stall cannot fill client.log. */
	private static final int MAX_FREEZE_DUMPS = 3;
	private static final int MAX_FRAMES = 48;
	private static final int MAX_DUMP_CHARS = 200_000;

	private static volatile PluginManager pluginManager;
	private static volatile Client client;
	private static Thread watchdog; // guarded by DiagnosticsBridge.class

	// Watchdog state, read by engineReport for the "client cycle" line.
	private static volatile int lastCycle = Integer.MIN_VALUE;
	private static volatile long lastCycleChangeNs;
	/**
	 * The game's own thread (the client names it {@value #GAME_THREAD_NAME}), found once the cycle is seen advancing.
	 * An error that escapes the game loop ends it and nothing restarts it: the picture freezes until the app is
	 * reopened. Only a thread seen alive can be reported gone, so a build that names it differently reports nothing.
	 */
	private static volatile Thread gameThread;
	static final String GAME_THREAD_NAME = "Client";
	/**
	 * For {@link #gameThreadCpuNanos()}, which the app's main thread reads. Fetched on the watchdog thread alongside
	 * {@link #gameThread}, because the first fetch loads a lot of classes and the main thread can't spare the wait.
	 */
	private static volatile ThreadMXBean threadBean;
	/** Polls spent looking for the game thread; the search stops after {@link #MAX_GAME_THREAD_SEARCHES}. */
	private static int gameThreadSearches; // watchdog thread only
	private static final int MAX_GAME_THREAD_SEARCHES = 30;

	private DiagnosticsBridge()
	{
	}

	/** Wired from {@code HeadlessClientUI} once the plugin manager and client exist; starts the freeze watchdog. */
	public static synchronized void init(PluginManager pm, Client c)
	{
		pluginManager = pm;
		client = c;
		if (watchdog == null && c != null)
		{
			watchdog = new Thread(DiagnosticsBridge::watch, "rm-freeze-watchdog");
			watchdog.setDaemon(true);
			watchdog.start();
		}
	}

	/**
	 * The engine section of a "Share logs" report, as {@code {"names":[...],"text":"..."}}. {@code names} holds the
	 * logged-in character's name(s), which the shell removes from the whole report (this text included) before it
	 * is shared; {@code text} is plain text. Safe from any thread.
	 */
	public static String engineReport()
	{
		final Set<String> names = new LinkedHashSet<>();
		final StringBuilder sb = new StringBuilder(16_384);
		try
		{
			appendEngine(sb, names);
		}
		catch (Throwable t)
		{
			sb.append("(engine report failed: ").append(t).append(")\n");
		}
		final StringBuilder json = new StringBuilder(sb.length() + 64);
		json.append("{\"names\":[");
		boolean first = true;
		for (String n : names)
		{
			json.append(first ? "" : ",").append(BridgeJson.quoted(n));
			first = false;
		}
		json.append("],\"text\":").append(BridgeJson.quoted(sb.toString())).append('}');
		return json.toString();
	}

	private static void appendEngine(StringBuilder sb, Set<String> names)
	{
		final Client c = client;
		final Runtime rt = Runtime.getRuntime();
		sb.append("RuneLite ").append(RuneLiteProperties.getVersion());
		if (c != null)
		{
			final GameState gs = c.getGameState();
			sb.append(" | ").append(gs);
			if (gs == GameState.LOGGED_IN || gs == GameState.LOADING || gs == GameState.HOPPING)
			{
				sb.append(" | world ").append(c.getWorld());
			}
		}
		sb.append(" | heap ").append((rt.totalMemory() - rt.freeMemory()) >> 20).append('/')
			.append(rt.maxMemory() >> 20).append(" MB\n");
		sb.append("Audio: ").append(HeadlessAudio.report()).append('\n');
		final int fpsCap = MobileUiBridge.fpsCap();
		sb.append("Frame-rate cap: ").append(fpsCap > 0 ? fpsCap + " fps" : "none").append('\n');

		final long changedNs = lastCycleChangeNs;
		if (c != null && changedNs != 0)
		{
			final long stillMs = (System.nanoTime() - changedNs) / 1_000_000L;
			final String how;
			if (gameThreadExited())
			{
				how = " (the game thread has exited)";
			}
			else
			{
				how = stillMs < POLL_MS * 2 ? " (running)" : " (unchanged for " + stillMs / 1000 + " s)";
			}
			sb.append("Client cycle ").append(c.getGameCycle()).append(how).append('\n');
		}

		addName(names, System.getenv("JX_DISPLAY_NAME"));
		if (c != null)
		{
			try
			{
				final Player me = c.getLocalPlayer();
				if (me != null)
				{
					addName(names, me.getName());
				}
			}
			catch (RuntimeException e)
			{
				// read off the client thread; a torn read just means no extra name to remove
			}
		}

		appendPlugins(sb);
		sb.append('\n').append(threadDump());
	}

	private static void addName(Set<String> names, String name)
	{
		if (name != null && !name.trim().isEmpty())
		{
			names.add(name.trim());
		}
	}

	private static void appendPlugins(StringBuilder sb)
	{
		final PluginManager pm = pluginManager;
		if (pm == null)
		{
			sb.append("Plugins: (not loaded yet)\n");
			return;
		}
		final List<String> hub = new ArrayList<>();
		final Set<String> builtIn = new TreeSet<>(String.CASE_INSENSITIVE_ORDER);
		for (Plugin p : pm.getPlugins())
		{
			final PluginDescriptor d = p.getClass().getAnnotation(PluginDescriptor.class);
			final String name = d != null ? d.name() : p.getClass().getSimpleName();
			final boolean on = pm.isPluginEnabled(p);
			final PluginHubManifest.JarData jar = ExternalPluginManager.getJarData(p.getClass());
			if (jar != null)
			{
				final PluginHubManifest.DisplayData dd = ExternalPluginManager.getDisplayData(p.getClass());
				final String hash = jar.getJarHash();
				hub.add("  " + name + " (" + jar.getInternalName() + ")"
					+ (dd != null && dd.getVersion() != null ? " v" + dd.getVersion() : "")
					+ (hash != null ? " build " + hash.substring(0, Math.min(8, hash.length())) : "")
					+ (on ? (pm.isPluginActive(p) ? " | on" : " | on, not started") : " | off"));
			}
			else if (on && (d == null || !d.hidden()))
			{
				builtIn.add(name);
			}
		}
		hub.sort(String.CASE_INSENSITIVE_ORDER);
		sb.append("Plugin Hub plugins (").append(hub.size()).append("):\n");
		for (String line : hub)
		{
			sb.append(line).append('\n');
		}
		sb.append("Built-in plugins on (").append(builtIn.size()).append("): ").append(String.join(", ", builtIn))
			.append('\n');
	}

	/**
	 * Every thread's state and stack, deadlocked threads first, capped at {@link #MAX_DUMP_CHARS}. Uses the
	 * management API for lock owners and deadlock detection, and falls back to {@link Thread#getAllStackTraces()}
	 * when that module is missing from the runtime.
	 */
	static String threadDump()
	{
		final StringBuilder sb = new StringBuilder(32_768);
		try
		{
			final ThreadMXBean mx = ManagementFactory.getThreadMXBean();
			final long[] dead = mx.findDeadlockedThreads();
			final Set<Long> deadIds = new HashSet<>();
			if (dead != null)
			{
				for (long id : dead)
				{
					deadIds.add(id);
				}
			}
			final ThreadInfo[] infos = mx.dumpAllThreads(true, true);
			Arrays.sort(infos, Comparator.comparing((ThreadInfo ti) -> !deadIds.contains(ti.getThreadId()))
				.thenComparing(ti -> ti.getThreadName(), String.CASE_INSENSITIVE_ORDER));
			sb.append("Threads (").append(infos.length).append("), deadlocked: ")
				.append(deadIds.isEmpty() ? "none" : deadIds.size() + " threads").append('\n');
			for (ThreadInfo ti : infos)
			{
				if (sb.length() > MAX_DUMP_CHARS)
				{
					sb.append("... (thread dump cut at ").append(MAX_DUMP_CHARS).append(" characters)\n");
					break;
				}
				appendThread(sb, ti, deadIds.contains(ti.getThreadId()));
			}
			return sb.toString();
		}
		catch (Throwable t)
		{
			sb.setLength(0);
			sb.append("(lock details unavailable: ").append(t.getClass().getSimpleName()).append(")\n");
		}
		final List<Map.Entry<Thread, StackTraceElement[]>> all = new ArrayList<>(Thread.getAllStackTraces().entrySet());
		all.sort(Comparator.comparing(e -> e.getKey().getName(), String.CASE_INSENSITIVE_ORDER));
		sb.append("Threads (").append(all.size()).append(")\n");
		for (Map.Entry<Thread, StackTraceElement[]> e : all)
		{
			if (sb.length() > MAX_DUMP_CHARS)
			{
				sb.append("... (thread dump cut at ").append(MAX_DUMP_CHARS).append(" characters)\n");
				break;
			}
			final Thread t = e.getKey();
			sb.append('"').append(t.getName()).append('"').append(t.isDaemon() ? " daemon " : " ").append(t.getState())
				.append('\n');
			appendFrames(sb, e.getValue(), null);
		}
		return sb.toString();
	}

	private static void appendThread(StringBuilder sb, ThreadInfo ti, boolean deadlocked)
	{
		sb.append('"').append(ti.getThreadName()).append('"').append(ti.isDaemon() ? " daemon " : " ")
			.append(ti.getThreadState());
		if (ti.isInNative())
		{
			sb.append(" (in native)");
		}
		if (deadlocked)
		{
			sb.append(" DEADLOCKED");
		}
		final LockInfo lock = ti.getLockInfo();
		if (lock != null)
		{
			sb.append(" on ").append(lock);
			if (ti.getLockOwnerName() != null)
			{
				sb.append(" held by \"").append(ti.getLockOwnerName()).append('"');
			}
		}
		sb.append('\n');
		appendFrames(sb, ti.getStackTrace(), ti.getLockedMonitors());
	}

	private static void appendFrames(StringBuilder sb, StackTraceElement[] frames, MonitorInfo[] held)
	{
		final int n = Math.min(frames.length, MAX_FRAMES);
		for (int i = 0; i < n; i++)
		{
			sb.append("\tat ").append(frames[i]).append('\n');
			if (held != null)
			{
				for (MonitorInfo m : held)
				{
					if (m.getLockedStackDepth() == i)
					{
						sb.append("\t- holds ").append(m).append('\n');
					}
				}
			}
		}
		if (frames.length > n)
		{
			sb.append("\t... ").append(frames.length - n).append(" more\n");
		}
	}

	/** See {@link MobileUiBridge#gameThreadCpuNanos()}. */
	static long gameThreadCpuNanos()
	{
		final Thread t = gameThread;
		final ThreadMXBean bean = threadBean;
		if (t == null || bean == null)
		{
			return -1;
		}
		try
		{
			return bean.getThreadCpuTime(t.getId());
		}
		catch (Throwable e)
		{
			return -1;
		}
	}

	private static ThreadMXBean fetchThreadBean()
	{
		try
		{
			return ManagementFactory.getThreadMXBean();
		}
		catch (Throwable e)
		{
			return null; // the management module can be missing from the runtime, as in threadDump
		}
	}

	private static boolean gameThreadExited()
	{
		final Thread t = gameThread;
		return t != null && !t.isAlive();
	}

	/** A live thread called {@code name}, or null. Walks the thread groups: no stacks, no safepoint. */
	static Thread findThread(String name)
	{
		ThreadGroup root = Thread.currentThread().getThreadGroup();
		while (root.getParent() != null)
		{
			root = root.getParent();
		}
		final Thread[] all = new Thread[root.activeCount() + 16];
		final int n = root.enumerate(all, true);
		for (int i = 0; i < n; i++)
		{
			if (name.equals(all[i].getName()))
			{
				return all[i];
			}
		}
		return null;
	}

	private static void watch()
	{
		int dumps = 0;
		boolean frozen = false;
		boolean checkFailed = false;
		long lastPollNs = System.nanoTime();
		while (true)
		{
			try
			{
				Thread.sleep(POLL_MS);
			}
			catch (InterruptedException e)
			{
				return;
			}
			try
			{
				final long now = System.nanoTime();
				final Client c = client;
				// This thread was held up too (the process suspended in the background, or a long GC pause): the
				// client never had the chance to run, so restart the clock rather than call it a freeze.
				final boolean heldUp = now - lastPollNs > POLL_MS * 3 * 1_000_000L;
				lastPollNs = now;
				if (c == null)
				{
					continue;
				}
				final int cycle = c.getGameCycle();
				if (cycle != lastCycle || heldUp || lastCycleChangeNs == 0)
				{
					if (frozen && cycle != lastCycle)
					{
						log.info("[freeze] the client thread is running again after {} s",
							(now - lastCycleChangeNs) / 1_000_000_000L);
					}
					frozen = false;
					lastCycle = cycle;
					lastCycleChangeNs = now;
					if (gameThread == null && gameThreadSearches < MAX_GAME_THREAD_SEARCHES)
					{
						gameThreadSearches++;
						threadBean = threadBean != null ? threadBean : fetchThreadBean();
						gameThread = findThread(GAME_THREAD_NAME);
					}
					continue;
				}
				final GameState gs = c.getGameState();
				if (frozen || gs == GameState.UNKNOWN || gs == GameState.STARTING
					|| now - lastCycleChangeNs < FREEZE_AFTER_MS * 1_000_000L)
				{
					continue;
				}
				frozen = true;
				if (dumps++ >= MAX_FREEZE_DUMPS)
				{
					continue;
				}
				if (gameThreadExited())
				{
					// The cause is the error logged when it ended, further up this log.
					log.warn("[freeze] the game thread has exited ({}): the game can't go on until the app restarts; "
						+ "thread dump:\n{}", gs, threadDump());
				}
				else
				{
					log.warn("[freeze] the client thread has not run for {} s ({}); thread dump:\n{}",
						(now - lastCycleChangeNs) / 1_000_000_000L, gs, threadDump());
				}
			}
			catch (Throwable t)
			{
				if (!checkFailed)
				{
					checkFailed = true; // once: a check that keeps failing must not write every 2 s
					log.warn("[freeze] watchdog check failed", t);
				}
			}
		}
	}
}
