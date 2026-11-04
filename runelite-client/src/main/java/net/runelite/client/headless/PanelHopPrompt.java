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

/**
 * Spots the game's "Are you sure you wish to switch to World N?" prompt opening. It comes up in the chatbox when a
 * plugin hops through the game's own hop, as Star Miners does. On desktop the side panel sits beside the chatbox. On a
 * phone it covers it, so the player taps a row, sees nothing happen and can't answer the question they were never
 * shown. The native World Switcher doesn't meet the prompt: it hops by relogging.
 */
final class PanelHopPrompt
{
	private static final String WORDING = "switch to World";

	private boolean up;

	/** True on the frame it opens and no other, so a panel opened while it's still up can stay open. Client thread. */
	boolean justOpened(Client c)
	{
		final Widget text = c.getWidget(InterfaceID.Objectbox.TEXT);
		final boolean now = text != null && !text.isHidden() && text.getText() != null
			&& text.getText().contains(WORDING);
		final boolean opened = now && !up;
		up = now;
		return opened;
	}
}
