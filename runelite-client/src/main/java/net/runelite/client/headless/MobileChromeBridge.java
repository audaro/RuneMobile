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

import java.awt.Rectangle;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.gameval.VarClientID;
import net.runelite.api.gameval.VarbitID;
import net.runelite.api.widgets.Widget;

/**
 * W3 hybrid-chrome (Phase 6): the <b>read-only</b> geometry/state snapshot the native Jagex-Mobile chrome
 * reads each display tick. The desktop {@code ToplevelOsm} (group 601) mobile layout is unreachable and would
 * break unmodified plugins (see {@code AUDIT-RESULT-mobile-layout-toplevel-osm.md}); the hybrid plan keeps the
 * desktop resizable root authoritative for the real game UI and <em>draws native chrome over it</em>. To do
 * that the native side needs, every frame, where the desktop tab stones / side panel / minimap / orbs / chat
 * live and which tab is active — so it can cover them with native rails, proxy taps to the live widgets, and
 * highlight the active tab.
 *
 * <p><b>This class never mutates a widget.</b> It only reads. That is the whole point of leading the hybrid
 * build with a read surface: hiding or moving desktop widgets risks breaking overlay anchoring
 * ({@code OverlayRenderer.getViewportLayer} / {@code WidgetOverlay} both assume desktop root geometry) and the
 * ~9 plugins that hardcode desktop toplevel IDs. Cover-and-proxy needs none of that; only reads.
 *
 * <p>The active root is resolved the same way {@code OverlayRenderer.getViewportLayer} does — fixed
 * {@code Toplevel} (548), or one of the two resizable roots ({@code ToplevelOsrsStretch} 161 /
 * {@code ToplevelPreEoc} 164) by {@code RESIZABLE_STONE_ARRANGEMENT}. Device and desktop both run resizable,
 * so PRE_EOC/OSRS_STRETCH are the live cases; FIXED is supported for completeness (its minimap/side container
 * components differ and are simply reported absent).
 *
 * <p>Thread model mirrors {@link MobileUiBridge}: {@link #tick(Client)} runs on the client thread (from
 * {@code Hooks.draw}) and publishes an escaped JSON snapshot into a volatile; {@link #getSnapshot()} is read
 * lock-free from the native JNI thread. Entirely inert unless {@code -Drunelite.mobilechrome=true}.
 *
 * <p>For the desktop de-risk it also emits, once, a single bash-parseable readability verdict line
 * ({@code [chrome] CHROME_READ …}) so a harness can md5-gate that the entire read surface resolved (documented
 * false-GREEN history — never trust a shell echo).
 */
@Slf4j
public final class MobileChromeBridge
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.mobilechrome");

	private enum Root { FIXED, OSRS_STRETCH, PRE_EOC, NONE }

	// The 14 tab stones per root, in tab-index order (0..13). All three roots define STONE0..13.
	private static final int[] STONES_FIXED = {
		InterfaceID.Toplevel.STONE0, InterfaceID.Toplevel.STONE1, InterfaceID.Toplevel.STONE2,
		InterfaceID.Toplevel.STONE3, InterfaceID.Toplevel.STONE4, InterfaceID.Toplevel.STONE5,
		InterfaceID.Toplevel.STONE6, InterfaceID.Toplevel.STONE7, InterfaceID.Toplevel.STONE8,
		InterfaceID.Toplevel.STONE9, InterfaceID.Toplevel.STONE10, InterfaceID.Toplevel.STONE11,
		InterfaceID.Toplevel.STONE12, InterfaceID.Toplevel.STONE13,
	};
	private static final int[] STONES_OSRS_STRETCH = {
		InterfaceID.ToplevelOsrsStretch.STONE0, InterfaceID.ToplevelOsrsStretch.STONE1, InterfaceID.ToplevelOsrsStretch.STONE2,
		InterfaceID.ToplevelOsrsStretch.STONE3, InterfaceID.ToplevelOsrsStretch.STONE4, InterfaceID.ToplevelOsrsStretch.STONE5,
		InterfaceID.ToplevelOsrsStretch.STONE6, InterfaceID.ToplevelOsrsStretch.STONE7, InterfaceID.ToplevelOsrsStretch.STONE8,
		InterfaceID.ToplevelOsrsStretch.STONE9, InterfaceID.ToplevelOsrsStretch.STONE10, InterfaceID.ToplevelOsrsStretch.STONE11,
		InterfaceID.ToplevelOsrsStretch.STONE12, InterfaceID.ToplevelOsrsStretch.STONE13,
	};
	private static final int[] STONES_PRE_EOC = {
		InterfaceID.ToplevelPreEoc.STONE0, InterfaceID.ToplevelPreEoc.STONE1, InterfaceID.ToplevelPreEoc.STONE2,
		InterfaceID.ToplevelPreEoc.STONE3, InterfaceID.ToplevelPreEoc.STONE4, InterfaceID.ToplevelPreEoc.STONE5,
		InterfaceID.ToplevelPreEoc.STONE6, InterfaceID.ToplevelPreEoc.STONE7, InterfaceID.ToplevelPreEoc.STONE8,
		InterfaceID.ToplevelPreEoc.STONE9, InterfaceID.ToplevelPreEoc.STONE10, InterfaceID.ToplevelPreEoc.STONE11,
		InterfaceID.ToplevelPreEoc.STONE12, InterfaceID.ToplevelPreEoc.STONE13,
	};

	// -1 = component does not exist for that root (fixed lacks MAP_MINIMAP/MAP_CONTAINER/SIDE_CONTAINER).
	private static final int NONE_ID = -1;

	// Latest read-only snapshot (escaped JSON); published on the client thread, read on the native thread.
	private static volatile String snapshotJson = "{\"enabled\":false}";

	// Content-derived publish seq: bumped only when the snapshot JSON actually changes, so the native republish
	// loop can skip the per-frame String copy on an unchanged frame (the menu-peek gate pattern). Because the seq
	// is derived from the bytes, an unchanged seq guarantees byte-identical JSON — the native side can never show
	// a stale snapshot. ALWAYS publish through {@link #publishSnapshot} so every assignment updates the seq.
	private static volatile long snapshotSeq;

	private static void publishSnapshot(String json)
	{
		if (!json.equals(snapshotJson))
		{
			snapshotJson = json;   // store the JSON BEFORE the seq so a native reader that sees the new seq sees it
			snapshotSeq++;
		}
	}

	// FATAL-1: the engine-fatal code (js5connect / js5io / crash / other) noted from RSAppletStub.onError.
	// onError runs on the Swing EDT, off the client thread, so this is a plain volatile handoff — the next
	// tick() folds it into the snapshot; never publish directly from the noting thread. A fatal stop is
	// terminal (the applet is dead, nothing recovers), so once set it outranks every other snapshot state.
	private static volatile String fatalCode;

	/**
	 * Note an engine-fatal error code (from {@code RSAppletStub.onError} on mobile). Terminal: the shells
	 * surface a native card with a path forward instead of the Swing FatalErrorDialog that can't render
	 * headless. Safe from any thread; no-op when the bridge is disabled.
	 */
	public static void noteFatalError(String code)
	{
		if (ENABLED)
		{
			// Codes are fixed engine tokens (e.g. error_game_js5connect); sanitize anyway so the value can
			// be inlined into the hand-built JSON without an escaper.
			fatalCode = code == null ? "unknown" : code.replaceAll("[^A-Za-z0-9_.-]", "_");
		}
	}

	// One-shot readability verdict accumulator (desktop de-risk). Tracks the BEST any frame achieved, since
	// some widgets are not built on the very first LOGGED_IN frame.
	private static final int VERDICT_FRAME = 60;   // ~1.2s of LOGGED_IN frames at ~50 fps
	private static int loggedInFrames;
	private static boolean verdictEmitted;
	private static boolean sawSidePanel;
	private static boolean sawMinimap;
	private static boolean sawOrbs;
	private static boolean sawChat;
	private static boolean sawViewport;
	private static int lastActiveTab = Integer.MIN_VALUE;

	private MobileChromeBridge()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/**
	 * Build the read-only chrome snapshot for this frame. Runs on the client thread (from {@code Hooks.draw}),
	 * where widget bounds and varcs are safe to read. Touches no widget.
	 */
	public static void tick(Client c)
	{
		try
		{
			tickImpl(c);
		}
		catch (RuntimeException e)
		{
			BridgeFaults.note("MobileChromeBridge.tick", e);
		}
	}

	private static void tickImpl(Client c)
	{
		if (!ENABLED || c == null)
		{
			return;
		}

		// FATAL-1: a noted engine-fatal outranks EVERYTHING (including a lingering LOGGED_IN state — the
		// applet is dead by the time onError fires). The shells show a native "game updated / no
		// connection / crashed" card with a path forward; without this the headless boot is a silent
		// black screen after every weekly OSRS update.
		final String fatal = fatalCode;
		if (fatal != null)
		{
			publishSnapshot("{\"enabled\":true,\"loggedIn\":false,\"fatalError\":true,\"fatalCode\":\"" + fatal + "\"}");
			return;
		}

		final GameState state = c.getGameState();
		final boolean loggedIn = state == GameState.LOGGED_IN;
		if (!loggedIn)
		{
			// FIX-9: while the auto-reconnect machine is recovering an in-session drop, flag it so the native shell
			// can show a "Reconnecting…" overlay over the engine's brief transient login screens. The reconnect
			// string is byte-for-byte unchanged.
			// Bug 8: on a (non-reconnect) login screen add a loginScreen flag so the native chrome can tell a genuine
			// LOGIN_SCREEN→LOGGED_IN login (which needs a brief post-login chrome-suppression window to avoid the
			// welcome-frame flash) apart from an in-game LOADING/teleport blip (state==LOADING, never LOGIN_SCREEN —
			// stays loggedIn:false with no flag, so native keeps chrome engaged through region loads).
			// UX-LOGIN-01: a give-up (autologin/reconnect exhausted) parks on the raw login screen with no further
			// recovery — flag it so the native shell shows a "Session expired — sign in again" overlay (launches the
			// on-device login), distinct from the transient reconnecting scrim. Ordered: an ACTIVE reconnect wins
			// (still recovering); else a give-up is sessionExpired; else a plain login screen.
			publishSnapshot(HeadlessLogin.isReconnecting()
				? "{\"enabled\":true,\"loggedIn\":false,\"reconnecting\":true}"
				: HeadlessLogin.hasGivenUp()
					? "{\"enabled\":true,\"loggedIn\":false,\"loginScreen\":true,\"sessionExpired\":true}"
					: state == GameState.LOGIN_SCREEN
						? "{\"enabled\":true,\"loggedIn\":false,\"loginScreen\":true}"
						: "{\"enabled\":true,\"loggedIn\":false}");
			return;
		}

		final boolean resized = safeResized(c);
		final Root root = resolveRoot(c, resized);
		final int topLevel = safeTopLevel(c);
		final int activeTab = safeVarc(c, VarClientID.TOPLEVEL_PANEL);

		final int[] stones = stonesFor(root);
		final int minimapId = idMinimap(root);
		final int mapContainerId = idMapContainer(root);
		final int orbsId = idOrbs(root);
		final int sidePanelsId = idSidePanels(root);
		final int sideContainerId = idSideContainer(root);
		final int chatId = idChat(root);

		final StringBuilder sb = new StringBuilder(640);
		sb.append("{\"enabled\":true,\"loggedIn\":true")
			.append(",\"rootKind\":\"").append(root.name()).append('"')
			.append(",\"topLevelId\":").append(topLevel)
			.append(",\"resized\":").append(resized)
			.append(",\"activeTab\":").append(activeTab);

		// World viewport rect.
		final int[] vp = viewport(c);
		final boolean vpOk = vp != null;
		sb.append(",\"viewport\":");
		appendBounds(sb, vp);

		// Tab stones (always 14 slots so the native index maps 1:1 to the tab; null where not yet built).
		sb.append(",\"tabs\":[");
		for (int i = 0; i < stones.length; i++)
		{
			if (i > 0)
			{
				sb.append(',');
			}
			appendBounds(sb, boundsOf(c, stones[i]));
		}
		sb.append(']');

		final int[] sidePanel = boundsOf(c, sidePanelsId);
		final int[] sideContainer = boundsOf(c, sideContainerId);
		final int[] minimap = boundsOf(c, minimapId);
		final int[] mapContainer = boundsOf(c, mapContainerId);
		final int[] orbs = boundsOf(c, orbsId);
		final int[] chat = boundsOf(c, chatId);

		sb.append(",\"sidePanel\":");
		appendBounds(sb, sidePanel);
		sb.append(",\"sideContainer\":");
		appendBounds(sb, sideContainer);
		sb.append(",\"minimap\":");
		appendBounds(sb, minimap);
		sb.append(",\"mapContainer\":");
		appendBounds(sb, mapContainer);
		sb.append(",\"orbs\":");
		appendBounds(sb, orbs);
		sb.append(",\"chat\":");
		appendBounds(sb, chat);
		// FIX-4: the inventory item-grid bounds (canvas px) so the native shell can hit-test a drag's start
		// point on the UI thread (where it can't call into the JVM) and route it as an item-drag. Snapshotted
		// each tapTick by JavaBridge.snapshotInventoryBounds; null when the inventory tab isn't showing.
		final int[] inv = JavaBridge.getInventoryBounds();
		sb.append(",\"inv\":");
		appendBounds(sb, (inv != null && inv.length == 4 && inv[2] > 0 && inv[3] > 0) ? inv : null);
		// DRAG-1b: the engine drag-to-reorder pane bounds (Prayer/Spellbook/Bank), packed [x,y,w,h] per pane, so
		// the native shell can route a one-finger drag starting inside one as a reorder (onTouch) not a camera pan.
		// Snapshotted each tapTick by JavaBridge.snapshotReorderPaneBounds; empty array when none is on-screen.
		final int[] panes = JavaBridge.getReorderPaneBounds();
		sb.append(",\"reorderPanes\":[");
		if (panes != null)
		{
			for (int i = 0; i + 3 < panes.length; i += 4)
			{
				if (i > 0)
				{
					sb.append(',');
				}
				sb.append('[').append(panes[i]).append(',').append(panes[i + 1])
					.append(',').append(panes[i + 2]).append(',').append(panes[i + 3]).append(']');
			}
		}
		sb.append("]}");

		publishSnapshot(sb.toString());

		// ---- readability accumulator + one-shot verdict ----
		loggedInFrames++;
		sawSidePanel |= sidePanel != null;
		// minimap may be reported via either the minimap widget or its map container (fixed lacks both).
		sawMinimap |= minimap != null || mapContainer != null;
		sawOrbs |= orbs != null;
		sawChat |= chat != null;
		sawViewport |= vpOk;
		if (activeTab != lastActiveTab)
		{
			log.debug("[chrome] activeTab {} -> {} (root={})", lastActiveTab, activeTab, root);
			lastActiveTab = activeTab;
		}

		if (!verdictEmitted && loggedInFrames >= VERDICT_FRAME)
		{
			verdictEmitted = true;
			// Census the tab stones into present / hidden / absent / zero-size. The decisive read-surface gate
			// is tabsZeroSize == 0 — i.e. EVERY stone that exists and is shown resolved to real bounds. Stones
			// that are HIDDEN or ABSENT are legitimate account/layout states (e.g. tabs not yet unlocked on
			// Tutorial Island), NOT a read failure, so they must not fail the gate.
			int present = 0;
			int hidden = 0;
			int absent = 0;
			int zeroSize = 0;
			for (final int id : stones)
			{
				switch (classify(c, id))
				{
					case 0:
						present++;
						break;
					case 1:
						hidden++;
						break;
					case 2:
						absent++;
						break;
					default:
						zeroSize++;
						break;
				}
			}
			log.info("[chrome] CHROME_READ rootKind={} topLevel={} resized={} activeTab={} tabsTotal={} "
					+ "tabsPresent={} tabsHidden={} tabsAbsent={} tabsZeroSize={} "
					+ "sidePanel={} minimap={} orbs={} chat={} viewport={}",
				root, topLevel, resized, lastActiveTab, stones.length,
				present, hidden, absent, zeroSize,
				b01(sawSidePanel), b01(sawMinimap), b01(sawOrbs), b01(sawChat), b01(sawViewport));
		}
	}

	/** Latest read-only chrome snapshot as escaped JSON (native reads this each display tick). */
	public static String getSnapshot()
	{
		return snapshotJson;
	}

	/** Monotonic counter bumped once per CHANGED snapshot — native skips the per-frame copy when it is unchanged. */
	public static long getSnapshotSeq()
	{
		return snapshotSeq;
	}

	// ---- internals -------------------------------------------------------------------------------------

	private static Root resolveRoot(Client c, boolean resized)
	{
		try
		{
			if (resized)
			{
				return c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT) == 1 ? Root.PRE_EOC : Root.OSRS_STRETCH;
			}
			return Root.FIXED;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileChromeBridge.resolveRoot", ex);
			return Root.NONE;
		}
	}

	private static int[] stonesFor(Root r)
	{
		switch (r)
		{
			case PRE_EOC:
				return STONES_PRE_EOC;
			case OSRS_STRETCH:
				return STONES_OSRS_STRETCH;
			case FIXED:
				return STONES_FIXED;
			default:
				return new int[0];
		}
	}

	private static int idMinimap(Root r)
	{
		return r == Root.PRE_EOC ? InterfaceID.ToplevelPreEoc.MAP_MINIMAP
			: r == Root.OSRS_STRETCH ? InterfaceID.ToplevelOsrsStretch.MAP_MINIMAP : NONE_ID;
	}

	private static int idMapContainer(Root r)
	{
		return r == Root.PRE_EOC ? InterfaceID.ToplevelPreEoc.MAP_CONTAINER
			: r == Root.OSRS_STRETCH ? InterfaceID.ToplevelOsrsStretch.MAP_CONTAINER : NONE_ID;
	}

	private static int idOrbs(Root r)
	{
		switch (r)
		{
			case PRE_EOC:
				return InterfaceID.ToplevelPreEoc.ORBS;
			case OSRS_STRETCH:
				return InterfaceID.ToplevelOsrsStretch.ORBS;
			case FIXED:
				return InterfaceID.Toplevel.ORBS;
			default:
				return NONE_ID;
		}
	}

	private static int idSidePanels(Root r)
	{
		switch (r)
		{
			case PRE_EOC:
				return InterfaceID.ToplevelPreEoc.SIDE_PANELS;
			case OSRS_STRETCH:
				return InterfaceID.ToplevelOsrsStretch.SIDE_PANELS;
			case FIXED:
				return InterfaceID.Toplevel.SIDE_PANELS;
			default:
				return NONE_ID;
		}
	}

	private static int idSideContainer(Root r)
	{
		return r == Root.PRE_EOC ? InterfaceID.ToplevelPreEoc.SIDE_CONTAINER
			: r == Root.OSRS_STRETCH ? InterfaceID.ToplevelOsrsStretch.SIDE_CONTAINER : NONE_ID;
	}

	private static int idChat(Root r)
	{
		switch (r)
		{
			case PRE_EOC:
				return InterfaceID.ToplevelPreEoc.CHAT_CONTAINER;
			case OSRS_STRETCH:
				return InterfaceID.ToplevelOsrsStretch.CHAT_CONTAINER;
			case FIXED:
				return InterfaceID.Toplevel.CHAT_CONTAINER;
			default:
				return NONE_ID;
		}
	}

	/** {@code [x,y,w,h]} canvas bounds of a widget, or {@code null} if absent/hidden/zero-size/unknown id. */
	private static int[] boundsOf(Client c, int id)
	{
		if (id == NONE_ID)
		{
			return null;
		}
		try
		{
			final Widget w = c.getWidget(id);
			if (w == null || w.isHidden())
			{
				return null;
			}
			final Rectangle b = w.getBounds();
			if (b == null || b.width <= 0 || b.height <= 0)
			{
				return null;
			}
			return new int[]{b.x, b.y, b.width, b.height};
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileChromeBridge.boundsOf", ex);
			return null;
		}
	}

	/**
	 * Classify a stone widget for the read-surface census: {@code 0}=present (shown, real bounds),
	 * {@code 1}=hidden (exists but {@code isHidden}), {@code 2}=absent ({@code getWidget} null),
	 * {@code 3}=zero-size (shown but non-positive bounds — the only result that signals a read problem).
	 */
	private static int classify(Client c, int id)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w == null)
			{
				return 2;
			}
			if (w.isHidden())
			{
				return 1;
			}
			final Rectangle b = w.getBounds();
			return (b != null && b.width > 0 && b.height > 0) ? 0 : 3;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileChromeBridge.classify", ex);
			return 2;
		}
	}

	private static int[] viewport(Client c)
	{
		try
		{
			final int vx = c.getViewportXOffset();
			final int vy = c.getViewportYOffset();
			final int vw = c.getViewportWidth();
			final int vh = c.getViewportHeight();
			if (vx < 0 || vy < 0 || vw <= 0 || vh <= 0)
			{
				return null;
			}
			return new int[]{vx, vy, vw, vh};
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileChromeBridge.viewport", ex);
			return null;
		}
	}

	private static void appendBounds(StringBuilder sb, int[] b)
	{
		if (b == null)
		{
			sb.append("null");
			return;
		}
		sb.append('[').append(b[0]).append(',').append(b[1]).append(',').append(b[2]).append(',').append(b[3]).append(']');
	}

	private static boolean safeResized(Client c)
	{
		try
		{
			return c.isResized();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileChromeBridge.safeResized", ex);
			return false;
		}
	}

	private static int safeTopLevel(Client c)
	{
		try
		{
			return c.getTopLevelInterfaceId();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileChromeBridge.safeTopLevel", ex);
			return -1;
		}
	}

	private static int safeVarc(Client c, int var)
	{
		try
		{
			return c.getVarcIntValue(var);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("MobileChromeBridge.safeVarc", ex);
			return -1;
		}
	}

	private static int b01(boolean v)
	{
		return v ? 1 : 0;
	}
}
