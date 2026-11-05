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

import net.runelite.api.GameState;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import org.junit.Test;

/** Where 117HD may start: both ports in the world, and only Android on the login screen. */
public class RLHDStarterTest
{
	@Test
	public void waitingForTheWorldSkipsTheLoginScreen()
	{
		assertFalse(RLHDStarter.engages(GameState.LOGIN_SCREEN, true));
		assertTrue(RLHDStarter.engages(GameState.LOGGED_IN, true));
	}

	@Test
	public void notWaitingStartsOnEither()
	{
		assertTrue(RLHDStarter.engages(GameState.LOGIN_SCREEN, false));
		assertTrue(RLHDStarter.engages(GameState.LOGGED_IN, false));
	}

	@Test
	public void noOtherStateStartsIt()
	{
		for (GameState state : new GameState[]{GameState.STARTING, GameState.LOGGING_IN, GameState.LOADING,
			GameState.CONNECTION_LOST, GameState.HOPPING})
		{
			assertFalse(state.name(), RLHDStarter.engages(state, false));
			assertFalse(state.name(), RLHDStarter.engages(state, true));
		}
	}
}
