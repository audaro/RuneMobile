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

import java.awt.Canvas;
import net.runelite.api.Client;
import net.runelite.api.GameState;
import net.runelite.api.World;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import org.junit.Before;
import org.junit.Test;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for the {@link HeadlessLogin} latch web — the give-up ({@code gaveUp}) / reconnect
 * ({@code isReconnecting}) state the native shells read to decide between the "Reconnecting…" overlay and the
 * "Session expired — sign in again" card. These latches are behavioural contract the shared-contract signature
 * diff cannot see; a regression here strands the user on a silent black login screen with no card at all.
 * Invariants under test:
 * <ul>
 *   <li><b>Exhaustion latches {@code gaveUp}</b> on every automated stage (Play Now, Try Again), and only
 *       exhaustion — a healthy login/reconnect never shows the expired card.</li>
 *   <li><b>Every re-arm clears it</b>: a fresh CONNECTION_LOST re-arms the machine (budgets included) so a
 *       later recovery isn't starved by a previous give-up, and the reconnect budget itself is capped at
 *       {@code MAX_RECONNECT} per drop and refreshed by a successful login.</li>
 *   <li><b>LEGACY-1 stage order</b>: the post-disconnect "Try again" dialog (loginIndex 9) is handled BEFORE
 *       the legacy branch. Before the fix, a legacy-mode client parked on that dialog forever — no clicks, no
 *       give-up — because {@code tickLegacy} only understands loginIndex 0/2 and returned first.</li>
 *   <li><b>World-hop re-arm/cancel</b>: {@code requestWorldHop} re-arms a relogin into the target world
 *       (changeWorld on the login screen), {@code cancelWorldHop} restores idle without stranding state.</li>
 * </ul>
 * Pure: {@link Client} is mocked, the canvas is a bare headless AWT {@link Canvas} (the synthesized clicks go
 * to the toolkit EventQueue and are simply never dispatched). All login state is static, so every test starts
 * from {@link HeadlessLogin#resetForTest()}; the {@code -D} config (enable flag, shortened warmup/cooldown) is
 * set in the static initialiser before the class loads — reliable because no other test in the module touches
 * HeadlessLogin. Legacy mode is flipped per-test via {@link HeadlessLogin#setLegacyEnabledForTest} since the
 * property is read once at clinit.
 */
public class HeadlessLoginTest
{
	static
	{
		System.setProperty("java.awt.headless", "true");
		System.setProperty("runelite.headless.autologin", "true");
		// Shrink the draw-count pacing so exhaustion drives take tens of ticks, not thousands.
		System.setProperty("runelite.headless.autologin.warmup", "2");
		System.setProperty("runelite.headless.autologin.cooldown", "3");
	}

	// Mirrors of the production constants (MAX_ATTEMPTS default 5, MAX_TRYAGAIN_ATTEMPTS 30, MAX_RECONNECT 3)
	// sized as tick budgets: warmup + attempts * cooldown, with slack for the post-exhaustion latch tick.
	private static final int PLAY_EXHAUST_TICKS = 40;
	private static final int TRYAGAIN_EXHAUST_TICKS = 130;
	private static final int WELCOME_LOGIN_INDEX = 10;
	private static final int RECONNECT_LOGIN_INDEX = 9;

	private final Canvas canvas = new Canvas();
	private Client client;

	@Before
	public void reset()
	{
		HeadlessLogin.resetForTest();
		client = mock(Client.class);
		when(client.getCanvas()).thenReturn(canvas);
		when(client.getViewportWidth()).thenReturn(100);   // LOGGED_IN == in-world (no news overlay)
	}

	private void tickN(GameState state, int loginIndex, int n)
	{
		for (int i = 0; i < n; i++)
		{
			HeadlessLogin.tick(client, state, loginIndex);
		}
	}

	/** Drive a clean login to the {@code done} latch: Play Now once, then LOGGED_IN in-world. */
	private void driveToLoggedIn()
	{
		tickN(GameState.LOGIN_SCREEN, WELCOME_LOGIN_INDEX, 5);
		tickN(GameState.LOGGED_IN, -1, 1);
		assertFalse("a successful login must not read as given-up", HeadlessLogin.hasGivenUp());
		assertFalse("a successful login must not read as reconnecting", HeadlessLogin.isReconnecting());
	}

	@Test
	public void playNowExhaustionLatchesGiveUp()
	{
		tickN(GameState.LOGIN_SCREEN, WELCOME_LOGIN_INDEX, PLAY_EXHAUST_TICKS);
		assertTrue("exhausting the Play Now budget must latch gaveUp", HeadlessLogin.hasGivenUp());
		assertFalse("a hard give-up is not a transient reconnect", HeadlessLogin.isReconnecting());
	}

	@Test
	public void healthyLoginNeverGivesUp()
	{
		driveToLoggedIn();
	}

	@Test
	public void disconnectReArmClearsGiveUpAndReenablesRecovery()
	{
		// Park in the given-up state first (expired session: Play Now bounced 5 times).
		tickN(GameState.LOGIN_SCREEN, WELCOME_LOGIN_INDEX, PLAY_EXHAUST_TICKS);
		assertTrue(HeadlessLogin.hasGivenUp());

		// A real disconnect signal re-arms the machine: give-up clears, the reconnect overlay shows.
		tickN(GameState.CONNECTION_LOST, -1, 1);
		tickN(GameState.LOGIN_SCREEN, RECONNECT_LOGIN_INDEX, 1);
		assertFalse("CONNECTION_LOST re-arm must clear a prior give-up", HeadlessLogin.hasGivenUp());
		assertTrue("the re-armed cycle must read as reconnecting", HeadlessLogin.isReconnecting());
	}

	/**
	 * UX §4.7 regression: the post-login "Click here to play" news screen stays up (the 3D viewport is never
	 * allocated) and the fixed-coordinate auto-dismiss can't clear it. Before the fix this reported a clean
	 * login ({@code hasGivenUp() == false}) while stranding the user on the news screen; now the give-up is
	 * latched honestly so it isn't silently mistaken for success.
	 */
	@Test
	public void welcomeStrandLatchesGiveUpInsteadOfFalseSuccess()
	{
		when(client.getViewportWidth()).thenReturn(0);        // pre-spawn: the news overlay is still up
		tickN(GameState.LOGIN_SCREEN, WELCOME_LOGIN_INDEX, 5); // Play Now
		tickN(GameState.LOGGED_IN, -1, PLAY_EXHAUST_TICKS);    // welcome-dismiss exhausts its clicks pre-spawn
		assertTrue("a stranded post-login news screen must latch gaveUp", HeadlessLogin.hasGivenUp());
		assertFalse("a strand is not a transient reconnect", HeadlessLogin.isReconnecting());
	}

	@Test
	public void tryAgainExhaustionLatchesGiveUp()
	{
		driveToLoggedIn();
		tickN(GameState.CONNECTION_LOST, -1, 1);
		// The re-armed recovery lands on the "Try again" dialog and never gets past it (network stays dead).
		tickN(GameState.LOGIN_SCREEN, RECONNECT_LOGIN_INDEX, TRYAGAIN_EXHAUST_TICKS);
		assertTrue("exhausting the Try-Again budget must latch gaveUp", HeadlessLogin.hasGivenUp());
		assertFalse("an exhausted reconnect must drop the reconnecting overlay", HeadlessLogin.isReconnecting());
	}

	@Test
	public void reconnectBudgetIsCappedPerDropAndRefreshedBySuccess()
	{
		driveToLoggedIn();
		// Burn all MAX_RECONNECT re-arm cycles: each disconnect re-arms once, then the cycle dies on Try Again.
		for (int cycle = 0; cycle < 3; cycle++)
		{
			tickN(GameState.CONNECTION_LOST, -1, 1);
			tickN(GameState.LOGIN_SCREEN, RECONNECT_LOGIN_INDEX, TRYAGAIN_EXHAUST_TICKS);
			assertTrue("cycle " + cycle + " must end given-up", HeadlessLogin.hasGivenUp());
		}
		// Budget spent: a 4th disconnect must NOT re-arm (no infinite churn on a dead account/world).
		tickN(GameState.CONNECTION_LOST, -1, 1);
		tickN(GameState.LOGIN_SCREEN, RECONNECT_LOGIN_INDEX, 5);
		assertTrue("past MAX_RECONNECT the give-up must hold", HeadlessLogin.hasGivenUp());
		assertFalse(HeadlessLogin.isReconnecting());

		// ...but a SUCCESSFUL login refreshes the budget for the next real drop.
		HeadlessLogin.resetForTest();
		client = mock(Client.class);
		when(client.getCanvas()).thenReturn(canvas);
		when(client.getViewportWidth()).thenReturn(100);
		driveToLoggedIn();
		tickN(GameState.CONNECTION_LOST, -1, 1);
		tickN(GameState.LOGIN_SCREEN, RECONNECT_LOGIN_INDEX, 1);
		assertTrue("a fresh drop after success must re-arm", HeadlessLogin.isReconnecting());
	}

	/**
	 * LEGACY-1 regression: with legacy mode on (and no credentials in the env, so {@code tickLegacy} is a
	 * no-op), the loginIndex-9 "Try again" dialog must still be driven by the shared reconnect stage. Under
	 * the pre-fix ordering the legacy branch swallowed the tick first, so the machine neither clicked nor ever
	 * gave up — this drive would end with {@code hasGivenUp() == false}, parked forever.
	 */
	@Test
	public void legacyModeStillDrivesTheTryAgainDialog()
	{
		HeadlessLogin.setLegacyEnabledForTest(true);
		tickN(GameState.LOGIN_SCREEN, RECONNECT_LOGIN_INDEX, TRYAGAIN_EXHAUST_TICKS);
		assertTrue("legacy mode must reach the shared Try-Again stage (LEGACY-1 stage order)",
			HeadlessLogin.hasGivenUp());
	}

	@Test
	public void legacyBranchShortCircuitsTheJxStages()
	{
		HeadlessLogin.setLegacyEnabledForTest(true);
		// The JX welcome sub-state means nothing to a legacy client: no Play Now clicks, no give-up latch.
		tickN(GameState.LOGIN_SCREEN, WELCOME_LOGIN_INDEX, PLAY_EXHAUST_TICKS);
		assertFalse("legacy mode must not burn the JX Play Now budget", HeadlessLogin.hasGivenUp());
	}

	@Test
	public void worldHopReArmsAReloginIntoTheTarget()
	{
		final World world = mock(World.class);
		when(client.createWorld()).thenReturn(world);

		driveToLoggedIn();
		HeadlessLogin.requestWorldHop(316, "oldschool16.runescape.com", false);
		// Still LOGGED_IN while the logout is in flight — the machine must wait, not re-declare done.
		tickN(GameState.LOGGED_IN, -1, 3);
		// The logout lands: the relogin must point the client at the hop target before Play Now.
		tickN(GameState.LOGIN_SCREEN, WELCOME_LOGIN_INDEX, 5);
		verify(world).setId(316);
		verify(client).changeWorld(world);
		assertFalse(HeadlessLogin.hasGivenUp());
	}

	@Test
	public void cancelWorldHopRestoresIdleWithoutStranding()
	{
		driveToLoggedIn();
		HeadlessLogin.requestWorldHop(316, "oldschool16.runescape.com", false);
		HeadlessLogin.cancelWorldHop();
		// Disarmed and done again: a later login screen must not chase the stale hop target.
		tickN(GameState.LOGIN_SCREEN, WELCOME_LOGIN_INDEX, PLAY_EXHAUST_TICKS);
		verify(client, never()).changeWorld(any(World.class));
		assertFalse("a cancelled hop must not decay into a give-up", HeadlessLogin.hasGivenUp());
	}
}
