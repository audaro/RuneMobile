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

import java.awt.AWTEvent;
import java.awt.Canvas;
import java.awt.EventQueue;
import java.awt.Toolkit;
import java.awt.event.MouseEvent;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.Menu;
import net.runelite.api.MenuAction;
import net.runelite.api.MenuEntry;
import net.runelite.api.Point;
import net.runelite.api.events.MenuOptionClicked;
import net.runelite.client.callback.ClientThread;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * The press-timing contract for an armed tap: no button goes down until the finger lifts.
 *
 * <p>OSRS acts on the PRESS. Its release handler only clears the button state, so whatever a press resolves to
 * — a walk, an attack, a pick-up — has happened by the time any release arrives. An earlier version posted the
 * press when the settle gate accepted, while the finger was still on the glass, so the engine would see the
 * real hold. A contact that rested for a couple of frames and then became a camera drag or a long-press had
 * already walked to where it landed, and releasing the press afterwards could not take that back. These tests
 * pin the fix and the two things around it that must not regress:
 * <ul>
 *   <li><b>The arm still pays the settle up front.</b> The gate resolves the point while the finger is down,
 *       and the lift clicks there at once instead of starting a second settle.</li>
 *   <li><b>The engine's answer is still read.</b> The tap is in {@code CLICKED} before its press goes out, so the
 *       {@code MenuOptionClicked} the engine raises for it is taken as this tap's result.</li>
 * </ul>
 *
 * <p>Pure: the {@link Client} is mocked and no engine boots. Events are captured by pushing an
 * {@link EventQueue} that records what the bridge POSTS, rather than by listening on the canvas — a test
 * canvas is never displayable, so AWT's own delivery to it is not something to assert against.
 */
public class JavaBridgePressTimingTest
{
	static
	{
		System.setProperty("runelite.bridge", "true");
	}

	/** The point every tap in here lands on. */
	private static final int TAP_X = 300;
	private static final int TAP_Y = 220;

	private final java.util.concurrent.atomic.AtomicBoolean menuOpen =
		new java.util.concurrent.atomic.AtomicBoolean();
	private final java.util.concurrent.atomic.AtomicBoolean menuOpenThrows =
		new java.util.concurrent.atomic.AtomicBoolean();
	private Capture cap;
	private Canvas canvas;
	private Client client;

	@Before
	public void setUp() throws Exception
	{
		resetTapState();
		menuOpen.set(false);
		menuOpenThrows.set(false);
		cap = new Capture();
		Toolkit.getDefaultToolkit().getSystemEventQueue().push(cap);
		canvas = new Canvas();
		client = loggedInClient(canvas);
		JavaBridge.register(client);
		JavaBridge.setClientThread(inlineClientThread());
	}

	@After
	public void tearDown() throws Exception
	{
		cap.popQueue();
		resetTapState();
		JavaBridge.register(null);
	}

	/**
	 * The headline, and the bug it fixes: the gate has accepted, the finger is still down, and the contact turns
	 * into a camera drag. Nothing may have been pressed — a press would already have walked the character to the
	 * point the finger landed on.
	 */
	@Test
	public void aContactThatBecomesADragPressesNothing() throws Exception
	{
		JavaBridge.armTap(TAP_X, TAP_Y);
		pump();
		settleUntilArmed();
		assertEquals("the gate accepting must not press while the finger is still down",
			0, cap.count(MouseEvent.MOUSE_PRESSED));

		JavaBridge.cancelArmedTap();
		pump();

		assertEquals("a drag must never press", 0, cap.count(MouseEvent.MOUSE_PRESSED));
		assertEquals("so there is nothing to release", 0, cap.count(MouseEvent.MOUSE_RELEASED));
		assertEquals("and nothing to click", 0, cap.count(MouseEvent.MOUSE_CLICKED));
		assertEquals("the arm is dropped", "IDLE", tapState());
	}

	/** A long-press that opens the menu over an armed contact must not have acted first either. */
	@Test
	public void aLongPressMenuOverAnArmPressesNothing() throws Exception
	{
		JavaBridge.armTap(TAP_X, TAP_Y);
		pump();
		settleUntilArmed();

		menuOpen.set(true);
		JavaBridge.tapTick(client);
		pump();

		assertEquals("the menu owns input now; the arm never pressed", 0, cap.count(MouseEvent.MOUSE_PRESSED));
		assertEquals("the arm is dropped", "IDLE", tapState());
	}

	/**
	 * The lift of an armed tap clicks at once, on the point the gate resolved: press, release and click, in that
	 * order, with no further frames spent settling.
	 */
	@Test
	public void theLiftClicksAtOnceOnTheResolvedPoint() throws Exception
	{
		JavaBridge.armTap(TAP_X, TAP_Y);
		pump();
		final int ticks = settleUntilArmed();
		assertTrue("the gate must prove the point before it parks, not on the first tick", ticks >= 2);

		JavaBridge.onClick(TAP_X, TAP_Y, MouseEvent.BUTTON1);
		pump();

		assertEquals("the lift must click without waiting on another settle",
			List.of("PRESSED", "RELEASED", "CLICKED"), cap.buttonSequence());
		final MouseEvent press = cap.first(MouseEvent.MOUSE_PRESSED);
		final MouseEvent release = cap.first(MouseEvent.MOUSE_RELEASED);
		assertEquals("press x", TAP_X, press.getX());
		assertEquals("press y", TAP_Y, press.getY());
		assertEquals("release x", TAP_X, release.getX());
		assertEquals("release y", TAP_Y, release.getY());
	}

	/**
	 * The engine acts on the press within a tick and raises {@code MenuOptionClicked} for it. That must find the
	 * tap in {@code CLICKED}: with the press out early it arrived while the tap was still armed, was ignored, and
	 * the tap later timed out with no result (the "CLICKED timeout ... (unexpected)" log).
	 */
	@Test
	public void theEnginesAnswerFindsTheTapWaitingForIt() throws Exception
	{
		JavaBridge.armTap(TAP_X, TAP_Y);
		pump();
		settleUntilArmed();
		JavaBridge.onClick(TAP_X, TAP_Y, MouseEvent.BUTTON1);
		pump();
		assertEquals("the press goes out with the tap waiting for its answer", "CLICKED", tapState());

		final MenuOptionClicked answer = new MenuOptionClicked(walkEntry());
		invokeMenuOptionClicked(answer);

		assertFalse("the tap's own click must reach the game", answer.isConsumed());
		assertFalse("and it must close the tap", "CLICKED".equals(tapState()));
	}

	/** A throw out of the tick while armed resets the state machine and leaves no button down. */
	@Test
	public void aThrowWhileArmedLeavesNoButtonDown() throws Exception
	{
		JavaBridge.armTap(TAP_X, TAP_Y);
		pump();
		settleUntilArmed();

		menuOpenThrows.set(true);
		JavaBridge.tapTick(client);
		pump();

		assertEquals("the tick must reset", "IDLE", tapState());
		assertEquals("and must not have pressed", 0, cap.count(MouseEvent.MOUSE_PRESSED));
	}

	/** An arm nobody commits times out without ever pressing. */
	@Test
	public void anArmNobodyCommitsTimesOutWithoutPressing() throws Exception
	{
		JavaBridge.armTap(TAP_X, TAP_Y);
		pump();
		settleUntilArmed();

		for (int i = 0; i < 200 && "ARMED".equals(tapState()); i++)
		{
			JavaBridge.tapTick(client);
		}
		pump();

		assertEquals("the arm must time out", "IDLE", tapState());
		assertEquals("without pressing", 0, cap.count(MouseEvent.MOUSE_PRESSED));
	}

	/**
	 * An item drag owns the button from its own press to its lift. Both shells start one by dropping the tap's arm
	 * ({@code cancelArmedTap}) and then posting the drag's press ({@code onTouch}) in the same breath; with no tap
	 * press ever down, nothing may release the item before the finger lifts.
	 */
	@Test
	public void anItemDragKeepsHoldingTheItemUntilTheFingerLifts() throws Exception
	{
		JavaBridge.armTap(TAP_X, TAP_Y);
		pump();
		settleUntilArmed();
		cap.clear();

		// The real client thread runs work handed to it from another thread on its next frame, not inline.
		final List<Runnable> nextFrame = new ArrayList<>();
		JavaBridge.setClientThread(deferredClientThread(nextFrame));
		JavaBridge.cancelArmedTap();
		JavaBridge.onTouch(0, TAP_X, TAP_Y, 1);         // press on the source slot
		JavaBridge.onTouch(1, TAP_X + 40, TAP_Y, 1);    // the finger moves before the client thread runs
		runFrame(nextFrame);
		JavaBridge.onTouch(1, TAP_X + 80, TAP_Y, 1);
		runFrame(nextFrame);

		assertEquals("the drag presses once and stays held",
			List.of("PRESSED", "DRAGGED", "DRAGGED"), cap.buttonSequence());

		JavaBridge.onTouch(2, TAP_X + 80, TAP_Y, 1);    // the lift
		runFrame(nextFrame);

		assertEquals("only the lift may release the drag",
			List.of("PRESSED", "DRAGGED", "DRAGGED", "RELEASED"), cap.buttonSequence());
		assertEquals("the item is let go where the finger lifted", TAP_X + 80, cap.last(MouseEvent.MOUSE_RELEASED).getX());
		assertEquals("and a drag is never a click", 0, cap.count(MouseEvent.MOUSE_CLICKED));
	}

	// ---- harness ---------------------------------------------------------------------------------------

	/** A {@link ClientThread} like the real one seen from another thread: work waits for the next frame. */
	private static ClientThread deferredClientThread(List<Runnable> nextFrame)
	{
		final ClientThread ct = mock(ClientThread.class);
		doAnswer(inv ->
		{
			nextFrame.add(inv.getArgument(0));
			return null;
		}).when(ct).invoke(any(Runnable.class));
		doAnswer(inv ->
		{
			nextFrame.add(inv.getArgument(0));
			return null;
		}).when(ct).invokeLater(any(Runnable.class));
		return ct;
	}

	/** One client frame: run what was handed over, in order, then flush what it posted. */
	private static void runFrame(List<Runnable> nextFrame) throws Exception
	{
		final List<Runnable> work = new ArrayList<>(nextFrame);
		nextFrame.clear();
		work.forEach(Runnable::run);
		pump();
	}

	/** Drive the settle gate a frame at a time until it accepts and parks the arm. Returns the ticks it took. */
	private int settleUntilArmed() throws Exception
	{
		for (int i = 1; i <= 40; i++)
		{
			JavaBridge.tapTick(client);
			pump();
			if ("ARMED".equals(tapState()))
			{
				return i;
			}
		}
		throw new AssertionError("the settle gate never accepted in 40 ticks");
	}

	/** Flush everything already posted: an InvocationEvent behind them is dispatched last. */
	private static void pump() throws Exception
	{
		EventQueue.invokeAndWait(() ->
		{
		});
	}

	private Client loggedInClient(Canvas c)
	{
		// A stable menu tail is what the gate watches: identical reads for STABLE_NEEDED consecutive frames is
		// its proof that the engine rebuilt its menu from OUR move. One fixed entry gives exactly that.
		final MenuEntry[] entries = {walkEntry()};
		final Menu menu = mock(Menu.class);
		when(menu.getMenuEntries()).thenReturn(entries);

		final Client cl = mock(Client.class);
		when(cl.getCanvas()).thenReturn(c);
		when(cl.getGameState()).thenReturn(GameState.LOGGED_IN);
		when(cl.isMenuOpen()).thenAnswer(inv ->
		{
			if (menuOpenThrows.get())
			{
				throw new RuntimeException("engine read blew up");
			}
			return menuOpen.get();
		});
		when(cl.getMenu()).thenReturn(menu);
		// The gate's other observable: the engine's own cursor, which it compares to the tap point. Reporting
		// the tap point stands in for the EDT having folded our move.
		when(cl.getMouseCanvasPosition()).thenReturn(new Point(TAP_X, TAP_Y));
		return cl;
	}

	private static MenuEntry walkEntry()
	{
		final MenuEntry e = mock(MenuEntry.class);
		when(e.getOption()).thenReturn("Walk here");
		when(e.getTarget()).thenReturn("");
		when(e.getType()).thenReturn(MenuAction.WALK);
		when(e.getIdentifier()).thenReturn(0);
		when(e.getParam0()).thenReturn(0);
		when(e.getParam1()).thenReturn(0);
		when(e.getItemId()).thenReturn(-1);
		when(e.getWorldViewId()).thenReturn(-1);
		return e;
	}

	/** A {@link ClientThread} that runs its work inline, so the tap ingress resolves within the test thread. */
	/**
	 * The world list picks the row its last draw found under the cursor, so the click has to wait for a draw after
	 * the move. Posted together, tapping a world chose the row under the previous tap.
	 */
	@Test
	public void aLoginScreenClickWaitsForADrawAfterItsMove() throws Exception
	{
		when(client.getGameState()).thenReturn(net.runelite.api.GameState.LOGIN_SCREEN);
		final List<java.util.function.BooleanSupplier> drain = new ArrayList<>();
		final ClientThread ct = mock(ClientThread.class);
		doAnswer(inv ->
		{
			drain.add(inv.getArgument(0));
			return null;
		}).when(ct).invokeLater(any(java.util.function.BooleanSupplier.class));
		JavaBridge.setClientThread(ct);

		JavaBridge.onClick(TAP_X, TAP_Y, MouseEvent.BUTTON1);
		pump();
		assertEquals("the cursor moves at once", TAP_X, cap.last(MouseEvent.MOUSE_MOVED).getX());
		assertEquals("one deferred click", 1, drain.size());

		assertFalse("first drain: the engine has not drawn yet", drain.get(0).getAsBoolean());
		assertFalse("second drain: one draw is not known to be finished", drain.get(0).getAsBoolean());
		pump();
		assertEquals(0, cap.count(MouseEvent.MOUSE_PRESSED));

		assertTrue("third drain: the click goes out", drain.get(0).getAsBoolean());
		pump();
		assertEquals(TAP_X, cap.first(MouseEvent.MOUSE_PRESSED).getX());
		assertEquals(TAP_Y, cap.first(MouseEvent.MOUSE_PRESSED).getY());
		assertEquals(1, cap.count(MouseEvent.MOUSE_RELEASED));
	}

	private static ClientThread inlineClientThread()
	{
		final ClientThread ct = mock(ClientThread.class);
		doAnswer(inv ->
		{
			((Runnable) inv.getArgument(0)).run();
			return null;
		}).when(ct).invoke(any(Runnable.class));
		doAnswer(inv ->
		{
			((Runnable) inv.getArgument(0)).run();
			return null;
		}).when(ct).invokeLater(any(Runnable.class));
		return ct;
	}

	private static void invokeMenuOptionClicked(MenuOptionClicked ev) throws Exception
	{
		final Method m = JavaBridge.class.getDeclaredMethod("onMenuOptionClicked", MenuOptionClicked.class);
		m.setAccessible(true);
		m.invoke(null, ev);
	}

	/** The tap statics are shared across tests; start each one from rest. */
	private static void resetTapState() throws Exception
	{
		set("tapState", enumValue("TapState", "IDLE"));
		set("tapUncommitted", false);
		set("queuedTap", false);
		set("entered", false);
		set("focused", false);
		set("pressed", false);
	}

	private static Object enumValue(String type, String name) throws Exception
	{
		for (final Class<?> c : JavaBridge.class.getDeclaredClasses())
		{
			if (c.getSimpleName().equals(type))
			{
				for (final Object o : c.getEnumConstants())
				{
					if (o.toString().equals(name))
					{
						return o;
					}
				}
			}
		}
		throw new AssertionError("no " + type + "." + name);
	}

	private static String tapState() throws Exception
	{
		final Field f = JavaBridge.class.getDeclaredField("tapState");
		f.setAccessible(true);
		return String.valueOf(f.get(null));
	}

	private static void set(String field, Object value) throws Exception
	{
		final Field f = JavaBridge.class.getDeclaredField(field);
		f.setAccessible(true);
		f.set(null, value);
	}

	/**
	 * Records the {@link MouseEvent}s the bridge posts. Mouse events are swallowed rather than passed to
	 * {@code super}: the assertion is about what was POSTED, and a non-displayable test canvas is not a
	 * meaningful delivery target. Everything else (the focus {@code InvocationEvent}s, our own pump) passes
	 * through untouched.
	 */
	private static final class Capture extends EventQueue
	{
		private final List<MouseEvent> seen = new ArrayList<>();

		@Override
		protected void dispatchEvent(AWTEvent e)
		{
			if (e instanceof MouseEvent)
			{
				synchronized (seen)
				{
					seen.add((MouseEvent) e);
				}
				return;
			}
			super.dispatchEvent(e);
		}

		void clear()
		{
			synchronized (seen)
			{
				seen.clear();
			}
		}

		int count(int id)
		{
			synchronized (seen)
			{
				return (int) seen.stream().filter(e -> e.getID() == id).count();
			}
		}

		MouseEvent first(int id)
		{
			synchronized (seen)
			{
				return seen.stream().filter(e -> e.getID() == id).findFirst()
					.orElseThrow(() -> new AssertionError("no event with id " + id));
			}
		}

		MouseEvent last(int id)
		{
			synchronized (seen)
			{
				return seen.stream().filter(e -> e.getID() == id).reduce((a, b) -> b)
					.orElseThrow(() -> new AssertionError("no event with id " + id));
			}
		}

		/** The button events in the order they were posted: what decides whether something is held or clicked. */
		List<String> buttonSequence()
		{
			synchronized (seen)
			{
				final List<String> out = new ArrayList<>();
				for (final MouseEvent e : seen)
				{
					switch (e.getID())
					{
						case MouseEvent.MOUSE_PRESSED:
							out.add("PRESSED");
							break;
						case MouseEvent.MOUSE_RELEASED:
							out.add("RELEASED");
							break;
						case MouseEvent.MOUSE_DRAGGED:
							out.add("DRAGGED");
							break;
						case MouseEvent.MOUSE_CLICKED:
							out.add("CLICKED");
							break;
						default:
							break;
					}
				}
				return out;
			}
		}

		void popQueue()
		{
			super.pop();
		}
	}
}
