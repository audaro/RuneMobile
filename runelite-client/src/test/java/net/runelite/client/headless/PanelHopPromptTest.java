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
import net.runelite.api.widgets.Widget;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import org.junit.Test;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Only the opening of the hop prompt counts, and only the hop prompt. */
public class PanelHopPromptTest
{
	private final Client client = mock(Client.class);
	private final PanelHopPrompt prompt = new PanelHopPrompt();

	private void showing(String text)
	{
		final Widget w = mock(Widget.class);
		when(w.getText()).thenReturn(text);
		when(client.getWidget(InterfaceID.Objectbox.TEXT)).thenReturn(w);
	}

	private void gone()
	{
		when(client.getWidget(InterfaceID.Objectbox.TEXT)).thenReturn(null);
	}

	@Test
	public void nothingOpenIsNothing()
	{
		gone();
		assertFalse(prompt.justOpened(client));
	}

	@Test
	public void itFiresOnTheFrameThePromptOpens()
	{
		gone();
		prompt.justOpened(client);
		showing("Are you sure you wish to switch to World 316?");
		assertTrue(prompt.justOpened(client));
	}

	@Test
	public void itFiresOnceHoweverLongThePromptStaysUp()
	{
		showing("Are you sure you wish to switch to World 316?");
		prompt.justOpened(client);
		assertFalse(prompt.justOpened(client));
		assertFalse(prompt.justOpened(client));
	}

	@Test
	public void theNextPromptFiresAgain()
	{
		showing("Are you sure you wish to switch to World 316?");
		prompt.justOpened(client);
		gone();
		prompt.justOpened(client);
		showing("Are you sure you wish to switch to World 326?");
		assertTrue(prompt.justOpened(client));
	}

	@Test
	public void anotherMessageInTheSameBoxIsLeftAlone()
	{
		showing("You find some ore.");
		assertFalse(prompt.justOpened(client));
	}

	@Test
	public void aHiddenBoxIsNotOpen()
	{
		showing("Are you sure you wish to switch to World 316?");
		when(client.getWidget(InterfaceID.Objectbox.TEXT).isHidden()).thenReturn(true);
		assertFalse(prompt.justOpened(client));
	}

	@Test
	public void aBoxWithNoTextYetIsNotOpen()
	{
		showing(null);
		assertFalse(prompt.justOpened(client));
	}
}
