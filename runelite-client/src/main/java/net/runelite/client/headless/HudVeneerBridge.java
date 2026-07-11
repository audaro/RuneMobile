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

import java.awt.image.BufferedImage;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.ChatLineBuffer;
import net.runelite.api.ChatMessageType;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.MessageNode;
import net.runelite.api.Player;
import net.runelite.api.ScriptID;
import net.runelite.api.SpritePixels;
import net.runelite.api.VarClientStr;
import net.runelite.api.events.BeforeRender;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.gameval.VarClientID;
import net.runelite.api.gameval.VarbitID;
import net.runelite.api.widgets.Widget;
import net.runelite.api.widgets.WidgetModalMode;
import net.runelite.api.widgets.WidgetPositionMode;
import net.runelite.api.widgets.WidgetSizeMode;
import net.runelite.client.eventbus.Subscribe;
import net.runelite.client.util.Text;

/**
 * W3 Feature-A (A3) — controls the engine chatbox so the chat-at-top look matches the OSRS Mobile reference.
 * A desktop probe ({@code ChatRelocateProbe}) proved the engine's own chatbox can be {@code setForcedPosition}'d
 * to the top and STILL renders there (not occluded by the 3D viewport — unlike tab stones). So instead of
 * reproducing the chat natively, we relocate the engine's pixel-perfect chat (tabs / scrollback / colours /
 * input all stay live, since it IS the real chat) and flip it to OSRS transparent-chat mode.
 *
 * <p>The desired state is set from the native shell (reverse JNI) and re-applied each frame on the client thread
 * (the engine rebuilds the toplevel on {@code TOPLEVEL_REDRAW}). Two modes: {@link #relocateChat} (move the
 * chatbox + optional transparency) or {@link #setChatHidden} (hide it outright). Inert unless
 * {@code -Drunelite.hudveneer=true}.
 */
@Slf4j
public final class HudVeneerBridge
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.hudveneer");

	private static final int CONTROLS_H = 23;   // the chat tab-row (CONTROLS) height, from the layout dump

	// W3 A3 (native chat tabs): the 7 chat tab buttons of the CONTROLS row in display order. The gamepack lays
	// each button out as a parent widget whose children are GRAPHIC = id+1 (the tab-background sprite), TEXT =
	// id+2 (the channel label) and FILTER = id+3 (the live "On"/"Off"/"Filter"/"Hide" sub-label) — except CHAT_ALL
	// which has no filter. The native veneer recreates these BIGGER (the engine has no per-widget scale and the
	// sprites are fixed-size), so this bridge publishes their live canvas geometry + state each frame and the
	// native side draws scaled UIKit buttons over them, proxying a precise click onto the live engine button.
	private static final int[] CHAT_TAB_IDS = {
		InterfaceID.Chatbox.CHAT_ALL, InterfaceID.Chatbox.CHAT_GAME, InterfaceID.Chatbox.CHAT_PUBLIC,
		InterfaceID.Chatbox.CHAT_PRIVATE, InterfaceID.Chatbox.CHAT_FRIENDSCHAT, InterfaceID.Chatbox.CHAT_CLAN,
		InterfaceID.Chatbox.CHAT_TRADE, InterfaceID.Chatbox.REPORTABUSE,
	};
	private static final String[] CHAT_TAB_NAMES = { "All", "Game", "Public", "Private", "Channel", "Clan", "Trade", "Report" };
	private static final int SPR_CHATBTN_SELECTED = 3053;   // SpriteID.CHATBOX_BUTTON_SELECTED — active tab
	private static final int SPR_CHATBTN_NEW = 3055;        // SpriteID.CHATBOX_BUTTON_NEW_MESSAGES — unread tab
	private static final int SPR_CHATBTN_IDLE = 3051;       // SpriteID.CHATBOX_BUTTON — idle tab

	// Native-chrome tab sprite set, loaded ONCE from the live cache after login and handed to the native shell so
	// the 2-col grid + chat-tab veneer composite the real OSRS art with NOTHING committed to the repo (the same
	// sprites the engine already draws — see captureTabSprites). stone 1180/1181 = RESIZEABLE_MODE_TAB_STONE_MIDDLE
	// [_SELECTED]; 774+tabIndex = the 14 tab glyphs; 3051/3053/3055 = the chat-tab backgrounds.
	private static final int SPR_STONE_INACTIVE = 1180;
	private static final int SPR_STONE_ACTIVE = 1181;
	private static final int SPR_TAB_ICON_BASE = 774;       // 774 + tabIndex, 14 glyphs (combat..music)
	private static volatile String tabSpritesJson = "";     // one-shot ARGB payload (see captureTabSprites); "" until ready
	private static boolean tabSpritesCaptured = false;      // client-thread guard
	// Sprites load lazily — an archive the engine hasn't rendered (our tab stones are HIDDEN) isn't in the cache yet,
	// so a single tick returns a partial set. We accumulate across ticks (nudging missing archives via loadData) and
	// only latch when the grid set is complete, or at a deadline. Index: 0=stoneInactive,1=stoneActive,2..15=icons,
	// 16=chatbtn,17=chatbtnSelected,18=chatbtnNew.
	private static final int TAB_SPRITE_COUNT = 19;
	private static final String[] TAB_SPRITE_KEYS = {
		"stoneInactive", "stoneActive",
		"i0", "i1", "i2", "i3", "i4", "i5", "i6", "i7", "i8", "i9", "i10", "i11", "i12", "i13",
		"chatbtn", "chatbtnSelected", "chatbtnNew",
	};
	private static final String[] tabSpriteB64 = new String[TAB_SPRITE_COUNT];
	private static final int[][] tabSpriteDim = new int[TAB_SPRITE_COUNT][2];
	private static int tabCaptureTicks = 0;
	private static final int TAB_CAPTURE_DEADLINE = 600;    // generous safety valve before shipping a partial set

	// Desired state, set from native, applied on the client thread. chatX < 0 = not relocating.
	private static volatile int chatX = -1;
	private static volatile int chatY = -1;
	private static volatile boolean transparentChat;
	private static volatile boolean hideChat;

	// Minimap+orbs cluster (MAP_CONTAINER) relocate. minimapX < 0 = not relocating. Proven by MinimapRelocateProbe:
	// MAP_CONTAINER is root-anchored (setForcedPosition is ~canvas-absolute) and holds both the minimap globe and
	// the orbs as children, so one relocate moves the whole cluster — it renders at the new spot (not occluded) and
	// stays click-to-walk + orb-clickable (it IS the live engine HUD). This is A4 (minimap) + A5 (orbs) in one move.
	private static volatile int minimapX = -1;
	private static volatile int minimapY = -1;

	// Side panel (SIDE_CONTAINER = the inventory / equipment / spellbook / etc. panel) relocate. sideX < 0 = off.
	// Same root-anchored relocate as the minimap; edge-to-edge needs it pulled inward so it doesn't clip under the
	// notch. Best-effort (only shows when a tab is open); independently toggleable so a misbehave can be isolated.
	private static volatile int sideX = -1;
	private static volatile int sideY = -1;

	// Minimap ENLARGE (make the top-right globe bigger). 0 = natural size. Resizing the draw-area widget (MINIMAP)
	// makes the engine render a bigger globe (terrain + dots scale, click-to-walk follows for free since
	// Perspective.localToMinimap reads that widget's centre/size). The globe is RIGHT+TOP anchored so it grows
	// left+down about its fixed top-right corner; the surrounding chrome (compass / orbs / world-map / wiki / store)
	// are separate fixed widgets that DON'T scale, so we reposition them about that same corner to keep them hugging
	// the bigger globe, and hide the now-mismatched frame ring. Driven from native (setMinimapScale) or, off-device,
	// the -Drunelite.hudveneer.test.minimapScalePct prop.
	private static volatile int minimapScalePct;

	// Tab stones. The native 2-col tab grid replaces them, so we HIDE all 14 engine stones (removes the gray cover
	// patch the old proxy approach needed) and switch tabs by REPLAYING the stone's own op script — which works
	// even with the stone hidden (TabScriptProbe: replay + worksHidden GREEN). pendingOpenTab is a one-shot action
	// applied on the client thread (where runScript is legal).
	private static volatile boolean hideStones;
	private static volatile int pendingOpenTab = -1;
	// FIX-5: one-shot native "open the world map" — replays the ORB_WORLDMAP orb's op script so a native control
	// can open the map without hitting the ~25px engine orb (and fixes the legacy-account orb block). Applied on
	// the client thread in tick (where runScript is legal).
	private static volatile boolean pendingOpenWorldMap;

	// Native chat-tab veneer (A3 bigger buttons). chatTabRowH = the canvas-px height the native (enlarged) tab row
	// occupies; the message area (CHATAREA) is pushed down past it instead of the engine's 23px CONTROLS row. 0 =
	// fall back to CONTROLS_H. chatAreaW = the canvas-px width the native row spans, so the message area is widened
	// to ALIGN with the bigger buttons (0 = the engine default 519). chatSnapshotJson = the per-frame chat-tab
	// geometry/state the native side reads.
	private static volatile int chatTabRowH;
	private static volatile int chatAreaW;
	private static volatile String chatSnapshotJson = "{\"loggedIn\":false}";
	// True while an NPC/options/level-up/message/make-X dialogue interface is open. Those interfaces render INTO
	// the chatbox region, which the chat veneer's relocate+transparency suppresses — so while one is open we
	// RELEASE the veneer (chat back to natural+opaque) and the native side hides its chat veneer (reads this in
	// the snapshot as "dialogueActive"), giving the desktop-identical opaque dialogue box.
	private static volatile boolean dialogueOpen;
	// The open dialogue's content + head bounds (escaped JSON) for the native opaque dialogue. Built in tick when a
	// dialogue is open; "{}" otherwise. The native shell draws an opaque parchment over the chatbox region (so the
	// engine's transparent dialogue + the chat tabs/messages behind it are occluded), with a CUTOUT at the head
	// bounds so the engine's real 3D head model still shows through.
	private static volatile String dialogueJson = "{}";
	// The engine refuses to RASTER its chatbox once the host container is relocated (proven), so chat-at-top draws
	// the MESSAGE lines natively in UIKit instead. The engine chat stays alive + populated (off-screen); this snapshot
	// is the live message model — read from client.getChatLineMap() (not the broken widgets), filtered to the active
	// tab, with <col=> colour runs pre-parsed — that the native veneer renders. Published per-frame in tick().
	private static volatile String chatLinesJson = "{\"loggedIn\":false}";
	// Native minimap-orb touch veneer: per-frame canvas bounds of the live orbs (HP/prayer/run/spec/store/
	// world-map/wiki). The engine hard-pins the orbs and they render at ~25px — too small/dense for a finger —
	// so the native shell reads these bounds, enlarges the tap zone, and proxies a PRECISE click to the orb's
	// centre. The orbs stay live engine widgets (never moved); only the touch target grows. Published in tick().
	private static volatile String orbSnapshotJson = "{\"loggedIn\":false}";
	private static volatile int chatLinesSeq;

	// Content-derived publish seqs: each bumps only when its snapshot JSON actually changes, so the native
	// republish loop can skip the per-frame String copy when nothing changed (the menu-peek gate pattern). Because
	// the seq is derived from the bytes, an unchanged seq guarantees byte-identical JSON — so the native side can
	// never render a stale veneer (the GLM "seq must bump on every invalidation" caveat is satisfied by
	// construction). ALWAYS publish through the publishX helpers so every assignment updates the seq.
	private static volatile long chatSnapshotSeq;
	private static volatile long orbSnapshotSeq;
	private static volatile long dialogueSeq;
	private static volatile long mapSnapshotSeq;

	private static void publishChatSnapshot(String json)
	{
		if (!json.equals(chatSnapshotJson)) { chatSnapshotJson = json; chatSnapshotSeq++; }   // JSON before seq
	}

	private static void publishOrbSnapshot(String json)
	{
		if (!json.equals(orbSnapshotJson)) { orbSnapshotJson = json; orbSnapshotSeq++; }
	}

	private static void publishDialogueJson(String json)
	{
		if (!json.equals(dialogueJson)) { dialogueJson = json; dialogueSeq++; }
	}

	private static void publishMapSnapshot(String json)
	{
		if (!json.equals(mapSnapshotJson)) { mapSnapshotJson = json; mapSnapshotSeq++; }
	}

	// Native chat-tab SWITCH: which tab (0..7 index into CHAT_TAB_IDS) the native veneer asked to open. The engine
	// tab sprites are hidden (so they don't peek under the native row), which makes them unclickable — so switching
	// REPLAYS the tab's op-script instead of clicking, the same way the bottom tab-grid drives the hidden stones.
	// One-shot, applied on the client thread in tick(). -1 = nothing pending.
	private static volatile int pendingChatTab = -1;

	// Chat COLLAPSE: when the user taps the already-active tab, the chat box hides (mobile behaviour); a tap on any
	// tab reopens it. Driven from native (setChatCollapsed). While collapsed the engine chat raster is fully blanked
	// (the message CONTENT is hidden AND the engine tab row is hidden, which suppresses the whole raster) so nothing
	// renders behind the always-shown native tab row; reopening shows the tabs again + rebuilds the message list.
	private static volatile boolean chatCollapsed;
	// Last collapsed state APPLIED on the client thread — so the tick can detect the collapsed->open edge and rebuild.
	private static boolean chatCollapsedApplied;

	// True while a forefront window (bank / GE / shop / …) is open OVER the relocated chat region — the chat is
	// hidden so it sits BEHIND the window. Computed each tick; published as windowOpen in buildChatSnapshot so the
	// native shell hides its tab row too (UIKit tabs draw over the engine blit, so they must hide, not z-order).
	private static volatile boolean chatWindowOccluded;

	// Finger-scroll: accumulated chat scroll delta (canvas px) requested from native, applied on the client thread
	// in tick() via the chatbox's own scroll layer/scrollbar — NOT via a mouse wheel (the wheel also zooms the
	// camera because the transparent chat sits over the viewport). +delta = toward newer (bottom).
	private static final AtomicInteger pendingChatScroll = new AtomicInteger(0);

	private static final int CHAT_DEFAULT_W = 519;       // the engine's native chatbox width (from the layout dump)
	// Collapse = shove the live chatbox this far below its anchor (off-canvas) instead of hiding it, so its
	// history + selected channel survive and reopening is instant. Far enough to clear any stretched canvas.
	private static final int CHAT_COLLAPSE_OFFSCREEN_DY = 3000;
	private static final int ORIG_CHAT_CONTENT_H = 142;  // the natural message-area height (container 165 − CONTROLS 23)

	// Desktop off-device test harness: when -Drunelite.hudveneer.test=true, auto-apply the same chat veneer the
	// native shell drives (relocate + enlarged-tab geometry) once logged in, so the headless capture renders the
	// real chatbox geometry to PNG on the Mac (no device / StikDebug). Values default to the device's (render
	// 1304x600 → chat at 93,8, 32px tab row, natural width); overridable via -Drunelite.hudveneer.test.* props.
	private static final boolean TEST_APPLY = Boolean.getBoolean("runelite.hudveneer.test");
	private static boolean testApplied;

	private HudVeneerBridge()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/** Native: move the engine chatbox to {@code (x,y)} (top-left of the screen). {@code x < 0} stops relocating.
	 *  NOTE: the {@code transparent} flag is currently IGNORED — the relocated chatbox is always kept OPAQUE (its
	 *  background sprites hidden, so the brown box never shows) so that engine dialogues render as the solid
	 *  desktop parchment; the native veneer supplies the translucent chat look over the scene. The flag is retained
	 *  in the signature for API stability. */
	public static void relocateChat(int x, int y, boolean transparent)
	{
		chatX = x;
		chatY = y;
		transparentChat = transparent;
	}

	/** Native: hide the engine chatbox outright (used when the native veneer fully replaces it). */
	public static void setChatHidden(boolean hidden)
	{
		hideChat = hidden;
	}

	/** Native: relocate the engine minimap+orbs cluster ({@code MAP_CONTAINER}) to canvas {@code (x,y)}.
	 *  {@code x < 0} stops relocating. The cluster stays the live engine HUD — minimap clicks still walk and orb
	 *  clicks still fire (A4 + A5 in one relocate; MinimapRelocateProbe confirmed render + click-to-walk). */
	public static void relocateMinimap(int x, int y)
	{
		minimapX = x;
		minimapY = y;
	}

	/** Native: enlarge the engine minimap to {@code scalePct}% of its natural size (e.g. 130 = 30% bigger).
	 *  {@code 0} (or 100) = natural size. The globe + its chrome are re-laid each frame in {@link #tick}; the cluster
	 *  stays the live engine HUD, so click-to-walk + orb clicks keep working. */
	public static void setMinimapScale(int scalePct)
	{
		minimapScalePct = scalePct <= 0 ? 0 : scalePct;
	}

	/** Native: relocate the engine side panel ({@code SIDE_CONTAINER}) to canvas {@code (x,y)}. {@code x < 0} stops.
	 *  Same root-anchored relocate as the minimap; pulls the inventory/equipment panel inward for edge-to-edge so it
	 *  doesn't clip under the notch. The panel only exists while a tab is open, so this is a no-op until then. */
	public static void relocateSidePanel(int x, int y)
	{
		sideX = x;
		sideY = y;
	}

	/** Native: hide (or show) all 14 engine tab stones. With the native 2-col tab grid driving tabs via
	 *  {@link #openTab}, the real stones are hidden so there is no leftover stone row / cover patch. Re-applied
	 *  each frame (the engine rebuilds the toplevel on TOPLEVEL_REDRAW). */
	public static void setStonesHidden(boolean hidden)
	{
		hideStones = hidden;
	}

	/** Native: open the side-panel tab with the given index (0..13) by replaying that stone's op script — works
	 *  even while the stones are hidden. One-shot; applied on the client thread in {@link #tick}. */
	public static void openTab(int tabIndex)
	{
		pendingOpenTab = tabIndex;
	}

	/** Native: open the world map (FIX-5) by replaying the {@code ORB_WORLDMAP} orb's op script — a discoverable
	 *  open path decoupled from the ~25px engine orb. One-shot; applied on the client thread in {@link #tick}. */
	public static void openWorldMap()
	{
		pendingOpenWorldMap = true;
	}

	/** Native: the canvas-px height the enlarged native chat-tab row occupies, so the message area is pushed down
	 *  past it (the engine's own CONTROLS row is only 23px). {@code 0} restores the default 23px offset. */
	public static void setChatTabRowHeight(int canvasPx)
	{
		chatTabRowH = canvasPx;
	}

	/** Native: the canvas-px width the enlarged native chat-tab row spans, so the message area is widened to ALIGN
	 *  with the bigger buttons (the engine chatbox is fixed at 519). {@code 0} restores the default 519 width. */
	public static void setChatAreaWidth(int canvasPx)
	{
		chatAreaW = canvasPx;
	}

	/** Native: the live chat-tab geometry/state snapshot (escaped JSON) for the enlarged native tab veneer —
	 *  per-tab canvas bounds, selected/new-message state, and the live filter sub-label + colour. Read lock-free
	 *  on the JNI thread; published on the client thread in {@link #tick}. */
	public static String getChatSnapshot()
	{
		return chatSnapshotJson;
	}

	/** Monotonic counter bumped once per CHANGED chat-tab snapshot — native skips the copy when it is unchanged. */
	public static long getChatSnapshotSeq()
	{
		return chatSnapshotSeq;
	}

	/** Native: the live per-orb canvas bounds for the minimap-orb touch veneer — {@code {"loggedIn":true,
	 *  "hp":{"x":,"y":,"w":,"h":},"prayer":{..},"run":{..},"spec":{..},"store":{..},"worldmap":{..},"wiki":{..}}}
	 *  (an orb key is absent when that orb is hidden — e.g. spec with no spec weapon). Read lock-free on the JNI
	 *  thread; published on the client thread in {@link #tick}. The native side enlarges the tap zone and proxies a
	 *  precise click to the orb centre — orbs stay live engine widgets (hard-pinned), only the touch target grows. */
	public static String getOrbSnapshot()
	{
		return orbSnapshotJson;
	}

	/** Monotonic counter bumped once per CHANGED orb snapshot — native skips the copy when it is unchanged. */
	public static long getOrbSnapshotSeq()
	{
		return orbSnapshotSeq;
	}

	/** Native: the live chat MESSAGE lines (escaped JSON) for the active tab, with pre-parsed colour runs, for the
	 *  native top-rendered chatbox. Read lock-free on the JNI thread; published on the client thread in {@link #tick}.
	 *  Shape: {@code {"loggedIn":true,"view":N,"seq":K,"lines":[{"name":"..","type":N,"ts":N,"text":"..",
	 *  "runs":[{"o":N,"l":N,"c":RGB,"u":1}]}],"input":{"name":"..","text":".."}}} — lines OLDEST-first. */
	public static String getChatLines()
	{
		return chatLinesJson;
	}

	/** Native: the open dialogue's content for the native opaque-parchment renderer, or {@code "{}"} when none.
	 *  Shape: {@code {"type":"npc|player|both|message|options|levelup","name":"..","text":"..","runs":[..],
	 *  "continue":true,"options":[{"text":"..","runs":[..],"digit":N}],"head":{"x":,"y":,"w":,"h":}}} — bounds are
	 *  canvas px. The native side draws the parchment over the chatbox region with a cutout at {@code head} so the
	 *  engine's real 3D head model shows through; a continue tap sends SPACE, an option tap sends its digit. */
	public static String getDialogueJson()
	{
		return dialogueJson;
	}

	/** Monotonic counter bumped once per CHANGED dialogue snapshot — native skips the copy when it is unchanged. */
	public static long getDialogueSeq()
	{
		return dialogueSeq;
	}

	/** Native: scroll the chat by {@code deltaCanvasPx} (positive = toward newer/bottom). Accumulated and applied
	 *  on the client thread in {@link #tick} via the chatbox scroll layer — no mouse wheel, so the camera doesn't
	 *  zoom (the transparent chat overlays the viewport, where a wheel would zoom). */
	public static void scrollChat(int deltaCanvasPx)
	{
		pendingChatScroll.addAndGet(deltaCanvasPx);
	}

	/** Native: switch the chat to tab {@code index} (0..7 into the 7 native tabs + Report) by REPLAYING that tab's
	 *  op-script on the client thread — works even though the engine tab is hidden (a click wouldn't). One-shot. */
	public static void switchChatTab(int index)
	{
		pendingChatTab = index;
	}

	/** Native: collapse (hide) or expand the chat box. Tapping the active tab collapses; tapping any tab expands. */
	public static void setChatCollapsed(boolean collapsed)
	{
		chatCollapsed = collapsed;
	}

	// ---- Overlay snap-corner safe frame ----------------------------------------------------------------
	// The native shell renders the canvas EDGE-TO-EDGE, so the canvas corners sit under the iPhone's curved
	// bezel/notch, and the veneer relocates the chat to the canvas TOP-LEFT — both land on top of the default
	// overlay snap corners, so every plugin overlay snapped there (e.g. Quest Helper's TOP_LEFT guidance
	// panel) renders clipped and under the chat. Native pushes its safe-area insets in canvas px;
	// OverlayRenderer.positionSnapcorners insets the snap corners by them and additionally drops the top-left
	// corner below the relocated chat. Zero-impact on desktop (insets stay 0, chat not relocated).

	private static volatile int overlayInsetL, overlayInsetT, overlayInsetR, overlayInsetB;

	/** Native: the screen safe-area insets in canvas px (left, top, right, bottom). */
	public static void setOverlaySafeInsets(int l, int t, int r, int b)
	{
		overlayInsetL = l;
		overlayInsetT = t;
		overlayInsetR = r;
		overlayInsetB = b;
	}

	/** Snap-corner safe-area insets {l,t,r,b} in canvas px (all 0 until native pushes them). */
	public static int[] getOverlayInsets()
	{
		return new int[]{overlayInsetL, overlayInsetT, overlayInsetR, overlayInsetB};
	}

	/**
	 * The relocated chat's occupied canvas rect {x,y,w,h} for snap-corner avoidance — the native tab row only
	 * while collapsed, the full chat box while open — or null when the veneer isn't relocating the chat.
	 */
	public static int[] getOverlayChatAvoid()
	{
		if (!ENABLED || chatX < 0)
		{
			return null;
		}
		final int rowH = chatTabRowH > 0 ? chatTabRowH : CONTROLS_H;
		final int w = chatAreaW > 0 ? chatAreaW : CHAT_DEFAULT_W;
		final int h = chatCollapsed ? rowH : rowH + ORIG_CHAT_CONTENT_H + 2;
		return new int[]{chatX, chatY, w, h};
	}

	/**
	 * Pre-render re-assert of the PEEK-SUPPRESSION hides — called from {@code Hooks.frame()}, the engine's
	 * BeforeRender seam: after the client tick that may have rebuilt widgets, before anything rasterizes.
	 * {@link #tick} runs in the post-render draw callback, so an interface rebuild that reset our hidden
	 * flags (an item click's chat message re-running the chatbox script; a TOPLEVEL_REDRAW re-laying the tab
	 * stones) used to get exactly ONE rendered frame before the re-hide — the engine chat tabs/background
	 * flashing at the relocated top-left, and the desktop stone rows flashing at the bottom-right. Re-hiding
	 * here makes those widgets unpaintable instead of cleaned-up-a-frame-late. Hides only (cheap setHidden
	 * calls, idempotent); the position/size forcing stays in {@link #tick} where it always ran.
	 */
	public static void preRender(Client c)
	{
		if (!ENABLED || c == null || c.getGameState() != GameState.LOGGED_IN)
		{
			return;
		}
		try
		{
			if (!c.isResized())
			{
				return;
			}
			final boolean preEoc = c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT) == 1;
			if (hideStones)
			{
				final int[] ids = stoneIds(preEoc);
				hideRowOf(c, ids[0]);
				hideRowOf(c, ids[7]);
			}
			// Same gates as the chat block in tick(): only while the chat veneer is active and the world map
			// doesn't own the screen. (A dialogue uses the normal relocate path and stays at the top, so this
			// re-assert applies during dialogues too.)
			// Pin the chatbox TRANSPARENT as the final word before raster too (see tick/keepChatboxTransparent): the
			// engine then draws the message lines with the over-scene colour set (white names + shadow), the official
			// mobile look. Only while the veneer is relocating the chat — otherwise leave the chatbox's own setting.
			if (chatX >= 0)
			{
				// Path B: opaque (0) while a dialogue is open so the engine paints its own dialogue parchment + head;
				// transparent (1) otherwise. This is the FINAL word before raster, so it MUST mirror tick()'s
				// per-dialogue flip — forcing transparent here unconditionally would override the opaque dialogue.
				if (dialogueOpen)
				{
					setChatboxTransparency(c, 0);
				}
				else
				{
					keepChatboxTransparent(c);
				}
			}
			if (chatX >= 0 && !isWorldMapOpen(c))
			{
				// Engine tabs drive the WHOLE chat raster: shown -> the engine draws its chat (tabs + messages +
				// scrollbar) and the native row lays its enlarged buttons ON TOP; hidden -> the engine draws NOTHING
				// (proven off-device). So while collapsed we hide them too, which blanks the engine chat entirely (the
				// content-hide alone leaves the tab row rasterising behind the native row as a leftover 'border').
				setEngineChatTabsHidden(c, chatCollapsed);
				// Path B (final word before raster): SHOW the chat brown box while a dialogue is open (the dialogue
				// draws onto it -> opaque dialogue), HIDE it otherwise (transparent message veneer). Must mirror tick()
				// or this re-hide would blank the dialogue box every frame. CONTROLS backgrounds stay hidden.
				setHidden(c, InterfaceID.Chatbox.CHAT_BACKGROUND, !dialogueOpen);
				hide(c, InterfaceID.Chatbox.CONTROLS_BACKGROUND);
				hide(c, InterfaceID.Chatbox.CONTROLS_BACKGROUND_GRAPHIC);
			}
		}
		catch (Throwable e)
		{
			// preRender is its own per-frame engine-thread seam (a BeforeRender subscriber dispatched from
			// Hooks.frame()), NOT routed through HeadlessSeams.guard. EventBus.post catches only Exception and
			// Hooks.frame() catches nothing, so this is the terminal barrier: catch Throwable — not just
			// RuntimeException — so an upstream-merge LinkageError/NoSuchMethodError behind these engine-API
			// calls can't escape and kill the frame thread (the QA-P1-07 class). Matches HeadlessSeams.guard.
			BridgeFaults.note("HudVeneerBridge.preRender", e);
		}
	}

	/**
	 * Runs {@link #preRender(Client)} as the very last {@code BeforeRender} subscriber, so the engine-widget
	 * hides (tab-stone rows, chat tabs/background) get the final word just before the frame rasters — the
	 * "chrome flash on item click" fix. The priority is well below {@code TabInterface}'s {@code -1} (which
	 * rebuilds the tab stones on {@code BeforeRender}), so this re-hides them immediately after. Registered —
	 * only when {@link #isEnabled()} — from {@link net.runelite.client.ui.HeadlessClientUI}; this replaces the
	 * former direct call from {@code Hooks.frame()}, so that callback stays pure upstream.
	 */
	public static final class BeforeRenderListener
	{
		private final Client client;

		public BeforeRenderListener(Client client)
		{
			this.client = client;
		}

		@Subscribe(priority = -1000f)
		public void onBeforeRender(BeforeRender event)
		{
			preRender(client);
		}
	}

	/** Re-apply the requested chatbox state each frame. Client thread. */
	public static void tick(Client c)
	{
		if (!ENABLED || c == null || c.getGameState() != GameState.LOGGED_IN)
		{
			return;
		}
		try
		{
			if (!c.isResized())
			{
				return;   // native veneers + transparent chat are resizable-mode only
			}
			captureTabSprites(c);   // one-shot: hand the real cache tab/stone/chat sprites to the native shell
			if (TEST_APPLY && !testApplied)
			{
				// Off-device capture: drive the chat veneer ourselves (the native shell would on device). The
				// in-world "Welcome to RuneScape" news overlay is dismissed by HeadlessLogin so the chat is visible.
				testApplied = true;
				relocateChat(Integer.getInteger("runelite.hudveneer.test.chatX", 93),
					Integer.getInteger("runelite.hudveneer.test.chatY", 8),
					!"false".equals(System.getProperty("runelite.hudveneer.test.transparent")));
				setChatTabRowHeight(Integer.getInteger("runelite.hudveneer.test.rowH", 32));
				setChatAreaWidth(Integer.getInteger("runelite.hudveneer.test.areaW", 0));
			}
			final boolean preEoc = c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT) == 1;

			// The minimap-orb cluster's ORBS layer is built, but in this headless boot the engine never opens the
			// Orbs interface (group 160) INTO that layer — so the HP/prayer/run/spec orbs + world-map/wiki/store
			// icons never render (verified: the ORBS layer widget exists and is un-hidden, but every Orbs.* child
			// resolves null). Open it ourselves once the layer exists; the interface's own onload binds it to the
			// live orb varplayers, so it renders + updates like a normal client. No-op once the orbs are present.
			ensureOrbsLoaded(c, preEoc);
			buildOrbSnapshot(c);   // per-frame orb canvas bounds for the native minimap-orb touch veneer

			final int chatId = preEoc ? InterfaceID.ToplevelPreEoc.CHAT_CONTAINER : InterfaceID.ToplevelOsrsStretch.CHAT_CONTAINER;
			// While the world map is open it owns the screen: the relocated-HUD apply blocks below are gated
			// OFF (tickWorldMap shoves chat/minimap/side off-screen instead and grows the map to the full
			// canvas); when it closes the blocks resume re-forcing the HUD home on the very next frame.
			final boolean mapOpenNow = isWorldMapOpen(c);
			final boolean dlgOpen = isDialogueOpen(c);
			dialogueOpen = dlgOpen;   // published in buildChatSnapshot so the native side hides its chat veneer

			// Keep the engine chatbox TRANSPARENT from the FIRST logged-in frame so the message lines render in the
			// over-scene colour set (white names + glyph shadow = the official mobile look) instead of the dark
			// opaque-box colours. Pinned here before the chat/map gates (guarded, no script churn). The engine's own
			// dialogue is occluded by the native opaque parchment, so it no longer needs the chatbox forced opaque.
			// Only while the veneer is relocating the chat (chatX >= 0); when NOT relocating, leave the engine's
			// original chatbox at its own transparency setting (the user's choice).
			if (chatX >= 0)
			{
				// Path B (engine-rendered dialogue): while a dialogue is open switch the chatbox to OPAQUE (0) so the
				// engine paints its own dialogue parchment + full 3D head (desktop look); otherwise keep it
				// TRANSPARENT (1) for the over-scene message veneer. Edge-guarded inside setChatboxTransparency.
				if (dlgOpen)
				{
					setChatboxTransparency(c, 0);
				}
				else
				{
					keepChatboxTransparent(c);
					// Force chat USERNAMES white (official-mobile look) via the textrecolor config — ChatMessageManager
					// recolours sender names from it. Applies once; rebuild the chatbox that one time so the already-shown
					// lines recolour too (new lines recolour on their build).
					if (MobileUiBridge.forceWhiteChatUsernames())
					{
						try { c.runScript(ScriptID.BUILD_CHATBOX); } catch (RuntimeException ignore) { BridgeFaults.note("HudVeneerBridge.buildChatbox", ignore); }
					}
				}
			}

			// Chat box: keep the engine chatbox FULLY ALIVE at all times (never hidden). To "collapse" (the user
			// tapped the active tab) we shove the live widget far off-screen; reopening just moves it back — instant
			// and full, with NO interface teardown, tab-selection loss, or rebuild. (Hiding the container tore the
			// chat down, so reopen showed an empty box until a second tap.) The native tab row stays put because
			// buildChatSnapshot reports the configured chatX/chatY, not the widget's moved position.
			// A dialogue (NPC/options/level-up/message/make-X) is handled by the SAME relocate path as the chat —
			// the dialogue renders into the chatbox region and follows it to the relocated TOP position (which is
			// where the user expects it, and where the native tap routing resolves it). We do NOT release the chat
			// to the natural bottom (an earlier attempt did, which moved the dialogue's clickable widget away from
			// where it shows). `dialogueOpen` is still published so the native shell hides its chat-line veneer
			// (so it doesn't overlap the dialogue) and routes taps over the chatbox region to a precise click.
			if (chatX >= 0 && !mapOpenNow)
			{
				final int rowH = chatTabRowH > 0 ? chatTabRowH : CONTROLS_H;
				final int rowW = chatAreaW > 0 ? chatAreaW : CHAT_DEFAULT_W;
				// A forefront window (bank / GE / shop / …) open: hide the chat so it sits BEHIND the window (the
				// native shell also hides its tab row from the published windowOpen flag).
				chatWindowOccluded = isForefrontWindowOpen(c);
				dumpOpenInterfaces(c);   // DIAGNOSTIC — see the [ifaces] log to tune the FOREFRONT_WINDOW_GROUPS list
				final Widget w = c.getWidget(chatId);
				if (w != null)
				{
					if (chatWindowOccluded)
					{
						// HIDE the whole chat container. Collapse (tap the active tab) and a forefront window both hide
						// it the same way — the off-screen shove no longer holds now the engine draws the chat itself;
						// hiding is how the world map reliably hides it too. Reopen un-hides + rebuilds (BUILD_CHATBOX).
						if (!w.isHidden())
						{
							w.setHidden(true);
						}
					}
					else
					{
						if (w.isHidden())
						{
							w.setHidden(false);
							try { c.runScript(ScriptID.BUILD_CHATBOX); } catch (RuntimeException ignore) { BridgeFaults.note("HudVeneerBridge.buildChatbox", ignore); }
						}
						w.setForcedPosition(chatX, chatY);
						// Widen the chat CONTAINER to the native row width so its children (the message area) can fill it.
						if (w.getOriginalWidth() != rowW)
						{
							w.setOriginalWidth(rowW);
						}
						w.revalidate();
					}
				}
				// OSRS-Mobile tabs-on-top: the desktop chat stacks the tab row (CONTROLS, 23px) UNDER the message
				// area (CHATAREA, 142px). Flip it — force the tab row to the chat's top and push the messages down
				// by the tab height — so the layout reads tabs -> messages -> input like the mobile reference. When
				// the native veneer enlarges the tabs it reports its taller row height; push CHATAREA past THAT so
				// the scrollback clears the bigger buttons (the engine's own 23px CONTROLS stays put underneath,
				// covered by the native row, so a native tab tap can still proxy a precise click onto it).
				// setForcedPosition is RELATIVE TO THE PARENT, and the chat container is already at (chatX,chatY),
				// so position the children at (0, …) — using (chatX,chatY) double-offsets them right+down (the
				// misalignment + bottom clip). CONTROLS at the container's top-left.
				forcePos(c, InterfaceID.Chatbox.CONTROLS, 0, 0);
				// Engine tabs drive the WHOLE chat raster: hiding ANY tab widget suppresses it (the engine draws
				// nothing — proven off-device). When OPEN we WANT that raster (tabs + messages + scrollbar = the
				// desktop look) with the native row laid ON TOP (same sprite, no peeking) and a native tap proxying
				// the engine tab's op-script. When COLLAPSED we hide the tabs too so the engine draws NOTHING — the
				// content-hide below alone leaves the engine tab row rasterising behind the native row as a leftover
				// 'border'. Rebuild the chatbox on the collapsed->open edge so the messages repopulate (not an empty box).
				setEngineChatTabsHidden(c, chatCollapsed);
				// Repopulate the messages on the collapsed->open edge — UNLESS a dialogue is open (auto-open un-collapses
				// the chat to show the dialogue; rebuilding would briefly repopulate the message lines, which then bleed
				// over the opaque dialogue box). The dialogue replaces the messages anyway, so skip the rebuild.
				if (chatCollapsedApplied && !chatCollapsed && !dlgOpen)
				{
					try { c.runScript(ScriptID.BUILD_CHATBOX); } catch (RuntimeException ignore) { BridgeFaults.note("HudVeneerBridge.buildChatbox", ignore); }
				}
				chatCollapsedApplied = chatCollapsed;
				// Apply a pending tab switch (op-replay sets the channel; switchChatTabNow rebuilds the lines).
				final int switchTab = pendingChatTab;
				if (switchTab >= 0)
				{
					pendingChatTab = -1;
					switchChatTabNow(c, switchTab);
				}
				// Resize + reposition the message area so it ALIGNS with the bigger native row (width = rowW) and
				// FITS below it without clipping the newest line. Deterministic: read the chat container's real
				// height, then pin CHATAREA to ABSOLUTE width=rowW and height=(containerH - rowH - margin) at
				// container-relative (0, rowH). The display/scroll children are revalidated so they widen too.
				// Skip during a dialogue: sizeChatArea force-SHOWS the message widgets (CHATAREA/CHATDISPLAY/MES_LAYER/
				// SCROLLAREA/INPUT) every frame, which re-shows the chat lines over the opaque dialogue box. The
				// dialogue replaces the messages, so leave the area alone while one is open.
				if (!dlgOpen) sizeChatArea(c, chatId, rowW, rowH);
				// Path B: in classic OSRS the dialogue draws its head + text ONTO the chatbox brown box. So while a
				// dialogue is open SHOW CHAT_BACKGROUND (opaque dialogue box); otherwise HIDE it so chat messages draw
				// transparent over the scene. CONTROLS backgrounds stay hidden (the native tab row covers that strip).
				setHidden(c, InterfaceID.Chatbox.CHAT_BACKGROUND, !dlgOpen);
				hide(c, InterfaceID.Chatbox.CONTROLS_BACKGROUND);
				hide(c, InterfaceID.Chatbox.CONTROLS_BACKGROUND_GRAPHIC);
				// Collapse (tap the active tab) hides only the message CONTENT, not the container, so the lines are
				// PRESERVED (no teardown) and reopening is instant + populated instead of an empty box that needs a
				// second tap to rebuild. sizeChatArea force-shows these every frame, so re-hide them here when collapsed.
				// Hide the message area + input + scrollbar while COLLAPSED or while a DIALOGUE is open: the dialogue
				// replaces the chat messages (desktop behaviour), and leaving them shown lets live chat lines bleed
				// over the opaque dialogue box. The dialogue groups are separate top-level interfaces, so hiding
				// CHATAREA hides only the message lines, not the dialogue.
				// Hide the message area while COLLAPSED or while a DIALOGUE is open. Hiding the CHATAREA parent hides
				// its children (CHATDISPLAY/MES_LAYER/INPUT) too — and since sizeChatArea (which force-shows + resizes
				// them) is SKIPPED during a dialogue, nothing re-shows them, so this alone stops the chat-line bleed.
				// Do NOT separately hide+show the child layers: that hide/show cycle made the engine re-lay them on the
				// next BUILD_CHATBOX and clipped/dropped the bottom input line.
				final boolean hideMsgArea = chatCollapsed || dlgOpen;
				setHidden(c, InterfaceID.Chatbox.CHATAREA, hideMsgArea);
				setHidden(c, InterfaceID.Chatbox.INPUT, hideMsgArea);
				setHidden(c, InterfaceID.Chatbox.INPUT_CLICKAREA, hideMsgArea);
				setHidden(c, InterfaceID.Chatbox.CHATSCROLLBAR, hideMsgArea);
				buildChatSnapshot(c);
				buildChatLines(c);
				// While a dialogue is open, publish its content + head bounds so the native shell draws an opaque
				// parchment over the chatbox region (occluding the engine's transparent dialogue + the chat
				// tabs/messages) with a cutout where the engine's real 3D head renders. Cleared when none is open.
				if (dlgOpen)
				{
					buildDialogueJson(c);
				}
				else
				{
					publishDialogueJson("{}");
				}
				// Apply any finger-scroll requested from native (client thread — runScript is legal here).
				final int scrollDelta = pendingChatScroll.getAndSet(0);
				if (scrollDelta != 0)
				{
					applyChatScroll(c, scrollDelta);
				}
				dumpChatLayoutOnce(c, chatId);
			}
			else if (hideChat)
			{
				final Widget w = c.getWidget(chatId);
				if (w != null && !w.isHidden())
				{
					w.setHidden(true);
				}
			}

			// Minimap+orbs cluster relocate (independent of chat). Force MAP_CONTAINER each frame so it survives
			// TOPLEVEL_REDRAW; revalidate cascades to the globe + orb children.
			if (minimapX >= 0 && !mapOpenNow)
			{
				final int containerId = preEoc
					? InterfaceID.ToplevelPreEoc.MAP_CONTAINER : InterfaceID.ToplevelOsrsStretch.MAP_CONTAINER;
				final Widget w = c.getWidget(containerId);
				if (w != null)
				{
					w.setForcedPosition(minimapX, minimapY);
					w.revalidate();
				}
			}

			// Minimap ENLARGE: resize the globe + reposition its chrome so the whole cluster reads as a bigger
			// minimap. Off-device the scale comes from the test prop; on device it's driven by native setMinimapScale.
			if (TEST_APPLY)
			{
				final int p = Integer.getInteger("runelite.hudveneer.test.minimapScalePct", 0);
				if (p > 0)
				{
					minimapScalePct = p;
				}
			}
			if (minimapScalePct > 0)
			{
				applyMinimapScale(c, preEoc, minimapScalePct);
			}

			// Side panel relocate (independent). No-op until a tab is open (SIDE_CONTAINER then becomes non-null).
			if (sideX >= 0 && !mapOpenNow)
			{
				final int sideId = preEoc
					? InterfaceID.ToplevelPreEoc.SIDE_CONTAINER : InterfaceID.ToplevelOsrsStretch.SIDE_CONTAINER;
				final Widget w = c.getWidget(sideId);
				if (w != null)
				{
					w.setForcedPosition(sideX, sideY);
					w.revalidate();
				}
			}

			// Hide the engine tab-stone bottom row by hiding the stones' GRANDPARENT containers — NOT the stones
			// themselves. The engine re-pins the stone widgets every frame (setHidden/relocate on a stone is
			// overridden — confirmed on device), but the ancestor containers are normal widgets whose hidden state
			// STICKS. The PARENT holds only the stone icons (hiding it leaves the empty stone backgrounds); the
			// GRANDPARENT holds the whole row (icons + backgrounds), so hiding it clears the row completely
			// (StoneSuppressProbe steady-state PNG + device). Stones still resolve under the hidden ancestor, so
			// openTab (replaying a stone's op script) still switches tabs. STONE0 = left half, STONE7 = right half.
			if (hideStones)
			{
				final int[] ids = stoneIds(preEoc);
				hideRowOf(c, ids[0]);
				hideRowOf(c, ids[7]);
			}

			// One-shot: open a tab by replaying its stone's op script (works even with the stone hidden).
			final int openIdx = pendingOpenTab;
			if (openIdx >= 0)
			{
				pendingOpenTab = -1;
				openTabNow(c, preEoc, openIdx);
			}

			// One-shot: open the world map by replaying the orb's op script (FIX-5 native open control).
			if (pendingOpenWorldMap)
			{
				pendingOpenWorldMap = false;
				openWorldMapNow(c);
			}

			tickWorldMap(c);
		}
		catch (RuntimeException e)
		{
			BridgeFaults.note("HudVeneerBridge.tick", e);
		}
	}

	// ---- World map (touch-friendly — WORLDMAP-MOBILE-PLAN.md Phase 1) ----------------------------------------
	// Phase-0 probe facts: a synthetic left-drag does NOT pan the map, but setWorldMapPositionTarget does — so
	// the native pan gesture accumulates finger deltas (canvas px) here and tick converts them to map tiles via
	// the live zoom (px per tile) and moves the map centre — "grab the map", 1:1 with the finger. The snapshot
	// publishes open-state + the edge-control rects so native can gate gestures, raise the keyboard on a search
	// tap (the map search does NOT flip INPUT_TYPE), and proxy the bezel-clipped close button.

	private static final java.util.concurrent.atomic.AtomicInteger mapPanDx = new java.util.concurrent.atomic.AtomicInteger();
	private static final java.util.concurrent.atomic.AtomicInteger mapPanDy = new java.util.concurrent.atomic.AtomicInteger();
	private static final java.util.concurrent.atomic.AtomicInteger mapScrollDelta = new java.util.concurrent.atomic.AtomicInteger();
	private static float mapPanRemX, mapPanRemY;   // sub-tile remainders (client thread only)
	private static volatile String mapSnapshotJson = "{\"open\":false}";

	/** Native: pan the open world map by a finger delta in canvas px (drag right = map content follows right). */
	public static void panWorldMap(int dxPx, int dyPx)
	{
		mapPanDx.addAndGet(dxPx);
		mapPanDy.addAndGet(dyPx);
	}

	/** Native: scroll the open world map's KEY (legend) list — or the surface MAPLIST dropdown while it's open —
	 *  by a finger delta in canvas px. Applied on the client thread in {@link #tickWorldMap} via the engine's own
	 *  {@code UPDATE_SCROLLBAR} script (the same path the scrollbar arrows use), so no mouse-wheel/camera side-effect. */
	public static void scrollMapPanel(int deltaCanvasPx)
	{
		mapScrollDelta.addAndGet(deltaCanvasPx);
	}

	/** {@code {open, map:[x,y,w,h], close:[...], search:[...], zoomIn:[...], zoomOut:[...]}} (canvas px). */
	public static String getMapSnapshot()
	{
		return mapSnapshotJson;
	}

	/** Monotonic counter bumped once per CHANGED world-map snapshot — native skips the copy when it is unchanged. */
	public static long getMapSnapshotSeq()
	{
		return mapSnapshotSeq;
	}

	private static boolean lastWindowOccludedLogged;

	// Forefront "window" interface groups that should sit IN FRONT of the relocated chat, so the chat hides behind
	// them. Bank / deposit box / bank PIN / shop / Grand Exchange (offers + collect + view). Checked directly (an
	// open interface group is loaded) rather than via getWidgetRoots — the earlier root-scan missed them. Extend
	// this list from the [ifaces] diagnostic dump if a window the user opens isn't caught.
	private static final int[] FOREFRONT_WINDOW_GROUPS = {
		InterfaceID.BANKMAIN, InterfaceID.BANK_DEPOSITBOX, InterfaceID.BANKPIN_KEYPAD, InterfaceID.SHOPMAIN,
		InterfaceID.GE_OFFERS, InterfaceID.GE_COLLECT, InterfaceID.GE_VIEWONLY,
	};

	/** True if a forefront window (bank / GE / shop / …) is open, so the chat should hide and sit behind it. */
	private static boolean isForefrontWindowOpen(Client c)
	{
		for (final int g : FOREFRONT_WINDOW_GROUPS)
		{
			final Widget w;
			try
			{
				w = c.getWidget(g << 16);   // the group's root component (child 0); non-null + shown = the group is open
			}
			catch (RuntimeException ignore)
			{
				BridgeFaults.note("HudVeneerBridge.isForefrontWindowOpen", ignore);
				continue;
			}
			if (w != null && !w.isHidden())
			{
				if (!lastWindowOccludedLogged)
				{
					log.info("[veneer] chat occluded — forefront window group={} open", g);
					lastWindowOccludedLogged = true;
				}
				return true;
			}
		}
		lastWindowOccludedLogged = false;
		return false;
	}

	// DIAGNOSTIC (remove once occlusion is tuned): rate-limited dump of the open interface roots + candidate-window
	// probes, so the [ifaces] log reveals exactly which group/bounds the bank/GE use when the user opens one.
	private static int ifaceDumpTick;
	private static void dumpOpenInterfaces(Client c)
	{
		if (chatX < 0 || (++ifaceDumpTick % 150) != 0)
		{
			return;
		}
		int top = -1;
		try { top = c.getTopLevelInterfaceId(); } catch (RuntimeException ignore) { }
		log.info("[ifaces] top={} chat=({},{})", top, chatX, chatY);
		Widget[] roots = null;
		try { roots = c.getWidgetRoots(); } catch (RuntimeException ignore) { }
		if (roots != null)
		{
			for (final Widget r : roots)
			{
				if (r == null || r.isHidden())
				{
					continue;
				}
				log.info("[ifaces] root group={} bounds={}", (r.getId() >>> 16), r.getBounds());
			}
		}
		final int[] probe = {12, 192, 213, 300, 402, 465, 200, 383, 109, 593, 218};
		final StringBuilder open = new StringBuilder();
		for (final int g : probe)
		{
			Widget w = null;
			try { w = c.getWidget(g << 16); } catch (RuntimeException ignore) { }
			if (w != null && !w.isHidden())
			{
				open.append(g).append(' ');
			}
		}
		log.info("[ifaces] open candidate groups (getWidget<<16): {}", open.length() == 0 ? "(none)" : open.toString());
	}

	private static boolean isWorldMapOpen(Client c)
	{
		final Widget map = c.getWidget(InterfaceID.Worldmap.MAP_CONTAINER);
		return map != null && !map.isHidden();
	}

	private static boolean mapWasOpen;       // close-edge tracker (client thread only) — restores the chat
	// Canvas-px top/left margin of the map window. 2 = flush/maximal (the engine clamps the window to its
	// windowed max and rejects minus==0 as "no stored rect", so 2 is the closest to edge-to-edge it goes).
	private static final int MAP_INSET = 2;

	private static void tickWorldMap(Client c)
	{
		// WINDOW RECT (probe-settled): the world map is the desktop's draggable WINDOW, and the
		// WORLDMAP_X/Y + MINUSWIDTH/MINUSHEIGHT varcs are its remembered rect, read at OPEN — a seeded rect
		// is honored with REAL hit-testing (zoom/close click oracles green), from the first open. Hard
		// constraints (all probe-verified — don't re-tread): minus == 0 reads as "no stored rect" (the open
		// falls back to the default top-left window); size = windowed-max (canvas minus the structural
		// 215x165 reserve) minus the minus values, bigger/negative clamped; X/Y are capped at the minus
		// values (the window must fit inside the top-left windowed REGION, so true canvas-centering of a
		// big window is impossible); and forcing the map root re-lays render only (clicks go dead). Best
		// clean mobile result: a near-max FLOATING window inset MAP_INSET px from the top-left — clears the
		// curved bezel corner, engine close X fully visible, live scene showing around it (desktop-window
		// look). Seeded every tick so the session's first open already lands there.
		c.setVarcIntValue(VarClientID.WORLDMAP_X, MAP_INSET);
		c.setVarcIntValue(VarClientID.WORLDMAP_Y, MAP_INSET);
		c.setVarcIntValue(VarClientID.WORLDMAP_MINUSWIDTH, MAP_INSET * 2);
		c.setVarcIntValue(VarClientID.WORLDMAP_MINUSHEIGHT, MAP_INSET * 2);

		final boolean preEoc = c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT) == 1;
		final int chatId = preEoc ? InterfaceID.ToplevelPreEoc.CHAT_CONTAINER : InterfaceID.ToplevelOsrsStretch.CHAT_CONTAINER;
		if (!isWorldMapOpen(c))
		{
			if (mapWasOpen)
			{
				mapWasOpen = false;
				// Restore the chat hidden below: un-hide + rebuild (hiding tears the chat content down — the
				// op-replay lesson; BUILD_CHATBOX re-renders the message list so it doesn't come back empty).
				final Widget chat = c.getWidget(chatId);
				if (chat != null && chat.isHidden())
				{
					chat.setHidden(false);
				}
				try
				{
					c.runScript(ScriptID.BUILD_CHATBOX);
				}
				catch (RuntimeException ignore)
				{
					BridgeFaults.note("HudVeneerBridge.tickWorldMap", ignore);
				}
			}
			mapPanDx.set(0);
			mapPanDy.set(0);
			mapScrollDelta.set(0);
			mapPanRemX = mapPanRemY = 0;
			publishMapSnapshot("{\"open\":false}");
			return;
		}
		mapWasOpen = true;

		// HIDE the chat while the map is open — the relocated chat-at-top would draw over the fullscreen
		// map's top edge. Restored + rebuilt on the close edge (hiding tears the chat content down).
		final Widget chat = c.getWidget(chatId);
		if (chat != null && !chat.isHidden())
		{
			chat.setHidden(true);
		}

		// The relocated minimap cluster + side panel would draw OVER the map window (their apply blocks are
		// gated off while the map is open) — shove them off-screen (the collapse trick: forced far below the
		// canvas, NOT hidden, so nothing tears down); the blocks re-force them home after close. The official
		// mobile app shows NO HUD over the map — the native shell scales the window to fill the screen.
		if (minimapX >= 0)
		{
			shoveOffscreen(c, preEoc ? InterfaceID.ToplevelPreEoc.MAP_CONTAINER : InterfaceID.ToplevelOsrsStretch.MAP_CONTAINER, minimapX);
		}
		if (sideX >= 0)
		{
			shoveOffscreen(c, preEoc ? InterfaceID.ToplevelPreEoc.SIDE_CONTAINER : InterfaceID.ToplevelOsrsStretch.SIDE_CONTAINER, sideX);
		}

		final int sdy = mapScrollDelta.getAndSet(0);
		if (sdy != 0)
		{
			applyMapPanelScroll(c, sdy);
		}

		final int dx = mapPanDx.getAndSet(0);
		final int dy = mapPanDy.getAndSet(0);
		if (dx != 0 || dy != 0)
		{
			final net.runelite.api.worldmap.WorldMap wm = c.getWorldMap();
			final net.runelite.api.Point pos = wm == null ? null : wm.getWorldMapPosition();
			final float zoom = wm == null ? 0 : wm.getWorldMapZoom();   // px per tile
			if (pos != null && zoom > 0)
			{
				// Grab-the-map: finger right -> centre moves west; canvas y grows DOWN, world y grows NORTH.
				// Carry the sub-tile remainder so slow drags at high zoom aren't quantised away.
				final float fx = mapPanRemX + dx / zoom;
				final float fy = mapPanRemY + dy / zoom;
				final int tx = Math.round(fx);
				final int ty = Math.round(fy);
				mapPanRemX = fx - tx;
				mapPanRemY = fy - ty;
				if (tx != 0 || ty != 0)
				{
					wm.setWorldMapPositionTarget(new net.runelite.api.coords.WorldPoint(
						pos.getX() - tx, pos.getY() + ty, 0));
				}
			}
		}

		final StringBuilder sb = new StringBuilder(192);
		sb.append("{\"open\":true");
		// Engine search-active flag (1 while the magnifier search is focused). Native uses the 1->0 edge to
		// auto-dismiss the soft keyboard once a search commits/cancels (the search never flips INPUT_TYPE, so
		// this is the only signal the native shell has that the search ended).
		sb.append(",\"searching\":").append(c.getVarcIntValue(VarClientID.WORLDMAP_SEARCHING));
		appendRect(c, sb, "window", InterfaceID.Worldmap.UNIVERSE, InterfaceID.Worldmap.WINDOW);
		appendRect(c, sb, "map", InterfaceID.Worldmap.MAP_DISPLAY, InterfaceID.Worldmap.MAP_CONTAINER);
		appendRect(c, sb, "close", InterfaceID.Worldmap.CLOSE, -1);
		appendRect(c, sb, "search", InterfaceID.Worldmap.SEARCH, -1);
		appendRect(c, sb, "zoomIn", InterfaceID.Worldmap.ZOOM_IN, -1);
		appendRect(c, sb, "zoomOut", InterfaceID.Worldmap.ZOOM_OUT, -1);
		appendRect(c, sb, "key", InterfaceID.Worldmap.KEY_CONTAINER, -1);          // swipe-scroll target
		appendRect(c, sb, "maplist", InterfaceID.Worldmap.MAPLIST_CONTAINER, -1);  // surface dropdown (when open)
		sb.append('}');
		publishMapSnapshot(sb.toString());
	}

	/** Park a relocated toplevel container far below the canvas (kept alive, not hidden — no teardown). */
	private static void shoveOffscreen(Client c, int id, int x)
	{
		final Widget w = c.getWidget(id);
		if (w != null)
		{
			w.setForcedPosition(x, CHAT_COLLAPSE_OFFSCREEN_DY);
			w.revalidate();
		}
	}

	private static void appendRect(Client c, StringBuilder sb, String key, int id, int fallbackId)
	{
		Widget w = c.getWidget(id);
		if ((w == null || w.isHidden()) && fallbackId != -1)
		{
			w = c.getWidget(fallbackId);
		}
		if (w == null || w.isHidden())
		{
			return;
		}
		final java.awt.Rectangle b = w.getBounds();
		if (b == null || b.width <= 0 || b.height <= 0)
		{
			return;
		}
		sb.append(",\"").append(key).append("\":[")
			.append(b.x).append(',').append(b.y).append(',').append(b.width).append(',').append(b.height).append(']');
	}

	/** Hide the GRANDPARENT container of a stone (the whole stone-row half — icons + backgrounds). The engine
	 *  re-pins the stones but not their ancestor containers, so the grandparent's hidden state sticks and the row
	 *  disappears; the stones still resolve underneath for {@link #openTabNow}. */
	private static void hideRowOf(Client c, int stoneId)
	{
		try
		{
			final Widget s = c.getWidget(stoneId);
			if (s == null)
			{
				return;
			}
			final Widget p = s.getParent();
			final Widget gp = p == null ? null : p.getParent();
			if (gp != null && !gp.isHidden())
			{
				gp.setHidden(true);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.hideRowOf", ignore);
		}
	}

	private static int[] stoneIds(boolean preEoc)
	{
		return preEoc ? new int[]{
			InterfaceID.ToplevelPreEoc.STONE0, InterfaceID.ToplevelPreEoc.STONE1, InterfaceID.ToplevelPreEoc.STONE2,
			InterfaceID.ToplevelPreEoc.STONE3, InterfaceID.ToplevelPreEoc.STONE4, InterfaceID.ToplevelPreEoc.STONE5,
			InterfaceID.ToplevelPreEoc.STONE6, InterfaceID.ToplevelPreEoc.STONE7, InterfaceID.ToplevelPreEoc.STONE8,
			InterfaceID.ToplevelPreEoc.STONE9, InterfaceID.ToplevelPreEoc.STONE10, InterfaceID.ToplevelPreEoc.STONE11,
			InterfaceID.ToplevelPreEoc.STONE12, InterfaceID.ToplevelPreEoc.STONE13,
		} : new int[]{
			InterfaceID.ToplevelOsrsStretch.STONE0, InterfaceID.ToplevelOsrsStretch.STONE1, InterfaceID.ToplevelOsrsStretch.STONE2,
			InterfaceID.ToplevelOsrsStretch.STONE3, InterfaceID.ToplevelOsrsStretch.STONE4, InterfaceID.ToplevelOsrsStretch.STONE5,
			InterfaceID.ToplevelOsrsStretch.STONE6, InterfaceID.ToplevelOsrsStretch.STONE7, InterfaceID.ToplevelOsrsStretch.STONE8,
			InterfaceID.ToplevelOsrsStretch.STONE9, InterfaceID.ToplevelOsrsStretch.STONE10, InterfaceID.ToplevelOsrsStretch.STONE11,
			InterfaceID.ToplevelOsrsStretch.STONE12, InterfaceID.ToplevelOsrsStretch.STONE13,
		};
	}

	/** Open a tab by replaying its stone's op script with the stone as source + op 1 (RuneLite's standard
	 *  widget-op replay). Works while the stone is hidden — confirmed by TabScriptProbe. Client thread. */
	private static void openTabNow(Client c, boolean preEoc, int idx)
	{
		try
		{
			final int[] ids = stoneIds(preEoc);
			if (idx < 0 || idx >= ids.length)
			{
				return;
			}
			final Widget w = c.getWidget(ids[idx]);
			if (w == null)
			{
				return;
			}
			// The raw createScriptEventBuilder(onOpListener).run() op-replay is INERT for most tab stones (only a
			// few whose CS2 onOp self-contains fire — the rest silently no-op; see BUGFIX-HANDOFF 12/12). Fire the
			// engine's real CC_OP menu action instead — the exact path a click takes, proven on the logout button
			// (WorldSwitcherBridge) — so EVERY tab switches. op 1 = the stone's toggle op.
			// param0 MUST be -1 for a static interface-component op (matches the proven logout call and RuneLite's
			// own TabInterface potion-store click). Passing w.getIndex() misroutes the engine's onOp dispatch, so
			// only the stones whose child-index coincidentally matched were switching (the top-/bottom-row few).
			c.menuAction(-1, ids[idx], net.runelite.api.MenuAction.CC_OP, 1, -1, "Toggle", "");
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.openTabNow", ignore);
		}
	}

	/** Open the world map by SYNTHESIZING a left click on the {@code ORB_WORLDMAP} orb (resolved by its live
	 *  bounds, so the native tile opens it regardless of the ~25px orb's pixel position). This is the proven
	 *  open path (the {@code WorldMapProbe.synthClick} shape) — an op-script replay does NOT toggle the map
	 *  because the orb's open is server-side. Client thread (posting to the system EventQueue is legal here). */
	private static void openWorldMapNow(Client c)
	{
		try
		{
			final Widget orb = c.getWidget(InterfaceID.Orbs.ORB_WORLDMAP);
			if (orb == null)
			{
				return;
			}
			final java.awt.Rectangle b = orb.getBounds();
			if (b == null || b.width <= 0 || b.height <= 0)
			{
				return;
			}
			final java.awt.Canvas canvas = c.getCanvas();
			if (canvas == null)
			{
				return;
			}
			final int x = b.x + b.width / 2;
			final int y = b.y + b.height / 2;
			final java.awt.EventQueue q = java.awt.Toolkit.getDefaultToolkit().getSystemEventQueue();
			final long t = System.currentTimeMillis();
			// Prime focus/presence (harmless if already focused) then the full move+press+release+click — the
			// gamepack resolves the orb's "World Map" action and opens the map, same as a finger on the orb.
			q.postEvent(new java.awt.event.FocusEvent(canvas, java.awt.event.FocusEvent.FOCUS_GAINED, false, null));
			q.postEvent(new java.awt.event.MouseEvent(canvas, java.awt.event.MouseEvent.MOUSE_ENTERED, t, 0, x, y, 0, false));
			q.postEvent(new java.awt.event.MouseEvent(canvas, java.awt.event.MouseEvent.MOUSE_MOVED, t + 1, 0, x, y, 0, false));
			q.postEvent(new java.awt.event.MouseEvent(canvas, java.awt.event.MouseEvent.MOUSE_PRESSED, t + 2,
				java.awt.event.InputEvent.BUTTON1_DOWN_MASK, x, y, 1, false, java.awt.event.MouseEvent.BUTTON1));
			q.postEvent(new java.awt.event.MouseEvent(canvas, java.awt.event.MouseEvent.MOUSE_RELEASED, t + 3, 0, x, y, 1, false, java.awt.event.MouseEvent.BUTTON1));
			q.postEvent(new java.awt.event.MouseEvent(canvas, java.awt.event.MouseEvent.MOUSE_CLICKED, t + 4, 0, x, y, 1, false, java.awt.event.MouseEvent.BUTTON1));
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.openWorldMapNow", ignore);
		}
	}

	/** Switch the chat to tab {@code idx} by replaying that tab's op-script with op 1 (the left-click action) — the
	 *  same replay the tab stones use, so it works while the engine tab sprite is hidden. The op listener may sit on
	 *  the tab button (base) or its graphic child (base+1), so try both. Client thread. */
	private static void switchChatTabNow(Client c, int idx)
	{
		if (idx < 0 || idx >= CHAT_TAB_IDS.length)
		{
			return;
		}
		// Replaying the tab's op-script (op=1 = left click) on the tab that is ALREADY the active CHAT_VIEW makes the
		// engine TOGGLE its own chat-minimise: op=1 on the selected tab flips CHAT_VIEW between the channel and the
		// engine's "minimised" sentinel (1337, off-device-proven), and BUILD_CHATBOX with CHAT_VIEW==1337 renders NO
		// message lines. The native reopen always re-asserts the active tab, so replaying it every reopen flipped the
		// box populated/empty/populated (period-2). Only replay when actually CHANGING channel (idx != live view) —
		// or when the view is already at the minimised sentinel and needs un-minimising (idx, a 0..6 tab, != 1337).
		// A same-channel reopen skips the replay, leaving CHAT_VIEW on its channel; BUILD_CHATBOX then repopulates.
		int curView = -1;
		try
		{
			curView = c.getVarcIntValue(VarClientID.CHAT_VIEW);
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.switchChatTabNow", ignore);
		}
		if (curView != idx)
		{
			final int base = CHAT_TAB_IDS[idx];
			if (!replayOp(c, base, 1))
			{
				replayOp(c, base + 1, 1);   // the op listener may sit on the graphic child instead of the button
			}
		}
		// The op-replay sets CHAT_VIEW but doesn't re-render the message list (the engine does that as part of the
		// real click). Force the chatbox to rebuild so the (now-correct) channel's messages actually show — this runs
		// whether or not we replayed, so a same-channel reopen still repopulates.
		try
		{
			c.runScript(ScriptID.BUILD_CHATBOX);
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.buildChatbox", ignore);
		}
	}

	/** Replay a widget's op-script with the given op. Returns {@code true} if the widget has an op listener (so the
	 *  replay ran). Works on hidden widgets — {@code getWidget} resolves them and the script runs regardless. */
	private static boolean replayOp(Client c, int id, int op)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w == null)
			{
				return false;
			}
			final Object[] l = w.getOnOpListener();
			if (l == null)
			{
				return false;
			}
			c.createScriptEventBuilder(l).setSource(w).setOp(op).build().run();
			return true;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.replayOp", ex);
			return false;
		}
	}

	// Minimap-enlarge geometry. The globe draw-area widget is RIGHT+TOP anchored, so growing its absolute size keeps
	// its top-right corner fixed and grows it left+down; at 130% the rendered terrain disc is centre ~(120,100)
	// radius ~87 (cluster-local). The chrome is then placed at explicit cluster-local targets (see applyMinimapScale)
	// tuned to match the official OSRS-Mobile layout for that disc.
	private static final int MM_NAT_SIZE = 152;   // natural globe draw-area width/height
	private static boolean minimapTreeDumped;
	private static boolean minimapScaleLogged;

	/** One-time recursive dump of the minimap cluster (MAP_CONTAINER tree) + the named chrome widgets, so a fresh
	 *  session can see the exact child layout (bounds / relative / size modes / sprite / type) before designing the
	 *  enlarge-and-reposition. Off-device research only. */
	// Cooldown so a failing open is not hammered every tick; reset implicitly once the orbs load (early return).
	private static int orbsOpenCooldown = 0;

	/**
	 * Open the Orbs interface (group 160) into the toplevel's ORBS layer if it isn't already loaded. Headless boots
	 * here build the ORBS layer but never populate it, leaving the orbs invisible; opening the interface (NON_MODAL,
	 * like the engine would) runs its onload so the orbs bind to live varplayers and render + update normally. Runs
	 * on the client thread (called from {@link #tick}). No-op once the orbs are present; if the toplevel rebuilds
	 * (resize / relogin) and drops them, the next tick re-opens after a short cooldown.
	 */
	private static void ensureOrbsLoaded(Client c, boolean preEoc)
	{
		if (c.getWidget(InterfaceID.Orbs.ORB_HEALTH) != null)
		{
			return; // already loaded
		}
		if (orbsOpenCooldown > 0)
		{
			orbsOpenCooldown--;
			return;
		}
		final int orbLayer = preEoc ? InterfaceID.ToplevelPreEoc.ORBS : InterfaceID.ToplevelOsrsStretch.ORBS;
		if (c.getWidget(orbLayer) == null)
		{
			return; // cluster not built yet (welcome screen / mid-rebuild)
		}
		orbsOpenCooldown = 50; // don't re-attempt every frame if the open doesn't take
		try
		{
			c.openInterface(orbLayer, InterfaceID.ORBS, WidgetModalMode.NON_MODAL);
			log.info("[veneer] opened Orbs interface {} into ORBS layer {}",
				InterfaceID.ORBS, Integer.toHexString(orbLayer));
		}
		catch (RuntimeException ex)
		{
			log.warn("[veneer] openInterface(orbs) failed", ex);
		}
	}

	private static void dumpMinimapTree(Client c, boolean preEoc)
	{
		final int[] ids = {
			InterfaceID.ToplevelPreEoc.MAP_CONTAINER, InterfaceID.ToplevelPreEoc.MAP_MINIMAP,
			InterfaceID.ToplevelPreEoc.MINIMAP, InterfaceID.ToplevelPreEoc.COMPASSCLICK,
			InterfaceID.ToplevelPreEoc.MAP_MINIMAP_GRAPHIC6, InterfaceID.ToplevelPreEoc.MAP_MINIMAP_GRAPHIC9,
			InterfaceID.ToplevelPreEoc.ORBS,
			InterfaceID.ToplevelPreEoc.MAP_NOCLICK_0, InterfaceID.ToplevelPreEoc.MAP_NOCLICK_1,
			InterfaceID.ToplevelPreEoc.MAP_NOCLICK_2, InterfaceID.ToplevelPreEoc.MAP_NOCLICK_3,
			InterfaceID.ToplevelPreEoc.MAP_NOCLICK_4, InterfaceID.ToplevelPreEoc.MAP_NOCLICK_5,
		};
		final String[] names = {
			"MAP_CONTAINER", "MAP_MINIMAP", "MINIMAP", "COMPASSCLICK", "GRAPHIC6", "GRAPHIC9", "ORBS",
			"NOCLICK0", "NOCLICK1", "NOCLICK2", "NOCLICK3", "NOCLICK4", "NOCLICK5",
		};
		for (int i = 0; i < ids.length; i++)
		{
			dumpWidget(c, names[i], ids[i], false);
		}
		// The individual orbs live in the Orbs sub-interface (group 0xa0) hosted in the ORBS layer — dump them by id
		// so we get the HP/prayer/run/spec orb + world-map/wiki/store icon + XP-button canvas positions.
		final int[] orbIds = {
			InterfaceID.Orbs.XP_DROPS, InterfaceID.Orbs.CR_BACKING, InterfaceID.Orbs.ORB_HEALTH,
			InterfaceID.Orbs.ORB_PRAYER, InterfaceID.Orbs.ORB_RUNENERGY, InterfaceID.Orbs.ORB_SPECENERGY,
			InterfaceID.Orbs.ORB_STORE, InterfaceID.Orbs.ORB_WORLDMAP, InterfaceID.Orbs.WIKI,
		};
		final String[] orbNames = {
			"XP_DROPS", "CR_BACKING", "ORB_HEALTH", "ORB_PRAYER", "ORB_RUNENERGY", "ORB_SPECENERGY",
			"ORB_STORE", "ORB_WORLDMAP", "WIKI",
		};
		for (int i = 0; i < orbIds.length; i++)
		{
			dumpWidget(c, orbNames[i], orbIds[i], false);
		}
	}

	private static void dumpWidget(Client c, String name, int id, boolean unused)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w == null)
			{
				log.info("[veneer] mm-tree {} id={} = null", name, Integer.toHexString(id));
				return;
			}
			dumpWidgetObj(name + " id=" + Integer.toHexString(id), w);
		}
		catch (RuntimeException ignore)
		{
		}
	}

	private static void dumpWidgetObj(String label, Widget w)
	{
		try
		{
			final java.awt.Rectangle b = w.getBounds();
			log.info("[veneer] mm-tree {} type={} bounds={} rel=({},{}) orig=({},{},{}x{}) posMode=({},{}) sizeMode=({},{}) sprite={} model={} item={} hidden={} text='{}'",
				label, w.getType(), b, w.getRelativeX(), w.getRelativeY(),
				w.getOriginalX(), w.getOriginalY(), w.getOriginalWidth(), w.getOriginalHeight(),
				w.getXPositionMode(), w.getYPositionMode(), w.getWidthMode(), w.getHeightMode(),
				safeSpriteId(w), safeModelId(w), safeItemId(w), w.isHidden(), shortText(w));
		}
		catch (RuntimeException ex)
		{
			log.info("[veneer] mm-tree {} threw {}", label, String.valueOf(ex));
		}
	}

	private static int safeModelId(Widget w)
	{
		try
		{
			return w.getModelId();
		}
		catch (RuntimeException ex)
		{
			return -1;
		}
	}

	private static int safeItemId(Widget w)
	{
		try
		{
			return w.getItemId();
		}
		catch (RuntimeException ex)
		{
			return -1;
		}
	}

	private static String shortText(Widget w)
	{
		try
		{
			final String t = stripTags(w.getText());
			return t.length() > 16 ? t.substring(0, 16) : t;
		}
		catch (RuntimeException ex)
		{
			return "";
		}
	}

	/** Minimap-enlarge hook (currently DISABLED by default — {@code scalePct <= 100} no-ops). A clean bigger minimap
	 *  is not achievable by editing the engine widgets: the engine hard-pins every orb/icon each frame (so they can't
	 *  be rearranged to wrap a bigger globe) and the globe draw-area can only be resized, not repositioned (re-anchoring
	 *  it desyncs the minimap raster and the terrain stops drawing), so resizing alone grows the globe into the fixed
	 *  orbs. The size-only path is kept here for reference. Native-HUD layout is Classic (PreEoc 164) only. */
	private static void applyMinimapScale(Client c, boolean preEoc, int scalePct)
	{
		if (!preEoc)
		{
			return;   // the native HUD veneer only supports the Classic resizable layout
		}
		try
		{
			final Widget mm = c.getWidget(InterfaceID.ToplevelPreEoc.MINIMAP);
			if (mm == null)
			{
				return;   // cluster not built yet (welcome screen etc.)
			}
			if (TEST_APPLY && !minimapTreeDumped)
			{
				minimapTreeDumped = true;   // off-device record of the natural layout, before this frame's resize
				dumpMinimapTree(c, preEoc);
			}
			if (scalePct <= 100)
			{
				return;   // disabled → leave the natural minimap untouched (its layout IS the official-mobile layout)
			}
			// LIMITATION (confirmed off-device, 2026-06-07): a clean BIGGER minimap is not achievable by editing the
			// engine widgets. The engine hard-pins every minimap orb/icon to a fixed position each frame
			// (setForcedPosition updates the getter but is ignored at render — readback-confirmed), so the orbs can't
			// be rearranged to wrap a bigger globe; and the globe draw-area can only be RESIZED — repositioning or
			// re-anchoring it (to grow away from the orbs) desyncs the engine's minimap raster and the terrain stops
			// drawing. So resizing alone grows the globe left+down INTO the fixed orbs (they overlap). This size-only
			// path is kept (off by default) for reference; a genuinely bigger minimap needs a native scaled blit of
			// the whole MAP_CONTAINER region (uniform but soft + re-do hit-testing), not this.
			final double s = scalePct / 100.0;
			final int gs = (int) Math.round(MM_NAT_SIZE * s);
			if (mm.getWidthMode() != WidgetSizeMode.ABSOLUTE || mm.getOriginalWidth() != gs
				|| mm.getHeightMode() != WidgetSizeMode.ABSOLUTE || mm.getOriginalHeight() != gs)
			{
				mm.setWidthMode(WidgetSizeMode.ABSOLUTE);
				mm.setHeightMode(WidgetSizeMode.ABSOLUTE);
				mm.setOriginalWidth(gs);
				mm.setOriginalHeight(gs);
				mm.revalidate();
			}
			hide(c, InterfaceID.ToplevelPreEoc.MAP_MINIMAP_GRAPHIC9);   // frame ring no longer matches the bigger globe
			if (!minimapScaleLogged)
			{
				minimapScaleLogged = true;
				log.info("[veneer] MINIMAP_SCALE scalePct={} globe={}px (natural {})", scalePct, gs, MM_NAT_SIZE);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.applyMinimapScale", ignore);
		}
	}

	/** Scroll the chat message layer by {@code delta} canvas px (clamped), driving the chatbox's own scroll layer
	 *  ({@code SCROLLAREA}, the parent of the message lines) + scrollbar ({@code CHATSCROLLBAR}) via the engine's
	 *  {@code UPDATE_SCROLLBAR} script — the same path the scrollbar arrows use. No mouse-wheel event, so the camera
	 *  doesn't also zoom. Client thread. */
	private static void applyChatScroll(Client c, int delta)
	{
		try
		{
			final Widget area = c.getWidget(InterfaceID.Chatbox.SCROLLAREA);
			if (area == null)
			{
				return;
			}
			final int max = Math.max(0, area.getScrollHeight() - area.getHeight());
			final int cur = area.getScrollY();
			final int next = Math.max(0, Math.min(max, cur + delta));
			if (next != cur)
			{
				c.runScript(ScriptID.UPDATE_SCROLLBAR, InterfaceID.Chatbox.CHATSCROLLBAR, InterfaceID.Chatbox.SCROLLAREA, next);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.applyChatScroll", ignore);
		}
	}

	/** Scroll a scrollable world-map sub-panel by {@code delta} canvas px (clamped): the surface MAPLIST dropdown
	 *  when it is open, otherwise the KEY (legend) list. Drives the panel's own scroll layer + scrollbar via the
	 *  engine {@code UPDATE_SCROLLBAR} script (the scrollbar-arrow path), so the camera/zoom are untouched. Client
	 *  thread (called from {@link #tickWorldMap}). */
	private static void applyMapPanelScroll(Client c, int delta)
	{
		try
		{
			final Widget maplist = c.getWidget(InterfaceID.Worldmap.MAPLIST_CONTAINER);
			final boolean maplistOpen = maplist != null && !maplist.isHidden();
			final int areaId = maplistOpen ? InterfaceID.Worldmap.MAPLIST_LIST : InterfaceID.Worldmap.KEY_ENTRIES;
			final int barId = maplistOpen ? InterfaceID.Worldmap.MAPLIST_SCROLLBAR : InterfaceID.Worldmap.KEY_SCROLLBAR;
			final Widget area = c.getWidget(areaId);
			if (area == null)
			{
				return;
			}
			final int max = Math.max(0, area.getScrollHeight() - area.getHeight());
			final int cur = area.getScrollY();
			final int next = Math.max(0, Math.min(max, cur + delta));
			if (next != cur)
			{
				c.runScript(ScriptID.UPDATE_SCROLLBAR, barId, areaId, next);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.applyMapPanelScroll", ignore);
		}
	}

	/** Build the per-frame chat-tab snapshot the native veneer reads to draw + state its enlarged buttons. Runs on
	 *  the client thread (inside {@link #tick}) right after the chatbox widgets are force-positioned, so the button
	 *  bounds are fresh. Reports each of the 7 tabs' canvas bounds (for the proxy-click target + native layout),
	 *  selected/new-message state (from the GRAPHIC sprite id), and the live filter sub-label text + colour. */
	private static void buildChatSnapshot(Client c)
	{
		try
		{
			final StringBuilder sb = new StringBuilder(640);
			sb.append("{\"loggedIn\":true")
				.append(",\"chatX\":").append(chatX)
				.append(",\"chatY\":").append(chatY)
				.append(",\"rowH\":").append(chatTabRowH > 0 ? chatTabRowH : CONTROLS_H);
			int view = -1;
			try
			{
				view = c.getVarcIntValue(VarClientID.CHAT_VIEW);
			}
			catch (RuntimeException ignore)
			{
			}
			int topLevel = -1;
			try
			{
				topLevel = c.getTopLevelInterfaceId();
			}
			catch (RuntimeException ignore)
			{
			}
			sb.append(",\"view\":").append(view)
				.append(",\"topLevelId\":").append(topLevel)
				.append(",\"dialogueActive\":").append(dialogueOpen)
				.append(",\"engineDialogue\":").append(dialogueOpen)
				.append(",\"windowOpen\":").append(chatWindowOccluded);
			if (dialogueOpen)
			{
				// Canvas-px bounds of the open dialogue so the native shell can route a tap there through a PRECISE
				// click (resolving the dialogue's Continue/option) instead of walking the world behind it.
				final int[] dr = dialogueBounds(c);
				if (dr != null)
				{
					sb.append(",\"dlgX\":").append(dr[0]).append(",\"dlgY\":").append(dr[1])
						.append(",\"dlgW\":").append(dr[2]).append(",\"dlgH\":").append(dr[3]);
				}
			}
			sb.append(",\"tabs\":[");
			final int last = CHAT_TAB_IDS.length - 1;
			for (int i = 0; i < CHAT_TAB_IDS.length; i++)
			{
				if (i > 0)
				{
					sb.append(',');
				}
				// ALL (index 0) and Report (last) have no filter sub-label.
				appendTab(c, sb, CHAT_TAB_IDS[i], CHAT_TAB_NAMES[i], i != 0 && i != last);
			}
			sb.append("]}");
			publishChatSnapshot(sb.toString());
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.buildChatSnapshot", ignore);
			// keep the previous snapshot
		}
	}

	/**
	 * One-shot (client-thread) capture of the OSRS tab/stone/chat-button sprites from the live cache, so the native
	 * shell composites the REAL art with nothing committed to the repo — exactly how the desktop client renders its
	 * stones. Built once on the first logged-in tick (the cache is loaded by then), memoised into {@link #tabSpritesJson}
	 * and read by the native side via {@link #tabSprites()}. Pixels are sent as raw big-endian ARGB bytes (Base64) — no
	 * ImageIO/PNG dependency, which may be absent in the embedded JRE.
	 */
	private static int tabSpriteId(int slot)
	{
		if (slot == 0) return SPR_STONE_INACTIVE;
		if (slot == 1) return SPR_STONE_ACTIVE;
		if (slot >= 2 && slot <= 15) return SPR_TAB_ICON_BASE + (slot - 2);
		if (slot == 16) return SPR_CHATBTN_IDLE;
		if (slot == 17) return SPR_CHATBTN_SELECTED;
		return SPR_CHATBTN_NEW;   // slot 18
	}

	private static void captureTabSprites(Client c)
	{
		if (tabSpritesCaptured)
		{
			return;
		}
		try
		{
			// Try to load every still-missing sprite this tick; nudge its archive in first so a lazily-streamed one
			// (the engine never renders our hidden tabs, so it never requests these) is forced into the cache.
			int loaded = 0;
			for (int slot = 0; slot < TAB_SPRITE_COUNT; slot++)
			{
				if (tabSpriteB64[slot] == null)
				{
					final int id = tabSpriteId(slot);
					nudgeSpriteArchive(c, id);
					tabSpriteB64[slot] = spriteArgbB64(c, id, tabSpriteDim[slot]);
				}
				if (tabSpriteB64[slot] != null)
				{
					loaded++;
				}
			}
			tabCaptureTicks++;
			// Grid needs both stones + all 14 glyphs; chat (16/17) is secondary. Ship at the deadline regardless so a
			// sprite that genuinely never resolves can't stall the chrome forever.
			boolean gridComplete = true;
			for (int slot = 0; slot <= 15; slot++)
			{
				if (tabSpriteB64[slot] == null)
				{
					gridComplete = false;
					break;
				}
			}
			if (!gridComplete && tabCaptureTicks < TAB_CAPTURE_DEADLINE)
			{
				return;   // keep accumulating
			}
			final StringBuilder sb = new StringBuilder(64 * 1024);
			sb.append('{');
			// gridComplete=false means we hit the deadline with a missing slot — the consumer must NOT persist a
			// partial set to its boot cache (a fresh process re-captures and usually completes in a few ticks).
			sb.append("\"complete\":").append(gridComplete).append(',');
			appendSpriteSlot(sb, "stoneInactive", 0);
			sb.append(',');
			appendSpriteSlot(sb, "stoneActive", 1);
			sb.append(",\"icons\":[");
			for (int i = 0; i < 14; i++)
			{
				if (i > 0)
				{
					sb.append(',');
				}
				appendSpriteObjSlot(sb, 2 + i);
			}
			sb.append(']');
			sb.append(',');
			appendSpriteSlot(sb, "chatbtn", 16);
			sb.append(',');
			appendSpriteSlot(sb, "chatbtnSelected", 17);
			sb.append(',');
			appendSpriteSlot(sb, "chatbtnNew", 18);
			sb.append('}');
			tabSpritesJson = sb.toString();
			tabSpritesCaptured = true;
			log.info("[veneer] tab sprites captured ({}/{} sprites, {} bytes, ticks={})",
				loaded, TAB_SPRITE_COUNT, tabSpritesJson.length(), tabCaptureTicks);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.captureTabSprites", ex);
		}
	}

	/** Force {@code spriteId}'s archive into the cache (the engine won't request it for our hidden tabs). */
	private static void nudgeSpriteArchive(Client c, int spriteId)
	{
		try
		{
			c.getIndexSprites().loadData(spriteId, 0);
		}
		catch (RuntimeException ignore)
		{
			// best-effort prime; spriteArgbB64 retries next tick
		}
	}

	/** {@code "name":{w,h,px}} from an accumulated slot. */
	private static void appendSpriteSlot(StringBuilder sb, String name, int slot)
	{
		sb.append('"').append(name).append("\":");
		appendSpriteObjSlot(sb, slot);
	}

	/** {@code {"w":W,"h":H,"px":"<base64 ARGB>"}} (or {@code null}) from an accumulated slot. */
	private static void appendSpriteObjSlot(StringBuilder sb, int slot)
	{
		final String px = tabSpriteB64[slot];
		if (px == null)
		{
			sb.append("null");
			return;
		}
		sb.append("{\"w\":").append(tabSpriteDim[slot][0]).append(",\"h\":").append(tabSpriteDim[slot][1])
			.append(",\"px\":\"").append(px).append("\"}");
	}

	/** Base64 of {@code spriteId}'s pixels as big-endian ARGB bytes; sets {@code dim=[w,h]}. {@code null} if absent. */
	private static String spriteArgbB64(Client c, int spriteId, int[] dim)
	{
		final SpritePixels[] sp = c.getSprites(c.getIndexSprites(), spriteId, 0);
		if (sp == null || sp.length == 0 || sp[0] == null)
		{
			return null;
		}
		final BufferedImage img = sp[0].toBufferedImage();
		if (img == null)
		{
			return null;
		}
		final int w = img.getWidth();
		final int h = img.getHeight();
		final int[] argb = img.getRGB(0, 0, w, h, null, 0, w);
		final byte[] bytes = new byte[argb.length * 4];
		for (int i = 0; i < argb.length; i++)
		{
			final int p = argb[i];
			bytes[i * 4] = (byte) (p >>> 24);
			bytes[i * 4 + 1] = (byte) (p >>> 16);
			bytes[i * 4 + 2] = (byte) (p >>> 8);
			bytes[i * 4 + 3] = (byte) p;
		}
		dim[0] = w;
		dim[1] = h;
		return Base64.getEncoder().encodeToString(bytes);
	}

	/** The captured tab-sprite payload (see {@link #captureTabSprites}); {@code ""} until ready. Read from native. */
	public static String tabSprites()
	{
		return tabSpritesJson;
	}

	/** Append one chat tab's geometry/state object. {@code base} = the tab parent widget; GRAPHIC=base+1,
	 *  TEXT=base+2, FILTER=base+3. */
	private static void appendTab(Client c, StringBuilder sb, int base, String name, boolean hasFilter)
	{
		final Widget btn = safeWidget(c, base);
		final Widget gfx = safeWidget(c, base + 1);
		final Widget txt = safeWidget(c, base + 2);
		final Widget flt = hasFilter ? safeWidget(c, base + 3) : null;
		final int[] b = canvasBounds(btn);
		final int spr = gfx == null ? -1 : safeSpriteId(gfx);
		sb.append("{\"name\":\"").append(name).append('"')
			.append(",\"x\":").append(b == null ? -1 : b[0])
			.append(",\"y\":").append(b == null ? -1 : b[1])
			.append(",\"w\":").append(b == null ? 0 : b[2])
			.append(",\"h\":").append(b == null ? 0 : b[3])
			.append(",\"sprite\":").append(spr)
			.append(",\"selected\":").append(spr == SPR_CHATBTN_SELECTED)
			.append(",\"new\":").append(spr == SPR_CHATBTN_NEW)
			.append(",\"labelColor\":").append(txt == null ? -1 : safeTextColor(txt))
			.append(",\"filter\":\"").append(flt == null ? "" : BridgeJson.escapedDropControls(stripTags(flt.getText())))
			.append('"')
			.append(",\"filterColor\":").append(flt == null ? -1 : safeTextColor(flt))
			.append('}');
	}

	private static Widget safeWidget(Client c, int id)
	{
		try
		{
			return c.getWidget(id);
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.safeWidget", ex);
			return null;
		}
	}

	/** {@code [x,y,w,h]} canvas bounds of a widget, or {@code null} if absent/zero-size. Hidden is fine — the
	 *  engine CONTROLS row stays shown (covered by the native row), so its buttons keep real bounds. */
	/** Publish the live per-orb canvas bounds for the native touch veneer (read via {@link #getOrbSnapshot}).
	 *  Each orb is a hard-pinned live engine widget; we only report where it currently renders so the native
	 *  shell can enlarge the tap zone and proxy a precise click to its centre. */
	private static void buildOrbSnapshot(Client c)
	{
		try
		{
			final StringBuilder sb = new StringBuilder(256);
			sb.append("{\"loggedIn\":true");
			appendOrb(sb, c, "hp", InterfaceID.Orbs.ORB_HEALTH);
			appendOrb(sb, c, "prayer", InterfaceID.Orbs.ORB_PRAYER);
			appendOrb(sb, c, "run", InterfaceID.Orbs.ORB_RUNENERGY);
			appendOrb(sb, c, "spec", InterfaceID.Orbs.ORB_SPECENERGY);
			appendOrb(sb, c, "store", InterfaceID.Orbs.ORB_STORE);
			appendOrb(sb, c, "worldmap", InterfaceID.Orbs.ORB_WORLDMAP);
			appendOrb(sb, c, "wiki", InterfaceID.Orbs.WIKI);
			sb.append('}');
			publishOrbSnapshot(sb.toString());
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.buildOrbSnapshot", ex);
		}
	}

	/** Append {@code ,"key":{x,y,w,h}} for a live, visible orb widget; skip it entirely when null/hidden/zero-size. */
	private static void appendOrb(StringBuilder sb, Client c, String key, int id)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w == null || w.isHidden())
			{
				return;
			}
			appendBounds(sb, key, canvasBounds(w));
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.appendOrb", ex);
		}
	}

	private static int[] canvasBounds(Widget w)
	{
		if (w == null)
		{
			return null;
		}
		try
		{
			final java.awt.Rectangle r = w.getBounds();
			if (r == null || r.width <= 0 || r.height <= 0)
			{
				return null;
			}
			return new int[]{r.x, r.y, r.width, r.height};
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.canvasBounds", ex);
			return null;
		}
	}

	private static int safeSpriteId(Widget w)
	{
		try
		{
			return w.getSpriteId();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.safeSpriteId", ex);
			return -1;
		}
	}

	private static int safeTextColor(Widget w)
	{
		try
		{
			return w.getTextColor();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.safeTextColor", ex);
			return -1;
		}
	}

	/** Strip RuneLite/cs2 colour-and-format tags ({@code <col=..>}, {@code </col>}, {@code <br>}) from a label. */
	private static String stripTags(String s)
	{
		if (s == null || s.isEmpty())
		{
			return "";
		}
		return s.replaceAll("<[^>]*>", "");
	}

	/** Minimal JSON string escaping (the only risky chars in chat sub-labels are quotes / backslashes). */

	// ---- Native top-rendered chat: the live MESSAGE model (read from getChatLineMap, not the un-rasterable widgets) ----

	// CHAT_VIEW (VarClientID) index -> the ChatMessageTypes that tab shows. Index 0 (All) = union every buffer; index
	// 7 (Report) = none. Mirrors net.runelite.client.plugins.chathistory.ChatboxTab so native chat matches the engine.
	private static final ChatMessageType[][] TAB_TYPES = {
		null, // 0 All -> union all buffers
		{ // 1 Game
			ChatMessageType.GAMEMESSAGE, ChatMessageType.ENGINE, ChatMessageType.BROADCAST,
			ChatMessageType.SNAPSHOTFEEDBACK, ChatMessageType.ITEM_EXAMINE, ChatMessageType.NPC_EXAMINE,
			ChatMessageType.OBJECT_EXAMINE, ChatMessageType.FRIENDNOTIFICATION, ChatMessageType.IGNORENOTIFICATION,
			ChatMessageType.CONSOLE, ChatMessageType.SPAM, ChatMessageType.PLAYERRELATED,
			ChatMessageType.TENSECTIMEOUT, ChatMessageType.WELCOME, ChatMessageType.UNKNOWN,
		},
		{ // 2 Public
			ChatMessageType.PUBLICCHAT, ChatMessageType.AUTOTYPER, ChatMessageType.MODCHAT,
			ChatMessageType.MODAUTOTYPER,
		},
		{ // 3 Private
			ChatMessageType.PRIVATECHAT, ChatMessageType.PRIVATECHATOUT, ChatMessageType.MODPRIVATECHAT,
			ChatMessageType.LOGINLOGOUTNOTIFICATION,
		},
		{ // 4 Channel (friends chat)
			ChatMessageType.FRIENDSCHATNOTIFICATION, ChatMessageType.FRIENDSCHAT,
			ChatMessageType.CHALREQ_FRIENDSCHAT,
		},
		{ // 5 Clan
			ChatMessageType.CLAN_CHAT, ChatMessageType.CLAN_MESSAGE, ChatMessageType.CLAN_GUEST_CHAT,
			ChatMessageType.CLAN_GUEST_MESSAGE,
		},
		{ // 6 Trade (CLAN_GIM_* live here, per ChatboxTab.TRADE_GROUP — not Clan)
			ChatMessageType.TRADE_SENT, ChatMessageType.TRADEREQ, ChatMessageType.TRADE,
			ChatMessageType.CHALREQ_TRADE, ChatMessageType.CLAN_GIM_CHAT, ChatMessageType.CLAN_GIM_MESSAGE,
		},
		{}, // 7 Report -> none
	};

	private static final int CHAT_LINES_CAP = 40;          // newest N message lines reported to native
	private static final int CHAT_DEFAULT_COLOR = 0xffffff;

	/** Build the native chat MESSAGE snapshot from the engine's live per-type message buffers (getChatLineMap),
	 *  filtered to the active CHAT_VIEW tab, newest {@link #CHAT_LINES_CAP} lines, oldest-first, with colour runs
	 *  pre-parsed from the {@code <col=..>} tags, plus the bottom input line. Client thread (inside {@link #tick}). */
	private static void buildChatLines(Client c)
	{
		try
		{
			final Map<Integer, ChatLineBuffer> map = c.getChatLineMap();
			int view = 0;
			try
			{
				view = c.getVarcIntValue(VarClientID.CHAT_VIEW);
			}
			catch (RuntimeException ignore)
			{
			}
			final List<MessageNode> nodes = new ArrayList<>();
			if (map != null)
			{
				final ChatMessageType[] types = (view > 0 && view < TAB_TYPES.length) ? TAB_TYPES[view] : null;
				if (types != null)
				{
					for (final ChatMessageType t : types)
					{
						collectLines(map.get(t.getType()), nodes);
					}
				}
				else if (view != 7)
				{
					for (final ChatLineBuffer buf : map.values())   // All (or unknown view) -> union every buffer
					{
						collectLines(buf, nodes);
					}
				}
			}
			// newest-first by timestamp (stable so same-second order is preserved), keep newest CAP, emit oldest-first.
			nodes.sort((a, b) -> Integer.compare(safeTs(b), safeTs(a)));
			final int n = Math.min(CHAT_LINES_CAP, nodes.size());
			final StringBuilder sb = new StringBuilder(2048);
			sb.append("{\"loggedIn\":true,\"view\":").append(view)
				.append(",\"seq\":").append(++chatLinesSeq)
				.append(",\"lines\":[");
			boolean first = true;
			for (int i = n - 1; i >= 0; i--)   // oldest-first so native renders top -> bottom
			{
				final String obj = chatLineObject(nodes.get(i));
				if (obj == null)
				{
					continue;
				}
				if (!first)
				{
					sb.append(',');
				}
				first = false;
				sb.append(obj);
			}
			sb.append(']');
			appendChatInput(sb, c);   // the bottom "PlayerName: typed*" input line (engine chat is invisible)
			sb.append('}');
			chatLinesJson = sb.toString();
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.buildChatLines", ignore);
			// keep the previous snapshot
		}
	}

	/** Append {@code ,"input":{"name":..,"text":..}} — the player's name + the live chatbox input buffer, so native
	 *  can draw the bottom "PlayerName: typed*" line the (invisible) engine chat would otherwise show. */
	private static void appendChatInput(StringBuilder sb, Client c)
	{
		String name = "";
		String typed = "";
		try
		{
			final Player lp = c.getLocalPlayer();
			if (lp != null && lp.getName() != null)
			{
				name = Text.removeTags(lp.getName());
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.appendChatInput", ignore);
		}
		try
		{
			final String t = c.getVarcStrValue(VarClientStr.CHATBOX_TYPED_TEXT);
			if (t != null)
			{
				typed = t;
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.appendChatInput", ignore);
		}
		sb.append(",\"input\":{\"name\":\"").append(BridgeJson.escapedDropControls(name))
			.append("\",\"text\":\"").append(BridgeJson.escapedDropControls(typed)).append("\"}");
	}

	private static void collectLines(ChatLineBuffer buf, List<MessageNode> out)
	{
		if (buf == null)
		{
			return;
		}
		try
		{
			final MessageNode[] lines = buf.getLines();
			if (lines == null)
			{
				return;
			}
			final int len = Math.min(buf.getLength(), lines.length);
			for (int i = 0; i < len; i++)
			{
				if (lines[i] != null)
				{
					out.add(lines[i]);
				}
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.collectLines", ignore);
		}
	}

	private static int safeTs(MessageNode n)
	{
		try
		{
			return n.getTimestamp();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.safeTs", ex);
			return 0;
		}
	}

	/** One chat line as a JSON object {@code {"name":..,"type":..,"ts":..,"text":..,"runs":[..]}}, or null to skip.
	 *  Composes "name: message" (name only when present — public/private chat; game messages have none). */
	private static String chatLineObject(MessageNode n)
	{
		try
		{
			String raw = n.getRuneLiteFormatMessage();
			if (raw == null)
			{
				raw = n.getValue();
			}
			if (raw == null)
			{
				raw = "";
			}
			final String name = Text.removeTags(n.getName() == null ? "" : n.getName());
			final int typeId = n.getType() == null ? -1 : n.getType().getType();
			final String full = name.isEmpty() ? raw : name + ": " + raw;
			final StringBuilder sb = new StringBuilder(full.length() + 48);
			sb.append("{\"name\":\"").append(BridgeJson.escapedDropControls(name)).append('"')
				.append(",\"type\":").append(typeId)
				.append(",\"ts\":").append(safeTs(n)).append(',');
			// Bug 11 — official-mobile look: chat lines render fully white (suppress per-<col=> run colours).
			appendTextWithRuns(sb, full, CHAT_DEFAULT_COLOR, true);
			sb.append('}');
			return sb.toString();
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.chatLineObject", ex);
			return null;
		}
	}

	/** Append {@code "text":"<stripped>","runs":[{"o":,"l":,"c":,"u":}]} for {@code raw}, parsing cs2 colour/format
	 *  tags. Runs are recorded against the STRIPPED text offsets; only spans differing from {@code defColor} (or
	 *  underlined) are emitted, so native applies the default elsewhere. */
	private static void appendTextWithRuns(StringBuilder sb, String raw, int defColor)
	{
		appendTextWithRuns(sb, raw, defColor, false);
	}

	/** As above; when {@code forceWhite}, every {@code <col=..>} colour override is ignored so all text renders at
	 *  {@code defColor} (the official-mobile all-white chat look). Underline tags are still honoured. */
	private static void appendTextWithRuns(StringBuilder sb, String raw, int defColor, boolean forceWhite)
	{
		final StringBuilder text = new StringBuilder(raw.length());
		final StringBuilder runs = new StringBuilder(96);
		boolean firstRun = true;
		int runStart = 0;
		int runColor = defColor;
		boolean runUnder = false;
		final int len = raw.length();
		int i = 0;
		while (i < len)
		{
			final char ch = raw.charAt(i);
			if (ch != '<')
			{
				text.append(ch);
				i++;
				continue;
			}
			final int gt = raw.indexOf('>', i);
			if (gt < 0)
			{
				text.append(ch);
				i++;
				continue;
			}
			final String tag = raw.substring(i + 1, gt);
			i = gt + 1;
			final String low = tag.toLowerCase(Locale.ROOT);
			int newColor = runColor;
			boolean newUnder = runUnder;
			boolean changed = false;
			if (low.startsWith("col="))
			{
				newColor = forceWhite ? defColor : parseHexColor(tag.substring(4));
				changed = true;
			}
			else if (low.equals("/col") || low.equals("colnormal"))
			{
				newColor = defColor;
				changed = true;
			}
			else if (low.equals("colhighlight"))
			{
				newColor = forceWhite ? defColor : 0xff0000;
				changed = true;
			}
			else if (low.equals("u"))
			{
				newUnder = true;
				changed = true;
			}
			else if (low.equals("/u"))
			{
				newUnder = false;
				changed = true;
			}
			else if (low.equals("br"))
			{
				text.append(' ');   // collapse hard breaks to a space
			}
			else if (low.equals("lt"))
			{
				text.append('<');
			}
			else if (low.equals("gt"))
			{
				text.append('>');
			}
			// else: <img=N>, <shad..>, unknown -> dropped
			if (changed)
			{
				firstRun = emitRun(runs, firstRun, runStart, text.length(), runColor, runUnder, defColor);
				runStart = text.length();
				runColor = newColor;
				runUnder = newUnder;
			}
		}
		emitRun(runs, firstRun, runStart, text.length(), runColor, runUnder, defColor);
		sb.append("\"text\":\"").append(BridgeJson.escapedDropControls(text.toString())).append("\",\"runs\":[").append(runs).append(']');
	}

	/** Emit a colour/underline run {@code {"o":,"l":,"c":,"u":}} if it spans text AND differs from the default.
	 *  Returns the updated firstRun flag (for comma handling). */
	private static boolean emitRun(StringBuilder runs, boolean firstRun, int start, int end, int color, boolean under, int defColor)
	{
		if (end <= start || color < 0 || (color == defColor && !under))
		{
			return firstRun;
		}
		if (!firstRun)
		{
			runs.append(',');
		}
		runs.append("{\"o\":").append(start).append(",\"l\":").append(end - start)
			.append(",\"c\":").append(color);
		if (under)
		{
			runs.append(",\"u\":1");
		}
		runs.append('}');
		return false;
	}

	/** Parse a {@code <col=...>} hex body (3- or 6-digit RRGGBB) into a 0xRRGGBB int, or -1 if malformed. */
	private static int parseHexColor(String hex)
	{
		if (hex == null || hex.isEmpty())
		{
			return -1;
		}
		try
		{
			final String h = hex.trim();
			int v = Integer.parseInt(h, 16);
			if (h.length() <= 3)
			{
				final int r = (v >> 8) & 0xf, g = (v >> 4) & 0xf, b = v & 0xf;   // 3-digit shorthand rgb -> rrggbb
				v = (r << 20) | (r << 16) | (g << 12) | (g << 8) | (b << 4) | b;
			}
			return v & 0xffffff;
		}
		catch (NumberFormatException ex)
		{
			return -1;
		}
	}

	private static void hide(Client c, int id)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w != null && !w.isHidden())
			{
				w.setHidden(true);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.hide", ignore);
		}
	}

	/** Hide (or show) the engine chat-tab buttons' VISUALS — the per-tab sprite (base+1), channel name (base+2) and
	 *  filter sub-label (base+3) — while leaving the base button widget shown so it stays a valid proxy-click target.
	 *  Used to stop the engine's 8 tabs peeking out from under the native 7-tab veneer. */
	private static void setEngineChatTabsHidden(Client c, boolean hidden)
	{
		for (final int base : CHAT_TAB_IDS)
		{
			setHidden(c, base + 1, hidden);   // GRAPHIC — the tab-background sprite
			setHidden(c, base + 2, hidden);   // TEXT — the channel name
			setHidden(c, base + 3, hidden);   // FILTER — the live "On"/"Off"/… sub-label (absent on some tabs)
		}
	}

	private static void setHidden(Client c, int id, boolean hidden)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w != null && w.isHidden() != hidden)
			{
				w.setHidden(hidden);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.setHidden", ignore);
		}
	}

	private static void forcePos(Client c, int id, int x, int y)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w != null)
			{
				w.setForcedPosition(x, y);
				w.revalidate();
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.forcePos", ignore);
		}
	}

	/** Force the chatbox to TRANSPARENT ({@code CHATBOX_TRANSPARENCY == 1}) so the engine draws the message lines in
	 *  the over-scene colour set (white/light usernames + glyph shadow), the official mobile look. Guarded so it only
	 *  writes when the value actually differs (no per-frame script churn / varbit-listener spam). */
	private static void keepChatboxTransparent(Client c)
	{
		setChatboxTransparency(c, 1);
	}

	/** Set {@code CHATBOX_TRANSPARENCY} to {@code val} (1 = transparent over-scene mode; 0 = opaque brown/parchment
	 *  box), rebuilding the chatbox so the new colour + background mode takes effect. Guarded so it only writes on a
	 *  CHANGE (no per-frame script churn / varbit-listener spam). Path B sets 0 while a dialogue is open so the engine
	 *  paints its OWN opaque dialogue parchment + full 3D head (desktop look), and 1 otherwise for the message veneer. */
	private static void setChatboxTransparency(Client c, int val)
	{
		try
		{
			// setVarbit alone doesn't re-colour/re-background the already-laid chatbox (the lines keep their colours,
			// the background stays as drawn). Rebuild on the (rare) CHANGE so it re-renders in the new mode.
			if (c.getVarbitValue(VarbitID.CHATBOX_TRANSPARENCY) != val)
			{
				c.setVarbit(VarbitID.CHATBOX_TRANSPARENCY, val);
				try { c.runScript(ScriptID.BUILD_CHATBOX); } catch (RuntimeException ignore) { BridgeFaults.note("HudVeneerBridge.buildChatbox", ignore); }
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.setChatboxTransparency", ignore);
		}
	}

	/** True if {@code id}'s interface is LOADED — i.e. the dialogue is open. This is the standard RuneLite
	 *  dialogue-open check (the in-tree dialogue plugins use a plain {@code getWidget(...) != null}); a dialogue
	 *  group is only resolvable while its dialogue is up. NOTE: deliberately NOT gated on {@code !isHidden()} — a
	 *  loaded dialogue widget can transiently report hidden, which silently killed detection. */
	private static boolean widgetShown(Client c, int id)
	{
		try
		{
			return c.getWidget(id) != null;
		}
		catch (RuntimeException ex)
		{
			return false;
		}
	}

	/** Is any chatbox dialogue interface open — NPC/player chat, "Select an Option", a "click here to continue"
	 *  message, a level-up, a make-X/quantity selector, or an item-reward box? These render into the chatbox
	 *  region; checking their content widget (loaded + shown) mirrors the in-tree dialogue plugins' detection. */
	private static boolean isDialogueOpen(Client c)
	{
		return widgetShown(c, InterfaceID.ChatLeft.TEXT)        // NPC dialogue
			|| widgetShown(c, InterfaceID.ChatRight.TEXT)       // player dialogue
			|| widgetShown(c, InterfaceID.ChatBoth.TEXT)        // combined NPC+player dialogue
			|| widgetShown(c, InterfaceID.Chatmenu.OPTIONS)     // "Select an Option"
			|| widgetShown(c, InterfaceID.Messagebox.TEXT)      // "click here to continue"
			|| widgetShown(c, InterfaceID.LevelupDisplay.CONTINUE) // level-up
			|| widgetShown(c, InterfaceID.Skillmulti.TITLE)     // make-X / quantity
			|| widgetShown(c, InterfaceID.Objectbox.TEXT)       // single-item reward box
			|| widgetShown(c, InterfaceID.ObjectboxDouble.TEXT); // double-item reward box
	}

	/** Canvas-px bounds {x,y,w,h} of the currently-open dialogue's ROOT interface (its own UNIVERSE — the dialogue
	 *  interfaces are separate top-level groups, so their root covers the dialogue rect, which CHAT_CONTAINER's
	 *  bounds would not). Pairs each detection widget with its interface root; returns the first open one, or null
	 *  (not yet laid out → the native side leaves the tap on the normal path that frame). */
	private static int[] dialogueBounds(Client c)
	{
		final int[][] dlg = {
			{InterfaceID.ChatLeft.TEXT, InterfaceID.ChatLeft.UNIVERSE},
			{InterfaceID.ChatRight.TEXT, InterfaceID.ChatRight.UNIVERSE},
			{InterfaceID.ChatBoth.TEXT, InterfaceID.ChatBoth.UNIVERSE},
			{InterfaceID.Chatmenu.OPTIONS, InterfaceID.Chatmenu.UNIVERSE},
			{InterfaceID.Messagebox.TEXT, InterfaceID.Messagebox.UNIVERSE},
			{InterfaceID.LevelupDisplay.CONTINUE, InterfaceID.LevelupDisplay.UNIVERSE},
			{InterfaceID.Skillmulti.TITLE, InterfaceID.Skillmulti.UNIVERSE},
			{InterfaceID.Objectbox.TEXT, InterfaceID.Objectbox.UNIVERSE},
			{InterfaceID.ObjectboxDouble.TEXT, InterfaceID.ObjectboxDouble.UNIVERSE},
		};
		for (final int[] d : dlg)
		{
			if (widgetShown(c, d[0]))
			{
				int[] b = canvasBounds(c.getWidget(d[1]));        // the dialogue's whole rect
				if (b == null)
				{
					b = canvasBounds(c.getWidget(d[0]));          // fall back to the content widget's rect
				}
				return b;
			}
		}
		return null;
	}

	/** Build {@link #dialogueJson} from the open dialogue's engine widgets, for the native opaque-parchment
	 *  renderer. Common types are handled (NPC/player/combined chat, "Select an Option", a continue message,
	 *  level-up); make-X / object-reward boxes stay {@code "{}"} (left to the engine — rare, still functional). */
	private static void buildDialogueJson(Client c)
	{
		try
		{
			publishDialogueJson(computeDialogueJson(c));
		}
		catch (RuntimeException e)
		{
			BridgeFaults.note("HudVeneerBridge.buildDialogueJson", e);
			publishDialogueJson("{}");
		}
	}

	private static String computeDialogueJson(Client c)
	{
		if (widgetShown(c, InterfaceID.ChatLeft.TEXT))
		{
			return dlgChat(c, "npc", InterfaceID.ChatLeft.NAME, InterfaceID.ChatLeft.TEXT, InterfaceID.ChatLeft.HEAD, InterfaceID.ChatLeft.CONTINUE);
		}
		if (widgetShown(c, InterfaceID.ChatRight.TEXT))
		{
			return dlgChat(c, "player", InterfaceID.ChatRight.NAME, InterfaceID.ChatRight.TEXT, InterfaceID.ChatRight.HEAD, InterfaceID.ChatRight.CONTINUE);
		}
		if (widgetShown(c, InterfaceID.ChatBoth.TEXT))
		{
			return dlgChat(c, "both", InterfaceID.ChatBoth.NAMES, InterfaceID.ChatBoth.TEXT, InterfaceID.ChatBoth.LEFT, InterfaceID.ChatBoth.CONTINUE);
		}
		if (widgetShown(c, InterfaceID.Chatmenu.OPTIONS))
		{
			return dlgOptions(c.getWidget(InterfaceID.Chatmenu.OPTIONS));
		}
		if (widgetShown(c, InterfaceID.Messagebox.TEXT))
		{
			return dlgChat(c, "message", -1, InterfaceID.Messagebox.TEXT, -1, InterfaceID.Messagebox.CONTINUE);
		}
		if (widgetShown(c, InterfaceID.LevelupDisplay.CONTINUE))
		{
			final String l1 = wText(c.getWidget(InterfaceID.LevelupDisplay.TEXT1));
			final String l2 = wText(c.getWidget(InterfaceID.LevelupDisplay.TEXT2));
			final StringBuilder sb = new StringBuilder(256);
			sb.append("{\"type\":\"levelup\",\"continue\":true,");
			appendTextWithRuns(sb, (l1 + " " + l2).trim(), CHAT_DEFAULT_COLOR);
			appendBounds(sb, "cont", canvasBounds(c.getWidget(InterfaceID.LevelupDisplay.CONTINUE)));
			sb.append('}');
			return sb.toString();
		}
		return "{}";
	}

	/** A chat dialogue (NPC/player/combined/continue-message): an optional name, the body text (with colour runs),
	 *  and the canvas bounds of the head model ({@code head}, for the native cutout) and the CONTINUE widget
	 *  ({@code cont}, so a continue tap can PRECISELY click the engine's live widget — robust regardless of the
	 *  "space bar to continue" setting). */
	private static String dlgChat(Client c, String type, int nameId, int textId, int headId, int continueId)
	{
		final StringBuilder sb = new StringBuilder(384);
		sb.append("{\"type\":\"").append(type).append("\",\"continue\":true");
		if (nameId >= 0)
		{
			final String nm = wText(c.getWidget(nameId)).replaceAll("<[^>]*>", "");
			if (!nm.isEmpty())
			{
				sb.append(",\"name\":\"").append(BridgeJson.escapedDropControls(nm)).append('"');
			}
		}
		sb.append(',');
		appendTextWithRuns(sb, wText(c.getWidget(textId)), CHAT_DEFAULT_COLOR);
		appendBounds(sb, "head", headId >= 0 ? canvasBounds(c.getWidget(headId)) : null);
		appendBounds(sb, "cont", continueId >= 0 ? canvasBounds(c.getWidget(continueId)) : null);
		sb.append('}');
		return sb.toString();
	}

	/** "Select an Option" — the title (child 0) + the option rows (children 1..n), each tagged with its digit key. */
	private static String dlgOptions(Widget optW)
	{
		final StringBuilder sb = new StringBuilder(384);
		sb.append("{\"type\":\"options\"");
		final Widget[] kids = optW == null ? null : optW.getDynamicChildren();
		final int n = kids == null ? 0 : kids.length;
		if (n > 0 && kids[0] != null)
		{
			final String title = wText(kids[0]).replaceAll("<[^>]*>", "");
			if (!title.isEmpty())
			{
				sb.append(",\"title\":\"").append(BridgeJson.escapedDropControls(title)).append('"');
			}
		}
		sb.append(",\"options\":[");
		boolean first = true;
		for (int i = 1; i < n; i++)
		{
			final Widget k = kids[i];
			if (k == null)
			{
				continue;
			}
			final String txt = wText(k);
			if (txt.isEmpty())
			{
				continue;
			}
			if (!first)
			{
				sb.append(',');
			}
			first = false;
			sb.append('{');
			appendTextWithRuns(sb, txt, CHAT_DEFAULT_COLOR);
			sb.append(",\"digit\":").append(i).append('}');
		}
		sb.append("]}");
		return sb.toString();
	}

	/** Append {@code ,"key":{"x":,"y":,"w":,"h":}} for a canvas-px rect, or nothing when {@code b} is null. */
	private static void appendBounds(StringBuilder sb, String key, int[] b)
	{
		if (b == null)
		{
			return;
		}
		sb.append(",\"").append(key).append("\":{\"x\":").append(b[0]).append(",\"y\":").append(b[1])
			.append(",\"w\":").append(b[2]).append(",\"h\":").append(b[3]).append('}');
	}

	/** Null-safe {@link Widget#getText()}. */
	private static String wText(Widget w)
	{
		try
		{
			final String t = w == null ? null : w.getText();
			return t == null ? "" : t;
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.wText", ex);
			return "";
		}
	}

	/** Position + size the chatbox message area ({@code CHATAREA}) so it aligns with + fits under the enlarged
	 *  native tab row. Key: the chat CONTENT (the message display + the bottom input prompt) is fixed-height and
	 *  does NOT shrink to a smaller area — shrinking CHATAREA clips the input line (the "username cut off until I
	 *  send a message" report). So instead of shrinking the content, GROW the chat container by the extra tab-row
	 *  height and keep CHATAREA at its full natural content height ({@code ORIG_CHAT_CONTENT_H}) below the tab row.
	 *  The display/input/line children then keep their natural sizes and fit. Width is the native row width (the
	 *  display children only need explicit widening when widened beyond the engine's default 519). */
	private static void sizeChatArea(Client c, int containerId, int rowW, int rowH)
	{
		try
		{
			final Widget area = c.getWidget(InterfaceID.Chatbox.CHATAREA);
			if (area == null)
			{
				return;
			}
			// A chatbox rebuild (e.g. triggered by switching the chat tab via op-replay) can leave the message
			// widgets HIDDEN, so the chat goes blank. Force them shown each frame — for the always-visible chat-at-top
			// they should never be hidden.
			setHidden(c, InterfaceID.Chatbox.CHATAREA, false);
			setHidden(c, InterfaceID.Chatbox.CHATDISPLAY, false);
			setHidden(c, InterfaceID.Chatbox.MES_LAYER, false);
			setHidden(c, InterfaceID.Chatbox.SCROLLAREA, false);
			// Keep the bottom input line ("<player>: <typed>*") shown — a chat rebuild can leave it hidden, which is
			// why it was missing from the relocated chat. The official mobile chat shows this prompt at the bottom.
			setHidden(c, InterfaceID.Chatbox.INPUT, false);
			setHidden(c, InterfaceID.Chatbox.INPUT_CLICKAREA, false);
			// Grow the container so the full-height content sits BELOW the taller native tab row instead of being
			// squeezed into the original 165px box. +2 breathing room so the bottom input line never edge-clips.
			final Widget cont = c.getWidget(containerId);
			final int wantContainerH = rowH + ORIG_CHAT_CONTENT_H + 2;
			if (cont != null && (cont.getHeightMode() != WidgetSizeMode.ABSOLUTE || cont.getOriginalHeight() != wantContainerH))
			{
				cont.setHeightMode(WidgetSizeMode.ABSOLUTE);
				cont.setOriginalHeight(wantContainerH);
				cont.revalidate();
			}
			// Message area: positioned at the ENGINE'S natural CONTROLS height (23), NOT the taller native row height
			// (rowH ~40). The engine renders the relocated chatbox to its natural ~165px viewport (CONTROLS_H +
			// ORIG_CHAT_CONTENT_H), NOT to our grown container — so offsetting CHATAREA by the full native row pushed
			// its bottom (and the input line) past the viewport and clipped it. Offsetting by CONTROLS_H keeps the
			// 142px area inside the viewport; the taller native tab row simply OVERLAYS the message area's top strip
			// (those top rows sit behind the opaque native row, like the engine CONTROLS did).
			area.setForcedPosition(0, CONTROLS_H);
			if (area.getWidthMode() != WidgetSizeMode.ABSOLUTE || area.getOriginalWidth() != rowW
				|| area.getHeightMode() != WidgetSizeMode.ABSOLUTE || area.getOriginalHeight() != ORIG_CHAT_CONTENT_H)
			{
				area.setWidthMode(WidgetSizeMode.ABSOLUTE);
				area.setOriginalWidth(rowW);
				area.setHeightMode(WidgetSizeMode.ABSOLUTE);
				area.setOriginalHeight(ORIG_CHAT_CONTENT_H);
				area.revalidate();
				// Only when the row is WIDER than the engine default do the display/scroll children need explicit
				// widening (they don't cascade); at the default 519 width they keep their natural, already-aligned
				// size + position, and their natural height fits the full-height area — so leave them untouched.
				if (rowW > CHAT_DEFAULT_W)
				{
					forceWidth(c, InterfaceID.Chatbox.CHATDISPLAY, rowW - 14, 7);
					forceWidth(c, InterfaceID.Chatbox.MES_LAYER, rowW - 14, 7);
					forceWidth(c, InterfaceID.Chatbox.SCROLLAREA, rowW - 30, 0);
				}
			}
			else
			{
				area.revalidate();
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.sizeChatArea", ignore);
		}
	}

	/** Force a chat sub-widget to an ABSOLUTE width, LEFT-anchored at {@code leftX} (these widgets centre by
	 *  default, so a width wider than their parent would shift their left edge off-screen), then revalidate. Used
	 *  for the display/scroll widgets that don't inherit the widened CHATAREA via their own size modes. */
	private static void forceWidth(Client c, int id, int w, int leftX)
	{
		try
		{
			final Widget wd = c.getWidget(id);
			if (wd == null)
			{
				return;
			}
			if (wd.getWidthMode() != WidgetSizeMode.ABSOLUTE || wd.getOriginalWidth() != w
				|| wd.getXPositionMode() != WidgetPositionMode.ABSOLUTE_LEFT || wd.getOriginalX() != leftX)
			{
				wd.setWidthMode(WidgetSizeMode.ABSOLUTE);
				wd.setOriginalWidth(w);
				wd.setXPositionMode(WidgetPositionMode.ABSOLUTE_LEFT);
				wd.setOriginalX(leftX);
				wd.revalidate();
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.forceWidth", ignore);
		}
	}

	// Dump the chatbox sub-widget layout for diagnosing the native chat-tab veneer. Fires a few times at STEADY
	// STATE (after the native side has applied the row width — chatAreaW>0 — so the dump reflects the resized
	// chat, not the first pre-native frame), spaced out, then stops.
	private static int dumpTick;
	private static int dumpsDone;

	private static void dumpChatLayoutOnce(Client c, int containerId)
	{
		if (dumpsDone >= 3)
		{
			return;   // cap the number of dumps (fires a few times at steady state)
		}
		if (dumpTick++ % 120 != 0)
		{
			return;   // ~every 2.4s
		}
		dumpsDone++;
		dumpOne(c, "CHAT_CONTAINER", containerId);
		dumpOne(c, "CONTROLS", InterfaceID.Chatbox.CONTROLS);
		dumpOne(c, "CHATAREA", InterfaceID.Chatbox.CHATAREA);
		dumpOne(c, "CHATDISPLAY", InterfaceID.Chatbox.CHATDISPLAY);
		dumpOne(c, "MES_LAYER", InterfaceID.Chatbox.MES_LAYER);
		dumpOne(c, "SCROLLAREA", InterfaceID.Chatbox.SCROLLAREA);
		dumpOne(c, "INPUT_CLICKAREA", InterfaceID.Chatbox.INPUT_CLICKAREA);
		dumpOne(c, "INPUT", InterfaceID.Chatbox.INPUT);
	}

	private static void dumpOne(Client c, String name, int id)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w == null)
			{
				log.info("[veneer] chat-layout {} = null", name);
				return;
			}
			final java.awt.Rectangle b = w.getBounds();
			log.info("[veneer] chat-layout {} bounds={} orig=({},{},{}x{}) relX={} relY={} hidden={}",
				name, b, w.getOriginalX(), w.getOriginalY(), w.getOriginalWidth(), w.getOriginalHeight(),
				w.getRelativeX(), w.getRelativeY(), w.isHidden());
		}
		catch (RuntimeException ex)
		{
			log.info("[veneer] chat-layout {} threw {}", name, String.valueOf(ex));
		}
	}
}
