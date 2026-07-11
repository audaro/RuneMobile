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

import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.MenuAction;
import net.runelite.api.MenuEntry;
import net.runelite.api.Point;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import org.junit.Test;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link MenuPeekBridge} — the read-only menu snapshot the native shells (iOS + Android) poll
 * each display tick. Two pieces of its output are a hard cross-port contract that the shared-contract
 * signature diff <em>cannot</em> catch (it only sees method shapes, not their emitted bytes):
 * <ul>
 *   <li>the {@linkplain MenuPeekBridge#getTopFingerprint() top-entry fingerprint} string the native side
 *       caches and string-compares for release-revalidation, and</li>
 *   <li>the {@linkplain MenuPeekBridge#getSnapshot() JSON snapshot} the native menu parses (display order,
 *       tag stripping, escaping, the MAX_ENTRIES truncation).</li>
 * </ul>
 * A silent change to either format keeps every signature identical yet breaks both ports — exactly the gap
 * these tests close. They are pure (no engine boot): the {@link Client}/{@link MenuEntry} reads are mocked.
 *
 * <p>{@code MenuPeekBridge.ENABLED} is a {@code private static final} read once at class load from
 * {@code -Drunelite.menupeek}. The static initialiser below sets it before any test touches the class, which
 * is reliable here because no other test in the module references the headless bridges (so nothing loads the
 * class first). {@link #enabledFlagIsSet()} fails loudly if that assumption is ever violated.
 */
public class MenuPeekBridgeTest
{
	static
	{
		System.setProperty("runelite.menupeek", "true");
	}

	/** Guards the whole suite's premise: if the gate flag didn't take, every tick() test would be vacuously inert. */
	@Test
	public void enabledFlagIsSet()
	{
		assertTrue("runelite.menupeek must be enabled before MenuPeekBridge loads", MenuPeekBridge.isEnabled());
	}

	@Test
	public void tickNullClientIsInert()
	{
		final String snapBefore = MenuPeekBridge.getSnapshot();
		final long seqBefore = MenuPeekBridge.getPublishSeq();

		MenuPeekBridge.tick(null);

		assertEquals("null client must not publish", snapBefore, MenuPeekBridge.getSnapshot());
		assertEquals("null client must not bump the seq", seqBefore, MenuPeekBridge.getPublishSeq());
	}

	@Test
	public void tickNotLoggedInPublishesLoggedOutSnapshot()
	{
		final Client client = mock(Client.class);
		when(client.getGameState()).thenReturn(GameState.LOGIN_SCREEN);
		final long seqBefore = MenuPeekBridge.getPublishSeq();

		MenuPeekBridge.tick(client);

		assertEquals("{\"active\":true,\"loggedIn\":false}", MenuPeekBridge.getSnapshot());
		assertEquals("EMPTY", MenuPeekBridge.getTopFingerprint());
		assertTrue("logged-out tick still publishes (bumps seq)", MenuPeekBridge.getPublishSeq() > seqBefore);
	}

	@Test
	public void tickLoggedInEmitsEntriesInDisplayOrder()
	{
		// Engine array order is bottom..top; the DISPLAY top (left-click action) is the array TAIL. The snapshot
		// must emit tail-first so entries[0] is the left-click action.
		final MenuEntry bottom = entry("Walk here", "", MenuAction.WALK, 0, 0, 0, -1);
		final MenuEntry middle = entry("Examine", "Goblin", MenuAction.EXAMINE_NPC, 7, 0, 0, -1);
		final MenuEntry top = entry("Attack", "Goblin", MenuAction.NPC_SECOND_OPTION, 7, 1, 2, -1);

		final Client client = loggedInClient(new MenuEntry[]{bottom, middle, top}, new Point(100, 200));
		MenuPeekBridge.tick(client);
		final String snap = MenuPeekBridge.getSnapshot();

		assertTrue("active", snap.contains("\"active\":true"));
		assertTrue("loggedIn", snap.contains("\"loggedIn\":true"));
		assertTrue("count reflects full engine array", snap.contains("\"count\":3"));
		assertTrue("mouseX from canvas position", snap.contains("\"mouseX\":100"));
		assertTrue("mouseY from canvas position", snap.contains("\"mouseY\":200"));

		// Display order: Attack (tail/top) before Examine before Walk here.
		final int iAttack = snap.indexOf("Attack");
		final int iExamine = snap.indexOf("Examine");
		final int iWalk = snap.indexOf("Walk here");
		assertTrue("top entry emitted", iAttack >= 0);
		assertTrue("Attack (display top) before Examine", iAttack < iExamine);
		assertTrue("Examine before Walk here (display bottom)", iExamine < iWalk);

		// topFingerprint must match the tail entry's fingerprint exactly (the native release-revalidation key).
		assertEquals(MenuPeekBridge.fingerprint(top), MenuPeekBridge.getTopFingerprint());
	}

	@Test
	public void tickStripsTagsFromTargetInSnapshot()
	{
		final MenuEntry e = entry("Attack", "<col=ff0000>Goblin</col>", MenuAction.NPC_SECOND_OPTION, 7, 0, 0, -1);
		MenuPeekBridge.tick(loggedInClient(new MenuEntry[]{e}, new Point(1, 1)));
		final String snap = MenuPeekBridge.getSnapshot();

		assertTrue("colour tags stripped from target", snap.contains("\"tgt\":\"Goblin\""));
		assertFalse("no raw markup leaks into JSON", snap.contains("<col"));
	}

	@Test
	public void tickStripsAllKnownOsrsMarkupTags()
	{
		// stripTags is <[^>]*>, so it must strip EVERY OSRS markup form, not just <col=>. A leaked <img=> or
		// <br> would feed raw markup to the native menu parser. Kitchen sink of the tags OSRS targets carry;
		// the bodies (A..E) concatenate tag-free with no spurious whitespace.
		final String target = "<col=ff0000>A</col><shad=000000>B</shad><br><img=5>C<u=00ff00>D</u>E";
		final MenuEntry e = entry("Attack", target, MenuAction.NPC_SECOND_OPTION, 7, 0, 0, -1);
		MenuPeekBridge.tick(loggedInClient(new MenuEntry[]{e}, new Point(1, 1)));
		final String snap = MenuPeekBridge.getSnapshot();

		assertTrue("all tag bodies survive, stripped of markup", snap.contains("\"tgt\":\"ABCDE\""));
		for (final String tag : new String[]{"<col", "<shad", "<br", "<img", "<u"})
		{
			assertFalse("no " + tag + "> markup leaks into JSON", snap.contains(tag));
		}
		// And the fingerprint (the native string-compare key) is tag-free too.
		assertEquals("Attack|ABCDE|" + MenuAction.NPC_SECOND_OPTION + "|7|0|0|-1", MenuPeekBridge.fingerprint(e));
	}

	@Test
	public void tickEscapesJsonSpecialCharsInOption()
	{
		// A quote and a backslash must be escaped, and a newline folded to a space, or the snapshot is invalid JSON.
		final MenuEntry e = entry("Say \"hi\"\\\nnow", "", MenuAction.WALK, 0, 0, 0, -1);
		MenuPeekBridge.tick(loggedInClient(new MenuEntry[]{e}, new Point(1, 1)));
		final String snap = MenuPeekBridge.getSnapshot();

		assertTrue("double-quote escaped", snap.contains("Say \\\"hi\\\""));
		assertTrue("backslash escaped", snap.contains("hi\\\"\\\\"));
		assertFalse("newline folded out", snap.contains("\n"));
	}

	@Test
	public void tickTruncatesEntriesToMaxButReportsFullCount()
	{
		// MENU-2: a crowded scene must not silently drop entries past the cap — the array is truncated to
		// MAX_ENTRIES (default 32) for size, but "count" still reports the true total so the native side knows.
		final int total = 40;
		final MenuEntry[] entries = new MenuEntry[total];
		for (int i = 0; i < total; i++)
		{
			entries[i] = entry("Opt" + i, "", MenuAction.WALK, i, 0, 0, -1);
		}

		MenuPeekBridge.tick(loggedInClient(entries, new Point(1, 1)));
		final String snap = MenuPeekBridge.getSnapshot();

		assertTrue("full count is reported", snap.contains("\"count\":40"));
		assertEquals("only MAX_ENTRIES (32) entries emitted", 32, countOccurrences(snap, "\"opt\":"));
	}

	@Test
	public void publishSeqIsMonotonicAcrossTicks()
	{
		final Client client = loggedInClient(new MenuEntry[]{entry("X", "", MenuAction.WALK, 0, 0, 0, -1)}, new Point(0, 0));

		final long a = MenuPeekBridge.getPublishSeq();
		MenuPeekBridge.tick(client);
		final long b = MenuPeekBridge.getPublishSeq();
		MenuPeekBridge.tick(client);
		final long c = MenuPeekBridge.getPublishSeq();

		assertTrue("seq strictly increases each publish", b > a && c > b);
	}

	@Test
	public void fingerprintOfNullEntryIsEmpty()
	{
		assertEquals("EMPTY", MenuPeekBridge.fingerprint(null));
	}

	@Test
	public void fingerprintFormatStripsTagsFromTargetOnly()
	{
		// Contract format: option|stripTags(target)|type|id|param0|param1|itemId. Tags are stripped from the
		// target but NOT the option (options are plain text); the native side compares this string verbatim.
		final MenuEntry e = entry("Attack", "<col=ff0000>Goblin</col>", MenuAction.NPC_SECOND_OPTION, 5, 1, 2, -1);
		final String expected = "Attack|Goblin|" + MenuAction.NPC_SECOND_OPTION + "|5|1|2|-1";
		assertEquals(expected, MenuPeekBridge.fingerprint(e));
	}

	// ---- helpers ---------------------------------------------------------------------------------------

	private static MenuEntry entry(String opt, String tgt, MenuAction type, int id, int p0, int p1, int itemId)
	{
		final MenuEntry e = mock(MenuEntry.class);
		when(e.getOption()).thenReturn(opt);
		when(e.getTarget()).thenReturn(tgt);
		when(e.getType()).thenReturn(type);
		when(e.getIdentifier()).thenReturn(id);
		when(e.getParam0()).thenReturn(p0);
		when(e.getParam1()).thenReturn(p1);
		when(e.getItemId()).thenReturn(itemId);
		when(e.getWorldViewId()).thenReturn(-1);
		when(e.isDeprioritized()).thenReturn(false);
		when(e.isForceLeftClick()).thenReturn(false);
		// getSubMenu() defaults to null on a Mockito mock -> no submenu block, which is what we want here.
		return e;
	}

	private static Client loggedInClient(MenuEntry[] entries, Point mouse)
	{
		final Client client = mock(Client.class);
		when(client.getGameState()).thenReturn(GameState.LOGGED_IN);
		when(client.getMenuEntries()).thenReturn(entries);
		when(client.getMouseCanvasPosition()).thenReturn(mouse);
		when(client.isMenuOpen()).thenReturn(false);
		when(client.isMenuScrollable()).thenReturn(false);
		when(client.getMenuX()).thenReturn(10);
		when(client.getMenuY()).thenReturn(20);
		when(client.getMenuWidth()).thenReturn(140);
		when(client.getMenuHeight()).thenReturn(80);
		return client;
	}

	private static int countOccurrences(String haystack, String needle)
	{
		int n = 0;
		for (int i = haystack.indexOf(needle); i >= 0; i = haystack.indexOf(needle, i + needle.length()))
		{
			n++;
		}
		return n;
	}
}
