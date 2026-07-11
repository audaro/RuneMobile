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

import com.google.inject.Injector;
import java.awt.Color;
import java.awt.EventQueue;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Type;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import javax.imageio.ImageIO;
import javax.swing.JPanel;
import javax.swing.JWindow;
import net.runelite.client.ui.NavigationButton;
import net.runelite.client.ui.PluginPanel;
import net.runelite.client.externalplugins.ExternalPluginClient;
import net.runelite.client.externalplugins.ExternalPluginManager;
import net.runelite.client.externalplugins.PluginHubManifest;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.client.RuneLite;
import net.runelite.client.config.Config;
import net.runelite.client.config.ConfigDescriptor;
import net.runelite.client.config.ConfigItemDescriptor;
import net.runelite.client.config.ConfigManager;
import net.runelite.client.eventbus.EventBus;
import net.runelite.client.eventbus.Subscribe;
import net.runelite.client.events.ConfigChanged;
import net.runelite.client.events.PluginChanged;
import net.runelite.client.plugins.Plugin;
import net.runelite.client.plugins.PluginDescriptor;
import net.runelite.client.plugins.PluginManager;
import net.runelite.client.ui.overlay.OverlayManager;

/**
 * Phase-6 (W3) STEP-0 de-risk smoke for {@link MobileUiBridge}, runnable <b>on device</b> (no JUnit). The
 * desktop harness ({@code ios/dev-tools/headless/MobileUiSmoke.java}) activates CACIO via the byte-buddy
 * JUnit extension; the device has no JUnit and no self-attach, so this lives in the shipping jar and is
 * armed by {@code RuneLiteHeadless.main} — covering BOTH boots (desktop {@code CacioHeadlessTest} and device
 * {@code DeviceHeadlessBoot} both call {@code RuneLiteHeadless.main}) from one code path, so desktop GREEN
 * re-proves the exact bytes that run on device.
 *
 * <p>Dormant unless {@code -Drunelite.mobileui.smoke=true}. When armed, {@link #arm()} spawns a daemon
 * thread that waits for the injector + the wired facade, then drives the facade exactly as the native shell
 * will and prints {@code MUI_*=...} markers to stdout (→ the device {@code jvm-stdio.log}). The verdict is
 * computed OUTSIDE the JVM in bash, md5-gated against the verbatim log — never a JVM-printed success string
 * (the documented false-GREEN guard).
 *
 * <p>What it proves: {@code -ea} live (so the {@code startPlugin} EDT asserts aren't silent no-ops);
 * {@code listPlugins()} parses; a config write fires {@code ConfigChanged} ON THE CLIENT THREAD (not EDT);
 * a plugin toggle runs ON THE EDT, becomes active, and registers an overlay headless; the chat-input
 * snapshot is plausible when logged in; and a config value PERSISTS across launches (each run reads the
 * previous run's sentinel back off disk, then writes its own).
 */
@Slf4j
public final class MobileUiSmokeRunner
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.mobileui.smoke");
	private static final String SENTINEL_GROUP = "mobileuismoke";
	private static final String SENTINEL_KEY = "probe";

	private MobileUiSmokeRunner()
	{
	}

	/** Spawn the smoke daemon iff {@code -Drunelite.mobileui.smoke=true}. Safe no-op otherwise. */
	public static void arm()
	{
		if (!ENABLED)
		{
			return;
		}
		final Thread t = new Thread(MobileUiSmokeRunner::runDaemon, "mobileui-smoke");
		t.setDaemon(true);
		t.start();
		log.info("[mui-smoke] armed");
	}

	private static void runDaemon()
	{
		try
		{
			out("MUI_PHASE=device");
			// (1) positive control: are the PluginManager start/stop EDT asserts actually LIVE? Probe the
			// EXACT class whose assertions matter — not a generic -ea check in this package, which the device's
			// surgical "-ea:net.runelite.client.plugins.PluginManager" would (correctly) leave disabled here.
			final boolean ea = net.runelite.client.plugins.PluginManager.class.desiredAssertionStatus();
			out("MUI_EA=" + ea);

			if (!await("injector", 90_000, () -> RuneLite.getInjector() != null))
			{
				out("MUI_FATAL=no-injector");
				return;
			}
			final Injector injector = RuneLite.getInjector();
			final EventBus eventBus = injector.getInstance(EventBus.class);
			final PluginManager pluginManager = injector.getInstance(PluginManager.class);
			final OverlayManager overlayManager = injector.getInstance(OverlayManager.class);
			final ConfigManager configManager = injector.getInstance(ConfigManager.class);
			final Client client = injector.getInstance(Client.class);

			await("facade-wired", 60_000, () -> !"[]".equals(MobileUiBridge.listPlugins()));

			runChecks(eventBus, pluginManager, overlayManager, configManager, client);
			runHubProbe(injector, pluginManager);
			runPanelProbe();
		}
		catch (Throwable ex)
		{
			out("MUI_FATAL=" + ex.getClass().getSimpleName() + ":" + ex.getMessage());
			log.warn("[mui-smoke] failed", ex);
		}
	}

	/**
	 * The shared check routine — identical on desktop and device. Prints {@code MUI_*} markers. Restores any
	 * plugin it toggled. Does not throw (records {@code MUI_FATAL} on a hard failure and returns).
	 */
	public static void runChecks(EventBus eventBus, PluginManager pluginManager, OverlayManager overlayManager,
		ConfigManager configManager, Client client) throws InterruptedException
	{
		// (PERSIST a) read back whatever a PRIOR launch flushed to disk (config is loaded at boot). On the
		// first-ever launch this is null; on a second launch it must equal the first launch's MUI_PERSIST_WRITTEN.
		final String preload = configManager.getConfiguration(SENTINEL_GROUP, SENTINEL_KEY);
		out("MUI_PERSIST_PRELOAD=" + preload);

		final Probe probe = new Probe(client);
		eventBus.register(probe);

		// (2) listPlugins snapshot
		final String list = MobileUiBridge.listPlugins();
		final int pluginCount = countOccurrences(list, "\"className\":");
		out("MUI_LIST_COUNT=" + pluginCount);
		out("MUI_LIST_OK=" + (pluginCount > 0 && list.startsWith("[") && list.endsWith("]")));

		// (3) config write -> CLIENT thread (not EDT)
		final String sentinel = "v" + Integer.toHexString(System.identityHashCode(probe)) + pluginCount
			+ "x" + (preload == null ? "0" : Integer.toHexString(preload.hashCode()));
		final long seqBefore = MobileUiBridge.getMobileUiSeq();
		final long writeId = parseWriteId(MobileUiBridge.setConfig(SENTINEL_GROUP, SENTINEL_KEY, sentinel));
		await("config-event", 10_000, () -> probe.lastConfig != null);
		final boolean configFired = probe.lastConfig != null;
		out("MUI_CONFIG_FIRED=" + configFired);
		out("MUI_CONFIG_VALUE_OK=" + (configFired && sentinel.equals(probe.lastConfig.getNewValue())));
		out("MUI_CONFIG_ON_CLIENT_THREAD=" + probe.configOnClientThread);
		out("MUI_CONFIG_ON_EDT=" + probe.configOnEdt);

		// (3b) event/ack surface: the write returns an id whose completion the panel polls; the bumped event
		// sequence + delta poll let the panel learn the change (even one it didn't make) without frame-binding.
		out("MUI_ACK_WRITEID=" + writeId);
		final boolean ackOk = writeId > 0
			&& await("write-ack", 10_000, () -> MobileUiBridge.getProcessedWriteId() >= writeId);
		out("MUI_ACK_OK=" + ackOk);
		out("MUI_EVT_SEQ_ADVANCED=" + (MobileUiBridge.getMobileUiSeq() > seqBefore));
		final String poll = MobileUiBridge.pollMobileUiEvents(seqBefore);
		out("MUI_EVT_POLL_OK=" + (poll.contains("\"group\":\"" + SENTINEL_GROUP + "\"")
			&& poll.contains("\"key\":\"" + SENTINEL_KEY + "\"")));

		// (4) plugin toggle -> EDT (+ becomes active + overlay registers headless). SEARCH for a plugin
		// whose enable grows the OverlayManager set, so we exercise the headless-overlay path, not a no-op.
		boolean toggleEdtOk = false;
		boolean toggleActiveOk = false;
		boolean overlayGrew = false;
		String chosen = "(none)";
		int attempts = 0;
		for (Plugin p : inactiveTogglable(pluginManager))
		{
			if (++attempts > 30)
			{
				break;
			}
			final String cls = p.getClass().getName();
			final int before = overlayCount(overlayManager);
			probe.lastPlugin = null;
			probe.pluginOnEdt = false;
			MobileUiBridge.setPluginEnabled(cls, true);
			await("plugin-active:" + p.getName(), 8_000, () -> pluginManager.isPluginActive(p));
			Thread.sleep(400);
			final boolean active = pluginManager.isPluginActive(p);
			final int after = overlayCount(overlayManager);
			if (active && chosen.equals("(none)"))
			{
				chosen = p.getName();
				toggleActiveOk = true;
				toggleEdtOk = probe.pluginOnEdt;
			}
			if (active && after > before)
			{
				chosen = p.getName();
				toggleActiveOk = true;
				toggleEdtOk = probe.pluginOnEdt;
				overlayGrew = true;
				out("MUI_OVERLAY_BEFORE=" + before);
				out("MUI_OVERLAY_AFTER=" + after);
				MobileUiBridge.setPluginEnabled(cls, false);
				Thread.sleep(200);
				break;
			}
			MobileUiBridge.setPluginEnabled(cls, false);
			Thread.sleep(150);
		}
		out("MUI_TOGGLE_TARGET=" + chosen);
		out("MUI_TOGGLE_ACTIVE=" + toggleActiveOk);
		out("MUI_TOGGLE_ON_EDT=" + toggleEdtOk);
		out("MUI_OVERLAY_GREW=" + overlayGrew);
		out("MUI_TOGGLE_OK=" + (toggleActiveOk && toggleEdtOk));

		// (PERSIST b) flush this run's sentinel so the NEXT launch reads it back as MUI_PERSIST_PRELOAD.
		configManager.sendConfig();
		out("MUI_PERSIST_WRITTEN=" + sentinel);
		out("MUI_PERSIST_XLAUNCH_OK=" + (preload != null));  // true on the 2nd+ launch (proves disk round-trip)

		// (6) chat-input bounds (only meaningful in-game)
		final boolean loggedIn = client.getGameState() == GameState.LOGGED_IN;
		out("MUI_LOGGED_IN=" + loggedIn);
		if (loggedIn)
		{
			Thread.sleep(1000); // let a tick() snapshot land
			final int[] b = MobileUiBridge.getChatInputBounds();
			final boolean vis = MobileUiBridge.isChatInputVisible();
			out("MUI_CHAT_VISIBLE=" + vis);
			out("MUI_CHAT_BOUNDS=" + b[0] + "," + b[1] + "," + b[2] + "," + b[3]);
			out("MUI_CHAT_OK=" + (vis && b[2] > 0 && b[3] > 0));
		}

		// (7) TYPED CONFIG ROUND-TRIP — the verdict's "single biggest de-risk". Write a real typed value
		// (color/int/double/enum) THROUGH the same MobileUiBridge.setConfig the native panel uses, with the
		// EXACT string serialization the native control must produce, then read it back through the typed
		// proxy path the live plugin reads from. Catches malformed serialization (esp. the signed-decimal
		// color trap: getRGB() is negative for opaque colors, ColorUtil.fromString uses Integer.decode which
		// rejects 0xFFxxxxxx hex) that would silently null out real config. Restores every value it touches.
		runTypedRoundTrip(pluginManager, configManager);

		out("MUI_DONE=1");
	}

	// ---- plugin side-panel render de-risk (own phase) -------------------------------------------------

	private static final boolean PANEL_PROBE = Boolean.getBoolean("runelite.mobileui.panelprobe");

	/**
	 * Plugin side-panel feasibility de-risk: prove a real plugin's Swing {@link PluginPanel} can be realized
	 * off-screen under CACIO and painted to a buffer (the core unknown for showing plugin panels on mobile —
	 * an embedded-Swing surface like the game blit). Captures the registered nav buttons, picks the first with
	 * a panel, realizes its wrapped Swing tree in a {@link JWindow}, calls {@code onActivate}, lays it out, and
	 * paints it to a {@link BufferedImage}; reports the non-blank pixel count and writes a PNG for an eyeball.
	 */
	private static void runPanelProbe() throws Exception
	{
		if (!PANEL_PROBE)
		{
			return;
		}
		final List<NavigationButton> navs = MobileUiBridge.navButtonsSorted();
		// Prefer real plugin panels; "Configuration" is RuneLite's own sidebar and is empty standalone.
		final List<NavigationButton> candidates = new ArrayList<>();
		int withPanel = 0;
		for (NavigationButton b : navs)
		{
			if (b.getPanel() != null)
			{
				withPanel++;
				if (!"Configuration".equals(b.getTooltip()))
				{
					candidates.add(b);
				}
			}
		}
		out("MUI_PANEL_NAV_COUNT=" + navs.size());
		out("MUI_PANEL_WITH_PANEL=" + withPanel);

		final int w = PluginPanel.PANEL_WIDTH + PluginPanel.SCROLLBAR_WIDTH;
		final int h = 600;
		String okName = null;
		int okNonBlank = 0;
		BufferedImage okImg = null;
		int tried = 0;
		for (NavigationButton nav : candidates)
		{
			if (tried >= 6 || okName != null)
			{
				break;
			}
			tried++;
			final BufferedImage img = renderPanel(nav, w, h);
			final int nb = img == null ? -1 : nonBlankCount(img, w, h);
			out("MUI_PANEL_TRY=" + nav.getTooltip() + " nonBlank=" + nb);
			if (nb > 200)
			{
				okName = nav.getTooltip();
				okNonBlank = nb;
				okImg = img;
			}
		}
		out("MUI_PANEL_NAME=" + (okName == null ? "(none)" : okName));
		out("MUI_PANEL_NONBLANK=" + okNonBlank);
		out("MUI_PANEL_OK=" + (okName != null));

		final String dir = System.getProperty("runelite.headless.capture.dir");
		if (okImg != null && dir != null)
		{
			try
			{
				final File f = new File(dir, "plugin-panel-probe.png");
				ImageIO.write(okImg, "png", f);
				out("MUI_PANEL_PNG=" + f.getAbsolutePath());
			}
			catch (Throwable ex)
			{
				out("MUI_PANEL_PNG_ERR=" + ex.getClass().getSimpleName());
			}
		}
	}

	/** Realize a plugin panel's wrapped Swing tree in a showing off-screen window and paint it to a buffer. */
	private static BufferedImage renderPanel(NavigationButton nav, int w, int h) throws Exception
	{
		final BufferedImage[] ref = new BufferedImage[1];
		EventQueue.invokeAndWait(() ->
		{
			try
			{
				final PluginPanel pp = nav.getPanel();
				final JPanel wrapped = pp.getWrappedPanel();
				final JWindow win = new JWindow();
				win.getContentPane().add(wrapped);
				win.setSize(w, h);
				win.setVisible(true);  // showing → children lay out + paint (no real screen under CACIO)
				win.validate();
				pp.onActivate();
				win.validate();
			}
			catch (Throwable ex)
			{
				out("MUI_PANEL_FATAL=activate:" + ex.getClass().getSimpleName() + ":" + ex.getMessage());
			}
		});
		Thread.sleep(1200); // let async populate (invokeLater in onActivate) settle
		EventQueue.invokeAndWait(() ->
		{
			try
			{
				final JPanel wrapped = nav.getPanel().getWrappedPanel();
				wrapped.setSize(w, h);
				wrapped.validate();
				final BufferedImage img = new BufferedImage(w, h, BufferedImage.TYPE_INT_ARGB);
				final Graphics2D g = img.createGraphics();
				wrapped.printAll(g);
				g.dispose();
				ref[0] = img;
				try
				{
					nav.getPanel().onDeactivate();
				}
				catch (Throwable ignore)
				{
				}
			}
			catch (Throwable ex)
			{
				out("MUI_PANEL_FATAL=paint:" + ex.getClass().getSimpleName() + ":" + ex.getMessage());
			}
		});
		return ref[0];
	}

	private static int nonBlankCount(BufferedImage img, int w, int h)
	{
		final int bg = img.getRGB(0, 0);
		int n = 0;
		for (int y = 0; y < h; y++)
		{
			for (int x = 0; x < w; x++)
			{
				if (img.getRGB(x, y) != bg)
				{
					n++;
				}
			}
		}
		return n;
	}

	// ---- plugin-hub de-risk (own phase) ---------------------------------------------------------------

	private static final boolean HUB_PROBE = Boolean.getBoolean("runelite.mobileui.hubprobe");

	/**
	 * Plugin-hub feasibility de-risk (device). Proves the whole external-plugin chain works on the on-device
	 * JIT JVM: download + verify the signed manifest (network), download a real hub jar, classload it through
	 * {@code PluginHubClassLoader} (a URLClassLoader), JIT-run + start it on the CACIO EDT, and confirm it
	 * shows up in {@link MobileUiBridge#listPlugins()}. Tries the smallest few jars (a singleton install can
	 * fail if a plugin has hub dependencies). Cleans up after (uninstall + flush) so a normal boot is unchanged.
	 * Requires safe-mode OFF (-Drunelite.hub) — otherwise ExternalPluginManager refuses to load anything.
	 */
	private static void runHubProbe(Injector injector, PluginManager pm)
	{
		if (!HUB_PROBE)
		{
			return;
		}
		try
		{
			out("MUI_HUB_PHASE=start");
			final ExternalPluginManager epm = injector.getInstance(ExternalPluginManager.class);
			final ExternalPluginClient client = injector.getInstance(ExternalPluginClient.class);

			final PluginHubManifest.ManifestLite manifest = client.downloadManifestLite();
			final List<PluginHubManifest.JarData> jars = new ArrayList<>(manifest.getJars());
			out("MUI_HUB_MANIFEST=" + jars.size()); // network + signature verify worked on device
			if (jars.isEmpty())
			{
				out("MUI_HUB_LOADED=false");
				out("MUI_HUB_DONE=1");
				return;
			}
			jars.sort(Comparator.comparingInt(PluginHubManifest.JarData::getJarSize));

			boolean loaded = false;
			boolean active = false;
			boolean inPanel = false;
			String chosen = "(none)";
			String loadedClass = "(none)";
			int attempts = 0;
			for (PluginHubManifest.JarData jd : jars)
			{
				if (loaded || attempts >= 3)
				{
					break;
				}
				attempts++;
				chosen = jd.getInternalName();
				out("MUI_HUB_TRY=" + chosen + " size=" + jd.getJarSize());
				epm.install(chosen);
				final long deadline = System.currentTimeMillis() + 60_000;
				Plugin hub = null;
				while (System.currentTimeMillis() < deadline && hub == null)
				{
					hub = findHubPlugin(pm);
					if (hub == null)
					{
						Thread.sleep(500);
					}
				}
				if (hub != null)
				{
					loaded = true;
					loadedClass = hub.getClass().getName();
					active = pm.isPluginActive(hub);
					inPanel = MobileUiBridge.listPlugins().contains(loadedClass);
				}
				else
				{
					epm.remove(chosen); // failed attempt — unlist it before trying the next
					Thread.sleep(1500);
				}
			}
			out("MUI_HUB_CHOSEN=" + chosen);
			out("MUI_HUB_LOADED=" + loaded);
			out("MUI_HUB_PLUGIN=" + loadedClass);
			out("MUI_HUB_ACTIVE=" + active);
			out("MUI_HUB_IN_PANEL=" + inPanel);

			// Also exercise the browse manifest (downloadManifestFull -> JSON) the native hub UI consumes.
			String hm = "{}";
			for (int i = 0; i < 60; i++)
			{
				hm = MobileUiBridge.hubManifest();
				if (hm.contains("\"status\":\"ok\"") || hm.contains("error"))
				{
					break;
				}
				Thread.sleep(1000);
			}
			out("MUI_HUB_FULL=" + countOccurrences(hm, "\"internalName\":"));

			// Clean up: uninstall the probe plugin + flush so a normal (non-hub) boot stays as before.
			if (loaded)
			{
				epm.remove(chosen);
				Thread.sleep(1000);
			}
			MobileUiBridge.flushConfig();
			out("MUI_HUB_DONE=1");
		}
		catch (Throwable t)
		{
			out("MUI_HUB_FATAL=" + t.getClass().getSimpleName() + ":" + t.getMessage());
		}
	}

	/** A loaded plugin whose class came from the hub URLClassLoader (matched by simple name, cross-package). */
	private static Plugin findHubPlugin(PluginManager pm)
	{
		for (Plugin p : pm.getPlugins())
		{
			final ClassLoader cl = p.getClass().getClassLoader();
			if (cl != null && "PluginHubClassLoader".equals(cl.getClass().getSimpleName()))
			{
				return p;
			}
		}
		return null;
	}

	// ---- typed config round-trip (verdict #7) ---------------------------------------------------------

	/**
	 * Find one real, editable config item of each typed kind and prove a native-shaped write round-trips
	 * through {@code ConfigManager}'s serialization into the value the live plugin's typed getter reads.
	 * Non-fatal: each type is independent and self-restoring; a missing type is reported absent, not failed.
	 */
	private static void runTypedRoundTrip(PluginManager pm, ConfigManager cm) throws InterruptedException
	{
		ConfigItemDescriptor colorItem = null, intItem = null, doubleItem = null, enumItem = null;
		String colorGroup = null, intGroup = null, doubleGroup = null, enumGroup = null;

		for (Plugin p : pm.getPlugins())
		{
			final PluginDescriptor pd = p.getClass().getAnnotation(PluginDescriptor.class);
			if (pd == null || pd.hidden() || pd.developerPlugin())
			{
				continue;
			}
			final ConfigDescriptor cd;
			try
			{
				final Config proxy = pm.getPluginConfigProxy(p);
				if (proxy == null)
				{
					continue;
				}
				cd = cm.getConfigDescriptor(proxy);
			}
			catch (RuntimeException ex)
			{
				continue;
			}
			final String group = cd.getGroup().value();
			for (ConfigItemDescriptor item : cd.getItems())
			{
				if (item.getItem().hidden() || item.getItem().secret())
				{
					continue;
				}
				final Type t = item.getType();
				if (!(t instanceof Class))
				{
					continue;
				}
				final Class<?> c = (Class<?>) t;
				if (colorItem == null && c == Color.class)
				{
					colorItem = item;
					colorGroup = group;
				}
				else if (intItem == null && (c == int.class || c == Integer.class))
				{
					intItem = item;
					intGroup = group;
				}
				else if (doubleItem == null && (c == double.class || c == Double.class))
				{
					doubleItem = item;
					doubleGroup = group;
				}
				else if (enumItem == null && c.isEnum() && ((Class<?>) c).getEnumConstants().length >= 2)
				{
					enumItem = item;
					enumGroup = group;
				}
			}
		}

		boolean colorOk = roundTripColor(cm, colorGroup, colorItem);
		boolean intOk = roundTripInt(cm, intGroup, intItem);
		boolean doubleOk = roundTripDouble(cm, doubleGroup, doubleItem);
		boolean enumOk = roundTripEnum(cm, enumGroup, enumItem);
		out("MUI_RT_OK=" + (colorOk && intOk && doubleOk && enumOk));

		// getPluginConfig completeness: hidden items omitted, secret values masked, set choices / alpha /
		// warning emitted when present (the verdict's JSON-completeness fixes).
		configMetadataCheck(pm, cm);

		// reset-to-default: an int item with a range + a non-null current value has a concrete numeric default,
		// so after write+reset the stored value must be reapplied (non-null) and differ from what we wrote —
		// proves resetConfig now reapplies the default instead of merely unsetting (the verdict's fix).
		resetDefaultCheck(pm, cm);

		// Native-origin leg (device only, gated): the iOS shell computes a signed-decimal opaque color in
		// ObjC and writes it via MobileUiBridge.setConfig to the throwaway sentinel group. This is the half
		// the desktop run can't cover — it proves the OBJC string-building (the signed-decimal getRGB trap),
		// not just the Java serialization. Inert on desktop (flag absent).
		nativeColorReadback(cm);
	}

	/** Pull the {@code writeId} out of {@code {"ok":true,"writeId":N}}; -1 if absent (e.g. not-ready). */
	private static long parseWriteId(String ack)
	{
		final String needle = "\"writeId\":";
		final int i = ack == null ? -1 : ack.indexOf(needle);
		if (i < 0)
		{
			return -1;
		}
		int j = i + needle.length();
		final StringBuilder n = new StringBuilder();
		while (j < ack.length() && (Character.isDigit(ack.charAt(j)) || (n.length() == 0 && ack.charAt(j) == '-')))
		{
			n.append(ack.charAt(j++));
		}
		try
		{
			return Long.parseLong(n.toString());
		}
		catch (NumberFormatException ex)
		{
			return -1;
		}
	}

	/**
	 * Verify {@link MobileUiBridge#getPluginConfig(String)} hides {@code hidden()} items, masks {@code secret}
	 * values, and emits set choices / alpha / warning when such items exist. Each leg is gated on a real item
	 * being found in the loaded plugins (PRESENT=false → OK=true, not a failure) so the run isn't flaky.
	 */
	private static void configMetadataCheck(PluginManager pm, ConfigManager cm)
	{
		ConfigItemDescriptor hidden = null, secret = null, setItem = null, alpha = null, warn = null;
		String hiddenG = null, secretG = null, setG = null, alphaG = null, warnG = null;
		for (Plugin p : pm.getPlugins())
		{
			final ConfigDescriptor cd;
			try
			{
				final net.runelite.client.config.Config proxy = pm.getPluginConfigProxy(p);
				if (proxy == null)
				{
					continue;
				}
				cd = cm.getConfigDescriptor(proxy);
			}
			catch (RuntimeException ex)
			{
				continue;
			}
			final String group = cd.getGroup().value();
			for (ConfigItemDescriptor item : cd.getItems())
			{
				if (hidden == null && item.getItem().hidden())
				{
					hidden = item;
					hiddenG = group;
				}
				if (secret == null && item.getItem().secret())
				{
					secret = item;
					secretG = group;
				}
				if (alpha == null && item.getAlpha() != null)
				{
					alpha = item;
					alphaG = group;
				}
				if (warn == null && !item.getItem().warning().isEmpty())
				{
					warn = item;
					warnG = group;
				}
				if (setItem == null && isSetOfEnum(item.getType()))
				{
					setItem = item;
					setG = group;
				}
			}
		}

		// hidden: the key must NOT appear in the group's JSON.
		out("MUI_CFG_HIDDEN_PRESENT=" + (hidden != null));
		out("MUI_CFG_HIDDEN_OK=" + (hidden == null
			|| !MobileUiBridge.getPluginConfig(hiddenG).contains("\"key\":\"" + hidden.key() + "\"")));

		// secret: write a sentinel into the secret item, assert it does NOT leak into the JSON, restore.
		boolean secretOk = true;
		if (secret != null)
		{
			final String secKey = secret.key();
			final String orig = cm.getConfiguration(secretG, secKey);
			final String mask = "SECRETSENTINEL_DONOTLEAK";
			cm.setConfiguration(secretG, secKey, mask);
			secretOk = !MobileUiBridge.getPluginConfig(secretG).contains(mask);
			if (orig == null)
			{
				cm.unsetConfiguration(secretG, secKey);
			}
			else
			{
				cm.setConfiguration(secretG, secKey, orig);
			}
		}
		out("MUI_CFG_SECRET_PRESENT=" + (secret != null));
		out("MUI_CFG_SECRET_OK=" + secretOk);

		out("MUI_CFG_SET_PRESENT=" + (setItem != null));
		out("MUI_CFG_SET_OK=" + (setItem == null
			|| MobileUiBridge.getPluginConfig(setG).contains("\"choices\":")));
		out("MUI_CFG_ALPHA_PRESENT=" + (alpha != null));
		out("MUI_CFG_ALPHA_OK=" + (alpha == null
			|| MobileUiBridge.getPluginConfig(alphaG).contains("\"alpha\":true")));
		out("MUI_CFG_WARNING_PRESENT=" + (warn != null));
		out("MUI_CFG_WARNING_OK=" + (warn == null
			|| MobileUiBridge.getPluginConfig(warnG).contains("\"warning\":")));
	}

	private static boolean isSetOfEnum(java.lang.reflect.Type type)
	{
		if (!(type instanceof java.lang.reflect.ParameterizedType))
		{
			return false;
		}
		final java.lang.reflect.ParameterizedType pt = (java.lang.reflect.ParameterizedType) type;
		final java.lang.reflect.Type raw = pt.getRawType();
		if (!(raw instanceof Class) || !java.util.Set.class.isAssignableFrom((Class<?>) raw))
		{
			return false;
		}
		final java.lang.reflect.Type[] args = pt.getActualTypeArguments();
		return args.length == 1 && args[0] instanceof Class && ((Class<?>) args[0]).isEnum();
	}

	/**
	 * Prove {@link MobileUiBridge#resetConfig} reapplies the default (not just unset): write a non-default
	 * in-range value, reset, and assert the stored value comes back non-null and different from what we wrote.
	 * Restores the original. Inert if no ranged int item was found.
	 */
	private static void resetDefaultCheck(PluginManager pm, ConfigManager cm) throws InterruptedException
	{
		// Find a ranged int whose current stored value is non-null (i.e. it has a concrete default to reapply).
		String group = null;
		ConfigItemDescriptor item = null;
		outer:
		for (Plugin p : pm.getPlugins())
		{
			final ConfigDescriptor cd;
			try
			{
				final net.runelite.client.config.Config proxy = pm.getPluginConfigProxy(p);
				if (proxy == null)
				{
					continue;
				}
				cd = cm.getConfigDescriptor(proxy);
			}
			catch (RuntimeException ex)
			{
				continue;
			}
			final String g = cd.getGroup().value();
			for (ConfigItemDescriptor it : cd.getItems())
			{
				final java.lang.reflect.Type t = it.getType();
				final boolean isInt = t == int.class || t == Integer.class;
				if (isInt && it.getRange() != null && cm.getConfiguration(g, it.key()) != null)
				{
					group = g;
					item = it;
					break outer;
				}
			}
		}
		if (item == null)
		{
			out("MUI_RESET_DEFAULT_PRESENT=false");
			out("MUI_RESET_DEFAULT_OK=true");
			return;
		}
		out("MUI_RESET_DEFAULT_PRESENT=true");
		out("MUI_RESET_DEFAULT_TARGET=" + group + "." + item.key());
		final String g = group;        // effectively-final alias for the await lambdas
		final String key = item.key();
		final String orig = cm.getConfiguration(g, key);
		final int min = item.getRange().min();
		final int max = item.getRange().max();
		final Integer cur = cm.getConfiguration(g, key, int.class);
		int v = (cur != null && cur == min) ? Math.min(min + 1, max) : min;
		final String written = Integer.toString(v);
		try
		{
			MobileUiBridge.setConfig(g, key, written);
			await("reset-write", 8_000, () -> written.equals(cm.getConfiguration(g, key)));
			MobileUiBridge.resetConfig(g, key);
			// after reset the value should change away from what we wrote and be reapplied (non-null)
			await("reset-applied", 8_000, () -> !written.equals(cm.getConfiguration(g, key)));
			final String after = cm.getConfiguration(g, key);
			out("MUI_RESET_AFTER=" + after);
			out("MUI_RESET_DEFAULT_OK=" + (after != null && !written.equals(after)));
		}
		finally
		{
			if (orig == null)
			{
				cm.unsetConfiguration(g, key); // truly restore unset (resetConfig would reapply the default)
			}
			else
			{
				MobileUiBridge.setConfig(g, key, orig);
			}
			await("reset-restore", 5_000, () -> Objects.equals(orig, cm.getConfiguration(g, key)));
		}
	}

	private static final boolean NATIVE_PROBE = Boolean.getBoolean("runelite.mobileui.nativeprobe");
	private static final String NATIVE_COLOR_KEY = "nativecolor";

	/**
	 * On device, await the color the native shell writes (group {@link #SENTINEL_GROUP}, key
	 * {@code nativecolor}) and assert it deserializes to the agreed opaque color {@code 0xFF123456} — i.e.
	 * the ObjC side produced the correct signed decimal of {@code Color.getRGB()}. The sentinel group is
	 * throwaway (same group the persistence check uses), so nothing real is touched and no restore is needed.
	 */
	private static void nativeColorReadback(ConfigManager cm) throws InterruptedException
	{
		if (!NATIVE_PROBE)
		{
			return;
		}
		final boolean appeared = await("native-color", 60_000,
			() -> cm.getConfiguration(SENTINEL_GROUP, NATIVE_COLOR_KEY) != null);
		final String raw = cm.getConfiguration(SENTINEL_GROUP, NATIVE_COLOR_KEY);
		out("MUI_RT_NATIVE_COLOR_RAW=" + raw);
		final Color got = cm.getConfiguration(SENTINEL_GROUP, NATIVE_COLOR_KEY, Color.class);
		final int expect = new Color(0x12, 0x34, 0x56, 0xFF).getRGB(); // agreed with JVMLauncher.m
		final boolean ok = appeared && got != null && got.getRGB() == expect;
		out("MUI_RT_NATIVE_COLOR_READBACK=" + (got == null ? "null" : got.toString()));
		out("MUI_RT_NATIVE_COLOR_OK=" + ok);
	}

	private static boolean roundTripColor(ConfigManager cm, String group, ConfigItemDescriptor item)
		throws InterruptedException
	{
		if (item == null)
		{
			out("MUI_RT_COLOR_TARGET=(none)");
			out("MUI_RT_COLOR_OK=false");
			return false;
		}
		final String key = item.key();
		final Color cur = cm.getConfiguration(group, key, Color.class);
		// An OPAQUE target so getRGB() is negative — the signed-decimal trap the native control must honor.
		Color target = new Color(0x12, 0x34, 0x56, 0xFF);
		if (cur != null && cur.getRGB() == target.getRGB())
		{
			target = new Color(0xAB, 0xCD, 0xEF, 0xFF);
		}
		final String serialized = String.valueOf(target.getRGB()); // == ConfigManager.objectToString(Color)
		final Color expect = target;
		return roundTrip(cm, "COLOR", group, key, Color.class, serialized,
			got -> got instanceof Color && ((Color) got).getRGB() == expect.getRGB());
	}

	private static boolean roundTripInt(ConfigManager cm, String group, ConfigItemDescriptor item)
		throws InterruptedException
	{
		if (item == null)
		{
			out("MUI_RT_INT_TARGET=(none)");
			out("MUI_RT_INT_OK=false");
			return false;
		}
		final String key = item.key();
		// honor the declared range when present; otherwise just perturb the current value
		final int min = item.getRange() != null ? item.getRange().min() : Integer.MIN_VALUE;
		final int max = item.getRange() != null ? item.getRange().max() : Integer.MAX_VALUE;
		final Integer cur = cm.getConfiguration(group, key, int.class);
		final int base = cur != null ? cur : min;
		// pick an in-range value that differs from the current one
		int target = base < max ? base + 1 : base - 1;
		if (target < min)
		{
			target = min;
		}
		if (target > max)
		{
			target = max;
		}
		final String serialized = Integer.toString(target);
		final int expect = target;
		return roundTrip(cm, "INT", group, key, int.class, serialized,
			got -> got instanceof Integer && (Integer) got == expect);
	}

	private static boolean roundTripDouble(ConfigManager cm, String group, ConfigItemDescriptor item)
		throws InterruptedException
	{
		if (item == null)
		{
			out("MUI_RT_DOUBLE_TARGET=(none)");
			out("MUI_RT_DOUBLE_OK=false");
			return false;
		}
		final String key = item.key();
		final Double cur = cm.getConfiguration(group, key, double.class);
		double target = (cur != null && cur == 1.5) ? 2.5 : 1.5;
		final String serialized = Double.toString(target);
		final double expect = target;
		return roundTrip(cm, "DOUBLE", group, key, double.class, serialized,
			got -> got instanceof Double && Math.abs((Double) got - expect) < 1e-9);
	}

	private static boolean roundTripEnum(ConfigManager cm, String group, ConfigItemDescriptor item)
		throws InterruptedException
	{
		if (item == null)
		{
			out("MUI_RT_ENUM_TARGET=(none)");
			out("MUI_RT_ENUM_OK=false");
			return false;
		}
		final String key = item.key();
		final Class<?> type = (Class<?>) item.getType();
		final Object[] constants = type.getEnumConstants();
		final Object curRaw = cm.getConfiguration(group, key, type);
		Object target = constants[0];
		if (curRaw == target)
		{
			target = constants[1];
		}
		final Enum<?> targetEnum = (Enum<?>) target;
		final String serialized = targetEnum.name(); // == ConfigManager.objectToString(Enum)
		final String expectName = targetEnum.name();
		return roundTrip(cm, "ENUM", group, key, type, serialized,
			got -> got instanceof Enum && ((Enum<?>) got).name().equals(expectName));
	}

	private interface TypedCheck
	{
		boolean ok(Object readBack);
	}

	/**
	 * Shared write→await→typed-read-back→restore skeleton. Writes {@code serialized} via the SAME
	 * {@link MobileUiBridge#setConfig} the native panel calls, waits for it to land, then reads it back
	 * through {@code getConfiguration(group,key,type)} — the exact path the plugin's config proxy uses, so a
	 * pass means the live plugin would consume the value. Restores the original (unset if it was unset).
	 */
	private static boolean roundTrip(ConfigManager cm, String tag, String group, String key, Type type,
		String serialized, TypedCheck check) throws InterruptedException
	{
		final String orig = cm.getConfiguration(group, key); // raw string (may be null = unset) to restore
		out("MUI_RT_" + tag + "_TARGET=" + group + "." + key);
		out("MUI_RT_" + tag + "_WRITE=" + serialized);
		try
		{
			MobileUiBridge.setConfig(group, key, serialized);
			final boolean landed = await("rt-" + tag, 10_000, () -> serialized.equals(cm.getConfiguration(group, key)));
			final Object got = cm.getConfiguration(group, key, type); // typed path the plugin reads from
			out("MUI_RT_" + tag + "_RAW=" + cm.getConfiguration(group, key));
			out("MUI_RT_" + tag + "_READBACK=" + (got == null ? "null" : got.toString()));
			final boolean ok = landed && check.ok(got);
			out("MUI_RT_" + tag + "_OK=" + ok);
			return ok;
		}
		finally
		{
			if (orig == null)
			{
				MobileUiBridge.resetConfig(group, key);
			}
			else
			{
				MobileUiBridge.setConfig(group, key, orig);
			}
			await("rt-restore-" + tag, 5_000, () -> Objects.equals(orig, cm.getConfiguration(group, key)));
		}
	}

	// ---- event probe ----------------------------------------------------------------------------------

	/** Records the thread each event was delivered on (the whole point: lane → thread). */
	public static final class Probe
	{
		volatile ConfigChanged lastConfig;
		volatile boolean configOnClientThread;
		volatile boolean configOnEdt;
		volatile PluginChanged lastPlugin;
		volatile boolean pluginOnEdt;

		private final Client client;

		public Probe(Client client)
		{
			this.client = client;
		}

		@Subscribe
		public void onConfigChanged(ConfigChanged e)
		{
			if (SENTINEL_GROUP.equals(e.getGroup()))
			{
				configOnClientThread = client.isClientThread();
				configOnEdt = java.awt.EventQueue.isDispatchThread();
				lastConfig = e;
			}
		}

		@Subscribe
		public void onPluginChanged(PluginChanged e)
		{
			pluginOnEdt = java.awt.EventQueue.isDispatchThread();
			lastPlugin = e;
		}
	}

	// ---- helpers --------------------------------------------------------------------------------------

	private static List<Plugin> inactiveTogglable(PluginManager pm)
	{
		final List<String> preferred = Arrays.asList(
			"Ground Items", "Ground Markers", "Screen Markers", "Tile Indicators", "World Map",
			"Coordinates", "Menu Entry Swapper", "Mouse Highlight");
		final List<Plugin> head = new ArrayList<>();
		final List<Plugin> tail = new ArrayList<>();
		for (Plugin p : pm.getPlugins())
		{
			final PluginDescriptor d = p.getClass().getAnnotation(PluginDescriptor.class);
			if (d == null || d.hidden() || d.developerPlugin() || pm.isPluginActive(p))
			{
				continue;
			}
			(preferred.contains(p.getName()) ? head : tail).add(p);
		}
		head.addAll(tail);
		return head;
	}

	@SuppressWarnings("unchecked")
	private static int overlayCount(OverlayManager om)
	{
		try
		{
			final Field f = OverlayManager.class.getDeclaredField("overlays");
			f.setAccessible(true);
			return ((List<Object>) f.get(om)).size();
		}
		catch (ReflectiveOperationException ex)
		{
			return -1;
		}
	}

	private static int countOccurrences(String haystack, String needle)
	{
		int n = 0, i = 0;
		while ((i = haystack.indexOf(needle, i)) >= 0)
		{
			n++;
			i += needle.length();
		}
		return n;
	}

	private interface Cond
	{
		boolean ok();
	}

	private static boolean await(String what, long timeoutMs, Cond c) throws InterruptedException
	{
		final long deadline = System.currentTimeMillis() + timeoutMs;
		while (System.currentTimeMillis() < deadline)
		{
			if (c.ok())
			{
				return true;
			}
			Thread.sleep(100);
		}
		out("[mui-smoke] timed out waiting for " + what);
		return false;
	}

	/** Markers go to stdout so they land in the device {@code jvm-stdio.log} verbatim for the bash md5-gate. */
	private static void out(String s)
	{
		System.out.println(s);
		System.out.flush();
	}
}
