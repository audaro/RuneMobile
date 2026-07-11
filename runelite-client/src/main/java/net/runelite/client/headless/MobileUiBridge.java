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

import java.awt.Component;
import java.awt.EventQueue;
import java.awt.Graphics2D;
import java.awt.Point;
import java.awt.event.KeyEvent;
import java.awt.event.MouseEvent;
import java.awt.image.BufferedImage;
import java.awt.image.DataBufferInt;
import java.lang.reflect.Field;
import java.lang.reflect.ParameterizedType;
import java.lang.reflect.Type;
import java.util.ArrayDeque;
import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import javax.swing.JPanel;
import javax.swing.JWindow;
import javax.swing.SwingUtilities;
import net.runelite.client.ui.PluginPanel;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.widgets.Widget;
import net.runelite.api.widgets.WidgetInfo;
import net.runelite.client.RuneLite;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.externalplugins.ExternalPluginClient;
import net.runelite.client.externalplugins.ExternalPluginManager;
import net.runelite.client.externalplugins.PluginHubManifest;
import net.runelite.client.config.ChatColorConfig;
import net.runelite.client.config.Config;
import net.runelite.client.config.ConfigDescriptor;
import net.runelite.client.config.ConfigItem;
import net.runelite.client.config.ConfigItemDescriptor;
import net.runelite.client.config.ConfigManager;
import net.runelite.client.config.ConfigSection;
import net.runelite.client.config.ConfigSectionDescriptor;
import net.runelite.client.config.Keybind;
import net.runelite.client.config.Notification;
import net.runelite.client.config.Range;
import net.runelite.client.config.RuneLiteConfig;
import net.runelite.client.config.Units;
import net.runelite.client.util.Text;
import net.runelite.client.eventbus.EventBus;
import net.runelite.client.eventbus.Subscribe;
import net.runelite.client.events.ConfigChanged;
import net.runelite.client.events.ExternalPluginsChanged;
import net.runelite.client.events.PluginChanged;
import net.runelite.client.events.ScreenshotTaken;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginDescriptor;
import net.runelite.client.plugins.PluginInstantiationException;
import net.runelite.client.plugins.PluginManager;
import net.runelite.client.ui.NavigationButton;

/**
 * Phase-6 (W3): the second reverse-JNI facade — the <em>Java-owned</em> mobile-UI control plane, sibling to
 * the hot-path {@link JavaBridge} (frame blit + input). Where {@code JavaBridge} is a thin pipe the native
 * side drives every display tick, this is a <em>thick</em> facade: the native UIKit chrome (plugin list,
 * config panel, chat-tap) calls a handful of coarse methods, and <b>this class owns the RuneLite-internal
 * details</b> — most importantly <em>which Java thread</em> each mutation runs on.
 *
 * <h2>Why a facade and not native reflection over JNI</h2>
 * The desktop config UI mutates plugins/config from the Swing event thread, and the engine relies on it:
 * <ul>
 *   <li>{@code PluginManager.startPlugin}/{@code stopPlugin} {@code assert SwingUtilities.isEventDispatchThread()}
 *       — they MUST run on the AWT EDT (under iOS, the CACIO CTC event thread).</li>
 *   <li>{@code ConfigManager.setConfiguration} posts {@code ConfigChanged} <b>synchronously</b> via the
 *       single-threaded {@code EventBus}, so every subscriber runs on the calling thread. The desktop
 *       calls it from the EDT; subscribers that touch the running client re-dispatch onto the
 *       {@link ClientThread} themselves.</li>
 * </ul>
 * If the native side called those directly, they would run on the JNI-attached UIKit thread — wrong thread,
 * silent corruption (worse still if assertions are disabled, where the {@code assert} is a no-op). So this
 * facade exposes exactly two dispatch lanes and routes every mutation through the correct one:
 * <ul>
 *   <li>{@link #onEdt(Runnable)} — plugin lifecycle (start/stop), mirroring {@code PluginListPanel}.</li>
 *   <li>{@link #onClientThread(Runnable)} — config writes + any read/write that touches live game state
 *       (widget bounds, varbits), mirroring how desktop config subscribers behave.</li>
 * </ul>
 *
 * <h2>Shape of the surface</h2>
 * Reads return <b>JSON snapshots</b> (hand-built, escaped) so the JNI surface is a few {@code String}-returning
 * static methods — trivial to cache method ids for and to parse into native shell types <em>once</em> per
 * panel open (never bound live to the native UI at frame rate). Writes are fire-and-forget: they queue onto the
 * right lane and return immediately; the resulting {@code ConfigChanged}/{@code PluginChanged} is the source
 * of truth, observed by re-reading the snapshot. Live UI-state the chrome polls (chat-input bounds, soft-input
 * open) is snapshotted on the client thread in {@link #tick(Client)} into volatiles and read lock-free.
 *
 * <p>Entirely inert unless {@code -Drunelite.mobileui=true}. {@link #init} wires the injected singletons in
 * once at startup (from {@code HeadlessClientUI}); {@link #tick} runs each frame from {@code Hooks.draw}.
 */
@Slf4j
public final class MobileUiBridge
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.mobileui");

	// Wired once by init() from HeadlessClientUI (which has these injected). volatile: published from the
	// engine/EDT init path, read from the native JNI thread.
	private static volatile PluginManager pluginManager;
	private static volatile ConfigManager configManager;
	private static volatile ClientThread clientThread;
	private static volatile Client client;
	private static volatile EventBus eventBus;
	private static volatile boolean listenerRegistered;

	// ---- Event/ack surface (the panel's refresh + write-confirm signal) --------------------------------
	// A monotonic sequence over ConfigChanged/PluginChanged so the panel can poll for changes (incl. ones it
	// did NOT make) and re-read only when something moved — never bind live at frame rate. Separately, every
	// queued write gets an id and the client thread records the highest id it has PROCESSED, so the panel
	// gets an ack even for a no-op write (which emits no ConfigChanged: ConfigManager early-returns when the
	// value is unchanged). Bounded ring of recent events for delta polling.
	private static final AtomicLong eventSeq = new AtomicLong();
	private static final AtomicLong writeSeq = new AtomicLong();
	private static volatile long processedWriteId;
	private static final int MAX_EVENTS = 256;
	private static final Object eventsLock = new Object();
	private static final ArrayDeque<Evt> events = new ArrayDeque<>();

	private static final class Evt
	{
		final long seq;
		final String kind; // "config" | "plugin"
		final String group; // config group, or plugin className
		final String key;   // config key, or "loaded"/"unloaded"

		Evt(long seq, String kind, String group, String key)
		{
			this.seq = seq;
			this.kind = kind;
			this.group = group;
			this.key = key;
		}
	}

	// Mobile notification delivery queue. Notifier funnels every fired notification here (an app sandbox has no
	// tray / taskbar / shell-out); the native shell drains it each frame and raises a real OS notification.
	// Bounded so a backlog can't grow unbounded before a drainer exists (desktop dev / pre-poll startup).
	private static final ConcurrentLinkedQueue<String> notifications = new ConcurrentLinkedQueue<>();
	private static final int MAX_NOTIFICATIONS = 64;

	// Outbound links. LinkBrowser funnels every browse(url) here (no system browser / xdg-open / Desktop#browse
	// in the sandbox); the native shell drains it and opens an in-app SFSafariViewController / CustomTabs.
	private static final ConcurrentLinkedQueue<String> links = new ConcurrentLinkedQueue<>();
	private static final int MAX_LINKS = 32;

	// SHOT-2: the Screenshot plugin's auto-screenshots (level-up / pet / boss kill / clue / collection-log …) are
	// written to the app sandbox screenshot dir, which is unreachable from Photos. We subscribe to ScreenshotTaken
	// and funnel each saved file's absolute path here; the native shell drains it and (if the user enabled
	// auto-save) copies the PNG into the Photos library. Bounded so a backlog can't grow before a drainer exists.
	private static final ConcurrentLinkedQueue<String> screenshots = new ConcurrentLinkedQueue<>();
	private static final int MAX_SCREENSHOTS = 16;

	// Favourite plugins: the same shared "pinnedPlugins" CSV the desktop ConfigPanel persists (RuneLite group),
	// so a pin set on either port (or desktop) round-trips. Names stored comma-stripped (desktop format).
	private static final String PINNED_KEY = "pinnedPlugins";

	// Mobile default-profile: applied once on the first tick (client thread), only for config keys the user
	// hasn't set, so it never fights a user choice.
	private static boolean defaultsApplied;

	// Live UI-state snapshot (written on the client thread in tick(), read lock-free from the native thread).
	private static volatile boolean chatInputVisible;
	private static volatile int chatInputX;
	private static volatile int chatInputY;
	private static volatile int chatInputW;
	private static volatile int chatInputH;

	private MobileUiBridge()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/**
	 * Mobile notification delivery channel. {@link net.runelite.client.Notifier} forwards every fired (enabled,
	 * focus-passing) notification here because an app sandbox has no tray / taskbar / shell-out. The native shell
	 * drains {@link #nextNotification()} each frame and raises a real OS notification (UNUserNotificationCenter on
	 * iOS / NotificationManager on Android). The in-canvas flash + in-chat game-message channels are unaffected
	 * (they render through the engine). Encoded {@code "title\u0001body"}; bounded; no-op unless the mobile UI is
	 * active so desktop dev doesn't accumulate an undrained backlog.
	 */
	public static void publishNotification(String title, String body)
	{
		// Back-compat 2-arg overload: native falls back to the platform default sound (sound type unspecified).
		publishNotification(title, body, null, -1);
	}

	/**
	 * As {@link #publishNotification(String, String)} but carrying the {@link net.runelite.client.config.NotificationSound}
	 * type name (NATIVE/CUSTOM/OFF) and a 0-100 volume hint so the native shell can honor OFF (no sound) and the
	 * configured sound/volume instead of always playing the default beep (desktop-parity NOTIF-1). The sound/volume
	 * are appended as extra separator-delimited fields so an older shell that splits on the first separator still
	 * reads title+body.
	 */
	public static void publishNotification(String title, String body, String soundType, int volume)
	{
		if (!ENABLED)
		{
			return;
		}
		while (notifications.size() >= MAX_NOTIFICATIONS)
		{
			notifications.poll();
		}
		notifications.add((title == null ? "" : title) + '\u0001' + (body == null ? "" : body)
			+ '\u0001' + (soundType == null ? "" : soundType) + '\u0001' + volume);
	}

	/** Drain the oldest pending notification ({@code "title\u0001body"}), or {@code null} if none. Native polls this. */
	public static String nextNotification()
	{
		return notifications.poll();
	}

	/**
	 * SHOT-2: the next auto-screenshot's sandbox file path (absolute), or null. The native shell drains this each
	 * frame and, when the user has enabled auto-save, copies the PNG into the Photos library.
	 */
	public static String nextScreenshot()
	{
		return screenshots.poll();
	}

	/**
	 * Outbound-link channel. {@link net.runelite.client.util.LinkBrowser#browse} forwards every URL here (Wiki,
	 * HiScore, plugin "open page" links, etc.) because the sandbox has no system browser. The native shell drains
	 * {@link #nextLink()} each frame and opens it in-app (SFSafariViewController / Custom Tabs). Bounded; gated.
	 */
	public static void publishLink(String url)
	{
		if (!ENABLED || url == null || url.isEmpty())
		{
			return;
		}
		while (links.size() >= MAX_LINKS)
		{
			links.poll();
		}
		links.add(url);
	}

	/** Drain the oldest pending outbound URL, or {@code null} if none. Native polls this. */
	public static String nextLink()
	{
		return links.poll();
	}

	/**
	 * Wire the facade to the live singletons. Called once from {@code HeadlessClientUI.init()} — the one
	 * component that already has {@link PluginManager}/{@link ConfigManager}/{@link ClientThread} injected —
	 * so this class stays a pure static JNI facade (the native side cannot hold a Guice-built instance).
	 */
	public static void init(PluginManager pm, ConfigManager cm, ClientThread ct, Client c, EventBus eb)
	{
		pluginManager = pm;
		configManager = cm;
		clientThread = ct;
		client = c;
		eventBus = eb;
		if (eb != null && !listenerRegistered)
		{
			eb.register(new Listener());
			listenerRegistered = true;
		}
		QuestHelperBridge.init(pm, ct); // native Quest Helper reflow shares this wiring + the client-thread tick
		WorldSwitcherBridge.init(c, ct, pm); // native World Switcher reflow (direct WorldService reads)
		LootTrackerBridge.init(pm, ct);   // native Loot Tracker reflow
		XpTrackerBridge.init(pm, ct);     // native XP Tracker reflow
		GrandExchangeBridge.init(pm, ct); // native Grand Exchange reflow
		TimeTrackingBridge.init(pm, ct);  // native Time Tracking reflow
		OverlayBridge.init(pm, ct);       // native overlay edit-mode (reposition/snap/reset)
		InfoBoxBridge.init(pm, ct);       // native infobox long-press menu
		log.info("[mobileui] facade wired: plugins={} config={} clientThread={} eventBus={}",
			pm != null, cm != null, ct != null, eb != null);
	}

	/**
	 * The EventBus subscriber that feeds the panel's revision surface. Public, non-static, {@code on<Event>}
	 * names — the shape {@code EventBus.register} requires. Runs on whatever thread posts the event (config
	 * on the client thread, plugin on the EDT); {@link #recordEvent} is the only mutation and it is guarded.
	 */
	public static final class Listener
	{
		@Subscribe
		public void onConfigChanged(ConfigChanged e)
		{
			recordEvent("config", e.getGroup(), e.getKey());
		}

		@Subscribe
		public void onPluginChanged(PluginChanged e)
		{
			recordEvent("plugin", e.getPlugin().getClass().getName(), e.isLoaded() ? "loaded" : "unloaded");
		}

		@Subscribe
		public void onExternalPluginsChanged(ExternalPluginsChanged e)
		{
			// A hub install/remove finished downloading + (un)loading. Clear the spinner and bump the seq so the
			// native hub screen re-fetches hubManifest() and sees the updated installed set.
			hubRefreshing = false;
			hubChangeSeq.incrementAndGet();
			recordEvent("hub", "external", "changed");
		}

		@Subscribe
		public void onScreenshotTaken(ScreenshotTaken e)
		{
			// SHOT-2: the file is already written to the sandbox by the Screenshot plugin; queue its absolute path
			// for the native drainer to surface into Photos. The BufferedImage is also on the event but the file
			// path avoids pushing pixels through JNI.
			final java.io.File f = e.getPath();
			if (f == null)
			{
				return;
			}
			while (screenshots.size() >= MAX_SCREENSHOTS)
			{
				screenshots.poll();
			}
			screenshots.add(f.getAbsolutePath());
		}
	}

	private static void recordEvent(String kind, String group, String key)
	{
		final long s = eventSeq.incrementAndGet();
		synchronized (eventsLock)
		{
			events.addLast(new Evt(s, kind, group, key));
			while (events.size() > MAX_EVENTS)
			{
				events.removeFirst();
			}
		}
	}

	/** Latest event sequence number. The panel stores this and polls {@link #pollMobileUiEvents(long)} from it. */
	public static long getMobileUiSeq()
	{
		return eventSeq.get();
	}

	/**
	 * Events with {@code seq > sinceSeq}, as {@code {seq, events:[{seq,kind,group,key}]}}. The panel diffs:
	 * any {@code config} event for a group it shows → re-read that group; any {@code plugin} event → re-read
	 * the plugin list (a toggle can disable conflicting plugins). Returns the latest {@code seq} so the panel
	 * advances its cursor even when no event matched.
	 */
	public static String pollMobileUiEvents(long sinceSeq)
	{
		final Json out = new Json().obj().kl("seq", eventSeq.get()).key("events").arr();
		synchronized (eventsLock)
		{
			for (Evt e : events)
			{
				if (e.seq > sinceSeq)
				{
					out.obj().kl("seq", e.seq).kv("kind", e.kind).kv("group", e.group).kvNullable("key", e.key).end();
				}
			}
		}
		return out.end().end().toString();
	}

	/** Highest write id whose client-thread runnable has finished — the fire-and-forget write ack. */
	public static long getProcessedWriteId()
	{
		return processedWriteId;
	}

	/**
	 * Flush pending config to disk NOW, SYNCHRONOUSLY ({@code ConfigManager.sendConfig}, the dirty delta only).
	 * On desktop this happens on a 5-minute timer + a clean shutdown; on iOS/Android the app can be closed/killed
	 * without running either, so the native shell calls this at explicit checkpoints to make plugin toggles and
	 * config edits survive a relaunch. It runs {@code sendConfig} on the CALLING thread and returns only once the
	 * write has completed — callers that must persist before the process goes away (e.g. the Android logout path,
	 * which calls this then {@code exit(0)}) depend on that guarantee, so do NOT make this asynchronous (QA-P1-03).
	 * Because it does a synchronous EventBus post + a blocking fsync, callers on a UI/main thread should instead
	 * use {@link #flushConfigQueued()} (fire-and-forget; enqueues {@code sendConfig} on the client thread).
	 */
	public static String flushConfig()
	{
		final ConfigManager cm = configManager;
		if (!ENABLED || cm == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		cm.sendConfig();
		return "{\"ok\":true}";
	}

	// ---- Plugin side-panels (NavigationButton/PluginPanel) ---------------------------------------------
	// HeadlessClientUI.addNavigation/removeNavigation forward here (the desktop sidebar/toolbar doesn't exist
	// headless). We keep the registered nav buttons so the native shell can show a toolbar and render the
	// selected plugin's Swing PluginPanel to a buffer (an embedded-Swing surface, like the game blit).
	private static final java.util.List<NavigationButton> navButtons = new java.util.concurrent.CopyOnWriteArrayList<>();

	public static void registerNav(NavigationButton b)
	{
		if (b != null && !navButtons.contains(b))
		{
			navButtons.add(b);
		}
	}

	public static void unregisterNav(NavigationButton b)
	{
		navButtons.remove(b);
	}

	/** Package-private view for the in-jar render probe / future panel renderer. Sorted like the desktop toolbar. */
	static java.util.List<NavigationButton> navButtonsSorted()
	{
		final java.util.List<NavigationButton> list = new java.util.ArrayList<>(navButtons);
		list.sort(java.util.Comparator.comparingInt(NavigationButton::getPriority)
			.thenComparing(NavigationButton::getTooltip));
		return list;
	}

	// The nav buttons the native panel UI offers: those with a real PluginPanel, minus RuneLite's own
	// "Configuration" sidebar (we have a native config panel). Stable order = the toolbar index space.
	private static java.util.List<NavigationButton> panelNavs()
	{
		final java.util.List<NavigationButton> out = new java.util.ArrayList<>();
		for (NavigationButton b : navButtonsSorted())
		{
			if (b.getPanel() != null && !"Configuration".equals(b.getTooltip()))
			{
				out.add(b);
			}
		}
		return out;
	}

	/**
	 * Toolbar list for the native shell: {@code [{index,tooltip,iconPng?}]} (panels only, Configuration
	 * excluded). {@code iconPng} is the nav button's icon as a base64 PNG so the native drawer can show the
	 * plugin's own icon in its title bar (the same icon RuneLite paints on the desktop sidebar toolbar).
	 */
	public static String listPanels()
	{
		final Json out = new Json().arr();
		final java.util.List<NavigationButton> navs = panelNavs();
		final Set<String> pinned = pinnedNames();
		for (int i = 0; i < navs.size(); i++)
		{
			final NavigationButton b = navs.get(i);
			final String tip = b.getTooltip();
			// name == tooltip (the panel's display name); pinned lets the redesign's grid show a favourites row +
			// star-toggle reusing the shared pinnedPlugins CSV (step-0 of the right-bar redesign, §3.5).
			out.obj().ki("index", i).kv("tooltip", tip).kv("name", tip)
				.kb("pinned", tip != null && pinned.contains(tip.replace(",", "")));
			final String icon = iconPngBase64(b.getIcon());
			if (icon != null)
			{
				out.kv("iconPng", icon);
			}
			out.end();
		}
		return out.end().toString();
	}

	/** A nav button's icon as a base64 PNG (or null). ImageIO PNG encode works headless under CACIO. */
	private static String iconPngBase64(BufferedImage icon)
	{
		if (icon == null)
		{
			return null;
		}
		try
		{
			final java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream(512);
			javax.imageio.ImageIO.write(icon, "png", baos);
			return java.util.Base64.getEncoder().encodeToString(baos.toByteArray());
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("MobileUiBridge.iconPngBase64", ex);
			return null;
		}
	}

	// ---- Native XP Tracker panel (§3.4 Tier-1) ---------------------------------------------------------
	// Instead of the supersampled Swing screenshot, the native shell draws the XP Tracker in RuneLite's own
	// charcoal style. We REUSE the plugin's own per-skill session computation (XpState.getSkillSnapshot) via
	// reflection — no reimplementation — and only enumerate the ALREADY-tracked skills (the xpSkills map keys),
	// never probing untracked ones (getSkillSnapshot computeIfAbsent's, which would pollute the plugin state).
	private static volatile String lastXpJson = "{}";
	private static volatile Object skillIconMgr;
	private static final java.util.Map<net.runelite.api.Skill, String> SKILL_ICON_CACHE = new java.util.concurrent.ConcurrentHashMap<>();

	private static Object findLoadedPlugin(String simpleName)
	{
		try
		{
			if (pluginManager == null)
			{
				return null;
			}
			for (Object p : pluginManager.getPlugins())
			{
				if (p != null && p.getClass().getSimpleName().equals(simpleName))
				{
					return p;
				}
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("MobileUiBridge.findLoadedPlugin", ignore);
		}
		return null;
	}

	/** True if the XP Tracker plugin is loaded — the native shell forks to its RuneLite-styled panel. */
	public static boolean xpTrackerAvailable()
	{
		return findLoadedPlugin("XpTrackerPlugin") != null;
	}

	/**
	 * The XP Tracker's live per-skill session data for the native panel: {@code {available, totalGained, totalHr,
	 * skills:[{skill,gained,hr,left,actions,startLevel,endLevel,progress,icon}]}} (icon = base64 PNG). Only skills
	 * with session XP &gt; 0 are emitted (matching the desktop panel). Safe to call off the client thread (the
	 * snapshot is immutable by design); on a transient reflection/concurrency hiccup the last-good JSON is returned.
	 */
	public static String xpTrackerJson()
	{
		try
		{
			final Object plugin = findLoadedPlugin("XpTrackerPlugin");
			if (plugin == null)
			{
				return "{}";
			}
			final Object xpState = readField(plugin, "xpState");
			if (xpState == null)
			{
				return "{}";
			}
			final java.util.Map<?, ?> xpSkills = (java.util.Map<?, ?>) readField(xpState, "xpSkills");
			if (xpSkills == null)
			{
				return "{}";
			}
			final java.lang.reflect.Method snap = xpState.getClass().getDeclaredMethod("getSkillSnapshot", net.runelite.api.Skill.class);
			snap.setAccessible(true);
			final java.lang.reflect.Method total = xpState.getClass().getDeclaredMethod("getTotalSnapshot");
			total.setAccessible(true);
			final Object tot = total.invoke(xpState);
			final StringBuilder sb = new StringBuilder(768);
			sb.append("{\"available\":true")
				.append(",\"totalGained\":").append(snapInt(tot, "xpGainedInSession"))
				.append(",\"totalHr\":").append(snapInt(tot, "xpPerHour"))
				.append(",\"skills\":[");
			boolean first = true;
			for (Object key : new java.util.ArrayList<>(xpSkills.keySet()))
			{
				if (!(key instanceof net.runelite.api.Skill))
				{
					continue;
				}
				final net.runelite.api.Skill skill = (net.runelite.api.Skill) key;
				final Object s = snap.invoke(xpState, skill);
				final int gained = snapInt(s, "xpGainedInSession");
				if (gained <= 0)
				{
					continue;
				}
				if (!first)
				{
					sb.append(',');
				}
				first = false;
				sb.append("{\"skill\":\"").append(skill.name()).append('"')
					.append(",\"gained\":").append(gained)
					.append(",\"hr\":").append(snapInt(s, "xpPerHour"))
					.append(",\"left\":").append(snapInt(s, "xpRemainingToGoal"))
					.append(",\"actions\":").append(snapInt(s, "actionsInSession"))
					.append(",\"startLevel\":").append(snapInt(s, "startLevel"))
					.append(",\"endLevel\":").append(snapInt(s, "endLevel"))
					.append(",\"progress\":").append((int) Math.round(snapDouble(s, "skillProgressToGoal")));
				final String icon = skillIconBase64(skill);
				if (icon != null)
				{
					sb.append(",\"icon\":\"").append(icon).append('"');
				}
				sb.append('}');
			}
			sb.append("]}");
			lastXpJson = sb.toString();
			return lastXpJson;
		}
		catch (Throwable e)
		{
			BridgeFaults.note("MobileUiBridge.xpTrackerJson", e);
			return lastXpJson;
		}
	}

	// ---- Native Grand Exchange panel (§3.4 Tier-1) -----------------------------------------------------
	// Thin delegators onto GrandExchangeBridge so the native GE screen reaches it through the same JNI surface
	// the rest of the mobile UI uses (MobileUiBridge static methods). The bridge already publishes the live
	// 8-slot offer snapshot + saved trade history on the client thread; the only addition is the Search tab
	// (the desktop plugin's search box doesn't live-filter and we can't fork it).

	/** Whether the native shell should offer the native Grand Exchange screen (the GE plugin is loaded). */
	public static boolean geAvailable()
	{
		try
		{
			return GrandExchangeBridge.isAvailable();
		}
		catch (Throwable e)
		{
			BridgeFaults.note("MobileUiBridge.geAvailable", e);
			return false;
		}
	}

	/** The native GE screen tells the bridge when it is on-screen so the client-thread refresh only runs while shown. */
	public static String geSetUiOpen(boolean open)
	{
		try
		{
			GrandExchangeBridge.setUiOpen(open);
		}
		catch (Throwable e)
		{
			BridgeFaults.note("MobileUiBridge.geSetUiOpen", e);
		}
		return "";
	}

	/** The cached 8-slot offer snapshot plus saved trade history (see {@link GrandExchangeBridge#getGeJson()}). */
	public static String geJson()
	{
		try
		{
			return GrandExchangeBridge.getGeJson();
		}
		catch (Throwable e)
		{
			BridgeFaults.note("MobileUiBridge.geJson", e);
			return "{\"available\":false}";
		}
	}

	/** Live tradeable-item name search for the Search tab (see {@link GrandExchangeBridge#search(String)}). */
	public static String geSearch(String query)
	{
		try
		{
			return GrandExchangeBridge.search(query);
		}
		catch (Throwable e)
		{
			BridgeFaults.note("MobileUiBridge.geSearch", e);
			return "{\"results\":[]}";
		}
	}

	private static Object readField(Object obj, String name) throws Exception
	{
		final java.lang.reflect.Field f = obj.getClass().getDeclaredField(name);
		f.setAccessible(true);
		return f.get(obj);
	}

	private static int snapInt(Object snap, String field)
	{
		try
		{
			final java.lang.reflect.Field f = snap.getClass().getDeclaredField(field);
			f.setAccessible(true);
			return f.getInt(snap);
		}
		catch (Exception e)
		{
			return 0;
		}
	}

	private static double snapDouble(Object snap, String field)
	{
		try
		{
			final java.lang.reflect.Field f = snap.getClass().getDeclaredField(field);
			f.setAccessible(true);
			return f.getDouble(snap);
		}
		catch (Exception e)
		{
			return 0;
		}
	}

	/** A skill's icon as a base64 PNG (cached; empty string cached = known-absent). Via SkillIconManager. */
	private static String skillIconBase64(net.runelite.api.Skill skill)
	{
		final String cached = SKILL_ICON_CACHE.get(skill);
		if (cached != null)
		{
			return cached.isEmpty() ? null : cached;
		}
		try
		{
			if (skillIconMgr == null)
			{
				final com.google.inject.Injector inj = net.runelite.client.RuneLite.getInjector();
				if (inj != null)
				{
					skillIconMgr = inj.getInstance(net.runelite.client.game.SkillIconManager.class);
				}
			}
			if (skillIconMgr == null)
			{
				return null;
			}
			final BufferedImage img = ((net.runelite.client.game.SkillIconManager) skillIconMgr).getSkillImage(skill, true);
			final String b64 = iconPngBase64(img);
			SKILL_ICON_CACHE.put(skill, b64 == null ? "" : b64);
			return b64;
		}
		catch (Throwable e)
		{
			SKILL_ICON_CACHE.put(skill, "");
			return null;
		}
	}

	// ---- Native Notes panel (§3.4 Tier-1) -------------------------------------------------------------
	// The note is a single config string (group "notes", key "notesData"); the native shell edits it directly in
	// a UITextView instead of the (non-editable) Swing screenshot, writing back on the client-thread config lane.
	/** True if the Notes plugin is loaded — the native shell forks to its editable RuneLite-styled note panel. */
	public static boolean notesAvailable()
	{
		return findLoadedPlugin("NotesPlugin") != null;
	}

	/** The current note text (empty string when unset). Lock-free config read. */
	public static String notesGet()
	{
		final ConfigManager cm = configManager;
		if (cm == null)
		{
			return "";
		}
		final String s = cm.getConfiguration("notes", "notesData");
		return s == null ? "" : s;
	}

	/** Persist the edited note text on the client-thread config lane (fires ConfigChanged where subscribers expect). */
	public static String notesSet(String text)
	{
		final ConfigManager cm = configManager;
		final ClientThread ct = clientThread;
		if (!ENABLED || cm == null || ct == null || text == null)
		{
			return "{\"ok\":false}";
		}
		final long id = enqueueClientWrite(ct, () -> cm.setConfiguration("notes", "notesData", text));
		return "{\"ok\":true,\"writeId\":" + id + "}";
	}

	// ---- Active plugin panel: realized off-screen under CACIO, painted to a buffer the native shell blits ----
	// Mirrors the game blit: the panel's full Swing tree is laid out at its natural width (PANEL_WIDTH) and full
	// content height in a SHOWING JWindow, painted to an ARGB int[] published for the native side to pull; the
	// native side scales to its view width and scrolls vertically. Touches map back to panel coords and dispatch
	// as MouseEvents on the EDT. A daemon repaints the active panel periodically so live updates (XP, etc.) show.
	private static final int PANEL_W = PluginPanel.PANEL_WIDTH + PluginPanel.SCROLLBAR_WIDTH;
	// Supersample the 242-logical panel into a higher-res buffer so the native side can display it at device
	// resolution 1:1 (crisp, no upscale blur) at a comfortable size. 4x of 242 = 968px ≈ 323pt at 3x density.
	// Clicks come back in buffer px and are divided by this to recover logical coords for Swing hit-testing.
	private static final int RENDER_SCALE = 4;
	// Memory budget for the panel buffer (pixels). ~3M px ARGB ≈ 12 MB — the cap below which the supersample
	// scale is allowed; tall panels step down from 4x so the buffer never OOMs the game-shared heap.
	private static final long MAX_BUFFER_PX = 3_000_000L;
	// Tallest panel we lay out + render in full (logical px). It is the SCALE-1 buffer limit (MAX_BUFFER_PX /
	// width): content up to this height renders COMPLETE, with the supersample step-down below trading crispness
	// for height so the buffer stays in budget — a tall panel is softer but no longer TRUNCATED. Was a flat 2500,
	// which clipped the JWindow and cut off the bottom of tall panels (Notes / Time Tracking / Kourend Library) —
	// a worse failure (inaccessible content) than reduced sharpness. Only content beyond ~MAX_BUFFER_PX px at
	// scale 1 (≈ a dozen screens) still clips; full crispness on tall panels needs viewport-windowed rendering.
	private static final int PANEL_MAX_H = (int) (MAX_BUFFER_PX / PANEL_W);
	private static volatile PluginPanel activePanel;
	private static volatile JPanel activeWrapped;
	private static volatile JWindow activeWindow;
	private static volatile int[] panelPixels;
	private static volatile int panelW;
	private static volatile int panelH;
	// The supersample scale actually used for the active panel's buffer (see renderActiveOnEdt — it is reduced
	// from RENDER_SCALE for tall panels to keep the buffer within a memory budget). panelClick divides by it.
	private static volatile int activeRenderScale = RENDER_SCALE;
	private static final AtomicInteger panelSeq = new AtomicInteger();
	private static volatile boolean panelRepainterRunning;
	// SC-4 (PANEL-1): the Swing text field the last panelClick landed in (so panelText/panelKey route typed input
	// to it) + the snapshot the native shell polls to decide whether to raise the soft keyboard + pre-fill it.
	private static volatile javax.swing.text.JTextComponent activeTextTarget;
	private static volatile boolean panelTextActive;
	private static volatile String panelTextValue = "";

	/** Open (realize + activate) the panel at the toolbar {@code index}; starts the repaint loop. */
	public static String openPanel(int index)
	{
		if (!ENABLED)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		final java.util.List<NavigationButton> navs = panelNavs();
		if (index < 0 || index >= navs.size())
		{
			return "{\"ok\":false,\"reason\":\"bad-index\"}";
		}
		final PluginPanel pp = navs.get(index).getPanel();
		EventQueue.invokeLater(() ->
		{
			try
			{
				closeActiveOnEdt();
				final JPanel wrapped = pp.getWrappedPanel();
				final JWindow win = new JWindow();
				win.getContentPane().add(wrapped);
				win.setSize(PANEL_W, PANEL_MAX_H);
				win.setVisible(true); // showing → children lay out + paint (no real screen under CACIO)
				win.validate();
				pp.onActivate();
				win.validate();
				activePanel = pp;
				activeWrapped = wrapped;
				activeWindow = win;
				renderActiveOnEdt();
			}
			catch (Throwable ex)
			{
				log.warn("[mobileui] openPanel {} failed", index, ex);
			}
		});
		startPanelRepainter();
		return "{\"ok\":true}";
	}

	/** Close the active panel (deactivate + dispose). */
	public static String closePanel()
	{
		EventQueue.invokeLater(MobileUiBridge::closeActiveOnEdt);
		panelPixels = null;
		activeTextTarget = null;   // dismiss the panel keyboard (SC-4 / PANEL-1)
		panelTextActive = false;
		panelSeq.incrementAndGet();
		return "{\"ok\":true}";
	}

	private static void closeActiveOnEdt()
	{
		final PluginPanel pp = activePanel;
		final JWindow win = activeWindow;
		if (pp != null)
		{
			try
			{
				pp.onDeactivate();
			}
			catch (Throwable ignore)
			{
				BridgeFaults.note("MobileUiBridge.closeActiveOnEdt", ignore);
			}
		}
		if (win != null)
		{
			win.setVisible(false);
			win.dispose();
		}
		activePanel = null;
		activeWrapped = null;
		activeWindow = null;
		// SC-4: drop the text-input target with the panel — a panel SWITCH (openPanel queues this before realizing the
		// new panel) must not leave a stale field focused, or the next tap's keyboard pre-fills the OLD panel's
		// text and panelText/panelKey route into a disposed component (PANEL-1).
		activeTextTarget = null;
		panelTextActive = false;
		panelTextValue = "";
	}

	// Lay out the active panel at full content height and paint it to a fresh ARGB buffer (EDT only).
	private static void renderActiveOnEdt()
	{
		final JPanel wrapped = activeWrapped;
		final PluginPanel pp = activePanel;
		if (wrapped == null || pp == null)
		{
			return;
		}
		wrapped.validate();
		final int logicalH = Math.max(1, Math.min(PANEL_MAX_H, pp.getPreferredSize().height + 12));
		// Pick the largest supersample scale whose buffer fits a memory budget. A tall panel (World Switcher,
		// Quest Helper) at full 4x is ~38 MB of ARGB on the 256 MB heap shared with the running game — that
		// OOMs and the panel renders blank. Short panels (XP Tracker) still get the full 4x and stay crisp.
		int scale = RENDER_SCALE;
		while (scale > 1 && (long) PANEL_W * scale * logicalH * scale > MAX_BUFFER_PX)
		{
			scale--;
		}
		activeRenderScale = scale;
		final int bw = PANEL_W * scale;
		final int bh = logicalH * scale;
		final BufferedImage img = new BufferedImage(bw, bh, BufferedImage.TYPE_INT_ARGB);
		final Graphics2D g = img.createGraphics();
		g.scale(scale, scale); // supersample: layout stays 242-logical, pixels are denser → crisp
		wrapped.printAll(g); // wrapped is PANEL_W x PANEL_MAX_H showing the content from the top
		g.dispose();
		// Publish the backing array directly (no copy). w/h are set BEFORE pixels; the native pull validates
		// w*h == pixels.length and skips the rare torn frame, so we avoid a multi-MB copy every repaint.
		panelW = bw;
		panelH = bh;
		panelPixels = ((DataBufferInt) img.getRaster().getDataBuffer()).getData();
		panelSeq.incrementAndGet();
	}

	private static void startPanelRepainter()
	{
		if (panelRepainterRunning)
		{
			return;
		}
		panelRepainterRunning = true;
		final Thread t = new Thread(() ->
		{
			try
			{
				while (activePanel != null)
				{
					Thread.sleep(500);
					if (activePanel != null)
					{
						EventQueue.invokeLater(MobileUiBridge::renderActiveOnEdt);
					}
				}
			}
			catch (InterruptedException ignore)
			{
			}
			finally
			{
				panelRepainterRunning = false;
			}
		}, "mobileui-panel-repaint");
		t.setDaemon(true);
		t.start();
	}

	public static int getPanelWidth()
	{
		return panelW;
	}

	public static int getPanelHeight()
	{
		return panelH;
	}

	public static int getPanelFrameSeq()
	{
		return panelSeq.get();
	}

	/** The active panel's full ARGB image (PANEL_W x panelH), or empty if none. */
	public static int[] getPanelPixels()
	{
		final int[] px = panelPixels;
		return px != null ? px : new int[0];
	}

	/**
	 * Dispatch a click at panel-space ({@code x},{@code y}) into the active panel's Swing tree (EDT). Drives
	 * buttons/checkboxes/combo arrows; a synthetic press+release+click on the deepest component at that point.
	 */
	public static String panelClick(int x, int y)
	{
		if (!ENABLED || activeWrapped == null)
		{
			return "{\"ok\":false}";
		}
		EventQueue.invokeLater(() ->
		{
			final JPanel wrapped = activeWrapped;
			if (wrapped == null)
			{
				return;
			}
			// Incoming coords are buffer pixels; recover the 242-logical coords the Swing tree is laid out in.
			// Divide by the scale ACTUALLY used for this panel's buffer (adaptive — see renderActiveOnEdt).
			final int s = Math.max(1, activeRenderScale);
			final int lx = x / s;
			final int ly = y / s;
			final Component target = SwingUtilities.getDeepestComponentAt(wrapped, lx, ly);
			if (target == null)
			{
				return;
			}
			final Point p = SwingUtilities.convertPoint(wrapped, lx, ly, target);
			final long when = panelSeq.get(); // monotonic, fine for event timestamps off the game clock
			final int mods = MouseEvent.BUTTON1_DOWN_MASK;
			target.dispatchEvent(new MouseEvent(target, MouseEvent.MOUSE_PRESSED, when, mods, p.x, p.y, 1, false, MouseEvent.BUTTON1));
			target.dispatchEvent(new MouseEvent(target, MouseEvent.MOUSE_RELEASED, when + 1, 0, p.x, p.y, 1, false, MouseEvent.BUTTON1));
			target.dispatchEvent(new MouseEvent(target, MouseEvent.MOUSE_CLICKED, when + 2, 0, p.x, p.y, 1, false, MouseEvent.BUTTON1));
			// SC-4 (PANEL-1): if the tap landed in an editable text field, focus it and snapshot its text so the
			// native shell raises the soft keyboard + pre-fills it; otherwise clear the target so it dismisses.
			final javax.swing.text.JTextComponent tc = textComponentFor(target);
			if (tc != null && tc.isEnabled() && tc.isEditable())
			{
				tc.requestFocusInWindow();
				activeTextTarget = tc;
				panelTextActive = true;
				panelTextValue = tc.getText() == null ? "" : tc.getText();
			}
			else
			{
				activeTextTarget = null;
				panelTextActive = false;
			}
			renderActiveOnEdt(); // reflect any state change immediately
		});
		return "{\"ok\":true}";
	}

	/** Walk up from {@code c} to the nearest {@link javax.swing.text.JTextComponent} (the tap may hit a child). */
	private static javax.swing.text.JTextComponent textComponentFor(Component c)
	{
		while (c != null)
		{
			if (c instanceof javax.swing.text.JTextComponent)
			{
				return (javax.swing.text.JTextComponent) c;
			}
			c = c.getParent();
		}
		return null;
	}

	/** True if the last {@link #panelClick} focused an editable panel text field — native raises the keyboard. */
	public static boolean isPanelTextActive()
	{
		return panelTextActive;
	}

	/** The focused panel text field's current text (native pre-fills its hidden field). */
	public static String getPanelText()
	{
		return panelTextValue;
	}

	/**
	 * Set the focused panel text field's whole text (SC-4 / PANEL-1) — the native side mirrors its hidden UITextField on
	 * each change, so a {@code setText} fires the field's DocumentListeners (live-filter search boxes: GE, plugin
	 * search, Hiscore, Skill-Calc, Notes). No-op if no field is focused.
	 */
	public static String panelText(String text)
	{
		final javax.swing.text.JTextComponent tc = activeTextTarget;
		if (!ENABLED || tc == null)
		{
			return "{\"ok\":false}";
		}
		EventQueue.invokeLater(() ->
		{
			try
			{
				tc.setText(text == null ? "" : text);
				panelTextValue = tc.getText() == null ? "" : tc.getText();
			}
			catch (Throwable ignore)
			{
				BridgeFaults.note("MobileUiBridge.panelText", ignore);
			}
			renderActiveOnEdt();
		});
		return "{\"ok\":true}";
	}

	/**
	 * Dispatch a single key (e.g. {@code VK_ENTER} to submit, {@code VK_BACK_SPACE}) to the focused panel text
	 * field (SC-4 / PANEL-1). Used for keys a whole-text mirror can't express, like Enter on a search box.
	 */
	public static String panelKey(int vk)
	{
		final javax.swing.text.JTextComponent tc = activeTextTarget;
		if (!ENABLED || tc == null)
		{
			return "{\"ok\":false}";
		}
		EventQueue.invokeLater(() ->
		{
			try
			{
				final long when = panelSeq.get();
				tc.dispatchEvent(new KeyEvent(tc, KeyEvent.KEY_PRESSED, when, 0, vk, KeyEvent.CHAR_UNDEFINED));
				tc.dispatchEvent(new KeyEvent(tc, KeyEvent.KEY_RELEASED, when + 1, 0, vk, KeyEvent.CHAR_UNDEFINED));
			}
			catch (Throwable ignore)
			{
				BridgeFaults.note("MobileUiBridge.panelKey", ignore);
			}
			renderActiveOnEdt();
		});
		return "{\"ok\":true}";
	}

	/**
	 * A right-click (BUTTON3) at panel-space ({@code x},{@code y}) into the active panel (SC-4 / PANEL-2 / §3.4) — drives
	 * context handlers (e.g. Loot Tracker reset). NOTE: a handler that opens a heavyweight {@code JPopupMenu}
	 * won't render into the panel buffer (the same limitation as combo dropdowns); direct-action handlers work.
	 */
	public static String panelLongPress(int x, int y)
	{
		return panelButton(x, y, MouseEvent.BUTTON3);
	}

	private static String panelButton(int x, int y, int button)
	{
		if (!ENABLED || activeWrapped == null)
		{
			return "{\"ok\":false}";
		}
		EventQueue.invokeLater(() ->
		{
			final JPanel wrapped = activeWrapped;
			if (wrapped == null)
			{
				return;
			}
			final int s = Math.max(1, activeRenderScale);
			final Component target = SwingUtilities.getDeepestComponentAt(wrapped, x / s, y / s);
			if (target == null)
			{
				return;
			}
			final Point p = SwingUtilities.convertPoint(wrapped, x / s, y / s, target);
			final long when = panelSeq.get();
			final int mask = button == MouseEvent.BUTTON3 ? MouseEvent.BUTTON3_DOWN_MASK : MouseEvent.BUTTON1_DOWN_MASK;
			target.dispatchEvent(new MouseEvent(target, MouseEvent.MOUSE_PRESSED, when, mask, p.x, p.y, 1, true, button));
			target.dispatchEvent(new MouseEvent(target, MouseEvent.MOUSE_RELEASED, when + 1, 0, p.x, p.y, 1, true, button));
			target.dispatchEvent(new MouseEvent(target, MouseEvent.MOUSE_CLICKED, when + 2, 0, p.x, p.y, 1, false, button));
			renderActiveOnEdt();
		});
		return "{\"ok\":true}";
	}

	/** Inner-scroll a panel's Swing component at ({@code x},{@code y}) by {@code rotation} wheel notches (SC-4 / §3.4). */
	public static String panelWheel(int x, int y, int rotation)
	{
		if (!ENABLED || activeWrapped == null)
		{
			return "{\"ok\":false}";
		}
		EventQueue.invokeLater(() ->
		{
			final JPanel wrapped = activeWrapped;
			if (wrapped == null)
			{
				return;
			}
			final int s = Math.max(1, activeRenderScale);
			final Component target = SwingUtilities.getDeepestComponentAt(wrapped, x / s, y / s);
			if (target == null)
			{
				return;
			}
			final Point p = SwingUtilities.convertPoint(wrapped, x / s, y / s, target);
			final long when = panelSeq.get();
			target.dispatchEvent(new java.awt.event.MouseWheelEvent(target, java.awt.event.MouseWheelEvent.MOUSE_WHEEL,
				when, 0, p.x, p.y, 0, false, java.awt.event.MouseWheelEvent.WHEEL_UNIT_SCROLL, 3, rotation));
			renderActiveOnEdt();
		});
		return "{\"ok\":true}";
	}

	/** Park a hover (MOUSE_MOVED) at panel-space ({@code x},{@code y}) so Swing tooltips/highlights fire (SC-4 / PANEL-2). */
	public static String panelMove(int x, int y)
	{
		if (!ENABLED || activeWrapped == null)
		{
			return "{\"ok\":false}";
		}
		EventQueue.invokeLater(() ->
		{
			final JPanel wrapped = activeWrapped;
			if (wrapped == null)
			{
				return;
			}
			final int s = Math.max(1, activeRenderScale);
			final Component target = SwingUtilities.getDeepestComponentAt(wrapped, x / s, y / s);
			if (target == null)
			{
				return;
			}
			final Point p = SwingUtilities.convertPoint(wrapped, x / s, y / s, target);
			final long when = panelSeq.get();
			target.dispatchEvent(new MouseEvent(target, MouseEvent.MOUSE_ENTERED, when, 0, p.x, p.y, 0, false));
			target.dispatchEvent(new MouseEvent(target, MouseEvent.MOUSE_MOVED, when + 1, 0, p.x, p.y, 0, false));
			renderActiveOnEdt();
		});
		return "{\"ok\":true}";
	}

	// ---- Plugin hub (browse / install) -----------------------------------------------------------------
	// Resolved lazily from the injector (not part of init()'s wiring). The manifest is downloaded ONCE on a
	// background daemon (network must not touch the JNI/client thread) and cached; hubManifest() returns
	// {status:loading} until ready, then the full plugin list with live installed flags. install/uninstall
	// route onto the client thread (config write) and flush so the installed list survives a relaunch.

	private static volatile ExternalPluginManager extPluginManager;
	private static volatile ExternalPluginClient extPluginClient;
	private static volatile List<PluginHubManifest.DisplayData> hubDisplay;
	private static volatile String hubStatus = "idle";
	private static volatile boolean hubLoading;
	// Hub install/remove progress: install()/remove() register synchronously but download+load the plugin async on
	// the ExternalPluginManager executor, signalling completion with ExternalPluginsChanged. refreshing flips true
	// on our install/remove and false when that event lands; the seq bumps so native can re-fetch hubManifest.
	private static volatile boolean hubRefreshing;
	private static final AtomicLong hubChangeSeq = new AtomicLong();
	// Hub plugins whose classes collide with a build-staged plugin already on the classpath. "117hd" is the
	// public hub build of rs117.hd — this client stages its own ported HdPlugin (the canonical panel entry),
	// so the hub copy is hidden from the catalog and refused at install.
	private static final Set<String> HUB_BLOCKED = Set.of("117hd");

	private static void ensureHubInjected()
	{
		if (extPluginManager != null && extPluginClient != null)
		{
			return;
		}
		final com.google.inject.Injector inj = RuneLite.getInjector();
		if (inj != null)
		{
			extPluginManager = inj.getInstance(ExternalPluginManager.class);
			extPluginClient = inj.getInstance(ExternalPluginClient.class);
		}
	}

	/**
	 * Plugin-hub catalog as JSON. First call kicks off a one-time background manifest download and returns
	 * {@code {"status":"loading"}}; the native side polls until {@code status} is {@code ok} (or
	 * {@code error:*}). When ready: {@code {status:ok, plugins:[{internalName,displayName,author,description,
	 * version,unavailable,installed}]}} with {@code installed} recomputed live each call.
	 */
	public static String hubManifest()
	{
		if (!ENABLED)
		{
			return "{\"status\":\"off\"}";
		}
		ensureHubInjected();
		if (extPluginClient == null || extPluginManager == null)
		{
			return "{\"status\":\"not-ready\"}";
		}
		final List<PluginHubManifest.DisplayData> display = hubDisplay;
		if (display == null)
		{
			if (!hubLoading)
			{
				hubLoading = true;
				hubStatus = "loading";
				final Thread t = new Thread(() ->
				{
					try
					{
						hubDisplay = extPluginClient.downloadManifestFull().getDisplay();
						hubStatus = "ok";
					}
					catch (Throwable ex)
					{
						hubStatus = "error:" + ex.getClass().getSimpleName();
						log.warn("[mobileui] hub manifest download failed", ex);
					}
					finally
					{
						hubLoading = false;
					}
				}, "mobileui-hub-manifest");
				t.setDaemon(true);
				t.start();
			}
			return "{\"status\":\"" + hubStatus + "\"}";
		}
		final Set<String> installed = new HashSet<>(extPluginManager.getInstalledExternalPlugins());
		final Json out = new Json().obj().kv("status", "ok").key("plugins").arr();
		for (PluginHubManifest.DisplayData d : display)
		{
			if (HUB_BLOCKED.contains(d.getInternalName()))
			{
				continue;
			}
			out.obj()
				.kv("internalName", d.getInternalName())
				.kv("displayName", d.getDisplayName())
				.kvNullable("author", d.getAuthor())
				.kvNullable("description", d.getDescription())
				.kvNullable("version", d.getVersion())
				.kvNullable("unavailable", d.getUnavailableReason())
				.kb("installed", installed.contains(d.getInternalName()))
				.end();
		}
		return out.end().end().toString();
	}

	/** Install a hub plugin by internal name (config write + flush so it persists; load happens async). */
	public static String hubInstall(String internalName)
	{
		return hubInstallOrRemove(internalName, true);
	}

	/**
	 * Hub install/remove progress. {@link #hubInstall}/{@code hubUninstall} only register synchronously; the jar
	 * download + plugin load happen async, completing with {@code ExternalPluginsChanged}. The native hub screen
	 * polls this: while {@code refreshing} is true it shows a spinner; when {@code seq} bumps (refresh finished)
	 * it re-fetches {@link #hubManifest()} to pick up the new installed set.
	 */
	public static String hubState()
	{
		return "{\"refreshing\":" + hubRefreshing + ",\"seq\":" + hubChangeSeq.get() + "}";
	}

	/** Uninstall a hub plugin by internal name. */
	public static String hubUninstall(String internalName)
	{
		return hubInstallOrRemove(internalName, false);
	}

	private static String hubInstallOrRemove(String internalName, boolean install)
	{
		if (!ENABLED || internalName == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		if (install && HUB_BLOCKED.contains(internalName))
		{
			return "{\"ok\":false,\"reason\":\"blocked\"}";
		}
		ensureHubInjected();
		final ExternalPluginManager epm = extPluginManager;
		final ConfigManager cm = configManager;
		final ClientThread ct = clientThread;
		if (epm == null || cm == null || ct == null)
		{
			return "{\"ok\":false,\"reason\":\"not-ready\"}";
		}
		hubRefreshing = true; // cleared by onExternalPluginsChanged once the async download+load completes
		final long id = enqueueClientWrite(ct, () ->
		{
			if (install)
			{
				epm.install(internalName);
			}
			else
			{
				epm.remove(internalName);
			}
			cm.sendConfig(); // persist the installed list immediately
		});
		return "{\"ok\":true,\"writeId\":" + id + "}";
	}

	/**
	 * Queue {@code r} on the client thread and return its write id. The runnable records the id as processed
	 * when it finishes (even if it was a no-op that emitted no {@code ConfigChanged}), so the panel can poll
	 * {@link #getProcessedWriteId()} for an ack. Caller must pass a non-null {@code ct}.
	 */
	private static long enqueueClientWrite(ClientThread ct, Runnable r)
	{
		final long id = writeSeq.incrementAndGet();
		ct.invokeLater(() ->
		{
			try
			{
				r.run();
			}
			finally
			{
				// invokeLater is FIFO and single-threaded, so ids complete monotonically.
				processedWriteId = id;
			}
		});
		return id;
	}

	// ---- The two dispatch lanes (the whole point of this class) ----------------------------------------

	/**
	 * Run {@code r} on the AWT event thread (under iOS, the CACIO CTC event thread). Use for plugin
	 * lifecycle — {@code PluginManager.startPlugin}/{@code stopPlugin} assert this thread.
	 */
	private static void onEdt(Runnable r)
	{
		EventQueue.invokeLater(r);
	}

	/**
	 * Run {@code r} on the game/client thread. Use for config writes and anything reading/writing live game
	 * state (widgets, varbits) — the same thread the desktop's config subscribers hop onto.
	 */
	private static void onClientThread(Runnable r)
	{
		final ClientThread ct = clientThread;
		if (ct != null)
		{
			ct.invokeLater(r);
		}
	}

	// ---- Reads: JSON snapshots (safe off-thread — they read already-resolved metadata) -----------------

	/**
	 * Snapshot of every (non-hidden) loaded plugin: identity, enabled/active state, and its config group (or
	 * null). The native list renders straight from this. {@code className} is the stable handle the write
	 * methods take.
	 */
	/** AG2 diagnostic: loaded-plugin count + any whose class name contains {@code needle}. For the routecgpu
	 *  starter to log why the gpu plugin is/ isn't in the loaded set. */
	public static String pluginDiag(String needle)
	{
		final PluginManager pm = pluginManager;
		if (pm == null)
		{
			return "pm=null";
		}
		int total = 0;
		final StringBuilder hits = new StringBuilder();
		for (Plugin p : pm.getPlugins())
		{
			total++;
			final String n = p.getClass().getName();
			if (needle != null && n.toLowerCase().contains(needle.toLowerCase()))
			{
				hits.append(n).append(' ');
			}
		}
		// Why is gpu not in the loaded set? Try to load the class + introspect its descriptor in this VM.
		String clazzDiag;
		try
		{
			final Class<?> gc = Class.forName("net.runelite.client.plugins.gpu.GpuPlugin", false, MobileUiBridge.class.getClassLoader());
			final PluginDescriptor d = gc.getAnnotation(PluginDescriptor.class);
			clazzDiag = "class=OK super=" + gc.getSuperclass().getSimpleName()
				+ " descriptor=" + (d == null ? "NULL" : ("present(dev=" + d.developerPlugin() + ",hidden=" + d.hidden() + ")"));
		}
		catch (Throwable t)
		{
			clazzDiag = "classLoad=" + t.getClass().getSimpleName() + ":" + t.getMessage();
		}
		return "loaded=" + total + " matching[" + needle + "]=" + (hits.length() == 0 ? "(none)" : hits.toString().trim())
			+ " | gpuClass: " + clazzDiag;
	}

	public static String listPlugins()
	{
		final PluginManager pm = pluginManager;
		if (!ENABLED || pm == null)
		{
			return "[]";
		}
		final Set<String> pinned = pinnedNames();
		final Json out = new Json().arr();
		for (Plugin p : pm.getPlugins())
		{
			final PluginDescriptor d = p.getClass().getAnnotation(PluginDescriptor.class);
			if (d == null || d.hidden())
			{
				continue;
			}
			String group = null;
			boolean hasConfig = false;
			try
			{
				final Config proxy = pm.getPluginConfigProxy(p);
				if (proxy != null)
				{
					final ConfigDescriptor cd = configManager.getConfigDescriptor(proxy);
					group = cd.getGroup().value();
					hasConfig = !cd.getItems().isEmpty();
				}
			}
			catch (RuntimeException ex)
			{
				// a plugin with no/odd config proxy still belongs in the list (toggle only)
			}
			out.obj()
				.kv("className", p.getClass().getName())
				.kv("name", d.name())
				.kv("description", d.description())
				.kv("tags", String.join(" ", d.tags()))
				.kb("enabled", pm.isPluginEnabled(p))
				.kb("active", pm.isPluginActive(p))
				.kb("hasConfig", hasConfig)
				.kb("developer", d.developerPlugin())
				.kb("pinned", pinned.contains(d.name().replace(",", "")))
				.kvNullable("configGroup", group)
				.end();
		}
		// Desktop registers two config-only "fake plugins" (config/ConfigPlugin) that are NOT real Plugins and so
		// never appear in pm.getPlugins(): the "RuneLite" core-settings group (overlay fonts, tooltip position,
		// infobox size, notification defaults, wiki prices) and "Chat Color" (textrecolor). Inject them as
		// synthetic config-only rows (configOnly:true → the native list shows no enable toggle, a tap opens config).
		emitFakePlugin(out, pinned, FAKE_RUNELITE_NAME, "RuneLite client settings", RuneLiteConfig.GROUP_NAME);
		emitFakePlugin(out, pinned, FAKE_CHATCOLOR_NAME, "Recolor chat text", FAKE_CHATCOLOR_GROUP);
		return out.end().toString();
	}

	// The two desktop config-only fake-plugins (see listPlugins). Display names match desktop so a pin round-trips.
	private static final String FAKE_RUNELITE_NAME = "RuneLite";
	private static final String FAKE_CHATCOLOR_NAME = "Chat Color";
	private static final String FAKE_CHATCOLOR_GROUP = "textrecolor";

	/** Emit one synthetic config-only plugin row (no enable toggle, no PluginPanel) backed by a {@link Config} group. */
	private static void emitFakePlugin(Json out, Set<String> pinned, String name, String desc, String group)
	{
		out.obj()
			.kv("className", "fakeplugin:" + group)
			.kv("name", name)
			.kv("description", desc)
			.kb("enabled", true)
			.kb("active", true)
			.kb("hasConfig", true)
			.kb("developer", false)
			.kb("configOnly", true)
			.kb("pinned", pinned.contains(name.replace(",", "")))
			.kvNullable("configGroup", group)
			.end();
	}

	/** The {@link Config} class backing a desktop fake-plugin group, or null if {@code group} isn't one. */
	private static Class<? extends Config> fakeConfigClass(String group)
	{
		if (RuneLiteConfig.GROUP_NAME.equals(group))
		{
			return RuneLiteConfig.class;
		}
		if (FAKE_CHATCOLOR_GROUP.equals(group))
		{
			return ChatColorConfig.class;
		}
		return null;
	}

	private static volatile boolean chatUsernamesWhited;

	/** Force every chat USERNAME colour to white (the official-mobile look). The desktop "Chat Color" plugin
	 *  ({@code textrecolor}) recolours chat sender names through {@link net.runelite.client.chat.ChatMessageManager}
	 *  at chatbox-build time, so writing white into its username keys makes every sender render white — the engine's
	 *  CHATBOX_TRANSPARENCY toggle is inert on this client build, so this config route is how we get there. Both the
	 *  opaque and transparent colour sets are written so it holds in either mode. Returns true only on the call that
	 *  actually applies it (so the caller can rebuild the chatbox once to recolour already-shown lines). Must run on
	 *  the client thread (ConfigManager.setConfiguration posts ConfigChanged synchronously) — called from
	 *  HudVeneerBridge.tick. */
	static boolean forceWhiteChatUsernames()
	{
		if (chatUsernamesWhited)
		{
			return false;
		}
		final ConfigManager cm = configManager;
		if (cm == null)
		{
			return false;   // config system not up yet — retry next tick
		}
		final java.awt.Color white = java.awt.Color.WHITE;
		final String[] usernameKeys = {
			"opaqueUsername", "opaquePrivateUsernames", "opaqueClanUsernames", "opaqueClanChatUsernames",
			"opaqueClanChatGuestUsernames", "opaquePublicFriendUsernames", "opaquePlayerUsername",
			"transparentUsername", "transparentPrivateUsernames", "transparentClanUsernames",
			"transparentClanClanUsernames", "transparentClanClanGuestUsernames", "transparentPublicFriendUsernames",
			"transparentPlayerUsername",
		};
		for (final String key : usernameKeys)
		{
			try
			{
				cm.setConfiguration(FAKE_CHATCOLOR_GROUP, key, white);
			}
			catch (RuntimeException ignore)
			{
				BridgeFaults.note("MobileUiBridge.forceWhiteChatUsernames", ignore);
			}
		}
		chatUsernamesWhited = true;
		return true;
	}

	// RuneLite core-settings keys that are window-manager / hardware-input concepts with no analogue on a
	// fullscreen touch app (the audit's WIN-NA / KEY-NA set) — filtered out of the native config editor so the
	// "RuneLite" fake-plugin shows only the presentation + notification defaults that actually apply on mobile.
	private static final Set<String> RUNELITE_HIDDEN_KEYS = new HashSet<>(java.util.Arrays.asList(
		"gameSize", "automaticResizeType", "lockWindowSize", "containInScreen2", "rememberScreenBounds",
		"uiEnableCustomChrome", "uiWindowOpacity", "gameAlwaysOnTop", "warningOnExit", "usernameInTitle",
		"trayIcon", "notificationTray", "notificationRequestFocus", "notificationTimeout", "notificationFocused",
		"sidebarToggleKey", "panelToggleKey", "blockExtraMouseButtons", "dragHotkey"));

	/** True for a {@code runelite}-group item that should be hidden from the mobile config editor (window/HW concept). */
	private static boolean isMobileHiddenItem(String group, String key)
	{
		return RuneLiteConfig.GROUP_NAME.equals(group) && RUNELITE_HIDDEN_KEYS.contains(key);
	}

	/** The set of pinned (favourite) plugin display names, comma-stripped — the shared desktop {@code pinnedPlugins} CSV. */
	private static Set<String> pinnedNames()
	{
		final ConfigManager cm = configManager;
		if (cm == null)
		{
			return java.util.Collections.emptySet();
		}
		final String csv = cm.getConfiguration(RuneLiteConfig.GROUP_NAME, PINNED_KEY);
		if (csv == null || csv.isEmpty())
		{
			return java.util.Collections.emptySet();
		}
		return new HashSet<>(Text.fromCSV(csv));
	}

	/**
	 * Pin/unpin a plugin (the desktop star) by display name. Persisted as the shared {@code pinnedPlugins} CSV
	 * the desktop {@code ConfigPanel} uses (RuneLite config group), so a pin set on either port — or on desktop —
	 * round-trips. The native list shows a star and sorts pinned-first. The read-modify-write runs on the client
	 * thread (like {@link #setConfig}) to avoid a lost update, and returns a {@code writeId} the native side polls
	 * for the ack. Names are stored comma-stripped to match the desktop format.
	 */
	public static String setPinned(String pluginName, boolean pinned)
	{
		final ConfigManager cm = configManager;
		if (!ENABLED || cm == null || pluginName == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		final ClientThread ct = clientThread;
		if (ct == null)
		{
			return "{\"ok\":false,\"reason\":\"not-ready\"}";
		}
		final String name = pluginName.replace(",", "");
		final long id = enqueueClientWrite(ct, () ->
		{
			final String csv = cm.getConfiguration(RuneLiteConfig.GROUP_NAME, PINNED_KEY);
			final java.util.List<String> names = new java.util.ArrayList<>(
				csv == null || csv.isEmpty() ? java.util.Collections.emptyList() : Text.fromCSV(csv));
			names.remove(name);
			if (pinned)
			{
				names.add(name);
			}
			cm.setConfiguration(RuneLiteConfig.GROUP_NAME, PINNED_KEY, String.join(",", names));
		});
		return "{\"ok\":true,\"writeId\":" + id + "}";
	}

	/**
	 * Full descriptor for one plugin's config {@code group}: per item the key, label, description, type,
	 * current value, and the typed metadata the native control needs (enum choices, int range, units,
	 * secret). Mirrors what the desktop {@code ConfigPanel} reflects, so the native side can render the same
	 * control set. Unknown/custom serialized types are returned with {@code "type":"unknown"} so the native
	 * side renders them read-only first.
	 */
	public static String getPluginConfig(String group)
	{
		final ConfigManager cm = configManager;
		// No PluginManager needed: the fake-plugin groups resolve via descriptorForGroup -> getConfig(...).
		if (!ENABLED || cm == null || group == null)
		{
			return "{}";
		}
		final ConfigDescriptor cd = descriptorForGroup(group);
		if (cd == null)
		{
			return "{}";
		}
		final Json out = new Json().obj().kv("group", group).key("items").arr();
		for (ConfigItemDescriptor item : cd.getItems())
		{
			final ConfigItem ci = item.getItem();
			if (ci.hidden())
			{
				// Desktop ConfigPanel skips hidden() items; match that so the native panel never shows them.
				continue;
			}
			final String key = item.key();
			if (isMobileHiddenItem(group, key))
			{
				// Window-chrome / hardware-input items in the RuneLite core group are N/A on a fullscreen touch
				// app (opacity, tray, always-on-top, window resize, sidebar/panel keybinds, extra mouse buttons).
				continue;
			}
			final Type type = item.getType();
			final boolean secret = ci.secret();
			out.obj()
				.kv("key", key)
				.kv("name", item.name())
				.kv("description", ci.description())
				.kv("section", ci.section())
				.ki("position", item.position())
				.kb("secret", secret)
				.kv("type", typeName(type));
			// Self-describe the wire format for the compound types so the native control knows exactly what string
			// to send back via setConfig (ConfigManager deserializes by declared type): a Dimension round-trips as
			// "WIDTHxHEIGHT", a Set as a gson JSON array of element names. Primitives/enum/color need no hint.
			final String tn = typeName(type);
			if ("dimension".equals(tn))
			{
				out.kv("encoding", "WxH");
			}
			else if ("set".equals(tn))
			{
				out.kv("encoding", "json-array");
			}
			// Secret values (passwords/tokens) are NOT round-tripped through the native side or its logs: emit
			// null. The native control renders a secure field and only sends a value when the user edits it.
			out.kvNullable("value", secret ? null : cm.getConfiguration(group, key));

			final String warning = ci.warning();
			if (warning != null && !warning.isEmpty())
			{
				out.kv("warning", warning);
			}
			final Range range = item.getRange();
			if (range != null)
			{
				out.ki("min", range.min()).ki("max", range.max());
			}
			final Units units = item.getUnits();
			if (units != null)
			{
				out.kv("units", units.value());
			}
			if (item.getAlpha() != null)
			{
				// Color picker should expose the alpha channel (desktop uses colorToAlphaHexCode when present).
				out.kb("alpha", true);
			}
			if (type instanceof Class && ((Class<?>) type).isEnum())
			{
				out.key("choices").arr();
				for (Object c : ((Class<?>) type).getEnumConstants())
				{
					out.val(((Enum<?>) c).name());
				}
				out.end();
			}
			else
			{
				// Set<Enum> multi-select: emit the element enum's constants so the panel can render checkboxes.
				final Class<?> el = setElementEnum(type);
				if (el != null)
				{
					out.key("choices").arr();
					for (Object c : el.getEnumConstants())
					{
						out.val(((Enum<?>) c).name());
					}
					out.end();
				}
			}
			if ("font".equals(tn))
			{
				// FontType is a class with a custom serializer (not an enum). Offer the 3 named presets; the
				// native side writes back the matching constant name — FontTypeSerializer.deserialize accepts the
				// legacy "REGULAR"/"BOLD"/"SMALL" strings (CFG-2).
				out.key("choices").arr().val("Regular").val("Bold").val("Small").end();
				out.key("choiceValues").arr().val("REGULAR").val("BOLD").val("SMALL").end();
			}
			out.end();
		}
		out.end();   // close the items array
		// Emit each @ConfigSection so the native side shows the friendly section NAME (not the key), honors
		// closedByDefault, and renders a collapsible header (CFG-6). Already position-sorted by getConfigDescriptor.
		out.key("sections").arr();
		for (ConfigSectionDescriptor s : cd.getSections())
		{
			final ConfigSection sec = s.getSection();
			out.obj()
				.kv("key", s.key())
				.kv("name", s.name())
				.kv("description", sec.description())
				.kb("closedByDefault", sec.closedByDefault())
				.ki("position", s.position())
				.end();
		}
		out.end();   // close the sections array
		return out.end().toString();   // close the root object
	}

	// ---- Writes: queued onto the correct lane, fire-and-forget -----------------------------------------

	/**
	 * Enable or disable a plugin by class name — the exact {@code PluginListPanel} sequence
	 * ({@code setPluginEnabled} then {@code startPlugin}/{@code stopPlugin}), dispatched onto the EDT because
	 * start/stop assert it. The follow-on {@code PluginChanged} is the confirmation; re-read
	 * {@link #listPlugins()} after it.
	 */
	public static String setPluginEnabled(String className, boolean enabled)
	{
		final PluginManager pm = pluginManager;
		if (!ENABLED || pm == null || className == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		final Plugin plugin = pluginByClassName(className);
		if (plugin == null)
		{
			return "{\"ok\":false,\"reason\":\"no-such-plugin\"}";
		}
		onEdt(() ->
		{
			try
			{
				pm.setPluginEnabled(plugin, enabled);
				if (enabled)
				{
					pm.startPlugin(plugin);
				}
				else
				{
					pm.stopPlugin(plugin);
				}
			}
			catch (PluginInstantiationException ex)
			{
				log.warn("[mobileui] toggle {} -> {} failed", className, enabled, ex);
			}
		});
		return "{\"ok\":true,\"queued\":\"edt\"}";
	}

	/**
	 * Mobile default-profile: seed the handful of plugin defaults that are wrong for a touch / memory-capped
	 * phone — currently just Low Detail ON (stock OFF, but it cuts engine memory + fill-rate, which matters on
	 * the CPU-rendered, heap-capped mobile path). Applied once on the first {@link #tick}. The cursor / key-remap
	 * / stretched-mode / interface-styles / anti-drag plugins flagged as touch-hostile are already stock-OFF, so
	 * there is nothing to flip; keeping them OUT OF REACH is a native "hide incompatible" concern, not a default.
	 * Must be a config/default policy, never a plugin edit.
	 */
	private static void applyMobileDefaults()
	{
		enableByDefaultIfUnset("LowMemoryPlugin", true);
	}

	/**
	 * Set a plugin's enabled state to {@code desired} ONLY if the user hasn't already chosen (its enabled-config
	 * key is unset) — so a re-seed never overrides an explicit user setting. Derives the key exactly like
	 * {@code PluginManager} (configName or class simple name, lower-cased) and toggles on the EDT like
	 * {@link #setPluginEnabled}.
	 */
	private static void enableByDefaultIfUnset(String simpleName, boolean desired)
	{
		final PluginManager pm = pluginManager;
		final ConfigManager cm = configManager;
		if (pm == null || cm == null)
		{
			return;
		}
		Plugin target = null;
		for (Plugin p : pm.getPlugins())
		{
			if (p.getClass().getSimpleName().equals(simpleName))
			{
				target = p;
				break;
			}
		}
		if (target == null)
		{
			return;
		}
		final PluginDescriptor d = target.getClass().getAnnotation(PluginDescriptor.class);
		final String keyName = (d != null && !d.configName().isEmpty() ? d.configName() : simpleName).toLowerCase();
		if (cm.getConfiguration(RuneLiteConfig.GROUP_NAME, keyName) != null)
		{
			return; // user (or a prior seed) already chose — leave it alone
		}
		final Plugin plugin = target;
		onEdt(() ->
		{
			try
			{
				pm.setPluginEnabled(plugin, desired);
				if (desired)
				{
					pm.startPlugin(plugin);
				}
				else
				{
					pm.stopPlugin(plugin);
				}
				log.info("[mobileui] default-profile: {} -> {}", simpleName, desired);
			}
			catch (PluginInstantiationException ex)
			{
				log.warn("[mobileui] default-profile {} -> {} failed", simpleName, desired, ex);
			}
		});
	}

	/**
	 * Track G AG3-b — load a plugin that is NOT in the {@code net.runelite.client.plugins} core scan (e.g. RLHD's
	 * {@code rs117.hd.HdPlugin}, which ships in the staged rlhd jar on the classpath) and start it. Mirrors
	 * {@code PluginListPanel}'s lifecycle but adds the {@code PluginManager.loadPlugins(List<Class>)} step the core
	 * scan would normally do. Idempotent: if the class is already loaded it just (re-)enables it. Runs the whole
	 * load+enable+start sequence on the EDT ({@code loadPlugins}/{@code startPlugin} touch plugin state + assert it).
	 * {@code loadPlugins} resolves the plugin's {@code @PluginDependency} from the already-loaded core set.
	 */
	public static String loadAndStartPlugin(String className)
	{
		final PluginManager pm = pluginManager;
		if (!ENABLED || pm == null || className == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		if (pluginByClassName(className) != null)
		{
			// Already loaded (a repeat call) — just ensure it is enabled + started.
			return setPluginEnabled(className, true);
		}
		final Class<?> cls;
		try
		{
			cls = Class.forName(className, false, MobileUiBridge.class.getClassLoader());
		}
		catch (Throwable t)
		{
			log.warn("[mobileui] loadAndStartPlugin {} classload failed", className, t);
			return "{\"ok\":false,\"reason\":\"classload\"}";
		}
		onEdt(() ->
		{
			try
			{
				final java.util.List<Plugin> loaded = pm.loadPlugins(java.util.Collections.singletonList(cls), null);
				pm.loadDefaultPluginConfiguration(loaded);
				for (Plugin p : loaded)
				{
					pm.setPluginEnabled(p, true);
					pm.startPlugin(p);
				}
				log.info("[mobileui] loadAndStartPlugin {} -> loaded {} plugin(s)", className, loaded.size());
			}
			catch (Throwable t)
			{
				log.warn("[mobileui] loadAndStartPlugin {} FAILED", className, t);
			}
		});
		return "{\"ok\":true,\"queued\":\"edt\"}";
	}

	/**
	 * Load a plugin (if not already) WITHOUT starting it, so it appears in {@link #listPlugins()} with an
	 * editable config but does not run. Same {@code pm.loadPlugins(List<Class>)} +
	 * {@code loadDefaultPluginConfiguration} as {@link #loadAndStartPlugin} but with no
	 * {@code setPluginEnabled}/{@code startPlugin}. Used to surface the renderer plugins (GPU / 117HD) in the
	 * native panel even when they are not the active renderer — the native side then drives the actual
	 * activation via a launch-time preference (it can't hot-swap the iOS GL bridge/present). Idempotent.
	 */
	public static String loadPluginNoStart(String className)
	{
		final PluginManager pm = pluginManager;
		if (!ENABLED || pm == null || className == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		if (pluginByClassName(className) != null)
		{
			return "{\"ok\":true,\"reason\":\"already-loaded\"}";
		}
		final Class<?> cls;
		try
		{
			cls = Class.forName(className, false, MobileUiBridge.class.getClassLoader());
		}
		catch (Throwable t)
		{
			log.warn("[mobileui] loadPluginNoStart {} classload failed", className, t);
			return "{\"ok\":false,\"reason\":\"classload\"}";
		}
		onEdt(() ->
		{
			try
			{
				final java.util.List<Plugin> loaded = pm.loadPlugins(java.util.Collections.singletonList(cls), null);
				pm.loadDefaultPluginConfiguration(loaded);
				log.info("[mobileui] loadPluginNoStart {} -> loaded {} plugin(s) (not started)", className, loaded.size());
			}
			catch (Throwable t)
			{
				log.warn("[mobileui] loadPluginNoStart {} FAILED", className, t);
			}
		});
		return "{\"ok\":true,\"queued\":\"edt\"}";
	}

	/**
	 * Write one config value (already serialized to its string form by the native control), queued onto the
	 * client thread — the desktop fires {@code ConfigChanged} synchronously, so this guarantees subscribers
	 * run where game-touching ones expect to be. The resulting {@code ConfigChanged} is the confirmation.
	 */
	public static String setConfig(String group, String key, String value)
	{
		final ConfigManager cm = configManager;
		if (!ENABLED || cm == null || group == null || key == null || value == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		final ClientThread ct = clientThread;
		if (ct == null)
		{
			// Don't ack a write we can't actually queue (the old code returned ok:true and dropped it).
			return "{\"ok\":false,\"reason\":\"not-ready\"}";
		}
		final long id = enqueueClientWrite(ct, () -> cm.setConfiguration(group, key, value));
		return "{\"ok\":true,\"writeId\":" + id + "}";
	}

	/** Raw read of a stored config value (null if unset). Used by RLHDStarter's first-launch defaults sentinel. */
	public static String getConfig(String group, String key)
	{
		final ConfigManager cm = configManager;
		if (!ENABLED || cm == null || group == null || key == null)
		{
			return null;
		}
		return cm.getConfiguration(group, key);
	}

	/** Persist the dirty config, but QUEUED on the client thread so it runs AFTER any setConfig writes enqueued
	 * just before it (sendConfig itself is immediate; ordering matters when seeding defaults then flushing). */
	public static String flushConfigQueued()
	{
		final ConfigManager cm = configManager;
		final ClientThread ct = clientThread;
		if (!ENABLED || cm == null || ct == null)
		{
			return "{\"ok\":false,\"reason\":\"not-ready\"}";
		}
		enqueueClientWrite(ct, cm::sendConfig);
		return "{\"ok\":true}";
	}

	/**
	 * Reset one config item to its default, matching the desktop: unset it, then reapply group defaults so
	 * the item is restored to its declared default value (not merely left unset). Returns a write id to poll.
	 */
	public static String resetConfig(String group, String key)
	{
		final ConfigManager cm = configManager;
		final PluginManager pm = pluginManager;
		if (!ENABLED || cm == null || pm == null || group == null || key == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		final ClientThread ct = clientThread;
		if (ct == null)
		{
			return "{\"ok\":false,\"reason\":\"not-ready\"}";
		}
		final Config proxy = proxyForGroup(group);
		final long id = enqueueClientWrite(ct, () ->
		{
			cm.unsetConfiguration(group, key);
			if (proxy != null)
			{
				cm.setDefaultConfiguration(proxy, false);
			}
		});
		return "{\"ok\":true,\"writeId\":" + id + "}";
	}

	/**
	 * Reset an ENTIRE plugin's config to defaults, matching the desktop ConfigPanel "Reset" — reapply group
	 * defaults with override=true AND call {@code plugin.resetConfiguration()} so non-config plugin state
	 * (screen-marker boxes, ground-marker tiles, GE history) is cleared too (CFG-10). Config-only fake-plugins
	 * have no owning Plugin, so only the defaults are reapplied. Returns a write id to poll.
	 */
	public static String resetPluginConfig(String group)
	{
		final ConfigManager cm = configManager;
		if (!ENABLED || cm == null || group == null)
		{
			return "{\"ok\":false,\"reason\":\"facade-off\"}";
		}
		final ClientThread ct = clientThread;
		if (ct == null)
		{
			return "{\"ok\":false,\"reason\":\"not-ready\"}";
		}
		final Config proxy = proxyForGroup(group);
		final Plugin owner = pluginForGroup(group);
		final long id = enqueueClientWrite(ct, () ->
		{
			if (proxy != null)
			{
				cm.setDefaultConfiguration(proxy, true);
			}
			if (owner != null)
			{
				try
				{
					owner.resetConfiguration();
				}
				catch (RuntimeException ignored)
				{
					BridgeFaults.note("MobileUiBridge.resetPluginConfig", ignored);
					// a plugin's resetConfiguration touching the engine off-tick shouldn't abort the reset
				}
			}
		});
		return "{\"ok\":true,\"writeId\":" + id + "}";
	}

	/**
	 * The fully-populated default {@link Notification} (built from the RuneLite core notification settings, exactly
	 * like the desktop NotificationPanel seeds a freshly-enabled notification) serialized to its config JSON. The
	 * native per-notification sub-editor uses this as the base when customizing an as-yet-uninitialized
	 * notification, so override=true never leaves a field unset (NOTIF-2).
	 */
	public static String notificationDefaults()
	{
		final ConfigManager cm = configManager;
		if (!ENABLED || cm == null)
		{
			return "{}";
		}
		try
		{
			final RuneLiteConfig rl = cm.getConfig(RuneLiteConfig.class);
			final Notification seed = new Notification(true, true, true,
				rl.enableTrayNotifications(), java.awt.TrayIcon.MessageType.NONE, rl.notificationRequestFocus(),
				rl.notificationSound(), null, rl.notificationVolume(), rl.notificationTimeout(),
				rl.enableGameMessageNotification(), rl.flashNotification(), rl.notificationFlashColor(),
				rl.sendNotificationsWhenFocused());
			// The injected Gson (RuneLiteAPI.GSON) is exactly what NotificationSerializer.serialize uses, so this
			// string is byte-identical to what the engine stores — including the Color adapter's "#AARRGGBB" form.
			return net.runelite.http.api.RuneLiteAPI.GSON.toJson(seed);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileUiBridge.notificationDefaults", ex);
			return "{}";
		}
	}

	// ---- KEY-1: plugin action-hotkeys -------------------------------------------------------------------

	/**
	 * The curated set of plugin action-hotkeys the native shell can fire from an on-screen strip — {group, config
	 * key, label}. These are the {@code HotkeyListener} / raw-{@code KeyListener} action binds (verified keyNames)
	 * that perform a one-shot toggle/action and so map to a button; modifier-hold binds (e.g. anti-drag Alt) are
	 * excluded.
	 */
	private static final String[][] HOTKEY_ACTIONS = {
		{"grounditems", "hotkey", "Hide ground items"},
		{"inventoryViewer", "toggleKeybind", "Inventory overlay"},
		{"worldhopper", "previousKey", "Quick-hop prev"},
		{"worldhopper", "nextKey", "Quick-hop next"},
		{"screenshot", "hotkey", "Screenshot"},
		{"bank", "searchKeybind", "Bank search"},
		{"raids", "screenshotHotkey", "Raids layout shot"},
	};

	// [keyCode, modifiers] reflected fields, resolved once and published through a single volatile reference so
	// there is no torn two-field state; a benign race just repeats the idempotent reflection.
	private static volatile Field[] kbFields;

	/**
	 * KEY-1: the curated action-hotkeys with each one's <em>current</em> binding, as JSON
	 * {@code [{group,key,label,keyCode,mods,bind}]}. {@code keyCode}/{@code mods} are the AWT extended key-code +
	 * {@code InputEvent.*_DOWN_MASK} bits (so the native side can fire directly), {@code bind} a human label
	 * ("Ctrl + F" / "Not set"). Read off the live config so a rebind in the plugin's config is reflected.
	 */
	public static String hotkeyActionsJson()
	{
		final ConfigManager cm = configManager;
		final StringBuilder sb = new StringBuilder(256);
		sb.append('[');
		boolean first = true;
		for (final String[] a : HOTKEY_ACTIONS)
		{
			Keybind kb = null;
			if (cm != null)
			{
				try
				{
					kb = cm.getConfiguration(a[0], a[1], Keybind.class);
				}
				catch (RuntimeException ex)
				{
					kb = null;
				}
			}
			int keyCode = KeyEvent.VK_UNDEFINED, mods = 0;
			String bind = "Not set";
			if (kb != null && !Keybind.NOT_SET.equals(kb))
			{
				final int[] km = keybindFields(kb);
				if (km != null)
				{
					keyCode = km[0];
					mods = km[1];
				}
				bind = kb.toString();
			}
			if (!first)
			{
				sb.append(',');
			}
			first = false;
			sb.append("{\"group\":\"").append(a[0]).append("\",\"key\":\"").append(a[1])
				.append("\",\"label\":\"").append(BridgeJson.escaped(a[2]))
				.append("\",\"keyCode\":").append(keyCode).append(",\"mods\":").append(mods)
				.append(",\"bind\":\"").append(BridgeJson.escaped(bind)).append("\"}");
		}
		sb.append(']');
		return sb.toString();
	}

	/**
	 * KEY-1b (user-defined hotkey buttons): EVERY plugin {@link Keybind} (or {@code ModifierlessKeybind}) config
	 * item that is currently BOUND, as JSON {@code [{group,key,label,keyCode,mods,bind}]} — the user picks which to
	 * surface as on-screen buttons (rather than the hand-picked {@link #hotkeyActionsJson} set). {@code label} is
	 * "&lt;Plugin&gt;: &lt;item name&gt;"; {@code keyCode}/{@code mods} are the AWT code + {@code InputEvent} masks
	 * (so the native side can fire), {@code bind} a human label. Read off live config; unbound items are omitted.
	 */
	public static String boundKeybindsJson()
	{
		final PluginManager pm = pluginManager;
		final ConfigManager cm = configManager;
		if (!ENABLED || pm == null || cm == null)
		{
			return "[]";
		}
		final StringBuilder sb = new StringBuilder(512);
		sb.append('[');
		boolean first = true;
		for (Plugin p : pm.getPlugins())
		{
			final PluginDescriptor d = p.getClass().getAnnotation(PluginDescriptor.class);
			if (d == null || d.hidden())
			{
				continue;
			}
			try
			{
				final Config proxy = pm.getPluginConfigProxy(p);
				if (proxy == null)
				{
					continue;
				}
				final ConfigDescriptor cd = cm.getConfigDescriptor(proxy);
				final String group = cd.getGroup().value();
				for (ConfigItemDescriptor item : cd.getItems())
				{
					final Type t = item.getType();
					if (!(t instanceof Class) || !Keybind.class.isAssignableFrom((Class<?>) t))
					{
						continue;
					}
					final String key = item.getItem().keyName();
					Keybind kb;
					try
					{
						kb = cm.getConfiguration(group, key, Keybind.class);
					}
					catch (RuntimeException ex)
					{
						continue;
					}
					if (kb == null || Keybind.NOT_SET.equals(kb))
					{
						continue;
					}
					final int[] km = keybindFields(kb);
					if (km == null || km[0] == KeyEvent.VK_UNDEFINED)
					{
						continue;
					}
					if (!first)
					{
						sb.append(',');
					}
					first = false;
					sb.append("{\"group\":\"").append(BridgeJson.escaped(group)).append("\",\"key\":\"").append(BridgeJson.escaped(key))
						.append("\",\"label\":\"").append(BridgeJson.escaped(d.name() + ": " + item.getItem().name()))
						.append("\",\"keyCode\":").append(km[0]).append(",\"mods\":").append(km[1])
						.append(",\"bind\":\"").append(BridgeJson.escaped(kb.toString())).append("\"}");
				}
			}
			catch (RuntimeException ex)
			{
				BridgeFaults.note("MobileUiBridge.boundKeybindsJson", ex);
			}
		}
		sb.append(']');
		return sb.toString();
	}

	/**
	 * KEY-1: fire a plugin action-hotkey by (config group, key) — reads the live {@link Keybind} and synthesizes
	 * its exact chord via {@link JavaBridge#onKeybind} (a matched {@code KEY_PRESSED}+{@code KEY_RELEASED}), which
	 * the plugin's {@code HotkeyListener} catches. No-op if the bind is unset.
	 */
	public static void fireHotkey(String group, String key)
	{
		final ConfigManager cm = configManager;
		if (!ENABLED || cm == null || group == null || key == null)
		{
			return;
		}
		try
		{
			final Keybind kb = cm.getConfiguration(group, key, Keybind.class);
			if (kb == null || Keybind.NOT_SET.equals(kb))
			{
				return;
			}
			final int[] km = keybindFields(kb);
			if (km == null || km[0] == KeyEvent.VK_UNDEFINED)
			{
				return;
			}
			JavaBridge.onKeybind(km[0], km[1]);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileUiBridge.fireHotkey", ex);
		}
	}

	/**
	 * Read a {@link Keybind}'s {keyCode, modifiers} via reflection — Keybind exposes neither as a getter, and we
	 * keep upstream {@code Keybind.java} unforked. Same-module reflection, fields cached after the first read.
	 */
	private static int[] keybindFields(Keybind kb)
	{
		try
		{
			Field[] f = kbFields;
			if (f == null)
			{
				final Field kc = Keybind.class.getDeclaredField("keyCode");
				final Field md = Keybind.class.getDeclaredField("modifiers");
				kc.setAccessible(true);
				md.setAccessible(true);
				f = new Field[]{kc, md};
				kbFields = f;   // single-reference publish — no torn two-field state
			}
			return new int[]{f[0].getInt(kb), f[1].getInt(kb)};
		}
		catch (ReflectiveOperationException ex)
		{
			return null;
		}
	}

	/** Minimal JSON string escape (quotes/backslashes/control chars) for the small labels this bridge emits. */

	/** The owning {@link Plugin} for a config {@code group} (for whole-plugin reset), or null (incl. fake-plugins). */
	private static Plugin pluginForGroup(String group)
	{
		final PluginManager pm = pluginManager;
		final ConfigManager cm = configManager;
		if (pm == null || cm == null || group == null)
		{
			return null;
		}
		for (Plugin p : pm.getPlugins())
		{
			try
			{
				final Config proxy = pm.getPluginConfigProxy(p);
				if (proxy != null && group.equals(cm.getConfigDescriptor(proxy).getGroup().value()))
				{
					return p;
				}
			}
			catch (RuntimeException ignored)
			{
				// keep scanning
			}
		}
		return null;
	}

	// ---- Live UI-state snapshot (client thread writes, native thread reads) ----------------------------

	/**
	 * Called each frame from {@code Hooks.draw} (the client thread) when the facade is on. Snapshots the
	 * chatbox text-entry widget bounds + visibility into volatiles so the native shell can (a) know where to
	 * hit-test a chat tap and (b) raise the soft keyboard when the field is live — without doing any widget
	 * read from the JNI thread.
	 */
	public static void tick(Client c)
	{
		try
		{
			tickImpl(c);
		}
		catch (RuntimeException e)
		{
			BridgeFaults.note("MobileUiBridge.tick", e);
		}
	}

	private static void tickImpl(Client c)
	{
		if (!ENABLED || c == null)
		{
			return;
		}
		if (!defaultsApplied)
		{
			defaultsApplied = true;
			applyMobileDefaults();
		}
		QuestHelperBridge.tick(c); // refresh the native Quest Helper snapshots (no-op unless its screen is open)
		WorldSwitcherBridge.tick(c); // refresh the native World Switcher snapshot (no-op unless its screen is open)
		LootTrackerBridge.tick(c);   // refresh the native Loot Tracker snapshot (no-op unless its screen is open)
		XpTrackerBridge.tick(c);     // refresh the native XP Tracker snapshot (no-op unless its screen is open)
		GrandExchangeBridge.tick(c); // refresh the native Grand Exchange snapshot (no-op unless its screen is open)
		TimeTrackingBridge.tick(c);  // refresh the native Time Tracking snapshot (no-op unless its screen is open)
		OverlayBridge.tick(c);       // refresh the native overlay edit-mode snapshot (no-op unless open)
		InfoBoxBridge.tick(c);       // refresh the native infobox menu snapshot (no-op unless open)
		// The "click here to talk" affordance is the right target — NOT the scroll/message area or the tabs.
		// INPUT_CLICKAREA is the entry hit-region; fall back to the input line (CHATBOX_INPUT) if absent.
		Widget w = c.getWidget(InterfaceID.Chatbox.INPUT_CLICKAREA);
		if (w == null || w.isHidden())
		{
			w = c.getWidget(WidgetInfo.CHATBOX_INPUT);
		}
		if (w == null || w.isHidden())
		{
			chatInputVisible = false;
			return;
		}
		final java.awt.Rectangle b = w.getBounds();
		if (b == null || b.width <= 0 || b.height <= 0)
		{
			chatInputVisible = false;
			return;
		}
		chatInputX = b.x;
		chatInputY = b.y;
		chatInputW = b.width;
		chatInputH = b.height;
		chatInputVisible = true;
	}

	public static boolean isChatInputVisible()
	{
		return chatInputVisible;
	}

	/** Chat-input bounds packed as {@code [x,y,w,h]} (game-canvas pixels), or {@code [0,0,0,0]} if hidden. */
	public static int[] getChatInputBounds()
	{
		return chatInputVisible
			? new int[]{chatInputX, chatInputY, chatInputW, chatInputH}
			: new int[]{0, 0, 0, 0};
	}

	// ---- internals -------------------------------------------------------------------------------------

	private static Plugin pluginByClassName(String className)
	{
		final PluginManager pm = pluginManager;
		if (pm == null)
		{
			return null;
		}
		for (Plugin p : pm.getPlugins())
		{
			if (p.getClass().getName().equals(className))
			{
				return p;
			}
		}
		return null;
	}

	/**
	 * PROD-COMPAT-01 bring-up self-test: force-compile the 117HD {@code ShaderOverlay} debug shaders on the live
	 * driver so a strict-GLSL-ES typing regression surfaces in a device/CI run. The gamma-calibration, shadow-map
	 * and tiled-lighting overlays are dev-toggle-gated and never activate in a default login run, so their shaders
	 * are otherwise never compiled on-device. Each overlay's {@code setActive(true)} runs its
	 * {@code initialize() -> shader.compile()} on the client thread; a compile failure logs "Failed to compile
	 * shader:". Every overlay program also compiles the shared {@code overlay_vert.glsl}, so this covers all four
	 * reachable overlay shaders (overlay_frag.glsl is replaced per-stage by each subclass and never compiled).
	 * Reflective — the overlays live in the staged rlhd jar, no compile-time dependency. To avoid coupling to
	 * field names (a refactor would silently skip), the overlays are found by TYPE: every {@code HdPlugin} field
	 * whose type is a {@code ShaderOverlay} subclass. This auto-covers any future overlay. The summary logs
	 * {@code found=M activated=N} (grep {@code RLHD_OVERLAY_SELFTEST}); the CI gate asserts M>=3 and N==M, so a
	 * reflection break (found=0) fails the run rather than passing a self-test that exercised nothing. Inert
	 * unless armed by {@link RLHDStarter}.
	 */
	public static String rlhdOverlaySelfTest()
	{
		final Plugin hd = pluginByClassName("rs117.hd.HdPlugin");
		if (hd == null)
		{
			final String s = "RLHD_OVERLAY_SELFTEST found=0 activated=0 (HdPlugin not loaded)";
			log.info("[mobileui] {}", s);
			return s;
		}
		final Class<?> overlayBase;
		try
		{
			overlayBase = Class.forName("rs117.hd.overlays.ShaderOverlay", false, MobileUiBridge.class.getClassLoader());
		}
		catch (Throwable t)
		{
			final String s = "RLHD_OVERLAY_SELFTEST found=0 activated=0 (ShaderOverlay class missing)";
			log.warn("[mobileui] {}", s, t);
			return s;
		}
		int found = 0, ok = 0;
		final StringBuilder detail = new StringBuilder();
		for (java.lang.reflect.Field f : hd.getClass().getDeclaredFields())
		{
			if (!overlayBase.isAssignableFrom(f.getType()))
			{
				continue;
			}
			found++;
			final String tn = f.getType().getSimpleName();
			try
			{
				f.setAccessible(true);
				final Object overlay = f.get(hd);
				if (overlay == null)
				{
					detail.append(tn).append("=null ");
					continue;
				}
				// setActive(true) -> initialize() -> shader.compile() (queued on the client thread inside setActive).
				overlay.getClass().getMethod("setActive", boolean.class).invoke(overlay, true);
				ok++;
				detail.append(tn).append("=active ");
			}
			catch (Throwable t)
			{
				detail.append(tn).append("=ERR(").append(t.getClass().getSimpleName()).append(") ");
				log.warn("[mobileui] overlay self-test {} failed", tn, t);
			}
		}
		final String summary = "RLHD_OVERLAY_SELFTEST found=" + found + " activated=" + ok
			+ " [" + detail.toString().trim() + "]";
		log.info("[mobileui] {}", summary);
		return summary;
	}

	private static ConfigDescriptor descriptorForGroup(String group)
	{
		final PluginManager pm = pluginManager;
		final ConfigManager cm = configManager;
		if (cm == null || group == null)
		{
			return null;
		}
		// The desktop config-only fake-plugins ("RuneLite" / "Chat Color") have no Plugin, so resolve their
		// descriptor straight off a getConfig(...) proxy (CORE-1).
		final Class<? extends Config> fake = fakeConfigClass(group);
		if (fake != null)
		{
			return cm.getConfigDescriptor(cm.getConfig(fake));
		}
		if (pm == null)
		{
			return null;
		}
		for (Plugin p : pm.getPlugins())
		{
			try
			{
				final Config proxy = pm.getPluginConfigProxy(p);
				if (proxy == null)
				{
					continue;
				}
				final ConfigDescriptor cd = cm.getConfigDescriptor(proxy);
				if (group.equals(cd.getGroup().value()))
				{
					return cd;
				}
			}
			catch (RuntimeException ignored)
			{
				// keep scanning
			}
		}
		return null;
	}

	/** The {@link Config} proxy backing a group — needed to reapply defaults on reset (desktop's path). */
	private static Config proxyForGroup(String group)
	{
		final PluginManager pm = pluginManager;
		final ConfigManager cm = configManager;
		if (cm == null || group == null)
		{
			return null;
		}
		final Class<? extends Config> fake = fakeConfigClass(group);
		if (fake != null)
		{
			return cm.getConfig(fake);
		}
		if (pm == null)
		{
			return null;
		}
		for (Plugin p : pm.getPlugins())
		{
			try
			{
				final Config proxy = pm.getPluginConfigProxy(p);
				if (proxy != null && group.equals(cm.getConfigDescriptor(proxy).getGroup().value()))
				{
					return proxy;
				}
			}
			catch (RuntimeException ignored)
			{
				// keep scanning
			}
		}
		return null;
	}

	/** If {@code type} is a {@code Set<E extends Enum>}, the element enum class; else null. */
	private static Class<?> setElementEnum(Type type)
	{
		if (!(type instanceof ParameterizedType))
		{
			return null;
		}
		final ParameterizedType pt = (ParameterizedType) type;
		final Type raw = pt.getRawType();
		if (!(raw instanceof Class) || !Set.class.isAssignableFrom((Class<?>) raw))
		{
			return null;
		}
		final Type[] args = pt.getActualTypeArguments();
		if (args.length == 1 && args[0] instanceof Class && ((Class<?>) args[0]).isEnum())
		{
			return (Class<?>) args[0];
		}
		return null;
	}

	/**
	 * The native control to render for a config item. Keep this list in lockstep with the desktop
	 * {@code ConfigPanel} control set; anything we don't recognise maps to {@code unknown} (rendered
	 * read-only on the native side until we add support).
	 */
	private static String typeName(Type type)
	{
		if (!(type instanceof Class))
		{
			// parameterized (e.g. Set<...>, EnumSet<...>) — treat as a multi-select string for now
			final String s = type == null ? "" : type.getTypeName();
			return s.contains("Set") ? "set" : "unknown";
		}
		final Class<?> c = (Class<?>) type;
		if (c == boolean.class || c == Boolean.class)
		{
			return "boolean";
		}
		if (c == int.class || c == Integer.class)
		{
			return "int";
		}
		if (c == double.class || c == Double.class)
		{
			return "double";
		}
		if (c == String.class)
		{
			return "string";
		}
		if (c.isEnum())
		{
			return "enum";
		}
		if (c == java.awt.Color.class)
		{
			return "color";
		}
		if (c == java.awt.Dimension.class)
		{
			return "dimension";
		}
		// Keybind / ModifierlessKeybind / Notification / custom serialized types: name them so the native side
		// can special-case the ones it supports and render the rest read-only.
		final String simple = c.getSimpleName();
		switch (simple)
		{
			case "Keybind":
			case "ModifierlessKeybind":
				return "keybind";
			case "Notification":
				return "notification";
			case "FontType":
				// A class with a custom serializer (not an enum); the native side renders a 3-way preset picker
				// from the choices/choiceValues emitted in getPluginConfig (CFG-2).
				return "font";
			default:
				return "unknown";
		}
	}

	/**
	 * Minimal streaming JSON writer — no Gson dependency on the JNI surface, correct escaping, and the chain
	 * shape keeps the DTO builders above readable. Tracks an open-container stack so {@link #end()} closes the
	 * right bracket. Not general-purpose; just enough for these snapshots.
	 */
	private static final class Json
	{
		private final StringBuilder sb = new StringBuilder(256);
		private char[] stack = new char[16];
		private int depth;
		private boolean needComma;

		private void push(char c)
		{
			if (depth == stack.length)
			{
				final char[] grown = new char[stack.length * 2];
				System.arraycopy(stack, 0, grown, 0, depth);
				stack = grown;
			}
			stack[depth++] = c;
		}

		Json obj()
		{
			sep();
			sb.append('{');
			push('}');
			needComma = false;
			return this;
		}

		Json arr()
		{
			sep();
			sb.append('[');
			push(']');
			needComma = false;
			return this;
		}

		Json end()
		{
			sb.append(stack[--depth]);
			needComma = true;
			return this;
		}

		Json key(String k)
		{
			sep();
			quote(k);
			sb.append(':');
			needComma = false;
			return this;
		}

		Json kv(String k, String v)
		{
			key(k);
			quote(v == null ? "" : v);
			needComma = true;
			return this;
		}

		Json kvNullable(String k, String v)
		{
			key(k);
			if (v == null)
			{
				sb.append("null");
			}
			else
			{
				quote(v);
			}
			needComma = true;
			return this;
		}

		Json kb(String k, boolean v)
		{
			key(k);
			sb.append(v ? "true" : "false");
			needComma = true;
			return this;
		}

		Json ki(String k, int v)
		{
			key(k);
			sb.append(v);
			needComma = true;
			return this;
		}

		Json kl(String k, long v)
		{
			key(k);
			sb.append(v);
			needComma = true;
			return this;
		}

		Json val(String v)
		{
			sep();
			quote(v == null ? "" : v);
			needComma = true;
			return this;
		}

		private void sep()
		{
			if (needComma)
			{
				sb.append(',');
			}
		}

		private void quote(String s)
		{
			sb.append('"');
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
				}
			}
			sb.append('"');
		}

		@Override
		public String toString()
		{
			return sb.toString();
		}
	}
}
