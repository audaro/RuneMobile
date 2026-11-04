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

import java.awt.event.MouseAdapter;
import javax.swing.JLabel;
import javax.swing.JPanel;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import org.junit.Before;
import org.junit.Test;

/** Rows shaped like Star Miners': a listening row, with listening columns, over text labels that listen for nothing. */
public class PanelClicksTest
{
	private static final long MS = 1_000_000L;

	private final PanelClicks clicks = new PanelClicks();
	private JPanel list;
	private JPanel rowA;
	private JPanel rowB;
	private JPanel worldColumnA;
	private JPanel locationColumnA;
	private JPanel worldColumnB;
	private JLabel labelA;

	@Before
	public void setUp()
	{
		list = new JPanel();
		list.setSize(240, 340);
		rowA = row(0);
		rowB = row(34);
		worldColumnA = (JPanel) ((JPanel) rowA.getComponent(0)).getComponent(0);
		locationColumnA = (JPanel) ((JPanel) rowA.getComponent(0)).getComponent(1);
		worldColumnB = (JPanel) ((JPanel) rowB.getComponent(0)).getComponent(0);
		labelA = (JLabel) worldColumnA.getComponent(0);
	}

	private JPanel row(int y)
	{
		final JPanel row = listening(new JPanel());
		row.setBounds(0, y, 240, 34);
		final JPanel inner = new JPanel();
		inner.setBounds(0, 2, 240, 30);
		final JPanel world = listening(new JPanel());
		world.setBounds(0, 0, 40, 30);
		world.add(new JLabel("301"));
		final JPanel location = listening(new JPanel());
		location.setBounds(40, 0, 120, 30);
		location.add(new JLabel("Crafting Guild"));
		inner.add(world);
		inner.add(location);
		row.add(inner);
		list.add(row);
		return row;
	}

	private static JPanel listening(JPanel p)
	{
		p.addMouseListener(new MouseAdapter()
		{
		});
		return p;
	}

	@Test
	public void aTapOnBareTextGoesToWhateverListensAboveIt()
	{
		assertSame(worldColumnA, PanelClicks.target(labelA));
	}

	@Test
	public void aComponentThatListensKeepsItsOwnTap()
	{
		assertSame(rowA, PanelClicks.target(rowA));
	}

	@Test
	public void withNothingListeningTheTapStaysWhereItLanded()
	{
		final JPanel bare = new JPanel();
		final JLabel text = new JLabel("x");
		bare.add(text);
		assertSame(text, PanelClicks.target(text));
	}

	@Test
	public void theFirstTapIsASingleClick()
	{
		assertEquals(1, clicks.count(worldColumnA, 0));
	}

	@Test
	public void aSecondQuickTapIsADoubleClick()
	{
		clicks.count(worldColumnA, 0);
		assertEquals(2, clicks.count(worldColumnA, 300 * MS));
	}

	@Test
	public void aSlowSecondTapStartsAgain()
	{
		clicks.count(worldColumnA, 0);
		assertEquals(1, clicks.count(worldColumnA, 501 * MS));
	}

	@Test
	public void theWindowRunsFromTheLastTapNotTheFirst()
	{
		clicks.count(worldColumnA, 0);
		clicks.count(worldColumnA, 400 * MS);
		assertEquals(3, clicks.count(worldColumnA, 800 * MS));
	}

	@Test
	public void mashingKeepsCountingSoADoubleClickHandlerFiresOnce()
	{
		clicks.count(worldColumnA, 0);
		clicks.count(worldColumnA, 100 * MS);
		assertEquals(3, clicks.count(worldColumnA, 200 * MS));
		assertEquals(4, clicks.count(worldColumnA, 300 * MS));
	}

	@Test
	public void aThumbDriftingToAnotherColumnIsStillTheSameRow()
	{
		clicks.count(worldColumnA, 0);
		assertEquals(2, clicks.count(locationColumnA, 150 * MS));
	}

	@Test
	public void theRowAndItsColumnsAreOneThing()
	{
		clicks.count(rowA, 0);
		assertEquals(2, clicks.count(worldColumnA, 150 * MS));
	}

	@Test
	public void theColumnsAndTheirRowAreOneThingInThatOrderToo()
	{
		clicks.count(worldColumnA, 0);
		assertEquals(2, clicks.count(rowA, 150 * MS));
	}

	@Test
	public void twoRowsAreNeverOneDoubleClick()
	{
		clicks.count(worldColumnA, 0);
		assertEquals(1, clicks.count(worldColumnB, 150 * MS));
	}

	@Test
	public void aListenerOnTheWholeListDoesNotJoinItsRows()
	{
		listening(list);
		clicks.count(worldColumnA, 0);
		assertEquals(1, clicks.count(worldColumnB, 150 * MS));
	}

	@Test
	public void aRowRebuiltBetweenTheTapsIsANewTap()
	{
		clicks.count(worldColumnA, 0);
		list.remove(rowA);
		assertEquals(1, clicks.count(worldColumnB, 150 * MS));
	}

	@Test
	public void resetForgetsTheLastTap()
	{
		clicks.count(worldColumnA, 0);
		clicks.reset();
		assertEquals(1, clicks.count(worldColumnA, 150 * MS));
	}
}
