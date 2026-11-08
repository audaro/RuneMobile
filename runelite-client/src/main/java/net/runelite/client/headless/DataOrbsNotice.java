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

import net.runelite.api.ChatMessageType;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.gameval.InterfaceID;
import net.runelite.api.gameval.VarbitID;

/**
 * Tells a player why there are no orbs by the minimap, and how to get them back.
 *
 * <p>The orbs (interface 160) are the server's to open, and it leaves them closed for a player with the game's Show
 * data orbs setting off. This client used to open them itself so the slot wouldn't look empty, but the server ignores
 * a click on an interface it never opened: the orbs drew, even changed colour, and did nothing. So the slot now stays
 * the way the server left it, the same as on desktop, and this says why. The official mobile app can't change the
 * setting (script 3975 returns early there), so it can still be off from a desktop session long ago.
 *
 * <p>The world map goes with them. Its button is one of the orbs, and the game's Ctrl+M is only a key on that button
 * (scripts 1492 and 5141), so with the orbs closed nothing on this side can open the map.
 *
 * <p>Turning the setting back on stays with the player. It's their account, and a client-side varbit write wouldn't
 * reach the server anyway. The server opens the orbs the moment it's ticked, so no relog is needed. Client thread.
 */
final class DataOrbsNotice
{
	/** No {@code <} in here: the chatbox reads one as the start of a tag. */
	static final String MESSAGE = "Rune Mobile: your orbs and world map button are turned off. To get them back, tick"
		+ " Show data orbs in All Settings, Interfaces.";

	/**
	 * How long a login gets before its orbs are judged. The setting and the interface arrive in the login's first
	 * packets, and until then the setting can still be the previous player's.
	 */
	static final int SETTLE_TICKS = 5;

	private static boolean told;
	private static int loginTick = -1;

	private DataOrbsNotice()
	{
	}

	/** Once per login: a world hop leaves through the same states, but never through the login screen. */
	static void tick(Client c)
	{
		try
		{
			final GameState state = c.getGameState();
			if (state == GameState.LOGIN_SCREEN)
			{
				told = false;
				loginTick = -1;
				return;
			}
			if (state != GameState.LOGGED_IN || told)
			{
				return;
			}
			final int now = c.getTickCount();
			if (loginTick < 0)
			{
				loginTick = now;
			}
			if (now - loginTick >= SETTLE_TICKS && orbsOff(c))
			{
				told = true;
				tell(c);
			}
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("DataOrbsNotice.tick", ex);
		}
	}

	/** The native map button found no orb to press: every tap gets the reason, or it just looks broken. */
	static void mapTapped(Client c)
	{
		try
		{
			if (orbsOff(c))
			{
				tell(c);
			}
		}
		catch (RuntimeException ex)
		{
			BridgeFaults.note("DataOrbsNotice.mapTapped", ex);
		}
	}

	private static void tell(Client c)
	{
		c.addChatMessage(ChatMessageType.GAMEMESSAGE, "", MESSAGE, null);
	}

	/** Both, because the setting alone isn't the orbs: the server can still have them open from before it changed.
	 *  Open means mounted, not loaded: the orbs group can resolve while the server holds it closed. */
	private static boolean orbsOff(Client c)
	{
		return c.getVarbitValue(VarbitID.ORBS_DISABLED) != 0 && !Interfaces.mounted(c, InterfaceID.ORBS);
	}

	/** Test seam: forget the current login. */
	static void resetForTest()
	{
		told = false;
		loginTick = -1;
	}
}
