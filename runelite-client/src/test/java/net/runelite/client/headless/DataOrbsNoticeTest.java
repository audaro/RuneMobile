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

import java.util.ArrayList;
import java.util.List;
import net.runelite.api.ChatMessageType;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.HashTable;
import net.runelite.api.WidgetNode;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.gameval.VarbitID;
import net.runelite.api.widgets.Widget;
import static org.junit.Assert.assertFalse;
import org.junit.Before;
import org.junit.Test;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** The notice speaks once per login, only when the orbs really are off, and only once the login has landed. */
public class DataOrbsNoticeTest
{
	private Client c;

	@Before
	public void setUp()
	{
		DataOrbsNotice.resetForTest();
		c = mock(Client.class);
		when(c.getGameState()).thenReturn(GameState.LOGGED_IN);
		when(c.getTickCount()).thenReturn(100);
	}

	/** One frame of a login that began {@code ticks} ago. */
	private void frameAfter(int ticks)
	{
		when(c.getTickCount()).thenReturn(100 + ticks);
		DataOrbsNotice.tick(c);
	}

	/** Open = the server opened the orbs: they're loaded AND the component table holds them. */
	private void orbs(boolean settingOn, boolean open)
	{
		when(c.getVarbitValue(VarbitID.ORBS_DISABLED)).thenReturn(settingOn ? 0 : 1);
		when(c.getWidget(InterfaceID.Orbs.ORB_HEALTH)).thenReturn(open ? mock(Widget.class) : null);
		final HashTable<WidgetNode> table = open ? tableHolding(InterfaceID.ORBS) : tableHolding(); // built before the when(): it stubs mocks of its own
		when(c.getComponentTable()).thenReturn(table);
	}

	/** A component table with one open-interface node per group; a fresh iterator per walk. */
	private static HashTable<WidgetNode> tableHolding(int... groups)
	{
		final List<WidgetNode> nodes = new ArrayList<>();
		for (final int g : groups)
		{
			final WidgetNode n = mock(WidgetNode.class);
			when(n.getId()).thenReturn(g);
			nodes.add(n);
		}
		@SuppressWarnings("unchecked")
		final HashTable<WidgetNode> table = mock(HashTable.class);
		when(table.iterator()).thenAnswer(inv -> nodes.iterator());
		return table;
	}

	private void verifyTold(int times)
	{
		verify(c, times(times)).addChatMessage(ChatMessageType.GAMEMESSAGE, "", DataOrbsNotice.MESSAGE, null);
	}

	@Test
	public void theSettingOffAndNoOrbsSaysSoOnce()
	{
		orbs(false, false);
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		frameAfter(DataOrbsNotice.SETTLE_TICKS + 1);
		verifyTold(1);
	}

	@Test
	public void itWaitsForTheLoginToLand()
	{
		orbs(false, false);
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS - 1);
		verifyTold(0);
	}

	@Test
	public void theSettingOnSaysNothing()
	{
		orbs(true, true);
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		verifyTold(0);
	}

	/** Until the login's first packets land, the setting can still be the last player's. */
	@Test
	public void theLastPlayersSettingSaysNothing()
	{
		orbs(false, false);
		frameAfter(0);
		orbs(true, true);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		verifyTold(0);
	}

	@Test
	public void orbsTheServerStillHoldsOpenSayNothing()
	{
		orbs(false, true);
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		verifyTold(0);
	}

	/** The orbs group can load with the server holding it closed. Loaded is not open, so the player still hears why. */
	@Test
	public void orbsLoadedButNotOpenStillSaySo()
	{
		orbs(false, false);
		when(c.getWidget(InterfaceID.Orbs.ORB_HEALTH)).thenReturn(mock(Widget.class));
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		verifyTold(1);
	}

	@Test
	public void unTickingItLaterStillExplainsTheEmptySlot()
	{
		orbs(true, true);
		frameAfter(0);
		frameAfter(50);
		orbs(false, false);
		frameAfter(51);
		verifyTold(1);
	}

	@Test
	public void aWorldHopDoesNotRepeatIt()
	{
		orbs(false, false);
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		when(c.getGameState()).thenReturn(GameState.HOPPING);
		DataOrbsNotice.tick(c);
		when(c.getGameState()).thenReturn(GameState.LOADING);
		DataOrbsNotice.tick(c);
		when(c.getGameState()).thenReturn(GameState.LOGGED_IN);
		frameAfter(DataOrbsNotice.SETTLE_TICKS + 20);
		verifyTold(1);
	}

	@Test
	public void theNextLoginSaysItAgain()
	{
		orbs(false, false);
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		when(c.getGameState()).thenReturn(GameState.LOGIN_SCREEN);
		DataOrbsNotice.tick(c);
		when(c.getGameState()).thenReturn(GameState.LOGGED_IN);
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		verifyTold(2);
	}

	@Test
	public void nothingIsSaidOffTheGameScreen()
	{
		orbs(false, false);
		when(c.getGameState()).thenReturn(GameState.LOGIN_SCREEN);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		when(c.getGameState()).thenReturn(GameState.LOADING);
		frameAfter(DataOrbsNotice.SETTLE_TICKS + 1);
		verify(c, never()).addChatMessage(any(), any(), any(), any());
	}

	@Test
	public void everyMapTapWithTheOrbsOffGetsTheReason()
	{
		orbs(false, false);
		DataOrbsNotice.mapTapped(c);
		DataOrbsNotice.mapTapped(c);
		verifyTold(2);
	}

	/** Mid-rebuild there's no orb for a moment, and that's no reason to tell a player their setting is off. */
	@Test
	public void aMapTapWithTheSettingOnSaysNothing()
	{
		orbs(true, false);
		DataOrbsNotice.mapTapped(c);
		verifyTold(0);
	}

	/** One try: the frame loop must not spend a login retrying a chat line. */
	@Test
	public void aChatFailureStaysHereAndIsNotRetried()
	{
		orbs(false, false);
		when(c.addChatMessage(eq(ChatMessageType.GAMEMESSAGE), eq(""), eq(DataOrbsNotice.MESSAGE), any()))
			.thenThrow(new IllegalStateException("no chatbox yet"));
		frameAfter(0);
		frameAfter(DataOrbsNotice.SETTLE_TICKS);
		frameAfter(DataOrbsNotice.SETTLE_TICKS + 1);
		verifyTold(1);
	}

	@Test
	public void theMessageHasNoTagOpener()
	{
		assertFalse(DataOrbsNotice.MESSAGE.contains("<"));
	}
}
