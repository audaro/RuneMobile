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
import java.util.Collections;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.HashTable;
import net.runelite.api.MenuAction;
import net.runelite.api.ScriptID;
import net.runelite.api.WidgetNode;
import net.runelite.api.events.ScriptPostFired;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.gameval.VarbitID;
import net.runelite.api.widgets.Widget;
import net.runelite.api.widgets.WidgetPositionMode;
import net.runelite.api.widgets.WidgetSizeMode;
import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import org.junit.Before;
import org.junit.Test;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for two pieces of {@link HudVeneerBridge} that both ports depend on.
 *
 * <p>The overlay snap-corner safe-frame geometry — the rect the native shells use to keep RuneLite overlays
 * clear of the relocated chat box. The math is pure (native pushes the chat position/size via setters; no
 * engine read), and a wrong rect silently lets overlays render under the chat on both ports. Covered: the
 * {@code chatX < 0} "not relocating" null guard, the width fallback (the official 461), and the height in each
 * state: open = the official 145-px chat; collapsed = the shells' 118-px column (4 px down), which runs deeper than
 * the filter row left showing; put away = the 79-px column without its keyboard stone.
 *
 * <p>And the snapshot's {@code dialogueActive} bit, which decides whether the chatbox region belongs to the
 * chat veneer or to the dialogue drawn over it — a miss there costs the user the dialogue's buttons.
 *
 * <p>{@code ENABLED} is read once at class load from {@code -Drunelite.hudveneer}; set in the static
 * initialiser before the class loads (reliable — no other module test references the headless bridges).
 * The chat geometry is shared static state, so every test sets the full state it needs (it never relies on
 * a default left by another test).
 */
public class HudVeneerBridgeTest
{
	static
	{
		System.setProperty("runelite.hudveneer", "true");
	}

	// Mirrors of the official mobile layout's numbers (scripts 113/2581, interface 601), which the rect math is built on.
	private static final int OFFICIAL_CHAT_W = 461;
	private static final int OFFICIAL_CHAT_H = 145;
	private static final int OFFICIAL_ROW_BOTTOM = 30;
	private static final int OFFICIAL_COLUMN_BOTTOM = 4 + 118;
	private static final int OFFICIAL_COLUMN_BOTTOM_PUT_AWAY = 4 + 79;

	/**
	 * Full reset of the shared static chat geometry before each test, so the suite is order-independent
	 * regardless of how JUnit sequences the methods. Tests still set the specific state they assert on; this
	 * is the safety net so a value left by one test can never leak into the next.
	 */
	@Before
	public void resetState()
	{
		HudVeneerBridge.relocateChat(-1, -1, false);   // chatX < 0 = not relocating
		HudVeneerBridge.setChatAreaWidth(0);            // 0 = fall back to the official width
		HudVeneerBridge.setChatCollapsed(false);
		HudVeneerBridge.setChatPutAway(false);
		HudVeneerBridge.relocateSidePanel(-1, -1);
		HudVeneerBridge.setStonesHidden(false);
		GameLayoutSwitch.resetForTest();               // tick() runs the layout switch too
		// Shared static: drop any world-map HUD hide or stone-row hide a previous test left standing (every
		// widget read comes back null, so the map reads closed and the restores run against nothing).
		HudVeneerBridge.preRender(loggedInClientWith(null));
	}

	@Test
	public void enabledFlagIsSet()
	{
		assertTrue("runelite.hudveneer must be enabled before HudVeneerBridge loads", HudVeneerBridge.isEnabled());
	}

	@Test
	public void overlaySafeInsetsRoundTrip()
	{
		HudVeneerBridge.setOverlaySafeInsets(1, 2, 3, 4);
		assertArrayEquals(new int[]{1, 2, 3, 4}, HudVeneerBridge.getOverlayInsets());
	}

	@Test
	public void chatAvoidIsNullWhenNotRelocating()
	{
		HudVeneerBridge.relocateChat(-1, -1, false);   // x < 0 = veneer is not relocating the chat
		assertNull("no avoidance rect when the veneer isn't moving the chat", HudVeneerBridge.getOverlayChatAvoid());
	}

	@Test
	public void chatAvoidOpenIsTheOfficialChat()
	{
		HudVeneerBridge.setChatAreaWidth(0);
		HudVeneerBridge.setChatCollapsed(false);
		HudVeneerBridge.relocateChat(10, 20, false);

		assertArrayEquals(new int[]{10, 20, OFFICIAL_CHAT_W, OFFICIAL_CHAT_H}, HudVeneerBridge.getOverlayChatAvoid());
	}

	@Test
	public void chatAvoidCollapsedIsTheColumnBesideIt()
	{
		HudVeneerBridge.setChatCollapsed(true);        // width left at the @Before default (0)
		HudVeneerBridge.relocateChat(10, 20, false);

		// Collapsed: only the filter row is left of the chat, and the column beside it runs deeper.
		assertArrayEquals(new int[]{10, 20, OFFICIAL_CHAT_W, OFFICIAL_COLUMN_BOTTOM}, HudVeneerBridge.getOverlayChatAvoid());
	}

	@Test
	public void chatAvoidPutAwayIsTheShortColumn()
	{
		HudVeneerBridge.setChatPutAway(true);
		HudVeneerBridge.relocateChat(10, 20, false);

		assertArrayEquals(new int[]{10, 20, OFFICIAL_CHAT_W, OFFICIAL_COLUMN_BOTTOM_PUT_AWAY},
			HudVeneerBridge.getOverlayChatAvoid());
	}

	@Test
	public void chatAvoidHonoursProvidedWidth()
	{
		HudVeneerBridge.setChatAreaWidth(600);
		HudVeneerBridge.setChatCollapsed(false);
		HudVeneerBridge.relocateChat(5, 6, false);

		assertArrayEquals(new int[]{5, 6, 600, OFFICIAL_CHAT_H}, HudVeneerBridge.getOverlayChatAvoid());
	}

	// --- dialogue detection -------------------------------------------------------------------------------
	// A chatbox dialogue is not a fixed list of interface groups: it is whatever the engine has opened ONTO
	// THE CHATBOX. Content opens its own boxes there (a quest's "do you wish to take one?" Yes/No), and one we
	// fail to recognise is not a cosmetic miss -- the native shells keep their chat veneer over it and route
	// every tap on it to the chat, so its buttons cannot be pressed at all. These pin the rule itself: the
	// ATTACHMENT decides, and an interface the engine opened anywhere else is not a dialogue.

	/** A mocked client far enough along for {@link HudVeneerBridge#tick} to reach the chat snapshot: every
	 *  widget read comes back null (the engine-widget work is all null-guarded), so the only thing the
	 *  snapshot's {@code dialogueActive} can be reading is the component table. */
	private static Client loggedInClientWith(HashTable<WidgetNode> componentTable)
	{
		final Client c = mock(Client.class);
		when(c.getGameState()).thenReturn(GameState.LOGGED_IN);
		when(c.isResized()).thenReturn(true);
		when(c.getComponentTable()).thenReturn(componentTable);
		return c;
	}

	/** A component table holding one open interface: {@code group} opened on {@code parentComponent}. The node's
	 *  hash IS the parent component it was opened on, which is the half that decides. */
	private static HashTable<WidgetNode> openInterface(int parentComponent, int group)
	{
		final WidgetNode node = mock(WidgetNode.class);
		when(node.getHash()).thenReturn((long) parentComponent);
		when(node.getId()).thenReturn(group);
		@SuppressWarnings("unchecked")
		final HashTable<WidgetNode> table = mock(HashTable.class);
		// A fresh iterator per call -- tick walks the table more than once (detection, then the dialogue rect).
		when(table.iterator()).thenAnswer(inv -> Collections.singletonList(node).iterator());
		return table;
	}

	@Test
	public void interfaceOpenedOnTheChatboxIsADialogue()
	{
		// Confirmdestroy stands in for the unnamed kinds: a real chatbox box (item + message + Yes/No) that none
		// of the named-widget checks look for, so only the attachment can report it.
		final Client c = loggedInClientWith(openInterface(InterfaceID.Chatbox.MES_LAYER, InterfaceID.CONFIRMDESTROY));
		HudVeneerBridge.relocateChat(93, 8, true);

		HudVeneerBridge.tick(c);

		assertTrue("an interface opened onto the chatbox is a dialogue, named kind or not",
			HudVeneerBridge.getChatSnapshot().contains("\"dialogueActive\":true"));
	}

	@Test
	public void interfaceOpenedElsewhereIsNotADialogue()
	{
		// The orb cluster is opened onto a TOPLEVEL component, like every other non-chatbox interface. Reporting
		// one of those would hide the chat veneer and swallow taps over the chatbox for as long as it stayed open.
		final Client c = loggedInClientWith(openInterface(InterfaceID.ToplevelOsrsStretch.ORBS, InterfaceID.ORBS));
		HudVeneerBridge.relocateChat(93, 8, true);

		HudVeneerBridge.tick(c);

		assertTrue("only the chatbox's own open interfaces are dialogues",
			HudVeneerBridge.getChatSnapshot().contains("\"dialogueActive\":false"));
	}

	@Test
	public void unnamedDialogueRectComesFromItsRootComponent()
	{
		// The shells union this rect with the chatbox rect to decide which taps belong to the dialogue, so an
		// unnamed kind has to publish one of its own: its root component (child 0), the same component the named
		// kinds' UNIVERSE entries name. Without it the box is detected but its rect is whatever the chat says.
		final Client c = loggedInClientWith(openInterface(InterfaceID.Chatbox.MES_LAYER, InterfaceID.CONFIRMDESTROY));
		final Widget root = mock(Widget.class);
		when(root.getBounds()).thenReturn(new Rectangle(93, 8, 519, 142));
		when(c.getWidget(InterfaceID.Confirmdestroy.UNIVERSE)).thenReturn(root);
		HudVeneerBridge.relocateChat(93, 8, true);

		HudVeneerBridge.tick(c);

		assertTrue("the unnamed dialogue's own rect, in canvas px",
			HudVeneerBridge.getChatSnapshot().contains("\"dlgX\":93,\"dlgY\":8,\"dlgW\":519,\"dlgH\":142"));
	}

	// --- a box that has gone ----------------------------------------------------------------------------------
	// An interface group stays resolvable after its box closes, so "its widget resolves" is not "it is open". A
	// player mining until the inventory filled got the "too full" message, chiselled the amethyst, and could not
	// tap the make-X box: the message still resolved, read as the dialogue on screen, and every tap went to its
	// continue. These pin that open means mounted, for the named kinds as much as the unnamed ones.

	/** A widget whose text is {@code text}, the one thing the message box's JSON reads off it. */
	private static Widget textWidget(String text)
	{
		final Widget w = mock(Widget.class);
		when(w.getText()).thenReturn(text);
		return w;
	}

	@Test
	public void anOpenMessageBoxIsADialogue()
	{
		final Client c = loggedInClientWith(openInterface(InterfaceID.Chatbox.CHATMODAL, InterfaceID.MESSAGEBOX));
		final Widget text = textWidget("Your inventory is too full.");
		when(c.getWidget(InterfaceID.Messagebox.TEXT)).thenReturn(text);
		HudVeneerBridge.relocateChat(93, 8, true);

		HudVeneerBridge.tick(c);

		assertTrue("a mounted message box is the dialogue on screen",
			HudVeneerBridge.getChatSnapshot().contains("\"dialogueActive\":true"));
		assertTrue("and it is published as the message it is", HudVeneerBridge.getDialogueJson().contains("\"type\":\"message\""));
	}

	@Test
	public void aMessageBoxThatHasClosedIsNotADialogue()
	{
		// Its widgets still resolve, but nothing in the component table holds it. Reading it as open hid the chat
		// behind a box that was not there and turned every tap on the chat into a continue.
		final Client c = loggedInClientWith(openInterface(InterfaceID.ToplevelOsrsStretch.ORBS, InterfaceID.ORBS));
		final Widget gone = textWidget("");
		when(c.getWidget(InterfaceID.Messagebox.TEXT)).thenReturn(gone);
		HudVeneerBridge.relocateChat(93, 8, true);

		HudVeneerBridge.tick(c);

		assertTrue("a box that has closed is not a dialogue, however long its widgets stay loaded",
			HudVeneerBridge.getChatSnapshot().contains("\"dialogueActive\":false"));
	}

	@Test
	public void makeXAfterAClosedMessageBoxTakesTheTap()
	{
		// The player's sequence: the make-X box is what is on the chatbox, the message it replaced still resolves.
		// The tap on an item has to fire that item's Make, not a continue on the message.
		final Widget box = widgetAt(InterfaceID.SKILLMULTI << 16, 93, 8, 519, 142);
		final Widget item = widgetAt((InterfaceID.SKILLMULTI << 16) | 15, 200, 60, 60, 60, "Make");
		when(box.getStaticChildren()).thenReturn(new Widget[]{item});
		final Client c = clientWithDialogue(InterfaceID.SKILLMULTI, box);
		final Widget gone = textWidget("");
		when(c.getWidget(InterfaceID.Messagebox.TEXT)).thenReturn(gone);

		tapAfterPublish(c, 230, 90);

		verify(c).menuAction(-1, (InterfaceID.SKILLMULTI << 16) | 15, MenuAction.CC_OP, 1, -1, "Make", "");
	}

	// --- pressing an unnamed dialogue --------------------------------------------------------------------------
	// Its buttons are the box's OWN components, so there is no modelled continue or option row to fire, and a
	// click at the finger is resolved against the scene behind the relocated chatbox -- it walks the player past
	// the box instead of pressing anything. tapDialogue therefore carries the POINT in and fires the op of the
	// widget under it. What these pin is the engine's dispatch rule (param0: -1 static, index dynamic), that the
	// BUTTON wins over the box behind it, and that a press lands only where there is something to press.

	/** A widget with canvas bounds and an optional sparse action list, the two things the resolver reads. */
	private static Widget widgetAt(int id, int x, int y, int w, int h, String... actions)
	{
		final Widget wi = mock(Widget.class);
		when(wi.getId()).thenReturn(id);
		when(wi.getBounds()).thenReturn(new Rectangle(x, y, w, h));
		when(wi.getActions()).thenReturn(actions.length == 0 ? null : actions);
		return wi;
	}

	/** A logged-in client with {@code group} open on the chatbox and {@code root} as that group's root component. */
	private static Client clientWithDialogue(int group, Widget root)
	{
		final Client c = loggedInClientWith(openInterface(InterfaceID.Chatbox.MES_LAYER, group));
		when(c.getWidget(group << 16)).thenReturn(root);
		return c;
	}

	/** Tap a box the shell has already seen open: a tick to publish it, the tap, then the tick that resolves it.
	 *  That order is the real one -- a tap is stamped with the box that was on screen when the finger landed. */
	private static void tapAfterPublish(Client c, int x, int y)
	{
		HudVeneerBridge.relocateChat(93, 8, true);
		HudVeneerBridge.tick(c);
		HudVeneerBridge.tapDialogue(x, y);
		HudVeneerBridge.tick(c);
	}

	@Test
	public void tapOnADialogueButtonFiresThatButtonsOwnOp()
	{
		// The box fills the chatbox and carries an op of its own; the Yes sits inside it. The tap is on the Yes,
		// so the Yes is what must fire -- the enclosing box is not what the finger pressed.
		final Widget box = widgetAt(584 << 16, 93, 8, 519, 142, "Close");
		final Widget yes = widgetAt((584 << 16) | 7, 300, 100, 60, 30, "Continue");
		when(box.getStaticChildren()).thenReturn(new Widget[]{yes});
		final Client c = clientWithDialogue(InterfaceID.CONFIRMDESTROY, box);

		tapAfterPublish(c, 320, 115);

		// param0 = -1: a static interface component is addressed by id alone, and passing an index misroutes the
		// engine's op dispatch (the rule the tab stones established here).
		verify(c).menuAction(-1, (584 << 16) | 7, MenuAction.CC_OP, 1, -1, "Continue", "");
	}

	@Test
	public void tapOnADynamicRowIsAddressedByItsIndex()
	{
		final Widget box = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget row = widgetAt((584 << 16) | 3, 100, 40, 300, 20, null, "Select");
		when(row.getIndex()).thenReturn(4);
		when(box.getDynamicChildren()).thenReturn(new Widget[]{row});
		final Client c = clientWithDialogue(InterfaceID.CONFIRMDESTROY, box);

		tapAfterPublish(c, 150, 50);

		// A dynamic child is addressed by index, and the op is the first NAMED action -- here op 2, since op 1
		// has no name and so no menu entry a finger could have pressed.
		verify(c).menuAction(4, (584 << 16) | 3, MenuAction.CC_OP, 2, -1, "Select", "");
	}

	@Test
	public void tapOnTheInertPartOfADialoguePressesNothing()
	{
		// Parchment with no op anywhere under the finger. Firing something would answer a quest for the player,
		// and falling back to a click is the walk-the-player this path exists to stop: the tap is consumed.
		final Widget box = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget text = widgetAt((584 << 16) | 5, 100, 40, 300, 40);
		when(box.getStaticChildren()).thenReturn(new Widget[]{text});
		final Client c = clientWithDialogue(InterfaceID.CONFIRMDESTROY, box);

		tapAfterPublish(c, 200, 60);

		verify(c, never()).menuAction(anyInt(), anyInt(), any(MenuAction.class), anyInt(), anyInt(),
			anyString(), anyString());
	}

	@Test
	public void tapOutsideEveryWidgetPressesNothing()
	{
		// The region gate is the shells' (chatbox rect union the published dialogue rect), so a point can arrive
		// that no widget holds. Nothing is pressed rather than the nearest thing found.
		final Widget box = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget yes = widgetAt((584 << 16) | 7, 300, 100, 60, 30, "Continue");
		when(box.getStaticChildren()).thenReturn(new Widget[]{yes});
		final Client c = clientWithDialogue(InterfaceID.CONFIRMDESTROY, box);

		tapAfterPublish(c, 700, 400);

		verify(c, never()).menuAction(anyInt(), anyInt(), any(MenuAction.class), anyInt(), anyInt(),
			anyString(), anyString());
	}

	@Test
	public void tapIsDroppedWhenAnotherBoxHasReplacedTheOneTapped()
	{
		// The finger was on the destroy prompt; by the time the tap resolves, a different box is open at the same
		// place. Pressing what is there now would answer, in the player's name, a question they never saw.
		final Widget destroy = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget yes = widgetAt((584 << 16) | 7, 300, 100, 60, 30, "Continue");
		when(destroy.getStaticChildren()).thenReturn(new Widget[]{yes});
		final Client tapped = clientWithDialogue(InterfaceID.CONFIRMDESTROY, destroy);

		final Widget other = widgetAt(InterfaceID.OBJECTBOX << 16, 93, 8, 519, 142);
		final Widget button = widgetAt((InterfaceID.OBJECTBOX << 16) | 2, 300, 100, 60, 30, "Continue");
		when(other.getStaticChildren()).thenReturn(new Widget[]{button});
		final Client live = clientWithDialogue(InterfaceID.OBJECTBOX, other);

		HudVeneerBridge.relocateChat(93, 8, true);
		HudVeneerBridge.tick(tapped);          // the destroy prompt is what is on screen
		HudVeneerBridge.tapDialogue(320, 115); // ... and what the tap is stamped with
		HudVeneerBridge.tick(live);            // the box changed before the tap could resolve

		verify(live, never()).menuAction(anyInt(), anyInt(), any(MenuAction.class), anyInt(), anyInt(),
			anyString(), anyString());
	}

	@Test
	public void aSelfHiddenButtonIsNotPressed()
	{
		// A box can carry a button it is not currently offering. Its bounds and actions stay populated, so only
		// its hidden flag says so -- and pressing what the user cannot see is not an answer they gave.
		final Widget box = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget ghost = widgetAt((584 << 16) | 9, 300, 100, 60, 30, "Continue");
		when(ghost.isSelfHidden()).thenReturn(true);
		when(box.getStaticChildren()).thenReturn(new Widget[]{ghost});
		final Client c = clientWithDialogue(InterfaceID.CONFIRMDESTROY, box);

		tapAfterPublish(c, 320, 115);

		verify(c, never()).menuAction(anyInt(), anyInt(), any(MenuAction.class), anyInt(), anyInt(),
			anyString(), anyString());
	}

	@Test
	public void twoButtonsOfEqualSizeResolveToTheOneDrawnOnTop()
	{
		// Same size, same place, both pressable: the later child is the one the engine draws over the other, so
		// it is the one under the finger. Declining the overlap would leave the tap with nothing to press.
		final Widget box = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget under = widgetAt((584 << 16) | 7, 300, 100, 60, 30, "Yes");
		final Widget over = widgetAt((584 << 16) | 8, 300, 100, 60, 30, "No");
		when(box.getStaticChildren()).thenReturn(new Widget[]{under, over});
		final Client c = clientWithDialogue(InterfaceID.CONFIRMDESTROY, box);

		tapAfterPublish(c, 320, 115);

		verify(c).menuAction(-1, (584 << 16) | 8, MenuAction.CC_OP, 1, -1, "No", "");
	}

	@Test
	public void tapIsDroppedWhenTheSameGroupReopensAfterAGap()
	{
		// The case the group check CANNOT see: a destroy prompt replaced by another destroy prompt -- same group,
		// different item. Reaching it needs the gap that makes a tap survive at all: tick returns early while
		// logged out, so the tap is never consumed there, and the engine runs on without it. The tap is dated for
		// exactly this, and two ticks later it is no longer an answer to anything the finger was on.
		final Widget first = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget firstYes = widgetAt((584 << 16) | 7, 300, 100, 60, 30, "Continue");
		when(first.getStaticChildren()).thenReturn(new Widget[]{firstYes});
		final Client tapped = clientWithDialogue(InterfaceID.CONFIRMDESTROY, first);

		final Widget second = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget secondYes = widgetAt((584 << 16) | 7, 300, 100, 60, 30, "Continue");
		when(second.getStaticChildren()).thenReturn(new Widget[]{secondYes});
		final Client live = clientWithDialogue(InterfaceID.CONFIRMDESTROY, second);

		final Client loading = mock(Client.class);
		when(loading.getGameState()).thenReturn(GameState.LOADING);

		HudVeneerBridge.relocateChat(93, 8, true);
		HudVeneerBridge.tick(tapped);          // the first prompt is on screen
		HudVeneerBridge.tapDialogue(320, 115); // ... and the tap is dated to it
		HudVeneerBridge.tick(loading);         // a hop: the tap is not consumed, but time passes
		HudVeneerBridge.tick(loading);
		HudVeneerBridge.tick(live);            // back, with another prompt of the SAME group open

		verify(live, never()).menuAction(anyInt(), anyInt(), any(MenuAction.class), anyInt(), anyInt(),
			anyString(), anyString());
	}

	@Test
	public void aTapTakenAfterThisTicksResolveIsStillAnsweredByTheNextOne()
	{
		// The other side of dating a tap: one ticks' staleness is the NORMAL path, not a stale tap. A finger that
		// lands after this tick's one-shot has already run is answered by the following tick, and must be.
		final Widget box = widgetAt(584 << 16, 93, 8, 519, 142);
		final Widget yes = widgetAt((584 << 16) | 7, 300, 100, 60, 30, "Continue");
		when(box.getStaticChildren()).thenReturn(new Widget[]{yes});
		final Client c = clientWithDialogue(InterfaceID.CONFIRMDESTROY, box);

		HudVeneerBridge.relocateChat(93, 8, true);
		HudVeneerBridge.tick(c);
		HudVeneerBridge.tapDialogue(320, 115);
		HudVeneerBridge.tick(c);

		verify(c).menuAction(-1, (584 << 16) | 7, MenuAction.CC_OP, 1, -1, "Continue", "");
	}

	// --- the fullscreen world map owns the screen ----------------------------------------------------------
	// The engine draws the world-map window UNDER the toplevel HUD layers, so with the map open the minimap
	// cluster, the side panel and the hover-option text paint on top of it. Moving the cluster is not enough:
	// the globe follows its draw widget, but the orbs are hard-pinned and the Orbs interface opened into the
	// ORBS layer carries its own position, so they stay over the map. Hiding ends the draw recursion at the
	// container, which nothing under it can get out from under. preRender is the seam that matters -- it is
	// the last word before the frame rasters, where tick() runs after it.

	/** A widget mock whose hidden flag really tracks {@code setHidden}, so a hide and its restore are both
	 *  observable (the bridge skips a write that would not change the flag). */
	private static Widget hidableLayer()
	{
		return hidableLayer(false);
	}

	/** As above, starting from a given hidden state — {@code true} stands for a layer the ENGINE has hidden. */
	private static Widget hidableLayer(boolean initiallyHidden)
	{
		final Widget w = mock(Widget.class);
		final boolean[] hidden = {initiallyHidden};
		when(w.isHidden()).thenAnswer(inv -> hidden[0]);
		when(w.isSelfHidden()).thenAnswer(inv -> hidden[0]);
		when(w.setHidden(anyBoolean())).thenAnswer(inv ->
		{
			hidden[0] = inv.getArgument(0);
			return w;
		});
		return w;
	}

	/** A logged-in client in the Resizable - Modern layout, with the three HUD layers wired up and the world
	 *  map open or closed. Index 0 = minimap cluster, 1 = side panel, 2 = hover-option text. */
	private static Client clientWithHudLayers(boolean worldMapOpen, Widget[] layers)
	{
		return clientWithHudLayers(worldMapOpen, layers, new boolean[]{true});
	}

	/**
	 * A client whose two toplevel HUD containers are {@code layers} and whose hover-option text is backed by
	 * {@code textEnabled}. The holder is passed in rather than owned here so one open/close pair can be driven
	 * through two mocks and still share the one piece of client state the engine really keeps.
	 */
	private static Client clientWithHudLayers(boolean worldMapOpen, Widget[] layers, boolean[] textEnabled)
	{
		final Client c = loggedInClientWith(null);
		when(c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT)).thenReturn(1);   // PreEoc (Resizable - Modern)
		when(c.getWidget(InterfaceID.ToplevelPreEoc.MAP_CONTAINER)).thenReturn(layers[0]);
		when(c.getWidget(InterfaceID.ToplevelPreEoc.SIDE_CONTAINER)).thenReturn(layers[1]);
		when(c.isMouseoverTextEnabled()).thenAnswer(inv -> textEnabled[0]);
		doAnswer(inv ->
		{
			textEnabled[0] = inv.getArgument(0);
			return null;
		}).when(c).setMouseoverTextEnabled(anyBoolean());
		if (worldMapOpen)
		{
			final Widget map = mock(Widget.class);
			when(map.isHidden()).thenReturn(false);
			when(c.getWidget(InterfaceID.Worldmap.MAP_CONTAINER)).thenReturn(map);
		}
		return c;
	}

	@Test
	public void anOpenWorldMapHidesEveryHudLayerThatWouldPaintOverIt()
	{
		final Widget[] layers = {hidableLayer(), hidableLayer()};
		final boolean[] text = {true};

		HudVeneerBridge.preRender(clientWithHudLayers(true, layers, text));

		assertTrue("the minimap+orbs cluster must stop painting over the map", layers[0].isHidden());
		assertTrue("the side panel must stop painting over the map", layers[1].isHidden());
		assertFalse("the hover-option text must stop painting over the map", text[0]);
	}

	@Test
	public void closingTheWorldMapGivesTheHudBack()
	{
		final Widget[] layers = {hidableLayer(), hidableLayer()};
		final boolean[] text = {true};

		HudVeneerBridge.preRender(clientWithHudLayers(true, layers, text));
		HudVeneerBridge.preRender(clientWithHudLayers(false, layers, text));

		assertFalse("the minimap+orbs cluster comes back with the map closed", layers[0].isHidden());
		assertFalse("the side panel comes back with the map closed", layers[1].isHidden());
		// NOT assertTrue: the label is off client-wide (HOVER_TEXT), and nothing switches it back on — see
		// theHoverLabelIsNeverSwitchedOn for why that is deliberate rather than an oversight.
		assertFalse("the hover-option text stays off — it is off client-wide, not just over the map", text[0]);
	}

	@Test
	public void withNoMapOpenTheHudIsNeverTouched()
	{
		// The restore is driven off what WE hid, not off "the map is closed": a side panel the engine itself
		// closed (no tab open) must not be forced back on every frame for the life of the session.
		final Widget[] layers = {hidableLayer(), hidableLayer()};
		final Client c = clientWithHudLayers(false, layers);

		HudVeneerBridge.preRender(c);

		for (final Widget layer : layers)
		{
			verify(layer, never()).setHidden(anyBoolean());
		}
	}

	@Test
	public void theHoverLabelIsOffWithOrWithoutAMapOpen()
	{
		// The label is suppressed client-wide, not just over the map: this client has no cursor, so the point
		// it names is never one the user put there. Camera rotation is the case that made it obvious — the
		// point stays put and the world turns under it, so the label re-names itself with nothing touching it.
		final boolean[] text = {true};

		HudVeneerBridge.preRender(clientWithHudLayers(false, new Widget[]{hidableLayer(), hidableLayer()}, text));

		assertFalse("no map open, and still no hover label", text[0]);
	}

	@Test
	public void aLayerTheEngineHadAlreadyHiddenIsNotHandedBackShown()
	{
		// The restore has to undo OUR hides and nothing else. The engine closes the side panel whenever no tab
		// is open, so a map opened in that state would otherwise come back with the panel forced SHOWN — and a
		// hidden toplevel would do that to both containers at once.
		final Widget[] layers = {hidableLayer(), hidableLayer(true)};

		HudVeneerBridge.preRender(clientWithHudLayers(true, layers));
		HudVeneerBridge.preRender(clientWithHudLayers(false, layers));

		assertFalse("the cluster was ours to hide, so it comes back", layers[0].isHidden());
		assertTrue("the layer the engine had hidden stays hidden", layers[1].isHidden());
		verify(layers[1], never()).setHidden(anyBoolean());
	}

	@Test
	public void theHoverLabelIsNeverSwitchedOn()
	{
		// The flag is client-global and a plugin may own it too. We can turn it off, but we can never tell our
		// own `false` from somebody else's, so we never write `true` — a restore would be a guess wearing
		// bookkeeping's clothes. Open the map, close it, no map at all: the setter is only ever called with
		// false, so a plugin that wants the label off keeps it off.
		final Widget[] layers = {hidableLayer(), hidableLayer()};
		final boolean[] text = {false};
		final Client open = clientWithHudLayers(true, layers, text);
		final Client closed = clientWithHudLayers(false, layers, text);

		HudVeneerBridge.preRender(open);
		HudVeneerBridge.preRender(closed);

		assertFalse("the hover text stays off — it was not ours to turn on", text[0]);
		verify(open, never()).setMouseoverTextEnabled(true);
		verify(closed, never()).setMouseoverTextEnabled(true);
	}

	@Test
	public void theHideIsReassertedEveryFrameTheMapStaysOpen()
	{
		// The engine rebuilds the toplevel (a TOPLEVEL_REDRAW, a tab switch) and the layer comes back shown.
		// preRender runs before the raster, so re-asserting here costs the map zero painted-over frames.
		final Widget[] layers = {hidableLayer(), hidableLayer()};
		final boolean[] text = {true};
		final Client c = clientWithHudLayers(true, layers, text);

		HudVeneerBridge.preRender(c);
		layers[0].setHidden(false);   // the engine re-shows the cluster mid-tick
		text[0] = true;               // ... and the hover text with it
		HudVeneerBridge.preRender(c);

		assertTrue("a re-shown layer is hidden again before the next frame rasters", layers[0].isHidden());
		assertFalse("a re-enabled hover text is off again before the next frame rasters", text[0]);
	}
	/** A widget whose live position follows its forced one, the way the engine's re-layout leaves it. */
	private static Widget pinnable(int[] pos)
	{
		final Widget w = mock(Widget.class);
		doAnswer(inv ->
		{
			pos[0] = inv.getArgument(0);
			pos[1] = inv.getArgument(1);
			return null;
		}).when(w).setForcedPosition(anyInt(), anyInt());
		when(w.getRelativeX()).thenAnswer(inv -> pos[0]);
		when(w.getRelativeY()).thenAnswer(inv -> pos[1]);
		return w;
	}

	@Test
	public void aPinnedWidgetIsNotReLaidOnAnUnchangedFrame()
	{
		final HudVeneerBridge.Pin pin = new HudVeneerBridge.Pin("test");
		final Widget w = pinnable(new int[]{0, 400});

		assertTrue("the first frame pins it", pin.apply(w, 93, 8, false));
		assertFalse("a frame that changes nothing costs no re-layout", pin.apply(w, 93, 8, false));
		assertFalse(pin.apply(w, 93, 8, false));
		verify(w, times(1)).setForcedPosition(93, 8);
		verify(w, times(1)).revalidate();
	}

	@Test
	public void aClearedPinIsRestoredOnTheNextFrame()
	{
		final HudVeneerBridge.Pin pin = new HudVeneerBridge.Pin("test");
		final int[] pos = {0, 400};
		final Widget w = pinnable(pos);
		pin.apply(w, 93, 8, false);

		// WidgetOverlay's overlay reset forces (-1, -1) and revalidates: the widget is back where the engine puts it.
		pos[0] = 0;
		pos[1] = 400;
		assertTrue(pin.apply(w, 93, 8, false));
		verify(w, times(2)).setForcedPosition(93, 8);
		verify(w, times(2)).revalidate();
	}

	@Test
	public void aRebuiltInterfaceIsPinnedAgainWhereverItSits()
	{
		final HudVeneerBridge.Pin pin = new HudVeneerBridge.Pin("test");
		pin.apply(pinnable(new int[]{0, 400}), 93, 8, false);

		// A rebuild hands back a new object with no forced position, even one that happens to sit on the target:
		// the next re-layout would move it.
		final Widget rebuilt = pinnable(new int[]{93, 8});
		assertTrue(pin.apply(rebuilt, 93, 8, false));
		verify(rebuilt).setForcedPosition(93, 8);
		verify(rebuilt).revalidate();
	}

	@Test
	public void aNewTargetOrAResizeReLaysThePin()
	{
		final HudVeneerBridge.Pin pin = new HudVeneerBridge.Pin("test");
		final Widget w = pinnable(new int[]{0, 400});
		pin.apply(w, 93, 8, false);

		assertTrue("shoved off-screen while the world map is open", pin.apply(w, 93, 3000, false));
		assertFalse(pin.apply(w, 93, 3000, false));
		assertTrue("home again when it closes", pin.apply(w, 93, 8, false));
		assertTrue("a size change re-lays it in place", pin.apply(w, 93, 8, true));
		verify(w, times(4)).revalidate();
	}

	@Test
	public void aChatRebuildReLaysTheChatAreaOnce()
	{
		final Client c = mock(Client.class);
		final Widget area = pinnable(new int[]{0, 0});
		when(area.getWidthMode()).thenReturn(WidgetSizeMode.ABSOLUTE);
		when(area.getOriginalWidth()).thenReturn(OFFICIAL_CHAT_W);
		when(area.getHeightMode()).thenReturn(WidgetSizeMode.ABSOLUTE);
		when(area.getOriginalHeight()).thenReturn(OFFICIAL_CHAT_H - OFFICIAL_ROW_BOTTOM);
		when(c.getWidget(InterfaceID.Chatbox.CHATAREA)).thenReturn(area);
		HudVeneerBridge.sizeChatArea(c, InterfaceID.Chatbox.UNIVERSE, OFFICIAL_CHAT_W, false);
		HudVeneerBridge.sizeChatArea(c, InterfaceID.Chatbox.UNIVERSE, OFFICIAL_CHAT_W, false);
		verify(area, times(1)).revalidate();
		verify(area).setForcedPosition(0, OFFICIAL_ROW_BOTTOM);

		// A new message or a tab switch runs the build script, which can rebuild the area's children in place.
		new HudVeneerBridge.BeforeRenderListener(c).onScriptPostFired(new ScriptPostFired(ScriptID.BUILD_CHATBOX));
		HudVeneerBridge.sizeChatArea(c, InterfaceID.Chatbox.UNIVERSE, OFFICIAL_CHAT_W, false);
		HudVeneerBridge.sizeChatArea(c, InterfaceID.Chatbox.UNIVERSE, OFFICIAL_CHAT_W, false);
		verify(area, times(2)).revalidate();
	}

	@Test
	public void aPromptTakesTheWholeChat()
	{
		// Script 2581: with the message layer up, the area fills the chat from the top, over the filter row.
		final Client c = mock(Client.class);
		final Widget area = pinnable(new int[]{0, 0});
		when(c.getWidget(InterfaceID.Chatbox.CHATAREA)).thenReturn(area);
		HudVeneerBridge.sizeChatArea(c, InterfaceID.Chatbox.UNIVERSE, OFFICIAL_CHAT_W, true);
		verify(area).setOriginalHeight(OFFICIAL_CHAT_H);
		verify(area).setForcedPosition(0, 0);
	}

	@Test
	public void theChatAreaLeavesAClosedPromptHidden()
	{
		final Client c = mock(Client.class);
		final Widget area = pinnable(new int[]{0, 0});
		when(c.getWidget(InterfaceID.Chatbox.CHATAREA)).thenReturn(area);
		// The game hid the bank search's layer when the search closed; its text is still in it.
		final Widget prompt = hidableLayer(true);
		when(c.getWidget(InterfaceID.Chatbox.MES_LAYER)).thenReturn(prompt);
		final Widget lines = hidableLayer(true);
		when(c.getWidget(InterfaceID.Chatbox.CHATDISPLAY)).thenReturn(lines);

		HudVeneerBridge.sizeChatArea(c, InterfaceID.Chatbox.UNIVERSE, OFFICIAL_CHAT_W, false);

		assertFalse("the chat lines a rebuild hid are shown again", lines.isHidden());
		assertTrue("a closed prompt stays hidden, or its text sits over the chat", prompt.isHidden());
		verify(prompt, never()).setHidden(false);
	}

	// --- the item search's results list ------------------------------------------------------------------------
	// The GE item search draws its results in the chatbox's message layer, with its own scrollbar. A finger drag
	// on it has to move THAT list -- the chat lines are not what is on screen -- and only the rows inside its
	// window may stay tap targets, or a row scrolled out of sight is still pickable over the title.

	/** A scroll layer: its window is {@code h} px tall and its content {@code contentH}, at scroll {@code y}. */
	private static Widget scrollLayer(int h, int contentH, int y, Widget... kids)
	{
		final Widget w = mock(Widget.class);
		when(w.getHeight()).thenReturn(h);
		when(w.getScrollHeight()).thenReturn(contentH);
		when(w.getScrollY()).thenReturn(y);
		when(w.getDynamicChildren()).thenReturn(kids);
		return w;
	}

	@Test
	public void aDragOnTheSearchResultsScrollsTheResults()
	{
		final Client c = mock(Client.class);
		final Widget results = scrollLayer(100, 300, 0, mock(Widget.class));
		final Widget chat = scrollLayer(100, 500, 400);
		when(c.getWidget(InterfaceID.Chatbox.MES_LAYER_SCROLLCONTENTS)).thenReturn(results);
		when(c.getWidget(InterfaceID.Chatbox.SCROLLAREA)).thenReturn(chat);

		HudVeneerBridge.applyChatScroll(c, 20, true);

		verify(c).runScript(ScriptID.UPDATE_SCROLLBAR, InterfaceID.Chatbox.MES_LAYER_SCROLLBAR,
			InterfaceID.Chatbox.MES_LAYER_SCROLLCONTENTS, 20);
		verify(c, never()).runScript(ScriptID.UPDATE_SCROLLBAR, InterfaceID.Chatbox.CHATSCROLLBAR,
			InterfaceID.Chatbox.SCROLLAREA, 380);
	}

	@Test
	public void theResultsStopAtTheirLastRow()
	{
		final Client c = mock(Client.class);
		final Widget results = scrollLayer(100, 300, 190, mock(Widget.class));
		when(c.getWidget(InterfaceID.Chatbox.MES_LAYER_SCROLLCONTENTS)).thenReturn(results);

		HudVeneerBridge.applyChatScroll(c, 50, true);

		verify(c).runScript(ScriptID.UPDATE_SCROLLBAR, InterfaceID.Chatbox.MES_LAYER_SCROLLBAR,
			InterfaceID.Chatbox.MES_LAYER_SCROLLCONTENTS, 200);
	}

	@Test
	public void withNoResultsListedTheChatScrollsAsBefore()
	{
		final Client c = mock(Client.class);
		// "Enter amount" is a prompt too, but it lists nothing: the drag stays with the chat.
		final Widget empty = scrollLayer(100, 0, 0);
		final Widget chat = scrollLayer(100, 500, 400);
		when(c.getWidget(InterfaceID.Chatbox.MES_LAYER_SCROLLCONTENTS)).thenReturn(empty);
		when(c.getWidget(InterfaceID.Chatbox.SCROLLAREA)).thenReturn(chat);

		HudVeneerBridge.applyChatScroll(c, -20, true);
		HudVeneerBridge.applyChatScroll(c, -30, false);

		verify(c).runScript(ScriptID.UPDATE_SCROLLBAR, InterfaceID.Chatbox.CHATSCROLLBAR,
			InterfaceID.Chatbox.SCROLLAREA, 380);
		verify(c).runScript(ScriptID.UPDATE_SCROLLBAR, InterfaceID.Chatbox.CHATSCROLLBAR,
			InterfaceID.Chatbox.SCROLLAREA, 370);
	}

	@Test
	public void aResultRowIsCutToTheListsWindow()
	{
		final int[] window = {10, 50, 400, 100};
		assertArrayEquals("inside the window: as drawn",
			new int[]{20, 60, 100, 20}, HudVeneerBridge.visiblePart(new int[]{20, 60, 100, 20}, window));
		assertArrayEquals("half above the window: the half on screen",
			new int[]{20, 50, 100, 10}, HudVeneerBridge.visiblePart(new int[]{20, 40, 100, 20}, window));
		assertNull("scrolled out above: no target",
			HudVeneerBridge.visiblePart(new int[]{20, 25, 100, 20}, window));
		assertNull("scrolled out below: no target",
			HudVeneerBridge.visiblePart(new int[]{20, 150, 100, 20}, window));
		assertArrayEquals("no window known: as drawn",
			new int[]{20, 25, 100, 20}, HudVeneerBridge.visiblePart(new int[]{20, 25, 100, 20}, null));
	}

	// --- the engine stone rows ------------------------------------------------------------------------------
	// The native tab grid stands in for the stones, so their rows are hidden -- by hiding each stone's
	// GRANDPARENT, the container the engine does not re-pin. In Resizable - Modern (164) that is the row alone.
	// In Resizable - Classic (161) it is SIDE_MENU, which holds the side panel too: hiding it there left a player
	// who logged in on Classic with no tabs and no panel, so no way into the Display settings to leave it. And
	// the hide sticks, so a row nothing gives back stays gone for the session.

	/** A hidable widget with an id, which is how the restore finds it again. */
	private static Widget hidableRow(int id, boolean initiallyHidden)
	{
		final Widget w = hidableLayer(initiallyHidden);
		when(w.getId()).thenReturn(id);
		return w;
	}

	/** A stone whose grandparent is {@code row}. */
	private static Widget stoneIn(Widget row)
	{
		final Widget parent = mock(Widget.class);
		when(parent.getParent()).thenReturn(row);
		final Widget stone = mock(Widget.class);
		when(stone.getParent()).thenReturn(parent);
		return stone;
	}

	/** A logged-in Resizable - Modern client: STONE0's row is {@code rows[0]}, STONE7's is {@code rows[1]}. */
	private static Client modernClientWithStoneRows(Widget[] rows)
	{
		final Client c = loggedInClientWith(null);
		// Built before the stubbing that returns them: a mock stubbed inside an unfinished when() fails it.
		final Widget left = stoneIn(rows[0]);
		final Widget right = stoneIn(rows[1]);
		when(c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT)).thenReturn(1);
		when(c.getWidget(InterfaceID.ToplevelPreEoc.STONE0)).thenReturn(left);
		when(c.getWidget(InterfaceID.ToplevelPreEoc.STONE7)).thenReturn(right);
		for (final Widget row : rows)
		{
			final int id = row.getId();   // read before the stubbing, so getWidget is the call being stubbed
			when(c.getWidget(id)).thenReturn(row);
		}
		return c;
	}

	/** A logged-in Resizable - Classic client, where both stone rows' grandparent is {@code sideMenu}. */
	private static Client classicClientWithSideMenu(Widget sideMenu)
	{
		final Client c = loggedInClientWith(null);
		final Widget left = stoneIn(sideMenu);
		final Widget right = stoneIn(sideMenu);
		when(c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT)).thenReturn(0);
		when(c.getWidget(InterfaceID.ToplevelOsrsStretch.STONE0)).thenReturn(left);
		when(c.getWidget(InterfaceID.ToplevelOsrsStretch.STONE7)).thenReturn(right);
		when(c.getWidget(InterfaceID.ToplevelOsrsStretch.SIDE_MENU)).thenReturn(sideMenu);
		return c;
	}

	private static Widget[] modernRows()
	{
		return new Widget[]{
			hidableRow(InterfaceID.ToplevelPreEoc.SIDE_MOVABLE_LAYER, false),
			hidableRow(InterfaceID.ToplevelPreEoc.SIDE_STATIC_LAYER, false),
		};
	}

	@Test
	public void inResizableModernBothStoneRowsAreHidden()
	{
		final Widget[] rows = modernRows();
		HudVeneerBridge.setStonesHidden(true);

		HudVeneerBridge.preRender(modernClientWithStoneRows(rows));

		assertTrue("the left stone row is hidden", rows[0].isHidden());
		assertTrue("the right stone row is hidden", rows[1].isHidden());
	}

	@Test
	public void inResizableClassicTheSideMenuIsNeverHidden()
	{
		// Both seams: preRender is the last word before the raster, tick the post-render pass that also hid.
		final Widget sideMenu = hidableRow(InterfaceID.ToplevelOsrsStretch.SIDE_MENU, false);
		final Client c = classicClientWithSideMenu(sideMenu);
		HudVeneerBridge.setStonesHidden(true);

		HudVeneerBridge.preRender(c);
		HudVeneerBridge.tick(c);

		assertFalse("the side menu, and the panel in it, stay on screen", sideMenu.isHidden());
		verify(sideMenu, never()).setHidden(anyBoolean());
	}

	@Test
	public void turningTheHideOffGivesTheRowsBack()
	{
		// The native shells turn it off when their grid stands down (an unsupported layout, the chrome toggled
		// off) and rely on the engine's own stones coming back.
		final Widget[] rows = modernRows();
		final Client c = modernClientWithStoneRows(rows);
		HudVeneerBridge.setStonesHidden(true);
		HudVeneerBridge.preRender(c);

		HudVeneerBridge.setStonesHidden(false);
		HudVeneerBridge.preRender(c);

		assertFalse(rows[0].isHidden());
		assertFalse(rows[1].isHidden());
	}

	@Test
	public void aSwitchToClassicGivesTheModernRowsBack()
	{
		// The hide follows the layout even with the native shell still asking for it, and the restore goes to
		// the rows it hid, not to whatever the live layout's stones sit in.
		final Widget[] rows = modernRows();
		HudVeneerBridge.setStonesHidden(true);
		HudVeneerBridge.preRender(modernClientWithStoneRows(rows));

		final Widget sideMenu = hidableRow(InterfaceID.ToplevelOsrsStretch.SIDE_MENU, false);
		final Client classic = classicClientWithSideMenu(sideMenu);
		when(classic.getWidget(InterfaceID.ToplevelPreEoc.SIDE_MOVABLE_LAYER)).thenReturn(rows[0]);
		when(classic.getWidget(InterfaceID.ToplevelPreEoc.SIDE_STATIC_LAYER)).thenReturn(rows[1]);
		HudVeneerBridge.preRender(classic);

		assertFalse(rows[0].isHidden());
		assertFalse(rows[1].isHidden());
		verify(sideMenu, never()).setHidden(anyBoolean());
	}

	@Test
	public void aStoneRowTheEngineHidIsNotHandedBackShown()
	{
		final Widget[] rows = {
			hidableRow(InterfaceID.ToplevelPreEoc.SIDE_MOVABLE_LAYER, true),
			hidableRow(InterfaceID.ToplevelPreEoc.SIDE_STATIC_LAYER, false),
		};
		final Client c = modernClientWithStoneRows(rows);
		HudVeneerBridge.setStonesHidden(true);
		HudVeneerBridge.preRender(c);
		HudVeneerBridge.setStonesHidden(false);
		HudVeneerBridge.preRender(c);

		assertTrue("the row the engine had hidden stays hidden", rows[0].isHidden());
		verify(rows[0], never()).setHidden(anyBoolean());
		assertFalse("the row that was ours comes back", rows[1].isHidden());
	}

	@Test
	public void aStoneRowTheEngineReShowsIsStillOursToGiveBack()
	{
		// The re-assert keeps the claim from the frame that first hid the row: a TOPLEVEL_REDRAW re-showing it
		// mid-session must not turn the row into one the restore leaves alone.
		final Widget[] rows = modernRows();
		final Client c = modernClientWithStoneRows(rows);
		HudVeneerBridge.setStonesHidden(true);
		HudVeneerBridge.preRender(c);
		rows[0].setHidden(false);   // the engine re-shows the row
		HudVeneerBridge.preRender(c);
		assertTrue("hidden again before the next raster", rows[0].isHidden());

		HudVeneerBridge.setStonesHidden(false);
		HudVeneerBridge.preRender(c);

		assertFalse(rows[0].isHidden());
	}

	@Test
	public void theSidePanelIsOnlyRelocatedInResizableModern()
	{
		// In Classic the side container sits inside SIDE_MENU, so a canvas position forced on it lands far
		// outside its parent: the panel is gone, and with it the way into the Display settings.
		HudVeneerBridge.relocateSidePanel(900, 300);

		final Widget classicSide = pinnable(new int[]{26, 37});
		final Client classic = classicClientWithSideMenu(hidableRow(InterfaceID.ToplevelOsrsStretch.SIDE_MENU, false));
		when(classic.getWidget(InterfaceID.ToplevelOsrsStretch.SIDE_CONTAINER)).thenReturn(classicSide);
		HudVeneerBridge.tick(classic);
		verify(classicSide, never()).setForcedPosition(anyInt(), anyInt());

		final Widget modernSide = pinnable(new int[]{0, 36});
		final Client modern = modernClientWithStoneRows(modernRows());
		when(modern.getWidget(InterfaceID.ToplevelPreEoc.SIDE_CONTAINER)).thenReturn(modernSide);
		HudVeneerBridge.tick(modern);
		verify(modernSide).setForcedPosition(900, 300);
	}

	@Test
	public void theTabGlyphsAreTheOnes164Draws()
	{
		// 164's ICON0..ICON13 sprites, read from the game cache (interface 601 draws the same ones). The old
		// 774+index set put the friends smiley on account management (8) and the ignore face on friends (9).
		final int[] icon164 = {168, 898, 899, 900, 901, 902, 903, 904, 1709, 905, -1, 908, 909, 910};
		for (int tab = 0; tab < 14; tab++)
		{
			final int id = HudVeneerBridge.tabSpriteId(2 + tab);
			if (icon164[tab] >= 0)
			{
				assertEquals("tab " + tab, icon164[tab], id);
			}
			assertFalse("tab " + tab + " still uses the pre-2018 glyphs", id >= 774 && id <= 787);
		}
		// 164 draws a close X for logout; the shells show it as 601's door.
		assertEquals(3560, HudVeneerBridge.tabSpriteId(2 + 10));
	}

	@Test
	public void theShellsGetTheMobileStonesAndFrame()
	{
		// 601's 40x40 stones, not 164's desktop ones, and the chat stones script 178 picks on mobile.
		assertEquals(5767, HudVeneerBridge.tabSpriteId(0));
		assertEquals(5769, HudVeneerBridge.tabSpriteId(1));
		assertEquals(5779, HudVeneerBridge.tabSpriteId(16));
		assertEquals(5780, HudVeneerBridge.tabSpriteId(17));
		assertEquals(5781, HudVeneerBridge.tabSpriteId(18));
		for (int i = 0; i < HudVeneerBridge.SPR_TAB_FRAME.length; i++)
		{
			assertEquals("frame piece " + i, 5814 + i, HudVeneerBridge.tabSpriteId(26 + i));
		}
	}

	@Test
	public void theEngineDrawsTheMobileChatStones()
	{
		assertEquals(5779, HudVeneerBridge.officialChatStone(3051));
		assertEquals("no hover stone on a touch screen", 5779, HudVeneerBridge.officialChatStone(3052));
		assertEquals(5780, HudVeneerBridge.officialChatStone(3053));
		assertEquals(5780, HudVeneerBridge.officialChatStone(3054));
		assertEquals(5781, HudVeneerBridge.officialChatStone(3055));
		assertEquals("anything else is left alone", 1018, HudVeneerBridge.officialChatStone(1018));
	}

	@Test
	public void theFilterStonesSitWhereTheOfficialAppPutsThem()
	{
		// Script 113's mobile branch right-aligns seven 58-px stones in the 461-px row, 65 px apart, 6 px from its
		// right edge: in left-edge terms that is 7 + 65 * i, and the last one ends 6 px short of the row's end.
		assertEquals(OFFICIAL_CHAT_W, HudVeneerBridge.OFFICIAL_ROW_W);
		final int last = HudVeneerBridge.OFFICIAL_TAB_X + 6 * HudVeneerBridge.OFFICIAL_TAB_PITCH;
		assertEquals(HudVeneerBridge.OFFICIAL_ROW_W - 6, last + HudVeneerBridge.OFFICIAL_TAB_W);
		assertEquals(OFFICIAL_ROW_BOTTOM, HudVeneerBridge.OFFICIAL_ROW_BOTTOM);
		assertEquals(OFFICIAL_CHAT_H, HudVeneerBridge.OFFICIAL_CHAT_H);
	}

	@Test
	public void theChatScrollbarGoesLeftOnce()
	{
		// Script 923 with the scrollbar on the left puts it a pixel left of the display. A forced position of -1
		// means "none", so the bar takes the spot as its own left-aligned x, and only when it hasn't got it.
		final Client c = mock(Client.class);
		final Widget row = pinnable(new int[]{0, 0});
		when(c.getWidget(InterfaceID.Chatbox.CONTROLS)).thenReturn(row);
		final Widget bar = mock(Widget.class);
		final int[] x = {0};
		final int[] mode = {WidgetPositionMode.ABSOLUTE_RIGHT};
		when(bar.getOriginalX()).thenAnswer(inv -> x[0]);
		when(bar.getXPositionMode()).thenAnswer(inv -> mode[0]);
		doAnswer(inv ->
		{
			x[0] = inv.getArgument(0);
			return bar;
		}).when(bar).setOriginalX(anyInt());
		doAnswer(inv ->
		{
			mode[0] = inv.getArgument(0);
			return bar;
		}).when(bar).setXPositionMode(anyInt());
		when(c.getWidget(InterfaceID.Chatbox.CHATSCROLLBAR)).thenReturn(bar);

		HudVeneerBridge.layOfficialChat(c);
		HudVeneerBridge.layOfficialChat(c);

		assertEquals(HudVeneerBridge.OFFICIAL_SCROLLBAR_X, x[0]);
		assertEquals(WidgetPositionMode.ABSOLUTE_LEFT, mode[0]);
		verify(bar, times(1)).revalidate();
		verify(bar, never()).setForcedPosition(anyInt(), anyInt());
	}
}
