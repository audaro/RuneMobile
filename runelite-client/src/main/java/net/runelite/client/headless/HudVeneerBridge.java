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
import java.util.concurrent.atomic.AtomicLong;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.ChatLineBuffer;
import net.runelite.api.ChatMessageType;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.HashTable;
import net.runelite.api.MainBufferProvider;
import net.runelite.api.MessageNode;
import net.runelite.api.Player;
import net.runelite.api.ScriptID;
import net.runelite.api.SpritePixels;
import net.runelite.api.VarClientStr;
import net.runelite.api.WidgetNode;
import net.runelite.api.events.BeforeRender;
import net.runelite.api.events.ScriptPostFired;
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
	// The desktop chat stones' hover variants: 3052 over an idle tab, 3054 over the selected one.
	private static final int SPR_CHATBTN_HOVER = 3052;
	private static final int SPR_CHATBTN_SELECTED_HOVER = 3054;
	// What script 178 draws instead when the toplevel is 601 (the official mobile layout): 58x24 stones, with no
	// hover state of their own (a hovered tab gets the selected stone, which a touch screen never wants).
	private static final int SPR_MCHATBTN_IDLE = 5779;
	private static final int SPR_MCHATBTN_SELECTED = 5780;
	private static final int SPR_MCHATBTN_NEW = 5781;

	// Native-chrome tab sprite set, loaded ONCE from the live cache after login and handed to the native shell so
	// the 2-col grid + chat column composite the real OSRS art with NOTHING committed to the repo (the same sprites
	// the engine draws — see captureTabSprites). The stones are 601's 40x40 mobile ones (STONEn_BACKGROUND, and the
	// red STONEn shown over the selected tab); SPR_TAB_ICONS = the 14 tab glyphs; 5779/5780/5781 = the chat stones.
	private static final int SPR_STONE_INACTIVE = 5767;
	private static final int SPR_STONE_ACTIVE = 5769;
	// The glyph for each engine tab index: what 164's own ICON0..ICON13 widgets draw, and 601 (the official mobile
	// layout) draws the same ones. The old 774+index set is the pre-2018 one, whose 8 and 9 are the friends smiley
	// and the ignore-list face, so account management showed the smiley and friends showed the red face. 164 draws a
	// close X for 10 (logout); the shells show logout as a door by the chat instead, so 10 is 601's door (ICON10).
	static final int[] SPR_TAB_ICONS = {168, 898, 899, 900, 901, 902, 903, 904, 1709, 905, 3560, 908, 909, 910};
	// 601's controls the shells copy: the logout door's stone (STONE10_BACKGROUND, 58x40) and its selected stone
	// (STONE10), and the arrow on the 7th inner stone, which script 7615 sets to 4795 ("Show Less") while both
	// columns show and to 4796 ("Show More") once collapsed to one.
	private static final int SPR_DOOR_STONE = 5773;
	private static final int SPR_DOOR_STONE_ACTIVE = 5775;
	private static final int SPR_SHOW_LESS = 4795;
	private static final int SPR_SHOW_MORE = 4796;
	// The rest of 601's chat column (script 7608): the lighter stone under the speech bubbles while the chat shows
	// and under the keyboard, the bubbles that toggle the chat, and the keyboard that starts typing. A hidden chat
	// puts the bubbles on the door's stone, flashing to its red one while a message waits (script 178).
	private static final int SPR_CHAT_STONE_OPEN = 5774;
	private static final int SPR_CHAT_TOGGLE = 664;
	private static final int SPR_KEYBOARD = 4794;
	// The frame behind the tab grid (SIDE_RIGHT_TABS_BACKGROUND): corners, edges and middle, row by row.
	static final int[] SPR_TAB_FRAME = {5814, 5815, 5816, 5817, 5818, 5819, 5820, 5821, 5822};
	// Bumped whenever the payload's art changes, so a shell drops a set it cached from an older jar instead of
	// showing it until the next capture lands (v1 = the 774+index glyphs, no door or arrow; v2 = desktop stones,
	// no chat column, frame or sprite offsets).
	static final int TAB_SPRITES_VERSION = 3;
	private static volatile String tabSpritesJson = "";     // one-shot ARGB payload (see captureTabSprites); "" until ready
	private static boolean tabSpritesCaptured = false;      // client-thread guard
	// Sprites load lazily — an archive the engine hasn't rendered (our tab stones are HIDDEN) isn't in the cache yet,
	// so a single tick returns a partial set. We accumulate across ticks (nudging missing archives via loadData) and
	// only latch when the grid set is complete, or at a deadline. Index: 0=stoneInactive,1=stoneActive,2..15=icons,
	// 16=chatbtn,17=chatbtnSelected,18=chatbtnNew,19=doorStone,20=doorStoneActive,21=showLess,22=showMore,
	// 23=chatStoneOpen,24=chatToggle,25=keyboard,26..34=frame.
	private static final int TAB_SPRITE_COUNT = 35;
	private static final int SLOT_FRAME = 26;
	private static final String[] TAB_SPRITE_KEYS = {
		"stoneInactive", "stoneActive",
		"i0", "i1", "i2", "i3", "i4", "i5", "i6", "i7", "i8", "i9", "i10", "i11", "i12", "i13",
		"chatbtn", "chatbtnSelected", "chatbtnNew",
		"doorStone", "doorStoneActive", "showLess", "showMore",
		"chatStoneOpen", "chatToggle", "keyboard",
	};
	private static final String[] tabSpriteB64 = new String[TAB_SPRITE_COUNT];
	// Per slot: the pixels' width and height, their offset into the sprite's full box, and that box's size. The
	// engine draws a sprite at its offset inside a widget the box's size, so a shell needs all six to place one.
	private static final int[][] tabSpriteDim = new int[TAB_SPRITE_COUNT][6];
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
	// Ticks until the next OverlayBridge.releaseHudOwned pass. It repeats, not once: a profile switch reloads saved
	// overlay positions, and a pass that failed is retried. Each pass only scans the list unless a position is set.
	private static final int HUD_RELEASE_EVERY = 300;
	private static int hudReleaseIn;   // client-thread only

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
	// The stone-row containers this bridge hid, by widget id; -1 = none of ours (client thread only). The rows'
	// hidden flag sticks, so without this record nothing would ever show them again — see applyStoneRows.
	private static final int[] stoneRowsWeHid = {-1, -1};
	private static volatile int pendingOpenTab = -1;
	// FIX-5: one-shot native "open the world map" — replays the ORB_WORLDMAP orb's op script so a native control
	// can open the map without hitting the ~25px engine orb (and fixes the legacy-account orb block). Applied on
	// the client thread in tick (where runScript is legal).
	private static volatile boolean pendingOpenWorldMap;
	// One-shot dialogue continue. The CONTINUE component carries no op listener (onOp=null), so the op-script
	// replay used for the tab stones cannot drive it -- the engine performs a continue through its own
	// WIDGET_CONTINUE handler, which is what this sends. The target is resolved on the client thread when the
	// action fires, never stored: a remembered id goes stale the moment the dialogue changes type or closes,
	// and firing a continue at a closed widget is exactly the kind of blind action this screen cannot afford.
	private static volatile boolean pendingContinueDialogue;
	// One-shot option pick: the row's child index, with the dialogue sequence the shell's tap targets were built
	// from. dialogueSeq only moves when the published dialogue actually CHANGES, so comparing it rejects a tap
	// aimed at a dialogue that has since been replaced -- which matters because a wrong pick answers a quest for
	// the player. The digit is written last and read first: it is the trigger, and the seq is already in place.
	private static volatile long pendingDialogueOptionSeq;
	private static volatile int pendingDialogueOptionDigit = -1;
	// One-shot tap on a dialogue no named kind models -- a quest's own "do you wish to take one?" Yes/No, an
	// item box's buttons. Carried as a POINT and resolved on the client thread, for the same reason the continue
	// above is a menu action rather than a click: the chatbox is force-positioned to the top of the screen and a
	// click there is resolved by the engine against the SCENE behind it, which walks the player and ends the
	// conversation.
	//
	// The tap carries the GROUP that was open when it was queued, and the resolver drops it unless that is still
	// what is open. Without it a tap resolves against whatever the next tick finds under the same coordinates,
	// and a box that closed in between (quest step advancing, a dialogue replacing it) would be answered in the
	// player's name by a tap meant for something else -- the same hazard selectDialogueOption's seq guard exists
	// for. The seq cannot serve here: it moves only when the PUBLISHED dialogue json changes, and these kinds
	// publish none, so it sits still across two different boxes.
	//
	// The group alone cannot answer "is this still the same box": the SAME group re-opened for another item
	// reads identical, and the engine gives no per-open identity to compare (it rebuilds a group's widgets, but
	// is not required to hand back new objects). So the tap is also DATED, and answered only on the tick it was
	// taken or the next one -- which is every tap that is not stale, since the one-shot runs every tick. That
	// bounds the staleness in TIME instead of by identity, and covers what the group check cannot see: a box
	// replaced by another of its own group while the tap waited.
	//
	// gen|group|x|y packed into one atomic so the client thread can never read a torn set: a point validated
	// against another tap's group, or dated by another tap's tick, would reintroduce exactly what this guards.
	// Canvas coordinates and interface groups fit 16 bits; the generation takes the 15 below the sign bit, so
	// NO_TAP (bit 63) stays a value the packing cannot produce. It wraps, and is compared as a wrapped
	// difference, which a counter this is only ever asked about two ticks of can afford.
	private static final long NO_TAP = Long.MIN_VALUE;
	private static final AtomicLong pendingDialogueTap = new AtomicLong(NO_TAP);
	// Display ticks since the bridge started. Written on the client thread, read by tapDialogue on the native one.
	private static volatile int tickGen;
	// How many ticks old a queued tap may be when it resolves. 1, not 0: a tap landing after this tick's one-shot
	// has already run is answered by the next one, and that is the normal path, not a stale tap.
	private static final int MAX_TAP_AGE_TICKS = 1;

	// chatAreaW = the canvas-px width of the chat right of the shells' column (0 = the official 461).
	// chatSnapshotJson = the per-frame chat-tab geometry/state the native side reads.
	private static volatile int chatAreaW;
	private static volatile String chatSnapshotJson = "{\"loggedIn\":false}";
	// True while an NPC/options/level-up/message/make-X dialogue interface is open. Those interfaces render INTO
	// the chatbox region, which the chat veneer's relocate+transparency suppresses — so while one is open we
	// RELEASE the veneer (chat back to natural+opaque) and the native side hides its chat veneer (reads this in
	// the snapshot as "dialogueActive"), giving the desktop-identical opaque dialogue box.
	private static volatile boolean dialogueOpen;
	// The dialogue the last tick saw was mounted on CHATMODAL, where every chatbox dialogue but a few named boxes
	// goes. preRender reads it to tell a dialogue that just closed (flag still set, mount gone) from one mounted
	// elsewhere. Client thread only.
	private static boolean dialogueOnModal;
	// The engine's chatbox message layer is taking typed input (GE item search, bank search, "Enter amount").
	// Separate from dialogueOpen because it is the opposite kind of thing: a dialogue REPLACES the chat area,
	// a prompt lives INSIDE it. Published so the native shell routes a tap there as a precise click.
	private static volatile boolean chatPromptOpen;
	// The forefront window stood down so the engine's search grid is visible, or -1. Latched for the life of the
	// prompt, so clearing the search box (which empties the result list) does not flap the window back on.
	private static int promptHiddenWindow = -1;
	// The open dialogue's content + head bounds (escaped JSON) for the native opaque dialogue. Built in tick when a
	// dialogue is open; "{}" otherwise. The native shell draws an opaque parchment over the chatbox region (so the
	// engine's transparent dialogue + the chat tabs/messages behind it are occluded), with a CUTOUT at the head
	// bounds so the engine's real 3D head model still shows through.
	private static volatile String dialogueJson = "{}";
	// The native chat MESSAGE lines: the live message model, read from client.getChatLineMap(), filtered to the
	// active tab, with <col=> colour runs pre-parsed. It was built for a UIKit chat renderer, back when a relocated
	// chatbox looked unrasterable. That turned out to be the hidden tab row, not the relocate: the engine rasters the
	// relocated chat itself, and neither port renders these lines any more. So the per-frame build is off unless
	// -Drunelite.hudveneer.chatlines=true, and getChatLines() stays logged-out.
	private static final boolean CHAT_LINES = Boolean.getBoolean("runelite.hudveneer.chatlines");
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

	// Bumps the seq ONLY on a changed snapshot, so it names the dialogue state a shell is showing and a pick can
	// be matched to it. The shells no longer depend on that in the way an earlier note here claimed: they used to
	// capture the seq only when rebuilding their rows, which meant a seq that went stale without a rebuild got
	// every option tap dropped by selectDialogueOption's guard until the text next changed -- a dialogue that
	// silently stopped answering. Both now re-tag their rows every pass, so a stale seq corrects itself.
	// Note the write order: payload first, THEN the seq. It must stay that way. A reader that catches the pair
	// mid-publish then sees a seq OLDER than the json, which gets a pick refused; bumping the seq first would
	// hand it a seq NEWER than the json, and a stale row would answer the dialogue that had just replaced it.
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
	// Chat PUT AWAY: the speech-bubble stone by the door (601's CHAT_TOGGLE) puts the whole chat away, filter
	// stones and all, where a collapse leaves the stones up. Driven from native (setChatPutAway).
	private static volatile boolean chatPutAway;
	// Last collapsed-or-hidden state APPLIED on the client thread, so the tick can detect the closed->open edge and
	// rebuild.
	private static boolean chatCollapsedApplied;
	// The canvas size and large-portrait state the chat's lines were last built for (0 = not yet). The build script
	// wraps and stacks the lines for the chat it finds, and re-laying the chat afterwards moves them as they are, so
	// after the phone turned they kept the old layout's wrapping, ran past the chat's edge and lost the last line.
	// Client thread.
	private static long chatLinesLayout;

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

	// Desktop off-device test harness: when -Drunelite.hudveneer.test=true, auto-apply the same chat veneer the
	// native shell drives (relocate + enlarged-tab geometry) once logged in, so the headless capture renders the
	// real chatbox geometry to PNG on the Mac (no device / StikDebug). Values default to the device's (render
	// 1304x600 → chat at 93,8, the official width); overridable via -Drunelite.hudveneer.test.* props.
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
	 *  each frame (the engine rebuilds the toplevel on TOPLEVEL_REDRAW). {@code false} gives back the rows this
	 *  hid. Only the Resizable - Modern layout is ever hidden; see {@link #applyStoneRows}. */
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

	/** Native: switch the account's game client layout to Resizable - Modern, the one layout the native HUD
	 *  supports, by pressing it in the game's own Settings &gt; Display dropdown. The setting is the server's and
	 *  account-wide, so it sticks on every client. One-shot; applied on the client thread in {@link #tick}, and
	 *  the outcome is logged as {@code [layout]}. See {@code GameLayoutSwitch}. */
	public static void switchToModernLayout()
	{
		GameLayoutSwitch.request(GameLayoutSwitch.MODERN);
	}

	/** Native: open the world map (FIX-5) by replaying the {@code ORB_WORLDMAP} orb's op script — a discoverable
	 *  open path decoupled from the ~25px engine orb. One-shot; applied on the client thread in {@link #tick}. */
	public static void openWorldMap()
	{
		pendingOpenWorldMap = true;
	}

	/** Native: advance the open chat dialogue. Applied on the client thread in {@link #tick}. */
	public static void continueDialogue()
	{
		pendingContinueDialogue = true;
	}

	/**
	 * Native: pick an option in the open options dialogue. Applied on the client thread in {@link #tick}.
	 *
	 * @param digit the option's child index, as published in {@code dlgOptions}
	 * @param seq   {@link #getDialogueSeq} as it stood when the shell built the tap targets this pick came from.
	 *              The pick is dropped if the dialogue has been republished since, so a tap meant for the
	 *              previous dialogue cannot answer the one that replaced it
	 */
	public static void selectDialogueOption(int digit, long seq)
	{
		pendingDialogueOptionSeq = seq;
		pendingDialogueOptionDigit = digit;
	}

	/**
	 * Native: press whatever the open dialogue has under this canvas point. For the kinds that have no modelled
	 * continue or option row -- the ones {@link #isDialogueOpen} finds by their chatbox attachment rather than
	 * by name -- the buttons are the box's OWN components, so only the box can name them: the point is matched
	 * against its live widgets on the client thread in {@link #tick} and delivered as that widget's engine op.
	 *
	 * <p>A point with nothing pressable under it is consumed, not forwarded as a click. Doing nothing is the
	 * right answer on the inert parts of a box, and the fallback click is exactly the walk-the-player this
	 * exists to stop.
	 *
	 * @param canvasX canvas-px x of the tap
	 * @param canvasY canvas-px y of the tap
	 */
	public static void tapDialogue(int canvasX, int canvasY)
	{
		// Stamped with the box that was open as of the last tick -- the one that was on screen under the finger.
		// A tap taken while a MODELLED kind is open stamps -1, which no live group matches, so it is dropped:
		// the shells only route here for the kinds the bridge publishes no targets for, and a lagging shell must
		// not answer a chat dialogue. Modelled, not merely named -- a named box whose buttons are its own is
		// routed here on purpose, and stamping it -1 dropped the only taps that could ever have pressed it.
		// A prompt stamps the chatbox group itself: its widgets are the chatbox's own, so no sub-interface names
		// it. No sub-interface can collide with that id — they are the groups attached TO the chatbox.
		final int stamp = chatPromptOpen ? InterfaceID.CHATBOX : lastEngineOwnedDialogueGroup;
		final long p = HudStrip.toEngine(canvasX, canvasY);
		pendingDialogueTap.set(packTap(tickGen, stamp, HudStrip.x(p), HudStrip.y(p)));
	}

	private static long packTap(int gen, int group, int x, int y)
	{
		return ((long) (gen & 0x7fff) << 48) | ((long) (group & 0xffff) << 32)
			| ((long) (x & 0xffff) << 16) | (y & 0xffff);
	}

	/** The group out of a packed tap. 0xffff is the "none open" -1 coming back through 16 bits, and is returned
	 *  as -1 so it compares against a live group as itself and reads as itself in the log. */
	private static int unpackTapGroup(long tap)
	{
		final int g = (int) ((tap >> 32) & 0xffff);
		return g == 0xffff ? -1 : g;
	}

	/** Ticks between the tap being taken and now, as a wrapped 15-bit difference. */
	private static int tapAge(long tap)
	{
		return (tickGen - (int) ((tap >> 48) & 0x7fff)) & 0x7fff;
	}

	/** Native, and no longer read: the engine now draws the filter row itself at the official app's fixed 30 px
	 *  (OFFICIAL_ROW_BOTTOM), so there is no taller native row to clear. Kept because both shells bind it. */
	public static void setChatTabRowHeight(int canvasPx)
	{
	}

	/** Native: the canvas-px width of the chat right of the shells' column. {@code 0} gives the official 461. */
	public static void setChatAreaWidth(int canvasPx)
	{
		chatAreaW = canvasPx;
	}

	/**
	 * Native: large portrait. The canvas runs {@code 400} px past the bottom of the screen and only its top
	 * {@code visibleHeight} rows show; the chat and the minimap draw full size in the hidden rows and are copied back,
	 * scaled by {@code canvasWidth/765}, to the shown corners {@link #relocateChat} and {@link #relocateMinimap} ask
	 * for. The game's windows (bank, Grand Exchange, Settings, ...) open full width between {@code windowTop} and
	 * {@code windowBottom}. Every canvas point a shell sends and every rect the bridge publishes stays in shown
	 * coordinates. {@code visibleHeight <= 0} turns it off. See {@code HudStrip}.
	 */
	public static void setHudStrip(int visibleHeight, int windowTop, int windowBottom)
	{
		HudStrip.set(visibleHeight, windowTop, windowBottom);
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
	 *  native top-rendered chatbox. Read lock-free on the JNI thread; published on the client thread in {@link #tick},
	 *  only under {@code -Drunelite.hudveneer.chatlines=true} ({@code {"loggedIn":false}} otherwise).
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
	 *  engine's real 3D head model shows through. Taps go to {@link #continueDialogue()} /
	 *  {@link #selectDialogueOption(int, long)}: a click on the CONTINUE widget resolves against the scene behind
	 *  the chatbox and walks the player, and a synthesized SPACE comes back consumed without advancing anything.
	 *  {@code digit} is the engine child index, so pass it through rather than renumbering the drawn rows. */
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

	/** Native: put the whole chat away, filter stones included, or bring it back (the speech-bubble stone by the
	 *  door, 601's "Toggle Chatbox"). */
	public static void setChatPutAway(boolean putAway)
	{
		chatPutAway = putAway;
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

	// The shell's own controls drawn over the game (its tab grid, the column by the chat, its buttons, the plugin
	// rail), flat {x,y,w,h,...} in shown canvas px. OverlayKeepOut keeps plugin overlay boxes off them.
	private static volatile int[] overlayKeepOut = new int[0];

	/**
	 * Native: the shell's own controls over the game, as a flat {@code {x, y, w, h, ...}} list in shown canvas px.
	 * Replaces the last list; null or empty clears it. Any thread.
	 */
	public static void setOverlayKeepOut(int[] rects)
	{
		overlayKeepOut = rects == null ? new int[0] : rects.clone();
	}

	/** The controls native last sent, flat {@code {x, y, w, h, ...}}. Any thread. */
	static int[] overlayKeepOut()
	{
		return overlayKeepOut;
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
		// The column left of the chat runs deeper than a collapsed chat's row, so it sets the depth then.
		final int h = chatPutAway ? OFFICIAL_COLUMN_Y + OFFICIAL_COLUMN_H_HIDDEN
			: chatCollapsed ? OFFICIAL_COLUMN_Y + OFFICIAL_COLUMN_H : OFFICIAL_CHAT_H;
		// In large portrait the chat shows smaller than the engine draws it.
		final float k = HudStrip.shownScale();
		return new int[]{chatX, chatY, Math.round(chatWidth() * k), Math.round(h * k)};
	}

	/**
	 * The minimap copy's canvas rect {x,y,w,h} while large portrait draws the windows' layer full width, so the
	 * top-right snap corner drops below it; null otherwise (the layer then ends left of the minimap by itself).
	 */
	public static int[] getOverlayMinimapAvoid()
	{
		final HudStrip.Layout l = HudStrip.layout();
		return ENABLED && l != null && l.mapDst != null ? l.mapDst.clone() : null;
	}

	/** The chat's width right of the shells' column: what native set, or the official 461. */
	private static int chatWidth()
	{
		return chatAreaW > 0 ? chatAreaW : OFFICIAL_ROW_W;
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
			if (ENABLED)
			{
				HudStrip.loggedOut();
			}
			return;
		}
		try
		{
			if (!c.isResized())
			{
				HudStrip.pin(c, false, false);
				return;
			}
			final boolean preEoc = c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT) == 1;
			// Large portrait: hold the game view to the screen and the windows to their band, before raster.
			HudStrip.pin(c, preEoc, isWorldMapOpen(c));
			if (!HOVER_TEXT)
			{
				// Asserted every frame, not once at boot: the flag is the engine's and a relog or a world hop
				// can hand it back. The write is skipped when it already reads false, so the steady state is
				// one field read per frame.
				disableMouseoverText(c);
			}
			applyStoneRows(c, preEoc);
			// The fullscreen world map owns the screen: the HUD layers over it are hidden here too, as the
			// final word before raster. tick() runs in the POST-render callback, so a layer the engine
			// re-showed during the client tick would otherwise get one fully painted frame on top of the map
			// — the same one-frame flash this seam exists to close for the stone rows and the chat tabs.
			setMapHudHidden(c, preEoc, isWorldMapOpen(c));
			// Same gates as the chat block in tick(): only while the chat veneer is active and the world map
			// doesn't own the screen. (A dialogue uses the normal relocate path and stays at the top, so this
			// re-assert applies during dialogues too.)
			// Pin the chatbox TRANSPARENT as the final word before raster too (see tick/keepChatboxTransparent): the
			// engine then draws the message lines with the over-scene colour set (white names + shadow), the official
			// mobile look. Only while the veneer is relocating the chat — otherwise leave the chatbox's own setting.
			// Whether a dialogue is on the chat as of THIS frame. dialogueOpen comes from tick(), which runs after the
			// draw, so on its own it is a frame late both ways: the first frame of a dialogue drew bare text over the
			// world (transparent, no box), and the first frame after one closed put the box behind the returning chat
			// lines. The CHATMODAL mount is read directly; dialogueOpen still answers for a box mounted elsewhere.
			final boolean modalNow = chatModalMounted(c);
			final boolean dialogueNow = modalNow || (dialogueOpen && !dialogueOnModal);
			if (chatX >= 0)
			{
				// Path B: opaque (0) while a dialogue is open so the engine paints its own dialogue parchment + head;
				// transparent (1) otherwise. This is the FINAL word before raster, so it MUST mirror tick()'s
				// per-dialogue flip — forcing transparent here unconditionally would override the opaque dialogue.
				// A message-layer prompt takes the opaque box for the same reason tick() un-hides CHAT_BACKGROUND
				// for it: transparent here would paint that box away again on the very next frame.
				if (dialogueNow || chatPromptOpen)
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
				// The engine draws the filter stones itself, in the official mobile layout, and the shells lay bare
				// tap targets over them. Laid here as well as in tick(): a chatbox rebuild in the client tick (every
				// new message) re-runs the desktop layout, and this is the last word before that frame rasters.
				layOfficialChat(c);
				// Centre a dialogue (fitDialogueArea) before raster too: it mounts in the client tick, and tick()
				// would centre it only after its first frame had drawn off to the right. On the mount alone: after a
				// close, centring would shift the returning chat lines 29 px left.
				if (modalNow)
				{
					fitDialogueArea(c);
				}
				// Path B (final word before raster): SHOW the chat brown box while a dialogue is open (the dialogue
				// draws onto it -> opaque dialogue), HIDE it otherwise (transparent message veneer). Must mirror tick()
				// or this re-hide would blank the dialogue box every frame. CONTROLS backgrounds stay hidden.
				// A PROMPT counts as open here too, exactly as it does for the transparency flip above. tick() shows
				// the box for a prompt and this ran after it with the dialogue test alone, so the last write before
				// raster hid it again every frame: the engine's search grid drew its icons over the bare scene with
				// nothing behind them. Transparency 0 cannot help a background that is hidden.
				setHidden(c, InterfaceID.Chatbox.CHAT_BACKGROUND, !dialogueNow && !chatPromptOpen);
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
	 * former direct call from {@code Hooks.frame()}, so that callback stays pure upstream. It also notes each run of
	 * the chatbox build script for {@link #sizeChatArea}.
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

		@Subscribe
		public void onScriptPostFired(ScriptPostFired event)
		{
			if (event.getScriptId() == ScriptID.BUILD_CHATBOX)
			{
				chatRebuilt = true;
			}
		}
	}

	/**
	 * Large portrait's copy of the chat and the minimap out of the hidden strip, from {@code postComposite}: after the
	 * overlays, before the CPU frame snapshot and before GPU or 117HD uploads this buffer as its interface layer.
	 */
	static void postComposite(Client c, MainBufferProvider b)
	{
		if (!ENABLED || c == null || b == null)
		{
			return;
		}
		if (c.getGameState() != GameState.LOGGED_IN || !c.isResized())
		{
			HudStrip.composite(c, null, 0, 0, -1, -1, -1, -1, false);
			return;
		}
		HudStrip.composite(c, b.getPixels(), b.getWidth(), b.getHeight(), chatX, chatY, minimapX, minimapY,
			isWorldMapOpen(c));
	}

	/** Re-apply the requested chatbox state each frame. Client thread. */
	public static void tick(Client c)
	{
		// Before the gate on purpose: this counter is what dates a queued dialogue tap, and the gap it has to
		// measure is exactly the one this gate creates. A tap queued with a box open, followed by a loading
		// screen or a world hop, is not consumed while logged out -- tick returns here without reaching the
		// one-shot -- so the tap would otherwise come back alive and answer whatever box is open on return.
		// If tick stops being called altogether the counter stands still, which is correct: no tick, no engine
		// state change, so nothing can have replaced the box the finger was on.
		tickGen++;
		if (!ENABLED || c == null || c.getGameState() != GameState.LOGGED_IN)
		{
			return;
		}
		try
		{
			// Before the resizable gate: Fixed is one of the layouts a switch leaves.
			GameLayoutSwitch.tick(c);
			if (!c.isResized())
			{
				return;   // native veneers + transparent chat are resizable-mode only
			}
			captureTabSprites(c);   // one-shot: hand the real cache tab/stone/chat sprites to the native shell
			// A saved WidgetOverlay position would force a container every frame against the pins below.
			if ((chatX >= 0 || minimapX >= 0 || sideX >= 0) && --hudReleaseIn <= 0)
			{
				// -1 = the overlay manager isn't up yet: try again next frame.
				hudReleaseIn = OverlayBridge.releaseHudOwned() < 0 ? 1 : HUD_RELEASE_EVERY;
			}
			if (TEST_APPLY && !testApplied)
			{
				// Off-device capture: drive the chat veneer ourselves (the native shell would on device). The
				// in-world "Welcome to RuneScape" news overlay is dismissed by HeadlessLogin so the chat is visible.
				testApplied = true;
				relocateChat(Integer.getInteger("runelite.hudveneer.test.chatX", 93),
					Integer.getInteger("runelite.hudveneer.test.chatY", 8),
					!"false".equals(System.getProperty("runelite.hudveneer.test.transparent")));
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
			dialogueOnModal = dlgOpen && chatModalMounted(c);
			// A prompt only counts when no dialogue owns the chat area: make-X and friends are named dialogues
			// that may also drive the message layer, and they keep their existing (parchment) handling.
			final boolean promptOpen = !dlgOpen && isChatPromptOpen(c);
			chatPromptOpen = promptOpen;
			// The engine draws the search itself -- item icons, three columns, the matched prefix underlined,
			// its own scrollbar -- and draws it into the chat area UNDER the forefront window. That rendering is
			// the one worth having (it is the desktop one), so the WINDOW steps aside for as long as the search
			// owns the chat, rather than the search being redrawn natively without the icons. There is no room
			// for both: the keyboard takes the bottom of the screen and the window the middle.
			// Only for a prompt that lists its answers there. A bank search puts no list in the chat because its
			// results ARE the bank items, and an "Enter amount" needs the window it is a number for.
			if (!promptOpen)
			{
				if (promptHiddenWindow >= 0)
				{
					setHidden(c, promptHiddenWindow << 16, false);
					promptHiddenWindow = -1;
				}
			}
			else if (promptHiddenWindow < 0 && promptListsResults(c))
			{
				final int g = openForefrontWindowGroup(c);
				if (g >= 0)
				{
					setHidden(c, g << 16, true);
					promptHiddenWindow = g;
					log.info("[veneer] search owns the chat — window group={} stood down", g);
				}
			}
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
				// A prompt counts as open here, and MUST: this is the same flip the pre-raster pin makes, and
				// when the two disagree they write opposite values every frame -- each change running
				// BUILD_CHATBOX, so the chatbox was being rebuilt twice a frame under a search, which is why it
				// came back transparent however many times the other end set it opaque.
				if (dlgOpen || promptOpen)
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
				final int rowW = chatWidth();
				// A forefront window (bank / GE / shop / …) open: hide the chat so it sits BEHIND the window (the
				// native shell also hides its tab row from the published windowOpen flag).
				//
				// EXCEPT while the engine is asking for input. The Grand Exchange item search, the bank search
				// and every "Enter amount" prompt are drawn into the chatbox container, so hiding it hides the
				// prompt and stops it hit-testing: the player taps "Choose an item", the engine opens the
				// search exactly as it should, and nothing appears — there is no way to see it, scroll it, or
				// pick a result. Nothing about the tap is wrong, which is why it reads as a dead button.
				chatWindowOccluded = isForefrontWindowOpen(c) && !promptOpen;
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
						final boolean unhidden = w.isHidden();
						if (unhidden)
						{
							w.setHidden(false);
							// Rebuild the message lines on the un-hide edge — but NOT when a prompt is what we are
							// un-hiding for. That edge is the moment the search opens, and BUILD_CHATBOX redraws
							// the chat area the prompt is living in; stale message lines for the life of a search
							// are a cheap price next to rebuilding over the thing the player just asked for.
							if (!promptOpen)
							{
								try { c.runScript(ScriptID.BUILD_CHATBOX); } catch (RuntimeException ignore) { BridgeFaults.note("HudVeneerBridge.buildChatbox", ignore); }
							}
						}
						// Widen the chat CONTAINER to the native row width so its children (the message area) can fill it.
						final boolean widened = w.getOriginalWidth() != rowW;
						if (widened)
						{
							w.setOriginalWidth(rowW);
						}
						// Re-laid on the un-hide edge as well: the chat comes back from a window or the world map
						// laid out the way the old every-frame revalidate left it.
						// Large portrait draws it in the strip and HudStrip copies it to (chatX, chatY).
						if (HudStrip.isOn())
						{
							CHAT_PIN.apply(w, HudStrip.slotX(), HudStrip.chatSlotY(), widened || unhidden);
						}
						else
						{
							CHAT_PIN.apply(w, chatX, chatY, widened || unhidden);
						}
					}
				}
				// OSRS-Mobile tabs-on-top: the desktop chat stacks the tab row (CONTROLS) UNDER the message area
				// (CHATAREA, 142px). layOfficialChat puts the row along the chat's top, in the official app's layout,
				// and the engine draws it; the shells only lay tap targets over the stones.
				layOfficialChat(c);
				// Repopulate the messages on the closed->open edge — UNLESS a dialogue is open (auto-open un-collapses
				// the chat to show the dialogue; rebuilding would briefly repopulate the message lines, which then bleed
				// over the opaque dialogue box). The dialogue replaces the messages anyway, so skip the rebuild.
				final boolean chatClosed = chatCollapsed || chatPutAway;
				if (chatCollapsedApplied && !chatClosed && !dlgOpen)
				{
					try { c.runScript(ScriptID.BUILD_CHATBOX); } catch (RuntimeException ignore) { BridgeFaults.note("HudVeneerBridge.buildChatbox", ignore); }
				}
				chatCollapsedApplied = chatClosed;
				// Apply a pending tab switch (op-replay sets the channel; switchChatTabNow rebuilds the lines).
				final int switchTab = pendingChatTab;
				if (switchTab >= 0)
				{
					pendingChatTab = -1;
					switchChatTabNow(c, switchTab);
				}
				// Size + place the message area below the filter row, as the official app does (sizeChatArea).
				// Skip during a dialogue: sizeChatArea force-SHOWS the message widgets (CHATAREA/CHATDISPLAY/
				// SCROLLAREA/INPUT) every frame, which re-shows the chat lines over the opaque dialogue box. The
				// dialogue replaces the messages, so leave the area alone while one is open.
				if (!dlgOpen) sizeChatArea(c, chatId, rowW, promptOpen);
				// Rebuild the lines once the layout under them changes (a turn, a fold, the strip going on or off; the
				// strip settles a frame after the canvas, which can take a second rebuild). Not while the chat is
				// closed, where the reopen edge rebuilds, or under a dialogue, which the lines would bleed over.
				final long layout = (long) c.getCanvasWidth() << 32 | c.getCanvasHeight() << 1 | (HudStrip.isOn() ? 1 : 0);
				if (layout != chatLinesLayout && !chatClosed && !dlgOpen)
				{
					if (chatLinesLayout != 0)
					{
						try { c.runScript(ScriptID.BUILD_CHATBOX); } catch (RuntimeException ignore) { BridgeFaults.note("HudVeneerBridge.buildChatbox", ignore); }
					}
					chatLinesLayout = layout;
				}
				// Path B: in classic OSRS the dialogue draws its head + text ONTO the chatbox brown box. So while a
				// dialogue is open SHOW CHAT_BACKGROUND (opaque dialogue box); otherwise HIDE it so chat messages draw
				// transparent over the scene. CONTROLS backgrounds stay hidden (the native tab row covers that strip).
				// A prompt gets the box too: it is text the player has to read over whatever window is behind it.
				setHidden(c, InterfaceID.Chatbox.CHAT_BACKGROUND, !dlgOpen && !promptOpen);
				hide(c, InterfaceID.Chatbox.CONTROLS_BACKGROUND);
				hide(c, InterfaceID.Chatbox.CONTROLS_BACKGROUND_GRAPHIC);
				// Collapse (tap the active tab) and put away hide only the message CONTENT, not the container, so the
				// lines are PRESERVED (no teardown) and reopening is instant + populated instead of an empty box that
				// needs a second tap to rebuild. sizeChatArea force-shows these every frame, so re-hide them here.
				// Hiding the CHATAREA parent hides its children (CHATDISPLAY/MES_LAYER/INPUT) too. Do NOT separately
				// hide+show the child layers: that hide/show cycle made the engine re-lay them on the next
				// BUILD_CHATBOX and clipped/dropped the bottom input line.
				// ... but NOT while a prompt is open. The prompt is drawn INTO the chat area, so hiding its parent
				// hides the prompt - the same mistake as the forefront-window rule above, one level down. A
				// collapsed chat yields to it too: the player just asked the game for this input.
				//
				// A DIALOGUE is drawn into the chat area as well: the game opens it on CHATMODAL (162:568), which
				// hangs off MES_LAYER_HIDE under CHATAREA, so hiding CHATAREA hides the dialogue. The game keeps it
				// shown by itself. The chatbox's sub-change script (80 -> 113 -> 923) un-hides CHATAREA whenever a
				// dialogue is mounted, and 908 hides the message lines (CHATDISPLAY) under it, so no chat line bleeds
				// over the box while sizeChatArea is skipped. Those scripts run once, when a dialogue opens or another
				// replaces it. Hiding CHATAREA here every frame left each one on screen for that one frame and then
				// blank, still answering taps (issue #5). So a dialogue gets the area shown and the lines left to the engine.
				// INPUT_CLICKAREA is the exception: no game script shows or hides it (it loads hidden; only the
				// branch below shows it), so it is hidden here, or the chat's input click zone would sit across the
				// bottom of the dialogue, where its "Click here to continue" is.
				if (dlgOpen)
				{
					setHidden(c, InterfaceID.Chatbox.CHATAREA, false);
					setHidden(c, InterfaceID.Chatbox.INPUT_CLICKAREA, true);
					fitDialogueArea(c);
				}
				else
				{
					final boolean hideMsgArea = chatClosed && !promptOpen;
					setHidden(c, InterfaceID.Chatbox.CHATAREA, hideMsgArea);
					setHidden(c, InterfaceID.Chatbox.INPUT, hideMsgArea);
					setHidden(c, InterfaceID.Chatbox.INPUT_CLICKAREA, hideMsgArea);
					setHidden(c, InterfaceID.Chatbox.CHATSCROLLBAR, hideMsgArea);
				}
				buildChatSnapshot(c);
				if (CHAT_LINES)
				{
					buildChatLines(c);
				}
				// While a dialogue is open, publish its content + head bounds so the native shell draws an opaque
				// parchment over the chatbox region (occluding the engine's transparent dialogue + the chat
				// tabs/messages) with a cutout where the engine's real 3D head renders. Cleared when none is open.
				if (dlgOpen || promptOpen)
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
					applyChatScroll(c, scrollDelta, promptOpen);
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

			// Minimap+orbs cluster relocate (independent of chat). Pinned each frame so it survives TOPLEVEL_REDRAW,
			// which costs a compare unless it moved (see Pin); a re-pin's revalidate cascades to the globe + orb children.
			if (minimapX >= 0 && !mapOpenNow)
			{
				final int containerId = preEoc
					? InterfaceID.ToplevelPreEoc.MAP_CONTAINER : InterfaceID.ToplevelOsrsStretch.MAP_CONTAINER;
				final Widget w = c.getWidget(containerId);
				if (w != null)
				{
					if (HudStrip.isOn())
					{
						MAP_PIN.apply(w, HudStrip.slotX(), HudStrip.mapSlotY(), false);
					}
					else
					{
						MAP_PIN.apply(w, minimapX, minimapY, false);
					}
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
			// Resizable - Modern only. In Classic the container sits inside SIDE_MENU, so a canvas x forced on it
			// lands far outside its parent and the panel is gone; and a switch to Classic made in-game reaches
			// here for a few frames before the native shell has stood its grid down and released this.
			if (sideX >= 0 && preEoc && !mapOpenNow)
			{
				final Widget w = c.getWidget(InterfaceID.ToplevelPreEoc.SIDE_CONTAINER);
				if (w != null)
				{
					SIDE_PIN.apply(w, sideX, sideY, false);
				}
			}

			// Hide the engine tab-stone bottom row by hiding the stones' GRANDPARENT containers — NOT the stones
			// themselves. The engine re-pins the stone widgets every frame (setHidden/relocate on a stone is
			// overridden — confirmed on device), but the ancestor containers are normal widgets whose hidden state
			// STICKS. The PARENT holds only the stone icons (hiding it leaves the empty stone backgrounds); the
			// GRANDPARENT holds the whole row (icons + backgrounds), so hiding it clears the row completely
			// (StoneSuppressProbe steady-state PNG + device). Stones still resolve under the hidden ancestor, so
			// openTab (replaying a stone's op script) still switches tabs. STONE0 = left half, STONE7 = right half.
			// Resizable - Modern only, and undone when the native grid stands down: see applyStoneRows.
			applyStoneRows(c, preEoc);

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

			// One-shot: advance the chat dialogue through the engine's own continue handler.
			if (pendingContinueDialogue)
			{
				pendingContinueDialogue = false;
				continueDialogueNow(c);
			}

			// One-shot: pick an option through the same continue handler.
			final int optDigit = pendingDialogueOptionDigit;
			if (optDigit >= 0)
			{
				final long optSeq = pendingDialogueOptionSeq;
				pendingDialogueOptionDigit = -1;
				selectDialogueOptionNow(c, optDigit, optSeq);
			}

			// One-shot: press the widget under a tap on a dialogue the named kinds don't model, through its own op.
			final long tap = pendingDialogueTap.getAndSet(NO_TAP);
			if (tap != NO_TAP)
			{
				tapDialogueNow(c, unpackTapGroup(tap), tapAge(tap),
					(int) ((tap >> 16) & 0xffff), (int) (tap & 0xffff));
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
		return openForefrontWindowGroup(c) >= 0;
	}
	/** The forefront window group currently drawn over the chat, or -1 — the id, so it can be restored later. */
	private static int openForefrontWindowGroup(Client c)
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
				return g;
			}
		}
		lastWindowOccludedLogged = false;
		return -1;
	}

	// DIAGNOSTIC: rate-limited dump of the open interface roots + candidate-window probes, so the [ifaces] log
	// reveals exactly which group/bounds the bank/GE use when the user opens one. It walks every root and logs a
	// line per root on the client thread, so it is off unless -Drunelite.hudveneer.ifacedump=true.
	private static final boolean IFACE_DUMP = Boolean.getBoolean("runelite.hudveneer.ifacedump");
	private static final long IFACE_DUMP_MS = 3000;
	private static long lastIfaceDump;
	private static void dumpOpenInterfaces(Client c)
	{
		if (!IFACE_DUMP || chatX < 0)
		{
			return;
		}
		final long now = System.currentTimeMillis();
		if (now - lastIfaceDump <= IFACE_DUMP_MS)
		{
			return;
		}
		lastIfaceDump = now;
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
			// Not edge-gated: setMapHudHidden restores only what IT hid, so this also recovers a HUD left
			// hidden by a tick that threw on its way here (the catch in tick() swallows it and the map-open
			// frame would otherwise be the last one that ever ran this).
			setMapHudHidden(c, preEoc, false);
			mapPanDx.set(0);
			mapPanDy.set(0);
			mapScrollDelta.set(0);
			mapPanRemX = mapPanRemY = 0;
			publishMapSnapshot("{\"open\":false}");
			return;
		}
		if (!mapWasOpen)
		{
			mapHudLeakLogged = false;   // open edge — arm the tripwire for this open
		}
		mapWasOpen = true;
		// tick() runs in the POST-render callback, so this reads the layers as the frame just RASTERISED
		// them, after preRender asserted the hide — the one place that can tell a hide which did not take
		// from a hide which took while something else painted. Device-confirmed holding 2026-10-20, so it is
		// silent now and stays silent; a line here means a layer came back on top of the map, which is what
		// an upstream merge re-pinning these layers would look like. Once per open, so it cannot spam.
		if (!mapHudLeakLogged)
		{
			final int[] live = mapHudLayerIds(preEoc);
			// Only the containers trip it. The hover label is reported for context but is not a leak: with
			// -Drunelite.hover.text=true it is over the map because that is what the switch asks for.
			if (isShown(c, live[0]) || isShown(c, live[1]))
			{
				mapHudLeakLogged = true;
				log.warn("[veneer] world map: HUD painted over it — cluster={} side={} (hoverText={})",
					shownNow(c, live[0]), shownNow(c, live[1]), c.isMouseoverTextEnabled());
			}
		}

		// HIDE the chat while the map is open — the relocated chat-at-top would draw over the fullscreen
		// map's top edge. Restored + rebuilt on the close edge (hiding tears the chat content down).
		final Widget chat = c.getWidget(chatId);
		if (chat != null && !chat.isHidden())
		{
			chat.setHidden(true);
		}

		// The official mobile app shows NO HUD over the map, and the engine draws the map window UNDER the
		// toplevel HUD layers, so they have to stop painting — see setMapHudHidden. Unconditional: it is the
		// engine's own HUD that covers the map, whether or not the native shell happens to be relocating it.
		setMapHudHidden(c, preEoc, true);
		// Shove the relocated containers off-screen as well, so anything that reads their BOUNDS (overlay
		// positioning, the native snapshots) sees them out of the way too. Gated on an active relocate
		// because that is what the post-close apply blocks re-force home; the hide is what the render obeys.
		if (minimapX >= 0)
		{
			shoveOffscreen(c, MAP_PIN, preEoc ? InterfaceID.ToplevelPreEoc.MAP_CONTAINER : InterfaceID.ToplevelOsrsStretch.MAP_CONTAINER, minimapX);
		}
		if (sideX >= 0 && preEoc)   // the relocate it pairs with is Modern-only (see tick)
		{
			shoveOffscreen(c, SIDE_PIN, InterfaceID.ToplevelPreEoc.SIDE_CONTAINER, sideX);
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

	/**
	 * Whether the engine's hover-option text ("Walk here", top-left) is drawn at all. Off, because this client
	 * has no cursor: that label names whatever the engine's tracked point resolves to, and on touch nothing
	 * the user did put the point there on purpose. It lingers after a tap and re-names itself as the world
	 * turns under it when the camera rotates, since camera rotation writes yaw/pitch directly and never moves
	 * the point. The official mobile app shows no hover text for the same reason — there is no hover.
	 * <p>
	 * This is the remedy {@code JavaBridge.parkPointer} prescribed in advance when it dropped the fabricated
	 * (−1,−1) cursor park: <em>stop drawing the label, do not move the cursor somewhere the finger never was.</em>
	 * Restore the desktop behaviour with {@code -Drunelite.hover.text=true}. That switch is the whole story:
	 * the world map does NOT suppress the label separately. One global flag, one owner — a second owner that
	 * turned it off for the map would have to turn it back on afterwards, and it cannot tell its own
	 * {@code false} from a plugin's. Asking for the desktop label is asking for it over the map too.
	 */
	private static final boolean HOVER_TEXT = Boolean.parseBoolean(System.getProperty("runelite.hover.text", "false"));

	// True while WE hold the toplevel HUD layers hidden for an open world map (client thread only). The
	// restore is driven off this flag, never off "the map just closed", so the HUD cannot be left hidden by a
	// frame that missed the close edge — and a layer the ENGINE closed is never forced back on.
	private static boolean mapHudHidden;
	private static boolean mapHudHiddenPreEoc;   // the layout the hide went to, so the restore can't miss it
	private static final boolean[] mapHudWeHid = new boolean[2];   // per layer: this hide is OURS to undo
	private static boolean mapHudLeakLogged;   // this open has already reported a layer painting over the map

	/** The toplevel layers that must not paint over the fullscreen world map, in {@link #mapHudWeHid} order:
	 *  the minimap+orbs cluster and the side panel. The hover-option text is NOT here — it is not a widget
	 *  at all; see {@link #setMapHudHidden}. */
	private static int[] mapHudLayerIds(boolean preEoc)
	{
		return preEoc
			? new int[]{InterfaceID.ToplevelPreEoc.MAP_CONTAINER, InterfaceID.ToplevelPreEoc.SIDE_CONTAINER}
			: new int[]{InterfaceID.ToplevelOsrsStretch.MAP_CONTAINER, InterfaceID.ToplevelOsrsStretch.SIDE_CONTAINER};
	}

	/**
	 * Turn the engine's hover-option text ("Walk here", top-left) off or back on, and report whether this call
	 * is what changed it — the only thing that earns the right to change it back.
	 * <p>
	 * Hiding {@code TopLevel*.MOUSEOVER} was the first attempt and is a confirmed no-op (device, 2026-10-20):
	 * that label is drawn by the client, not by a widget whose hidden flag could end it. RuneLite's own
	 * {@code SnapCorners} is the corroborating tell — it shifts every {@code TOP_LEFT} overlay down by a
	 * hardcoded 15px to clear this text, which is not something you do for a widget you could measure.
	 * {@link Client#setMouseoverTextEnabled} is the hook built for it.
	 * <p>
	 * One-way on purpose. The flag is client-global and a plugin may have its own opinion about it, so this
	 * never switches it back ON: there is no way to tell our own {@code false} from somebody else's, which
	 * makes a restore a guess dressed up as bookkeeping. Nothing here needs one — {@link #HOVER_TEXT} is a
	 * boot setting, not a state that toggles.
	 */
	private static void disableMouseoverText(Client c)
	{
		try
		{
			if (c.isMouseoverTextEnabled())
			{
				c.setMouseoverTextEnabled(false);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.disableMouseoverText", ignore);
		}
	}

	/** Set the widget's OWN hidden flag, ignoring its parents'. Returns true when this call is what changed
	 *  it — which is the only thing that earns the right to change it back. */
	private static boolean setSelfHidden(Client c, int id, boolean hidden)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w == null || w.isSelfHidden() == hidden)
			{
				return false;
			}
			w.setHidden(hidden);
			return true;
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.setSelfHidden", ignore);
			return false;
		}
	}

	/** True when the layer exists and is not hidden — i.e. it painted. */
	private static boolean isShown(Client c, int id)
	{
		try
		{
			final Widget w = c.getWidget(id);
			return w != null && !w.isHidden();
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.isShown", ignore);
			return false;
		}
	}

	/** {@code "SHOWN"} / {@code "hidden"} / {@code "absent"} — the layer as it stands right now. */
	private static String shownNow(Client c, int id)
	{
		try
		{
			final Widget w = c.getWidget(id);
			return w == null ? "absent" : w.isHidden() ? "hidden" : "SHOWN";
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.shownNow", ignore);
			return "?";
		}
	}

	/**
	 * Hide (or restore) the HUD that would otherwise paint over the fullscreen world map: the minimap+orbs
	 * cluster and the side panel. The engine's hover-option text ("Walk here") is NOT handled here: it is not
	 * a widget, and it is already off client-wide — see {@link #HOVER_TEXT} and {@link #disableMouseoverText}.
	 * <p>
	 * HIDING, not moving, is what the render obeys. Moving {@code MAP_CONTAINER} takes the globe with it — the
	 * engine rasterises that at the draw widget's live bounds — but not the orbs: they are hard-pinned each
	 * frame (the same readback-confirmed pinning documented on {@link #applyMinimapScale}), and the Orbs
	 * interface we open into the ORBS layer ourselves carries its own laid-out position. A hidden container
	 * ends the draw recursion, so nothing under it can paint itself anywhere, at any position, stale or not.
	 * <p>
	 * Idempotent, and re-asserted every frame from {@link #preRender} while the map is open, so a layer the
	 * engine re-shows gets at most zero painted frames.
	 * <p>
	 * Reads and writes each layer's OWN hidden flag, and restores only the flags this method actually set.
	 * The shared {@link #setHidden} helper guards on {@link Widget#isHidden()}, which counts a hidden PARENT
	 * too: a layer the engine had already hidden would be skipped on the way in (its flag already reads
	 * hidden) and then force-SHOWN on the way out. A hidden toplevel would do that to both at once.
	 */
	private static void setMapHudHidden(Client c, boolean preEoc, boolean hidden)
	{
		if (!hidden && !mapHudHidden)
		{
			return;   // nothing of ours to restore
		}
		// Restore the layout we HID, not the one that happens to be live now: a stone-arrangement flip between
		// the two would otherwise un-hide the other toplevel's layers and leave these three hidden for good.
		final boolean layout = hidden ? preEoc : mapHudHiddenPreEoc;
		if (hidden && layout != mapHudHiddenPreEoc)
		{
			java.util.Arrays.fill(mapHudWeHid, false);   // different toplevel, different widgets — nothing of ours
		}
		mapHudHidden = hidden;
		mapHudHiddenPreEoc = layout;
		final int[] ids = mapHudLayerIds(layout);
		for (int i = 0; i < ids.length; i++)
		{
			if (hidden)
			{
				// |= and not =: the re-assert has to keep the claim from the frame that first hid this layer,
				// or an engine re-show mid-open would hand the restore back a layer we are still holding down.
				mapHudWeHid[i] |= setSelfHidden(c, ids[i], true);
			}
			else if (mapHudWeHid[i])
			{
				mapHudWeHid[i] = false;
				setSelfHidden(c, ids[i], false);
			}
		}
	}

	/** Park a relocated toplevel container far below the canvas (kept alive, not hidden — no teardown). Through
	 *  the container's own pin, so the close edge's re-pin home sees the move and the frames in between cost nothing. */
	private static void shoveOffscreen(Client c, Pin pin, int id, int x)
	{
		final Widget w = c.getWidget(id);
		if (w != null)
		{
			pin.apply(w, x, CHAT_COLLAPSE_OFFSCREEN_DY, false);
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

	/**
	 * Hide the two engine stone rows while the native tab grid stands in for them, and give back the ones this
	 * hid once it doesn't. Client thread; asserted from both {@link #preRender} and {@link #tick}.
	 *
	 * <p>A row is a stone's GRANDPARENT container (icons + backgrounds). The engine re-pins the stones but not
	 * their ancestors, so the hide sticks and the stones still resolve underneath for {@link #openTabNow}. That
	 * container is the row alone only in Resizable - Modern (164). In Resizable - Classic (161) both rows share
	 * one grandparent, SIDE_MENU, which also holds the side panel: hiding it there took the panel too, so every
	 * tab opened into nothing and a player who logged in on Classic could not reach the Display settings to
	 * leave it. Classic is therefore never hidden.
	 *
	 * <p>Because the hide sticks, the restore is the other half of the fix. It undoes only a hide this made
	 * ({@code isSelfHidden}, recorded per row), never one the engine made, and it targets the widget it hid, so a
	 * layout switch cannot point it at the other toplevel's rows.
	 */
	private static void applyStoneRows(Client c, boolean preEoc)
	{
		final boolean hide = hideStones && preEoc;
		final int[] stones = hide ? stoneIds(true) : null;
		for (int i = 0; i < stoneRowsWeHid.length; i++)
		{
			if (hide)
			{
				try
				{
					final Widget row = rowOf(c, stones[i * 7]);   // STONE0 = left half, STONE7 = right half
					// A row already hidden keeps whatever claim it had: ours from an earlier frame, or none at all
					// if the engine hid it, which leaves it the engine's to show again.
					if (row != null && !row.isSelfHidden())
					{
						row.setHidden(true);
						stoneRowsWeHid[i] = row.getId();
					}
				}
				catch (RuntimeException ignore)
				{
					BridgeFaults.note("HudVeneerBridge.applyStoneRows", ignore);
				}
			}
			else if (stoneRowsWeHid[i] != -1)
			{
				setSelfHidden(c, stoneRowsWeHid[i], false);
				stoneRowsWeHid[i] = -1;
			}
		}
	}

	/** The stone row a stone sits in: its grandparent container, or null if the stone isn't loaded. */
	private static Widget rowOf(Client c, int stoneId)
	{
		final Widget s = c.getWidget(stoneId);
		final Widget p = s == null ? null : s.getParent();
		return p == null ? null : p.getParent();
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
	/**
	 * Perform a continue on the dialogue currently published. The component is a static interface child, so
	 * param0 is -1 -- the same rule the tab stones and the logout click already established here; passing an
	 * index misroutes the engine's dispatch. Its live hidden state is logged alongside, because the one sample
	 * taken when a dialogue first builds read hidden=true and that may simply have been its first tick.
	 */
	private static void continueDialogueNow(Client c)
	{
		final int id = resolveContinueId(c);
		if (id < 0)
		{
			System.out.println("[cont] no dialogue open");
			return;
		}
		try
		{
			final Widget w = c.getWidget(id);
			System.out.println("[cont] fire id=" + id + " widget=" + (w != null)
				+ (w == null ? "" : " hidden=" + w.isHidden() + " clickMask=" + w.getClickMask()));
			if (w == null)
			{
				return;
			}
			c.menuAction(-1, id, net.runelite.api.MenuAction.WIDGET_CONTINUE, 0, -1, "Continue", "");
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.continueDialogueNow", ignore);
		}
	}

	/**
	 * The CONTINUE component of whatever dialogue is open right now, or -1 if none is. Mirrors
	 * {@link #computeDialogueJson}'s detection order, and like it keys the chat kinds off their TEXT widget --
	 * a chat CONTINUE reads hidden even while its dialogue is on screen, so testing CONTINUE itself would find
	 * nothing. Options are deliberately absent: choosing a row is not continuing, and a continue fired at an
	 * options menu would answer for the player.
	 */
	private static int resolveContinueId(Client c)
	{
		if (widgetShown(c, InterfaceID.ChatLeft.TEXT))
		{
			return InterfaceID.ChatLeft.CONTINUE;
		}
		if (widgetShown(c, InterfaceID.ChatRight.TEXT))
		{
			return InterfaceID.ChatRight.CONTINUE;
		}
		if (widgetShown(c, InterfaceID.ChatBoth.TEXT))
		{
			return InterfaceID.ChatBoth.CONTINUE;
		}
		if (widgetShown(c, InterfaceID.Messagebox.TEXT))
		{
			return InterfaceID.Messagebox.CONTINUE;
		}
		if (widgetShown(c, InterfaceID.LevelupDisplay.CONTINUE))
		{
			return InterfaceID.LevelupDisplay.CONTINUE;
		}
		return -1;
	}

	/**
	 * Pick a dialogue option. An option row is a DYNAMIC child of the options component, not a static component
	 * like the continue, so it is addressed by index: param0 is the child index and param1 the parent. That is
	 * the other half of the rule the tab stones established -- there, passing an index misrouted a static
	 * component's op; here, -1 would name no row at all. The action is the engine's continue handler, the same
	 * one a continue tap uses, because answering an option resumes the paused script exactly as continuing does.
	 */
	private static void selectDialogueOptionNow(Client c, int digit, long seq)
	{
		try
		{
			// The dialogue must still be the one the tap was aimed at. A count of rows cannot establish that --
			// the next dialogue often offers the same number of options, and in a quest those mean different
			// answers -- so compare the publish the targets were built from.
			if (seq != dialogueSeq)
			{
				System.out.println("[opt] dropped digit=" + digit + " seq=" + seq + " live=" + dialogueSeq);
				return;
			}
			final Widget optW = c.getWidget(InterfaceID.Chatmenu.OPTIONS);
			final Widget[] kids = optW == null ? null : optW.getDynamicChildren();
			final int n = kids == null ? 0 : kids.length;
			// kids[0] is the title, so rows start at 1; a padded blank row is not a row.
			if (digit < 1 || digit >= n || kids[digit] == null || wText(kids[digit]).isEmpty())
			{
				System.out.println("[opt] dropped digit=" + digit + " kids=" + n + " (no such row)");
				return;
			}
			System.out.println("[opt] fire digit=" + digit + " parent=" + optW.getId()
				+ " childId=" + kids[digit].getId() + " index=" + kids[digit].getIndex()
				+ " hidden=" + kids[digit].isHidden() + " clickMask=" + kids[digit].getClickMask());
			c.menuAction(digit, optW.getId(), net.runelite.api.MenuAction.WIDGET_CONTINUE, 0, -1, "Continue", "");
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.selectDialogueOptionNow", ignore);
		}
	}

	/** The widget a dialogue tap resolved to, and the op to fire on it. */
	private static final class DialogueTarget
	{
		private Widget w;
		private boolean dynamic;   // came from the dynamic children, so the engine addresses it by index
		private int op;
		private String action = "";
		private int area = Integer.MAX_VALUE;
	}

	private static final Widget[] NO_KIDS = new Widget[0];

	/**
	 * Press the open dialogue's own widget under a canvas point -- the answer for every box that has no modelled
	 * continue or option row, which is every box the chatbox attachment finds and a name does not.
	 *
	 * <p>Takes the SMALLEST widget whose bounds hold the point and that carries a named op. Smallest, because a
	 * button sits inside the box's own full-size background and the background is not what the finger pressed;
	 * named, because a widget with no op name has no menu entry a player could click either. Two candidates of
	 * EQUAL area are resolved to the one visited last, which is the later entry in a child array -- the one the
	 * engine draws on top, so the one the finger landed on. That is as far as draw order can be established from
	 * the widget API; declining an overlap instead would leave a Yes with nothing behind the tap at all, which
	 * on a quest prompt is worse than taking the topmost.
	 *
	 * <p>Visibility is judged INSIDE the box only: a candidate is rejected if its own hidden flag is set, or if
	 * anything between it and the box's root has one, so an invisible button cannot be pressed. What is NOT
	 * consulted is {@link Widget#isHidden()}, which walks the chatbox ancestry above the box -- and that reads
	 * hidden for a dialogue plainly on screen (the modelled continue does, which is the whole reason a click
	 * never reaches one), so judging by it would reject every button in every box.
	 *
	 * <p>The press goes out as the engine's own CC_OP menu action, the proven path for every relocated widget
	 * here (the tab stones, the logout button), with param0 following the dispatch rule those established: -1
	 * for a static component, the child index for a dynamic one. A miss logs what IS under the finger, so a box
	 * that answers to something else arrives already described instead of needing another report.
	 */
	private static void tapDialogueNow(Client c, int tappedGroup, int ageTicks, int x, int y)
	{
		try
		{
			if (ageTicks > MAX_TAP_AGE_TICKS)
			{
				// Older than the tick after the one it was taken on, so the engine has run on without it: a
				// loading screen, a world hop, a frame that threw. Whatever is open now, the finger was not on it.
				log.info("[veneer] dialogue tap {},{} — dropped: {} ticks stale", x, y, ageTicks);
				return;
			}
			final int group = chatPromptOpen ? InterfaceID.CHATBOX : chatboxSubInterface(c);
			if (group != tappedGroup)
			{
				// The box the finger was on is not the box that is open now. Answering this one with that tap
				// would speak for the player in a conversation they never saw.
				log.info("[veneer] dialogue tap {},{} — dropped: tapped group={} open group={}",
					x, y, tappedGroup, group);
				return;
			}
			// The prompt's list lives in the chatbox's own message layer, not in a group of its own. Walking it
			// here is what makes a result pickable while the GE window is drawn on top: this fires the row's own
			// CC_OP, so the engine never hit-tests the point and draw order cannot swallow the pick.
			final Widget root = group == InterfaceID.CHATBOX
				? c.getWidget(InterfaceID.Chatbox.MES_LAYER)
				: c.getWidget(group << 16);
			if (root == null)
			{
				log.info("[veneer] dialogue tap {},{} — group={} has no root component", x, y, group);
				return;
			}
			final DialogueTarget best = new DialogueTarget();
			findDialogueOp(root, false, false, x, y, best, 0);
			if (best.w == null)
			{
				final StringBuilder under = new StringBuilder();
				describeUnder(root, x, y, under, 0);
				log.info("[veneer] dialogue tap {},{} group={} — nothing pressable; under the finger:{}",
					x, y, group, under.length() == 0 ? " (nothing)" : under.toString());
				return;
			}
			final int param0 = best.dynamic ? best.w.getIndex() : -1;
			log.info("[veneer] dialogue tap {},{} group={} — fire id={} param0={} op={} action={}",
				x, y, group, best.w.getId(), param0, best.op, best.action);
			c.menuAction(param0, best.w.getId(), net.runelite.api.MenuAction.CC_OP, best.op, -1, best.action, "");
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.tapDialogueNow", ex);
		}
	}

	/**
	 * Walk an open dialogue for the smallest op-carrying widget holding the point. The walk does NOT stop at a
	 * parent whose bounds miss the point: a layer that holds the buttons can itself report no size at all, and
	 * gating the descent on it finds nothing. Depth-capped because this runs on the client thread, where a tree
	 * that somehow refers back to itself would take the game down with it rather than just miss a tap.
	 */
	private static void findDialogueOp(Widget w, boolean dynamic, boolean hiddenAbove, int x, int y,
		DialogueTarget best, int depth)
	{
		if (w == null || depth > MAX_DIALOGUE_DEPTH)
		{
			return;
		}
		// Concealed by its own flag or by something above it inside the box: not pressable, but still walked --
		// a layer flagged hidden can hold the visible button, and the miss log should still describe what is here.
		final boolean concealed = hiddenAbove || w.isSelfHidden();
		final int[] b = canvasBounds(w);
		if (!concealed && b != null && x >= b[0] && x < b[0] + b[2] && y >= b[1] && y < b[1] + b[3])
		{
			final int area = b[2] * b[3];
			if (area <= best.area)
			{
				final String[] acts = w.getActions();
				final int op = firstNamedOp(acts);
				if (op > 0)
				{
					best.w = w;
					best.dynamic = dynamic;
					best.op = op;
					best.action = acts[op - 1];
					best.area = area;
				}
			}
		}
		for (final Widget k : kidsOf(w.getStaticChildren()))
		{
			findDialogueOp(k, false, concealed, x, y, best, depth + 1);
		}
		for (final Widget k : kidsOf(w.getNestedChildren()))
		{
			findDialogueOp(k, false, concealed, x, y, best, depth + 1);
		}
		for (final Widget k : kidsOf(w.getDynamicChildren()))
		{
			findDialogueOp(k, true, concealed, x, y, best, depth + 1);
		}
	}

	/** Everything under the finger, for the miss log: enough per widget to decide what a box answers to. */
	private static void describeUnder(Widget w, int x, int y, StringBuilder out, int depth)
	{
		if (w == null || depth > MAX_DIALOGUE_DEPTH || out.length() > 1200)
		{
			return;
		}
		final int[] b = canvasBounds(w);
		if (b != null && x >= b[0] && x < b[0] + b[2] && y >= b[1] && y < b[1] + b[3])
		{
			out.append(" [id=").append(w.getId()).append(" idx=").append(w.getIndex())
				.append(" ").append(b[2]).append('x').append(b[3])
				.append(" hidden=").append(w.isHidden()).append('/').append(w.isSelfHidden())
				.append(" mask=").append(w.getClickMask())
				.append(" onOp=").append(w.getOnOpListener() != null)
				.append(" acts=").append(actionsOf(w))
				.append(" text=").append(wText(w)).append(']');
		}
		for (final Widget k : kidsOf(w.getStaticChildren()))
		{
			describeUnder(k, x, y, out, depth + 1);
		}
		for (final Widget k : kidsOf(w.getNestedChildren()))
		{
			describeUnder(k, x, y, out, depth + 1);
		}
		for (final Widget k : kidsOf(w.getDynamicChildren()))
		{
			describeUnder(k, x, y, out, depth + 1);
		}
	}

	/** A dialogue's own tree is a handful of levels; this is a guard against a cycle, not a real limit. */
	private static final int MAX_DIALOGUE_DEPTH = 8;

	/** The 1-based op index of the widget's first NAMED action, or 0 if it carries none. */
	private static int firstNamedOp(String[] actions)
	{
		if (actions == null)
		{
			return 0;
		}
		for (int i = 0; i < actions.length; i++)
		{
			if (actions[i] != null && !actions[i].isEmpty())
			{
				return i + 1;
			}
		}
		return 0;
	}

	/** The widget's named actions, as {@code op:name} pairs, for the miss log. */
	private static String actionsOf(Widget w)
	{
		final String[] a = w.getActions();
		if (a == null)
		{
			return "-";
		}
		final StringBuilder sb = new StringBuilder();
		for (int i = 0; i < a.length; i++)
		{
			if (a[i] != null && !a[i].isEmpty())
			{
				sb.append(sb.length() == 0 ? "" : ",").append(i + 1).append(':').append(a[i]);
			}
		}
		return sb.length() == 0 ? "-" : sb.toString();
	}

	private static Widget[] kidsOf(Widget[] kids)
	{
		return kids == null ? NO_KIDS : kids;
	}

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
	 *  orbs. The size-only path is kept here for reference. Native-HUD layout is Resizable - Modern (PreEoc 164) only. */
	private static void applyMinimapScale(Client c, boolean preEoc, int scalePct)
	{
		if (!preEoc)
		{
			return;   // the native HUD veneer only supports the Resizable - Modern layout
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
	 *  doesn't also zoom. While a prompt lists its results (the GE item search) the finger is on that list, so it
	 *  is the list that scrolls, through its own scrollbar the same way. Client thread. */
	static void applyChatScroll(Client c, int delta, boolean promptOpen)
	{
		try
		{
			if (promptOpen && promptListsResults(c))
			{
				scrollLayerBy(c, InterfaceID.Chatbox.MES_LAYER_SCROLLBAR, InterfaceID.Chatbox.MES_LAYER_SCROLLCONTENTS,
					delta);
				return;
			}
			scrollLayerBy(c, InterfaceID.Chatbox.CHATSCROLLBAR, InterfaceID.Chatbox.SCROLLAREA, delta);
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.applyChatScroll", ignore);
		}
	}

	/** Move one scroll layer by {@code delta} canvas px, clamped to its content, through its scrollbar. */
	private static void scrollLayerBy(Client c, int barId, int areaId, int delta)
	{
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
				.append(",\"rowH\":").append(OFFICIAL_ROW_BOTTOM);
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
				// A prompt is BOTH, now that the window steps aside for it: active, so taps over the chat region
				// route to the engine and the chat-line veneer gets out of the way; and engine-drawn, so the
				// native parchment stays hidden instead of covering the result grid with a text copy of it. The
				// rows published below stay live either way -- both shells keep their tap targets current while
				// the engine owns the drawing, which is exactly this case.
				.append(",\"dialogueActive\":").append(dialogueOpen || chatPromptOpen)
				.append(",\"engineDialogue\":").append(dialogueOpen || chatPromptOpen)
				// Native-side this means one thing: hide the chat TAB ROW. A prompt wants that too — the row sits
				// in the chat region and the player is answering the game, not picking a chat channel.
				.append(",\"windowOpen\":").append(chatWindowOccluded || chatPromptOpen);
			if (dialogueOpen || chatPromptOpen)
			{
				// Canvas-px bounds of the open dialogue so the native shell can route a tap there through a PRECISE
				// click (resolving the dialogue's Continue/option) instead of walking the world behind it.
				final int[] dr = HudStrip.toShown(dialogueBounds(c));
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
	static int tabSpriteId(int slot)
	{
		if (slot == 0) return SPR_STONE_INACTIVE;
		if (slot == 1) return SPR_STONE_ACTIVE;
		if (slot >= 2 && slot <= 15) return SPR_TAB_ICONS[slot - 2];
		if (slot == 16) return SPR_MCHATBTN_IDLE;
		if (slot == 17) return SPR_MCHATBTN_SELECTED;
		if (slot == 18) return SPR_MCHATBTN_NEW;
		if (slot == 19) return SPR_DOOR_STONE;
		if (slot == 20) return SPR_DOOR_STONE_ACTIVE;
		if (slot == 21) return SPR_SHOW_LESS;
		if (slot == 22) return SPR_SHOW_MORE;
		if (slot == 23) return SPR_CHAT_STONE_OPEN;
		if (slot == 24) return SPR_CHAT_TOGGLE;
		if (slot == 25) return SPR_KEYBOARD;
		return SPR_TAB_FRAME[slot - SLOT_FRAME];   // slots 26..34
	}

	/** The sprites the chrome can't draw without: everything but the chat stones, which the engine draws itself. */
	private static boolean gridSlot(int slot)
	{
		return slot <= 15 || slot >= 19;
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
			// Grid needs every gridSlot; chat (16..18) is secondary. Ship at the deadline regardless so a sprite that
			// genuinely never resolves can't stall the chrome forever.
			boolean gridComplete = true;
			for (int slot = 0; slot < TAB_SPRITE_COUNT; slot++)
			{
				if (gridSlot(slot) && tabSpriteB64[slot] == null)
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
			sb.append("\"v\":").append(TAB_SPRITES_VERSION).append(',');
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
			for (int slot = 19; slot < SLOT_FRAME; slot++)
			{
				sb.append(',');
				appendSpriteSlot(sb, TAB_SPRITE_KEYS[slot], slot);
			}
			sb.append(",\"frame\":[");
			for (int slot = SLOT_FRAME; slot < TAB_SPRITE_COUNT; slot++)
			{
				if (slot > SLOT_FRAME)
				{
					sb.append(',');
				}
				appendSpriteObjSlot(sb, slot);
			}
			sb.append("]}");
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

	/** {@code {"w":W,"h":H,"ox":X,"oy":Y,"bw":BW,"bh":BH,"px":"<base64 ARGB>"}} (or {@code null}) from an
	 *  accumulated slot: the pixels are W x H and sit at (X, Y) in the sprite's BW x BH box. */
	private static void appendSpriteObjSlot(StringBuilder sb, int slot)
	{
		final String px = tabSpriteB64[slot];
		if (px == null)
		{
			sb.append("null");
			return;
		}
		final int[] d = tabSpriteDim[slot];
		sb.append("{\"w\":").append(d[0]).append(",\"h\":").append(d[1])
			.append(",\"ox\":").append(d[2]).append(",\"oy\":").append(d[3])
			.append(",\"bw\":").append(d[4]).append(",\"bh\":").append(d[5])
			.append(",\"px\":\"").append(px).append("\"}");
	}

	/** Base64 of {@code spriteId}'s pixels as big-endian ARGB bytes; sets {@code dim=[w,h,offsetX,offsetY,boxW,boxH]}.
	 *  {@code null} if absent. */
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
		dim[2] = sp[0].getOffsetX();
		dim[3] = sp[0].getOffsetY();
		dim[4] = Math.max(sp[0].getMaxWidth(), w);
		dim[5] = Math.max(sp[0].getMaxHeight(), h);
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
		final int[] b = HudStrip.toShown(canvasBounds(btn));
		final int spr = gfx == null ? -1 : safeSpriteId(gfx);
		sb.append("{\"name\":\"").append(name).append('"')
			.append(",\"x\":").append(b == null ? -1 : b[0])
			.append(",\"y\":").append(b == null ? -1 : b[1])
			.append(",\"w\":").append(b == null ? 0 : b[2])
			.append(",\"h\":").append(b == null ? 0 : b[3])
			.append(",\"sprite\":").append(spr)
			.append(",\"selected\":").append(spr == SPR_CHATBTN_SELECTED || spr == SPR_MCHATBTN_SELECTED)
			.append(",\"new\":").append(spr == SPR_CHATBTN_NEW || spr == SPR_MCHATBTN_NEW)
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

	// The chat as the official mobile app lays it out (scripts 113, 178 and 923 when the toplevel is 601), in px
	// relative to the chat container, which sits right of the shells' 58-px column (door, speech bubbles, keyboard).
	// The filter row is the 519-px chat less that column, 2 px down; its seven 58x24 stones are 65 px apart from 7 px
	// in, and Report has no stone (the speech bubbles carry its options). The message display is 457 px wide, 2 px
	// in, with its scrollbar on the left: 923's layout with CHATBOX_SCROLLBARSIDE set, which is what the official
	// app shows. The scroll area is 16 px narrower than the display and right-aligned 1 px in.
	static final int OFFICIAL_ROW_W = 461;
	static final int OFFICIAL_ROW_Y = 2;
	static final int OFFICIAL_ROW_H = 28;
	// The whole chat is 145 px tall (the desktop's 165 less 20), and the message area fills it below the row.
	static final int OFFICIAL_CHAT_H = 145;
	static final int OFFICIAL_ROW_BOTTOM = OFFICIAL_ROW_Y + OFFICIAL_ROW_H;
	// The shells' column left of the chat (601's SIDE_LEFT_CHAT): 4 px down, 118 px tall with the keyboard stone,
	// 79 without it (the chat is hidden).
	static final int OFFICIAL_COLUMN_Y = 4;
	static final int OFFICIAL_COLUMN_W = 58;
	static final int OFFICIAL_COLUMN_H = 118;
	static final int OFFICIAL_COLUMN_H_HIDDEN = 79;
	static final int OFFICIAL_TAB_X = 7;
	static final int OFFICIAL_TAB_PITCH = 65;
	static final int OFFICIAL_TAB_W = 58;
	private static final int OFFICIAL_TAB_GFX_H = 24;
	private static final int OFFICIAL_DISPLAY_X = 2;
	private static final int OFFICIAL_DISPLAY_INSET = 4;   // 457 of the 461
	private static final int OFFICIAL_SCROLLAREA_X = 15;   // right-aligned 1 px in, 16 px narrower than the display
	// A pixel left of the display. A forced position can't say -1 (it means "none"), so this one is the widget's own.
	static final int OFFICIAL_SCROLLBAR_X = -1;
	private static final int CHAT_FILTER_TABS = 7;   // CHAT_TAB_IDS less Report
	private static final Pin[] CHAT_TAB_PINS = new Pin[CHAT_FILTER_TABS];
	private static final Pin CHATDISPLAY_PIN = new Pin("chat display");
	private static final Pin SCROLLAREA_PIN = new Pin("chat scroll area");

	static
	{
		for (int i = 0; i < CHAT_FILTER_TABS; i++)
		{
			CHAT_TAB_PINS[i] = new Pin("chat tab " + i);
		}
	}

	/** The mobile stone script 178 would draw for a desktop chat stone; {@code spriteId} itself if it isn't one. */
	static int officialChatStone(int spriteId)
	{
		switch (spriteId)
		{
			case SPR_CHATBTN_IDLE:
			case SPR_CHATBTN_HOVER:
				return SPR_MCHATBTN_IDLE;
			case SPR_CHATBTN_SELECTED:
			case SPR_CHATBTN_SELECTED_HOVER:
				return SPR_MCHATBTN_SELECTED;
			case SPR_CHATBTN_NEW:
				return SPR_MCHATBTN_NEW;
			default:
				return spriteId;
		}
	}

	/**
	 * Lay the engine chat out the way the official mobile app does (see OFFICIAL_ROW_W). The desktop scripts re-lay
	 * it on every chatbox rebuild, so this runs every frame: each write is skipped when the widget already has it.
	 * A chat put away (setChatPutAway) loses its filter row too; a collapsed one keeps it. Client thread.
	 */
	static void layOfficialChat(Client c)
	{
		try
		{
			final Widget row = c.getWidget(InterfaceID.Chatbox.CONTROLS);
			if (row == null)
			{
				return;
			}
			if (row.isHidden() != chatPutAway)
			{
				row.setHidden(chatPutAway);
			}
			CONTROLS_PIN.apply(row, 0, OFFICIAL_ROW_Y, sizeAbsolute(row, OFFICIAL_ROW_W, OFFICIAL_ROW_H));
			for (int i = 0; i < CHAT_FILTER_TABS; i++)
			{
				final int base = CHAT_TAB_IDS[i];
				final Widget tab = c.getWidget(base);
				final Widget gfx = c.getWidget(base + 1);
				if (tab == null || gfx == null)
				{
					continue;
				}
				boolean relayout = sizeAbsolute(tab, OFFICIAL_TAB_W, OFFICIAL_ROW_H);
				if (sizeAbsolute(gfx, OFFICIAL_TAB_W, OFFICIAL_TAB_GFX_H))
				{
					relayout = true;
				}
				final int stone = officialChatStone(gfx.getSpriteId());
				if (stone != gfx.getSpriteId())
				{
					gfx.setSpriteId(stone);
				}
				CHAT_TAB_PINS[i].apply(tab, OFFICIAL_TAB_X + i * OFFICIAL_TAB_PITCH, 0, relayout);
			}
			hide(c, InterfaceID.Chatbox.REPORTABUSE);
			final Widget display = c.getWidget(InterfaceID.Chatbox.CHATDISPLAY);
			if (display != null)
			{
				final int displayW = chatWidth() - OFFICIAL_DISPLAY_INSET;
				final boolean resized = display.getWidthMode() != WidgetSizeMode.ABSOLUTE
					|| display.getOriginalWidth() != displayW
					|| display.getHeightMode() != WidgetSizeMode.MINUS || display.getOriginalHeight() != 0;
				if (resized)
				{
					display.setWidthMode(WidgetSizeMode.ABSOLUTE);
					display.setOriginalWidth(displayW);
					display.setHeightMode(WidgetSizeMode.MINUS);
					display.setOriginalHeight(0);
				}
				CHATDISPLAY_PIN.apply(display, OFFICIAL_DISPLAY_X, 0, resized);
				if (resized)
				{
					// Its input line and scroll area are sized from it, and the pin re-lays only the display.
					display.revalidateScroll();
				}
			}
			forcePos(c, SCROLLAREA_PIN, InterfaceID.Chatbox.SCROLLAREA, OFFICIAL_SCROLLAREA_X, 0);
			final Widget bar = c.getWidget(InterfaceID.Chatbox.CHATSCROLLBAR);
			if (bar != null && (bar.getXPositionMode() != WidgetPositionMode.ABSOLUTE_LEFT
				|| bar.getOriginalX() != OFFICIAL_SCROLLBAR_X))
			{
				bar.setXPositionMode(WidgetPositionMode.ABSOLUTE_LEFT);
				bar.setOriginalX(OFFICIAL_SCROLLBAR_X);
				bar.revalidate();
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.layOfficialChat", ignore);
		}
	}

	/** Give {@code w} an absolute {@code width} x {@code height} unless it has one; true if it changed. */
	private static boolean sizeAbsolute(Widget w, int width, int height)
	{
		if (w.getWidthMode() == WidgetSizeMode.ABSOLUTE && w.getOriginalWidth() == width
			&& w.getHeightMode() == WidgetSizeMode.ABSOLUTE && w.getOriginalHeight() == height)
		{
			return false;
		}
		w.setWidthMode(WidgetSizeMode.ABSOLUTE);
		w.setOriginalWidth(width);
		w.setHeightMode(WidgetSizeMode.ABSOLUTE);
		w.setOriginalHeight(height);
		return true;
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

	/**
	 * Where one relocated widget was last forced to, so pinning it on the next frame costs a compare instead of a
	 * re-layout. {@code revalidate()} re-lays the widget's whole subtree, and the chat, minimap and side containers
	 * each took one every frame to survive an interface rebuild that happens a few times a minute.
	 *
	 * <p>The forced position lives on the widget object and survives the engine's own re-layouts. It is lost when
	 * the engine rebuilds the interface, which hands back a new object, or when something clears it (WidgetOverlay's
	 * overlay reset forces (-1, -1) and revalidates); a cleared one shows as a live position that is no longer the
	 * pinned one. Either way the next frame re-pins, which is the same one frame the old per-frame force took to
	 * catch a rebuild, since tick() runs after the frame has rastered. Client thread.
	 */
	static final class Pin
	{
		private final String name;
		private Widget widget;
		private int x;
		private int y;
		private int count;

		Pin(String name)
		{
			this.name = name;
		}

		/** Force {@code w} to ({@code x}, {@code y}) and revalidate it, unless it is already pinned there and sits
		 *  there; {@code relayout} revalidates regardless, for a caller that has just changed the widget's size. */
		boolean apply(Widget w, int x, int y, boolean relayout)
		{
			final String why = w != widget ? "new widget" : x != this.x || y != this.y ? "new target"
				: w.getRelativeX() != x || w.getRelativeY() != y ? "moved" : relayout ? "relayout" : null;
			if (why == null)
			{
				return false;
			}
			w.setForcedPosition(x, y);
			w.revalidate();
			widget = w;
			this.x = x;
			this.y = y;
			// A pin that fires every frame would show here as a line every ~10 s; a healthy one goes quiet.
			if (++count <= 5 || count % 500 == 0)
			{
				log.info("[veneer] pin {} at ({},{}): {} (pin #{})", name, x, y, why, count);
			}
			return true;
		}
	}

	private static final Pin CHAT_PIN = new Pin("chat");
	private static final Pin CONTROLS_PIN = new Pin("chat tabs");
	private static final Pin CHATAREA_PIN = new Pin("chat area");
	// The chatbox build script ran (a new message, a tab switch) since the chat area was last sized. It may have
	// rebuilt the area's children, which the pin alone wouldn't re-lay, so the next sizing does. Client thread.
	private static boolean chatRebuilt;
	private static final Pin MAP_PIN = new Pin("minimap");
	private static final Pin SIDE_PIN = new Pin("side panel");

	private static void forcePos(Client c, Pin pin, int id, int x, int y)
	{
		try
		{
			final Widget w = c.getWidget(id);
			if (w != null)
			{
				pin.apply(w, x, y, false);
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
				// The "<player>: <typed>*" line has its own build script, which picks its colours (light with a shadow
				// over the scene) only when it runs: on the next keystroke, otherwise.
				try { c.runScript(ScriptID.CHAT_PROMPT_INIT); } catch (RuntimeException ignore) { BridgeFaults.note("HudVeneerBridge.chatPromptInit", ignore); }
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
	 *  message, a level-up, a make-X/quantity selector, an item-reward box, or a box only the content that opened
	 *  it has a name for? The named kinds are read off their content widget (loaded + shown), mirroring the
	 *  in-tree dialogue plugins' detection; {@link #chatboxSubInterface} answers for the rest. */
	/**
	 * Whether the engine is driving the chatbox MESSAGE LAYER — the Grand Exchange item search, the bank
	 * search, and every "Enter amount" / "Enter name" prompt. {@code MESLAYERMODE} is the engine's own flag
	 * for it (the varc the legacy API calls {@code VarClientInt.INPUT_TYPE}), so this is engine truth rather
	 * than a widget guess: it is set for the whole life of the prompt and cleared when it commits or cancels.
	 *
	 * <p>It matters because the prompt is drawn INTO the chatbox container, which the forefront-window rule
	 * below otherwise hides — and a hidden container neither draws nor hit-tests. Typing the normal chat line
	 * does not set it (that is {@code CHATINPUT}), and neither does the world-map search.
	 */
	/**
	 * True when the open prompt draws its ANSWER as a list in the message layer — the GE item search, whose
	 * results upstream reads straight out of this widget (3 children per row). A bank search is the opposite:
	 * it filters the bank items themselves and puts no list here, which is what keeps the bank on screen.
	 */
	private static boolean promptListsResults(Client c)
	{
		try
		{
			final Widget w = c.getWidget(InterfaceID.Chatbox.MES_LAYER_SCROLLCONTENTS);
			if (w == null || w.isHidden())
			{
				return false;
			}
			final Widget[] rows = w.getDynamicChildren();
			return rows != null && rows.length > 0;
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.promptListsResults", ignore);
			return false;
		}
	}
	private static boolean isChatPromptOpen(Client c)
	{
		try
		{
			return c.getVarcIntValue(VarClientID.MESLAYERMODE) != 0;
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.isChatPromptOpen", ignore);
			return false;
		}
	}

	private static boolean isDialogueOpen(Client c)
	{
		// MODELLED: the kinds computeDialogueJson publishes a type for, so the shell drives them through
		// continueDialogue / selectDialogueOption. -1 keeps tapDialogue off them -- a point fired at a chat
		// dialogue would press whatever its CONTINUE happens to sit under.
		final boolean modelled = widgetShown(c, InterfaceID.ChatLeft.TEXT) // NPC dialogue
			|| widgetShown(c, InterfaceID.ChatRight.TEXT)       // player dialogue
			|| widgetShown(c, InterfaceID.ChatBoth.TEXT)        // combined NPC+player dialogue
			|| widgetShown(c, InterfaceID.Chatmenu.OPTIONS)     // "Select an Option"
			|| widgetShown(c, InterfaceID.Messagebox.TEXT)      // "click here to continue"
			|| widgetShown(c, InterfaceID.LevelupDisplay.CONTINUE); // level-up
		if (modelled)
		{
			noteEngineOwnedDialogue(-1);
			return true;
		}
		// Everything else that has taken over the chatbox is ENGINE-OWNED, whether or not we have a name for
		// it. make-X / quantity and the two reward boxes USED to be named here, and being named was taken to
		// mean the shell could drive them -- it cannot: computeDialogueJson models none of the three, so it
		// publishes "{}", the shell reads "no modelled targets" and routes the tap to tapDialogue, and
		// tapDialogue then dropped it against the -1 this branch had stamped. Tappable by neither path: the
		// tap was consumed (no click-through -- the half that looked fixed) and nothing was pressed. Their
		// buttons are their own components, the same shape as a quest's confirm box and exactly what
		// tapDialogue exists to press, so they stamp their group like any box we cannot name. Having a name
		// for a box was never a reason to refuse to press it.
		final int sub = chatboxSubInterface(c);
		noteEngineOwnedDialogue(sub);
		// NOTE: a message-layer prompt (GE/bank search, "Enter amount") is deliberately NOT a dialogue here.
		// This flag means "a separate interface has replaced the chat lines", and the tick then stops laying out
		// the chat area (sizeChatArea), which a prompt needs: it lives INSIDE the chat area, laid from its top.
		// The prompt is tracked separately as chatPromptOpen; see the tick.
		if (sub >= 0)
		{
			return true;
		}
		// A named engine-owned box the component table does not show as attached to the chatbox is still a
		// dialogue: it keeps the opacity and the chat hiding it has always driven. No tap can be routed to
		// one (there is no group to stamp), which is the state all three were already in -- not a new dead end.
		return widgetShown(c, InterfaceID.Skillmulti.TITLE)     // make-X / quantity
			|| widgetShown(c, InterfaceID.Objectbox.TEXT)       // single-item reward box
			|| widgetShown(c, InterfaceID.ObjectboxDouble.TEXT); // double-item reward box
	}

	/** The group of an interface the engine has opened ONTO THE CHATBOX, or -1 when there is none. That
	 *  attachment is what a chatbox dialogue IS — the engine opens the dialogue's own interface on a chatbox
	 *  component and the component table records it — so reading it answers for every dialogue, including the
	 *  ones a list of groups cannot name: a quest's own "do you wish to take one?" confirm box is as real a
	 *  dialogue as an NPC's, and one we don't recognise is not merely drawn wrong. It leaves the native tab row
	 *  over the box, the chat message area force-shown under it, and every tap on it routed to the chat veneer,
	 *  which answers with a click the dialogue never sees — the "I cannot tap Yes / No" report.
	 *  (The chatbox itself hangs off the TOPLEVEL, so it can never match its own test.) */
	private static int chatboxSubInterface(Client c)
	{
		try
		{
			final HashTable<WidgetNode> open = c.getComponentTable();
			if (open == null)
			{
				return -1;
			}
			for (final WidgetNode n : open)
			{
				// Keyed by the PARENT COMPONENT the interface was opened on (what getParentId returns for its
				// root); the dialogue kinds we already model all attach to a component of the chatbox group.
				if (n != null && (((int) n.getHash()) >>> 16) == InterfaceID.CHATBOX)
				{
					return n.getId();
				}
			}
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("HudVeneerBridge.chatboxSubInterface", ex);
		}
		return -1;
	}

	// The group of the ENGINE-OWNED box on the chatbox right now, or -1 while a modelled kind is open (or
	// nothing is). Not "unnamed": whether we have a name for a box says nothing about who owns its buttons,
	// and reading it as the same thing is what made make-X and the reward boxes untappable. One open writes
	// one line. Volatile: written here on the client thread, read by tapDialogue on the native one to stamp a
	// tap with the box the finger was actually on.
	private static volatile int lastEngineOwnedDialogueGroup = -1;

	/** Note the chatbox box whose own components are its buttons, once per open — the ones tapDialogue
	 *  resolves a point against. The line carries the interface group so the NEXT report about a box of this
	 *  shape arrives already identified rather than described. */
	private static void noteEngineOwnedDialogue(int group)
	{
		if (group == lastEngineOwnedDialogueGroup)
		{
			return;
		}
		lastEngineOwnedDialogueGroup = group;
		if (group >= 0)
		{
			log.info("[veneer] chatbox dialogue group={} — engine-drawn, engine-owned taps (resolved by point)", group);
		}
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
		// An unnamed kind: its root component (child 0) is the dialogue's rect, same as the UNIVERSE entries above.
		final int sub = chatboxSubInterface(c);
		if (sub >= 0 && widgetShown(c, sub << 16))
		{
			return canvasBounds(c.getWidget(sub << 16));
		}
		// A message-layer prompt (GE/bank search, "Enter amount") has no root of its own: MES_LAYER is its rect.
		return isChatPromptOpen(c) ? canvasBounds(c.getWidget(InterfaceID.Chatbox.MES_LAYER)) : null;
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
		if (chatPromptOpen)
		{
			return dlgPrompt(c);
		}
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
	/**
	 * How many search results to publish. These are TAP TARGETS, not drawn rows — the engine draws the list
	 * itself — and only the rows inside the list's window are published, so the limit is the engine's own
	 * visible grid (three columns) with room to spare, not what a panel could hold. Each row's bounds are
	 * republished every tick, so they follow the list as it scrolls.
	 */
	private static final int MAX_PROMPT_ROWS = 24;

	/**
	 * A message-layer prompt, published as an options box — which is what a search IS: a title, what has been
	 * typed so far, and a list of answers to pick from. Rendering it natively is what makes it usable at all:
	 * the engine draws it into the chat area UNDER the forefront window, and with the keyboard over the bottom
	 * of the screen there is nowhere to move the chat to. Every row carries its engine widget's canvas bounds,
	 * so a pick fires that row's own op through {@link #tapDialogueNow} rather than a click the window would
	 * swallow. The last row is the engine's own close button, so the search can be left without clicking away.
	 */
	private static String dlgPrompt(Client c)
	{
		final StringBuilder sb = new StringBuilder(768);
		sb.append("{\"type\":\"options\",\"prompt\":true");
		final String title = wText(c.getWidget(InterfaceID.Chatbox.MES_TEXT)).replaceAll("<[^>]*>", "");
		if (!title.isEmpty())
		{
			sb.append(",\"name\":\"").append(BridgeJson.escapedDropControls(title)).append('"');
		}
		// What the player has typed, straight off the engine's own input varc, with a caret so an empty search
		// still shows where the letters are going. Falls back to the engine's hint line before the first key.
		String typed = "";
		try
		{
			final String v = c.getVarcStrValue(VarClientID.MESLAYERINPUT);
			typed = v == null ? "" : v;
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.dlgPrompt.input", ignore);
		}
		final String second = typed.isEmpty()
			? wText(c.getWidget(InterfaceID.Chatbox.MES_TEXT2)).replaceAll("<[^>]*>", "")
			: typed + "*";
		if (!second.isEmpty())
		{
			sb.append(",\"title\":\"").append(BridgeJson.escapedDropControls(second)).append('"');
		}
		int rows = 0;
		Widget[] kids = null;
		int[] window = null;
		try
		{
			final Widget sc = c.getWidget(InterfaceID.Chatbox.MES_LAYER_SCROLLCONTENTS);
			kids = sc == null ? null : sc.getDynamicChildren();
			// The list's window: the rows the engine draws are the ones inside it. Published as "list" only while
			// the list holds more than fits, which is when a drag on it should scroll it.
			window = canvasBounds(sc);
			if (window != null && sc.getScrollHeight() > sc.getHeight())
			{
				appendBounds(sb, "list", window);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.dlgPrompt.rows", ignore);
		}
		sb.append(",\"options\":[");
		if (kids != null)
		{
			// Three children a row (upstream's GE search reads this same widget the same way); the middle one
			// carries the name. Its raw text keeps the fuzzy-match underline tags, which the runs render.
			// Complete triplets only, as upstream does with length/3: a trailing partial row has no name child
			// to read, and whatever sits at that index is not one. A row scrolled out of the window is skipped
			// and one half out is cut to the part on screen: the engine clips them there, so a target left
			// standing outside it would sit over the title and pick a result nobody can see.
			for (int i = 0; i + 2 < kids.length && rows < MAX_PROMPT_ROWS; i += 3)
			{
				final Widget nameW = kids[i + 1];
				final String txt = wText(nameW);
				final int[] b = visiblePart(canvasBounds(nameW), window);
				if (txt.isEmpty() || b == null)
				{
					continue;
				}
				if (rows > 0)
				{
					sb.append(',');
				}
				sb.append('{');
				appendTextWithRuns(sb, txt, CHAT_DEFAULT_COLOR);
				sb.append(",\"digit\":").append(rows);
				appendBounds(sb, "b", b);
				sb.append('}');
				rows++;
			}
		}
		final int[] close = canvasBounds(c.getWidget(InterfaceID.Chatbox.MES_LAYER_CLOSE));
		if (close != null)
		{
			if (rows > 0)
			{
				sb.append(',');
			}
			sb.append('{');
			appendTextWithRuns(sb, "Close", CHAT_DEFAULT_COLOR);
			sb.append(",\"digit\":").append(rows);
			appendBounds(sb, "b", close);
			sb.append('}');
		}
		sb.append("]}");
		return sb.toString();
	}

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
			sb.append(",\"digit\":").append(i);
			// The option row's own canvas bounds: the native shell clicks THIS widget for the row under the
			// finger, so a pick lands on the engine's live option instead of inert parchment.
			appendBounds(sb, "b", canvasBounds(k));
			sb.append('}');
		}
		sb.append("]}");
		return sb.toString();
	}

	/** Append {@code ,"key":{"x":,"y":,"w":,"h":}} for a canvas-px rect, or nothing when {@code b} is null. */
	/** The part of {@code b} inside {@code window}, or null when none of it is; {@code b} as-is with no window. */
	static int[] visiblePart(int[] b, int[] window)
	{
		if (b == null || window == null)
		{
			return b;
		}
		final int x0 = Math.max(b[0], window[0]);
		final int y0 = Math.max(b[1], window[1]);
		final int x1 = Math.min(b[0] + b[2], window[0] + window[2]);
		final int y1 = Math.min(b[1] + b[3], window[1] + window[3]);
		return x1 > x0 && y1 > y0 ? new int[]{x0, y0, x1 - x0, y1 - y0} : null;
	}

	private static void appendBounds(StringBuilder sb, String key, int[] b)
	{
		if (b == null)
		{
			return;
		}
		// Every rect published this way is one a shell draws or hit-tests in shown coordinates.
		b = HudStrip.toShown(b);
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

	/** Position + size the chatbox message area ({@code CHATAREA}) the way the official mobile app does (script
	 *  2581): the chat container is {@code OFFICIAL_CHAT_H} tall, and the area fills it below the filter row, or
	 *  all of it while a prompt is up (the prompt's box then covers the row, as it does there). Width is the native
	 *  chat width; the display inside it is laid by {@link #layOfficialChat}. */
	static void sizeChatArea(Client c, int containerId, int rowW, boolean promptOpen)
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
			// they should never be hidden. Not MES_LAYER: it holds a prompt (bank or GE search, "Enter amount"), the
			// game shows it for one and hides it again on close without clearing the text, so forcing it shown left
			// the last prompt painted over the chat for the rest of the session.
			setHidden(c, InterfaceID.Chatbox.CHATAREA, false);
			setHidden(c, InterfaceID.Chatbox.CHATDISPLAY, false);
			setHidden(c, InterfaceID.Chatbox.SCROLLAREA, false);
			// Keep the bottom input line ("<player>: <typed>*") shown — a chat rebuild can leave it hidden, which is
			// why it was missing from the relocated chat. The official mobile chat shows this prompt at the bottom.
			setHidden(c, InterfaceID.Chatbox.INPUT, false);
			setHidden(c, InterfaceID.Chatbox.INPUT_CLICKAREA, false);
			final Widget cont = c.getWidget(containerId);
			if (cont != null && (cont.getHeightMode() != WidgetSizeMode.ABSOLUTE || cont.getOriginalHeight() != OFFICIAL_CHAT_H))
			{
				cont.setHeightMode(WidgetSizeMode.ABSOLUTE);
				cont.setOriginalHeight(OFFICIAL_CHAT_H);
				cont.revalidate();
			}
			final int areaY = promptOpen ? 0 : OFFICIAL_ROW_BOTTOM;
			final int areaH = OFFICIAL_CHAT_H - areaY;
			final boolean resized = area.getWidthMode() != WidgetSizeMode.ABSOLUTE || area.getOriginalWidth() != rowW
				|| area.getHeightMode() != WidgetSizeMode.ABSOLUTE || area.getOriginalHeight() != areaH;
			if (resized)
			{
				area.setWidthMode(WidgetSizeMode.ABSOLUTE);
				area.setOriginalWidth(rowW);
				area.setHeightMode(WidgetSizeMode.ABSOLUTE);
				area.setOriginalHeight(areaH);
			}
			final boolean rebuilt = chatRebuilt;
			chatRebuilt = false;
			if (CHATAREA_PIN.apply(area, 0, areaY, resized || rebuilt))
			{
				// The pin re-lays only the area. The message display inside it (the lines, the "<player>: <typed>*"
				// input line under them, the scrollbar) would keep the desktop's 142-px area, which puts the input line
				// below the chat's bottom edge, where the container clips it away. Only that subtree: the prompt layer,
				// the area's other child, is laid by the game when it opens.
				final Widget messages = c.getWidget(InterfaceID.Chatbox.MES_LAYER_HIDE);
				if (messages != null)
				{
					messages.revalidateScroll();
				}
			}
			// The prompt layer doesn't follow the area's width on its own.
			if ((resized || rebuilt) && rowW > CHAT_DEFAULT_W)
			{
				forceWidth(c, InterfaceID.Chatbox.MES_LAYER, rowW - 14, 7);
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.sizeChatArea", ignore);
		}
	}

	/** A dialogue is mounted on CHATMODAL right now (the component table is keyed by the component an interface
	 *  is opened on). Client thread. */
	private static boolean chatModalMounted(Client c)
	{
		final HashTable<WidgetNode> mounts = c.getComponentTable();
		return mounts != null && mounts.get(InterfaceID.Chatbox.CHATMODAL) != null;
	}

	/**
	 * Centre the chat area on the visible chat while a dialogue is on it. Every chatbox dialogue is laid out for the
	 * desktop's 519-px chat area: CHATMODAL fills the area, the conversation pages centre a 479-px box in it, and
	 * the options menu sits at a fixed x of 20. The official layout's container is {@link #chatWidth()} wide (461)
	 * and clips the rest, so with the area at x=0 every dialogue lost its right 38 px (the player's head, the end
	 * of a long line or option) beside 20 px of empty box on the left. Script 113 puts the area back at (0,0),
	 * 519 wide, whenever the chatbox's sub-interface changes, i.e. on every page, and sizeChatArea, which lays it
	 * otherwise, is skipped under a dialogue. So the area keeps the width the dialogues expect and is shifted to
	 * centre on what can be seen; the box overhangs by 9 px a side, its own margin. The height stays the game's.
	 * Client thread.
	 */
	private static void fitDialogueArea(Client c)
	{
		try
		{
			final Widget area = c.getWidget(InterfaceID.Chatbox.CHATAREA);
			if (area == null)
			{
				return;
			}
			final boolean resized = area.getWidthMode() != WidgetSizeMode.ABSOLUTE
				|| area.getOriginalWidth() != CHAT_DEFAULT_W;
			if (resized)
			{
				area.setWidthMode(WidgetSizeMode.ABSOLUTE);
				area.setOriginalWidth(CHAT_DEFAULT_W);
			}
			// The shift is left, and the engine ignores a negative forced position (pinned at -29, the area stayed at
			// 0 and the pin re-fired every frame). So it goes through the original x, with the forced x that
			// CHATAREA_PIN holds at 0 cleared; the forced y stays. sizeChatArea's pin forces (0, y) again once the
			// dialogue closes, since the area changes size then.
			final int x = (chatWidth() - CHAT_DEFAULT_W) / 2;
			if (resized || area.getXPositionMode() != WidgetPositionMode.ABSOLUTE_LEFT || area.getOriginalX() != x
				|| area.getRelativeX() != x)
			{
				area.setXPositionMode(WidgetPositionMode.ABSOLUTE_LEFT);
				area.setOriginalX(x);
				area.setForcedPosition(-1, OFFICIAL_ROW_BOTTOM);
				area.revalidate();
				if (resized)
				{
					// revalidate() lays the area alone; a new width has to reach the box, CHATMODAL and the dialogue.
					area.revalidateScroll();
				}
			}
		}
		catch (RuntimeException ignore)
		{
			BridgeFaults.note("HudVeneerBridge.fitDialogueArea", ignore);
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
