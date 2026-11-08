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
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.gameval.VarbitID;
import net.runelite.api.widgets.Widget;
import static org.junit.Assert.assertEquals;
import org.junit.Test;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** A hop's logout presses the logout tab of the root the tabs are on, never an old layout that still resolves. */
public class WorldSwitcherBridgeTest
{
	/** A resizable client with the arrangement setting and both toplevels' logout stones loaded. */
	private static Client resizedWithBothStones(boolean preEocArrangement)
	{
		final Client c = mock(Client.class);
		when(c.isResized()).thenReturn(true);
		when(c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT)).thenReturn(preEocArrangement ? 1 : 0);
		when(c.getWidget(InterfaceID.ToplevelPreEoc.STONE10)).thenReturn(mock(Widget.class));
		when(c.getWidget(InterfaceID.ToplevelOsrsStretch.STONE10)).thenReturn(mock(Widget.class));
		return c;
	}

	/** After a switch away from the modern layout its toplevel can still resolve; its stone would do nothing. */
	@Test
	public void theOldLayoutStillLoadedDoesNotWin()
	{
		assertEquals(InterfaceID.ToplevelOsrsStretch.STONE10, WorldSwitcherBridge.logoutStoneId(resizedWithBothStones(false)));
	}

	@Test
	public void theModernArrangementUsesItsOwnStone()
	{
		assertEquals(InterfaceID.ToplevelPreEoc.STONE10, WorldSwitcherBridge.logoutStoneId(resizedWithBothStones(true)));
	}

	@Test
	public void fixedHasNoStoneToPress()
	{
		final Client c = resizedWithBothStones(true);
		when(c.isResized()).thenReturn(false);
		assertEquals(-1, WorldSwitcherBridge.logoutStoneId(c));
	}

	/** Before the arranged root is built the hop must fail fast, not press the other root's stone. */
	@Test
	public void anUnbuiltRootHasNoStoneToPress()
	{
		final Client c = resizedWithBothStones(false);
		when(c.getWidget(InterfaceID.ToplevelOsrsStretch.STONE10)).thenReturn(null);
		assertEquals(-1, WorldSwitcherBridge.logoutStoneId(c));
	}
}
