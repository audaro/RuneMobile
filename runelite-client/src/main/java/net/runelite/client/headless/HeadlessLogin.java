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
import java.awt.EventQueue;
import java.awt.Toolkit;
import java.awt.event.FocusEvent;
import java.awt.event.InputEvent;
import java.awt.event.KeyEvent;
import java.awt.event.MouseEvent;
import java.util.EnumSet;
import lombok.extern.slf4j.Slf4j;
import net.runelite.api.Client;
import net.runelite.api.Constants;
import net.runelite.api.GameState;
import net.runelite.api.World;
import net.runelite.api.WorldType;

/**
 * Gate 1c-ii / Phase-4 spike: the minimal slice of input injection needed to cross the
 * {@code LOGIN_SCREEN → LOGGED_IN} boundary headless, in-process (no native touch bridge).
 *
 * <p>The {@code JX_*} launcher handoff auto-<em>authenticates</em> the account — the gamepack renders the
 * "Welcome to RuneScape / Play Now / &lt;name&gt;" welcome screen ({@code loginIndex == 10}) — but does
 * <em>not</em> auto-<em>login</em>; it parks at {@link GameState#LOGIN_SCREEN} waiting for a click on the
 * Play Now button. There is no programmatic shortcut ({@code setGameState(LOGGED_IN)} doesn't drive the
 * gamepack's network login), so we synthesize the click.
 *
 * <p>On a <em>fresh</em> client (e.g. the device, where {@code .runelite} is recreated each install) the
 * gamepack first shows an <strong>EULA Accept/Decline dialog</strong> at an earlier login sub-state
 * ({@code loginIndex == 12} as observed on device) before it will reach the welcome screen. So this is a
 * <strong>two-stage</strong> state machine: if the EULA stage is enabled, click <em>Accept</em> first, then
 * (once the gamepack advances to {@code loginIndex == 10}) click <em>Play Now</em>. The EULA stage is inert
 * on a client that has already accepted (desktop), where {@code loginIndex} goes straight to 10.
 *
 * <p>This answers a real Phase-4 kill-risk: does the window-less engine accept a synthesized AWT mouse
 * event at all (it may gate input on real focus, which has no peer headless)? We post a focus-gain plus a
 * full enter/move/press/release/click sequence to the gamepack {@link Canvas} via the toolkit
 * {@link EventQueue} — the same mechanism a UIKit-touch → AWT-{@code MouseEvent} bridge would use on iOS.
 *
 * <p>Entirely inert unless {@code -Drunelite.headless.autologin=true}. The Play Now point defaults to the
 * button centre and is overridable with {@code -Drunelite.headless.autologin.point=x,y}; the EULA stage is
 * gated on {@code -Drunelite.headless.autologin.eula=true} with point
 * {@code -Drunelite.headless.autologin.eula.point=x,y} and sub-state
 * {@code -Drunelite.headless.autologin.eula.loginIndex=12}. Each stage re-arms up to {@code maxAttempts}
 * times if the state hasn't advanced, so a coordinate miss is visible (the captured frames + the attempt
 * log tell us whether the click landed).
 */
@Slf4j
public final class HeadlessLogin
{
	private static final boolean ENABLED = Boolean.getBoolean("runelite.headless.autologin");
	// The "logged into a Jagex account, ready to play" welcome screen — the only login sub-state with a
	// Play Now button. (2 = username/password form, 4 = authenticator.)
	private static final int WELCOME_LOGIN_INDEX =
		Integer.getInteger("runelite.headless.autologin.loginIndex", 10);
	private static final int WARMUP_DRAWS = Integer.getInteger("runelite.headless.autologin.warmup", 20);
	private static final int COOLDOWN_DRAWS = Integer.getInteger("runelite.headless.autologin.cooldown", 120);
	private static final int MAX_ATTEMPTS = Integer.getInteger("runelite.headless.autologin.maxAttempts", 5);

	// Legacy (non-Jagex) account mode: instead of the JX_* welcome screen, drive the classic
	// username/password form. The credentials come from the process ENVIRONMENT (set natively before
	// JNI_CreateJavaVM, like the JX_* handoff) — never from -D opts, which get logged. loginIndex 0 is
	// the initial "Welcome to RuneScape" panel (Enter activates the Existing User form); loginIndex 2 is
	// the username/password form (fields set via the Client API, Enter submits).
	// Non-final only for the test seam (setLegacyEnabledForTest) — production never writes it after clinit.
	private static boolean legacyEnabled = Boolean.getBoolean("runelite.headless.autologin.legacy");
	private static final String LEGACY_USER = System.getenv("RL_LEGACY_USER");
	private static final String LEGACY_PASS = System.getenv("RL_LEGACY_PASS");
	private static final int LEGACY_WELCOME_INDEX = 0;
	private static final int LEGACY_FORM_INDEX = 2;

	// Stage 1 (optional): the EULA Accept/Decline dialog a fresh client shows before the welcome screen.
	// Inert on a client that already accepted (desktop) — loginIndex never equals EULA_LOGIN_INDEX there.
	private static final boolean EULA_ENABLED = Boolean.getBoolean("runelite.headless.autologin.eula");
	private static final int EULA_LOGIN_INDEX =
		Integer.getInteger("runelite.headless.autologin.eula.loginIndex", 12);

	// Stage 2: the Play Now button centre.
	private static final int CLICK_X;
	private static final int CLICK_Y;
	// Stage 1: the EULA Accept button centre (765x503 fixed login; observed on device ~302,312).
	private static final int EULA_X;
	private static final int EULA_Y;

	// Optional: switch to a specific world before clicking Play Now. A throwaway free-to-play account is
	// rejected ("You need a members' account to use this world") if the remembered world is members, so we
	// point it at an F2P world first. World W's host is oldschool{W-300}.runescape.com.
	private static final int WORLD_ID = Integer.getInteger("runelite.headless.autologin.world", 0);
	private static final String WORLD_ADDRESS = System.getProperty("runelite.headless.autologin.worldAddress");

	private static int draws;
	// Per-stage attempt bookkeeping so an EULA retry budget can't starve the Play Now stage.
	private static int eulaAttempts;
	private static int lastEulaDraw;
	private static boolean eulaCleared;
	private static int playAttempts;
	private static int lastPlayDraw;
	private static boolean worldSelected;
	private static boolean done;
	// Legacy-mode attempt bookkeeping (welcome-panel Enter vs credential submit are separate budgets).
	private static int legacyWelcomeAttempts;
	private static int lastLegacyWelcomeDraw;
	private static int legacySubmitAttempts;
	private static int lastLegacySubmitDraw;

	// FIX-9 reconnect: an in-session network drop goes LOGGED_IN -> CONNECTION_LOST -> LOGIN_SCREEN at the
	// "Failed to login. Please try again." dialog (loginIndex 9, device-captured). CONNECTION_LOST is the clean
	// disconnect signal — a deliberate logout never sets it — so on it we re-arm the login machine to auto-
	// recover: click Try Again (-> welcome loginIndex 10), then the normal Play Now stage. Capped per disconnect
	// so a token-lapse / dead world can't loop; a long lapse that routes Play Now through the Cloudflare check
	// just foregrounds Chrome (backgrounding us, which pauses this per-draw tick) — we never drive that page.
	private static final int RECONNECT_LOGIN_INDEX = 9;
	private static final int RECONNECT_X = Constants.GAME_FIXED_WIDTH / 2;   // "Try again" is horizontally centred
	private static final int RECONNECT_Y = 277;                             // ~middle of the 765x503 fixed login
	private static final int MAX_RECONNECT = 3;
	// "Try again" gets a generous attempt budget (vs MAX_ATTEMPTS for the one-shot login stages): the engine's
	// retry IS the network probe, so it must outlast a Wi-Fi re-associate. Looping here is benign — loginIndex 9
	// never routes to the Cloudflare check (that's the fresh Account-login path), so a dead network just keeps
	// failing back to 9 until this cap, then gives up. In the real case (app suspended, Wi-Fi still up) it wins
	// on attempt 1. ~30 attempts × COOLDOWN_DRAWS comfortably covers a re-associate.
	private static final int MAX_TRYAGAIN_ATTEMPTS = 30;
	private static boolean sawConnectionLost;
	private static int reconnectAttempts;
	private static int tryAgainAttempts;
	private static int lastTryAgainDraw;
	// UX-LOGIN-01: latched true when the login machine EXHAUSTS a stage's retry budget and gives up (EULA / Try
	// Again / Play Now), as opposed to {@code done} which is also set on a SUCCESSFUL login. While set, the client is
	// parked on the raw login screen with no further automated recovery — the native shell reads this (hasGivenUp)
	// to show a "Session expired — sign in again" overlay. Cleared on any re-arm (reconnect / world-hop) or success.
	private static boolean gaveUp;

	// Bug 4 — hop-via-relog. The headless in-game world hop (client.hopToWorld) is inert, but client.changeWorld()
	// on the LOGIN_SCREEN is known-good. WorldSwitcherBridge drives a logout then calls requestWorldHop(...) to hand
	// us the target world; once we reach the login screen we changeWorld(target) + Play Now, relogging into it.
	// `hopAwaitingLogin` keeps us from declaring `done` while the logout is still in flight (we're momentarily still
	// LOGGED_IN when the request arrives); it clears the instant we observe the login screen.
	private static boolean pendingHopActive;
	private static boolean hopAwaitingLogin;
	private static int pendingHopWorldId;
	private static String pendingHopWorldAddress;
	private static boolean pendingHopMembers;

	static
	{
		final int[] play = parsePoint("runelite.headless.autologin.point",
			Constants.GAME_FIXED_WIDTH / 2 /* 382 — Play Now is horizontally centred */,
			248 /* ~middle of the welcome panel (765x503 fixed login) */);
		CLICK_X = play[0];
		CLICK_Y = play[1];
		final int[] eula = parsePoint("runelite.headless.autologin.eula.point", 302, 312);
		EULA_X = eula[0];
		EULA_Y = eula[1];
		if (ENABLED)
		{
			log.info("[headless-login] ENABLED playPoint={},{} welcomeLoginIndex={} eula={} eulaPoint={},{} "
					+ "eulaLoginIndex={} maxAttempts={} world={} worldAddress={} legacy={}",
				CLICK_X, CLICK_Y, WELCOME_LOGIN_INDEX, EULA_ENABLED, EULA_X, EULA_Y, EULA_LOGIN_INDEX,
				MAX_ATTEMPTS, WORLD_ID, WORLD_ADDRESS, legacyEnabled);
			if (legacyEnabled && (LEGACY_USER == null || LEGACY_USER.isEmpty()
				|| LEGACY_PASS == null || LEGACY_PASS.isEmpty()))
			{
				log.warn("[headless-login] legacy mode enabled but RL_LEGACY_USER/RL_LEGACY_PASS env is "
					+ "missing/empty — legacy login will not fire");
			}
		}
	}

	private static int[] parsePoint(String prop, int defX, int defY)
	{
		int x = defX;
		int y = defY;
		final String p = System.getProperty(prop);
		if (p != null && p.contains(","))
		{
			try
			{
				final String[] parts = p.split(",", 2);
				x = Integer.parseInt(parts[0].trim());
				y = Integer.parseInt(parts[1].trim());
			}
			catch (NumberFormatException ex)
			{
				log.warn("[headless-login] bad {} '{}', using default {},{}", prop, p, defX, defY);
				x = defX;
				y = defY;
			}
		}
		return new int[]{x, y};
	}

	private HeadlessLogin()
	{
	}

	public static boolean isEnabled()
	{
		return ENABLED;
	}

	/**
	 * FIX-9: true while the auto-reconnect machine is actively recovering an in-session network drop
	 * (CONNECTION_LOST -&gt; "Try again" -&gt; Play Now -&gt; LOGGED_IN). The native shell reads this through the
	 * {@link MobileChromeBridge} snapshot to show a "Reconnecting…" overlay over the engine's brief transient
	 * login screens. It goes true the moment a real disconnect is observed and clears on a successful relogin
	 * <em>or</em> once the capped retry budget is exhausted ({@code done} is re-set on give-up), so the overlay
	 * never sticks on a hard failure. A fresh initial login (no prior drop) reports false. Package-private — read
	 * only by the sibling headless bridges in this package, so it is not part of the cross-platform contract.
	 */
	static boolean isReconnecting()
	{
		return (sawConnectionLost && reconnectAttempts < MAX_RECONNECT) || (reconnectAttempts > 0 && !done);
	}

	/**
	 * UX-LOGIN-01: true once the login machine has exhausted a stage's retry budget and given up (the client is
	 * parked on the raw login screen with no further automated recovery — an expired/lapsed session or rejected
	 * autologin). Distinct from a transient {@link #isReconnecting()} recovery and from a normal login screen. The
	 * native shell reads this to raise a "Session expired — sign in again" overlay. Package-private (same-package
	 * bridges only); not part of the cross-platform contract.
	 */
	static boolean hasGivenUp()
	{
		return gaveUp;
	}

	/**
	 * TEST-1 seam: the whole login machine is static (one engine per process), so unit tests need a
	 * deterministic reset between scenarios. Restores every mutable field to its clinit value, including the
	 * {@code legacyEnabled} mirror (re-read from the system property). Package-private, test-only — production
	 * never calls this; a live re-arm goes through the CONNECTION_LOST / world-hop paths instead so the
	 * reconnect budget survives.
	 */
	static void resetForTest()
	{
		draws = 0;
		eulaAttempts = 0;
		lastEulaDraw = 0;
		eulaCleared = false;
		playAttempts = 0;
		lastPlayDraw = 0;
		worldSelected = false;
		done = false;
		legacyWelcomeAttempts = 0;
		lastLegacyWelcomeDraw = 0;
		legacySubmitAttempts = 0;
		lastLegacySubmitDraw = 0;
		sawConnectionLost = false;
		reconnectAttempts = 0;
		tryAgainAttempts = 0;
		lastTryAgainDraw = 0;
		gaveUp = false;
		pendingHopActive = false;
		hopAwaitingLogin = false;
		pendingHopWorldId = 0;
		pendingHopWorldAddress = null;
		pendingHopMembers = false;
		welcomeAttempts = 0;
		lastWelcomeDraw = 0;
		welcomeDone = false;
		welcomeGaveUp = false;
		legacyEnabled = Boolean.getBoolean("runelite.headless.autologin.legacy");
	}

	/**
	 * TEST-1 seam: {@code legacyEnabled} is read once at clinit, so legacy-path tests can't flip it by setting
	 * the property (the class is already loaded by then). Package-private, test-only.
	 */
	static void setLegacyEnabledForTest(boolean enabled)
	{
		legacyEnabled = enabled;
	}

	/**
	 * Bug 4 — hop-via-relog. Called by {@link WorldSwitcherBridge} (same package, client thread) once it has begun
	 * driving a logout for a world hop. Re-arms the login machine to relogin into {@code worldId}: on the next
	 * {@link GameState#LOGIN_SCREEN} we {@code changeWorld(target)} (members type from {@code members}) before
	 * clicking Play Now. {@code hopAwaitingLogin} stops {@link #tick} from declaring {@code done} while we're still
	 * momentarily logged in (the logout hasn't dropped us yet). No-op unless autologin is enabled. Client thread.
	 */
	static void requestWorldHop(int worldId, String address, boolean members)
	{
		if (!ENABLED)
		{
			log.warn("[headless-login] world-hop relog requested (W{}) but autologin is disabled — ignoring", worldId);
			return;
		}
		pendingHopActive = true;
		pendingHopWorldId = worldId;
		pendingHopWorldAddress = address;
		pendingHopMembers = members;
		hopAwaitingLogin = true;
		// Re-arm the relogin: clear `done`/`worldSelected` and the Play-Now + Try-Again + welcome budgets so the
		// login machine drives a fresh Play-Now (and re-dismisses the in-world welcome screen) after the logout.
		done = false;
		gaveUp = false;   // UX-LOGIN-01: a fresh relogin attempt clears any prior give-up
		worldSelected = false;
		playAttempts = 0;
		lastPlayDraw = 0;
		tryAgainAttempts = 0;
		welcomeDone = false;
		welcomeAttempts = 0;
		welcomeGaveUp = false;
		log.info("[headless-login] world-hop relog armed -> W{} ({}) members={}", worldId, address, members);
	}

	/**
	 * Bug 4: disarm a pending world-hop relogin. Called by {@link WorldSwitcherBridge} when its logout driver gives
	 * up (e.g. the logout never lands), so a relogin we armed but can't fulfil doesn't strand the login machine with
	 * {@code hopAwaitingLogin}/{@code done=false} forever. Restores {@code done} since we're still logged in (the
	 * give-up only fires while LOGGED_IN), so the normal reconnect/idle paths keep working. Client thread.
	 */
	static void cancelWorldHop()
	{
		if (!pendingHopActive && !hopAwaitingLogin)
		{
			return;
		}
		log.info("[headless-login] world-hop relog cancelled (logout did not complete) — disarming, target was W{}", pendingHopWorldId);
		pendingHopActive = false;
		hopAwaitingLogin = false;
		worldSelected = false;
		done = true;   // we're still LOGGED_IN; treat the (failed) hop as finished so later logins behave normally
		gaveUp = false;
	}

	/**
	 * Called once per {@code Hooks.draw} (only when enabled). Drives the login as a two-stage machine: while
	 * the EULA dialog is up (stage 1, optional) it synthesizes an Accept click; once the gamepack reaches the
	 * authenticated welcome screen (stage 2) it synthesizes a Play Now click. Each stage re-arms until the
	 * state advances.
	 */
	public static void tick(Client client, GameState state, int loginIndex)
	{
		if (!ENABLED)
		{
			return;
		}
		// FIX-9 reconnect: re-arm on a real disconnect (CONNECTION_LOST), distinct from a deliberate logout.
		if (state == GameState.CONNECTION_LOST)
		{
			sawConnectionLost = true;
		}
		if (done && sawConnectionLost && state == GameState.LOGIN_SCREEN && reconnectAttempts < MAX_RECONNECT)
		{
			reconnectAttempts++;
			sawConnectionLost = false;
			done = false;
			gaveUp = false;   // UX-LOGIN-01: a new disconnect re-arms recovery — clear any prior give-up
			playAttempts = 0;
			tryAgainAttempts = 0;
			worldSelected = false;
			// LEGACY-1: give the legacy form its own fresh budget too, so a reconnect cycle can re-drive it.
			legacyWelcomeAttempts = 0;
			legacySubmitAttempts = 0;
			// UX §4.7: re-arm the welcome dismiss too, so a reconnect that lands on the news screen re-dismisses
			// it and a prior strand latch can't false-trigger the give-up branch on the fresh login.
			welcomeDone = false;
			welcomeAttempts = 0;
			welcomeGaveUp = false;
			log.info("[headless-login] reconnect: disconnect detected (CONNECTION_LOST) -> re-arming login (cycle {}/{})",
				reconnectAttempts, MAX_RECONNECT);
		}
		if (done)
		{
			return;
		}

		draws++;

		if (state != GameState.LOGIN_SCREEN)
		{
			// Past the login screen. OSRS may show an in-world "Welcome to RuneScape" news overlay (WelcomeScreen)
			// once LOGGED_IN that needs a click to enter the world — dismiss it before declaring done, so headless
			// harnesses actually reach the scene (not just the authenticated lobby). Keep waiting through
			// LOGGING_IN/LOADING; only finish once LOGGED_IN with no welcome overlay.
			if (state == GameState.LOGGED_IN)
			{
				// Bug 4: a world-hop logout is still in flight (WorldSwitcherBridge is driving it) — we're briefly
				// still LOGGED_IN. Don't declare done; wait until the logout drops us to the login screen below.
				if (hopAwaitingLogin)
				{
					return;
				}
				if (tryDismissWelcome(client))
				{
					return;   // welcome overlay shown -> clicked it this tick, keep going until it's gone
				}
				// tryDismissWelcome returned false: either the player spawned (viewport allocated) or the
				// auto-dismiss gave up pre-spawn. UX §4.7: don't conflate the two — a give-up that reported a
				// clean login stranded the user on the "Click here to play" news screen with autologin
				// "successful". Latch it honestly instead; the engine still renders the news screen and touches
				// map through, so a manual tap on the play button recovers the world.
				if (welcomeGaveUp && client.getViewportWidth() <= 0)
				{
					if (!done)
					{
						log.warn("[headless-login] gave up auto-dismissing the post-login 'Click here to play' news "
							+ "screen after {} click(s) at {},{} — tap the play button to enter the world",
							welcomeAttempts, WELCOME_X, WELCOME_Y);
						done = true;
						gaveUp = true;   // hasGivenUp() now honest; cleared by the next re-arm / clean login
					}
					return;
				}
				welcomeGaveUp = false;   // genuinely in-world — clear any stale strand latch
				if (eulaAttempts > 0 || playAttempts > 0 || tryAgainAttempts > 0)
				{
					log.info("[headless-login] state now {} after eula={} play={} tryAgain={} attempt(s) — stopping injection",
						state, eulaAttempts, playAttempts, tryAgainAttempts);
				}
				done = true;
				// FIX-9: a fresh login/reconnect succeeded — clear the disconnect latch + refresh the budget so a
				// LATER drop gets its own MAX_RECONNECT cycles.
				sawConnectionLost = false;
				reconnectAttempts = 0;
				gaveUp = false;   // UX-LOGIN-01: a successful login clears any prior give-up
				// Bug 4: a world-hop relogin completed — clear the pending target so later logins behave normally.
				if (pendingHopActive)
				{
					log.info("[headless-login] world-hop relog complete -> now on W{}", pendingHopWorldId);
					pendingHopActive = false;
				}
			}
			return;
		}

		// On the LOGIN_SCREEN now. Bug 4: if a world-hop logout was in flight, it has landed — clear the await latch
		// so the stages below relogin (changeWorld(target) happens in the Play-Now world-select step).
		if (hopAwaitingLogin)
		{
			hopAwaitingLogin = false;
			log.info("[headless-login] world-hop: logout reached LOGIN_SCREEN -> reloging into W{}", pendingHopWorldId);
		}

		if (draws < WARMUP_DRAWS)
		{
			return;
		}

		final Canvas canvas = client.getCanvas();
		if (canvas == null)
		{
			return;
		}

		// Stage 1 — EULA Accept/Decline. Only fires on a fresh client that shows the dialog; once we observe
		// the welcome sub-state we treat the EULA as cleared and never click it again.
		if (loginIndex == WELCOME_LOGIN_INDEX)
		{
			eulaCleared = true;
		}
		if (EULA_ENABLED && !eulaCleared && loginIndex == EULA_LOGIN_INDEX)
		{
			if (eulaAttempts >= MAX_ATTEMPTS)
			{
				if (!done)
				{
					log.warn("[headless-login] still on the EULA dialog (loginIndex={}) after {} Accept attempt(s) "
						+ "at {},{} — giving up", loginIndex, eulaAttempts, EULA_X, EULA_Y);
					done = true;
					gaveUp = true;   // UX-LOGIN-01: parked, native shell surfaces "sign in again"
				}
				return;
			}
			if (eulaAttempts > 0 && draws - lastEulaDraw < COOLDOWN_DRAWS)
			{
				return;
			}
			eulaAttempts++;
			lastEulaDraw = draws;
			log.info("[headless-login] EULA attempt {}/{}: synthesizing Accept click at {},{} (canvas {}x{} displayable={})",
				eulaAttempts, MAX_ATTEMPTS, EULA_X, EULA_Y, canvas.getWidth(), canvas.getHeight(), canvas.isDisplayable());
			synthesizeClick(canvas, EULA_X, EULA_Y);
			return;
		}

		// FIX-9 reconnect stage — the post-disconnect "Failed to login. Please try again." dialog (loginIndex 9).
		// Click "Try again" to return to the welcome screen (loginIndex 10), where Stage 2 below clicks Play Now.
		// LEGACY-1: this stage runs for BOTH account types (it used to sit below the legacy branch, so a legacy
		// drop parked on this dialog forever — no reconnect, no give-up): the dialog is account-agnostic, and
		// clicking Try Again returns a legacy client to the welcome panel (loginIndex 0) where tickLegacy
		// re-drives the form with the re-armed budgets. Exhaustion here latches gaveUp for legacy too.
		if (loginIndex == RECONNECT_LOGIN_INDEX)
		{
			if (tryAgainAttempts >= MAX_TRYAGAIN_ATTEMPTS)
			{
				if (!done)
				{
					log.warn("[headless-login] reconnect: still on 'Try again' (loginIndex={}) after {} attempt(s) — giving up",
						loginIndex, tryAgainAttempts);
					done = true;
					gaveUp = true;   // UX-LOGIN-01: reconnect exhausted — surface "session expired"
				}
				return;
			}
			if (tryAgainAttempts > 0 && draws - lastTryAgainDraw < COOLDOWN_DRAWS)
			{
				return;
			}
			tryAgainAttempts++;
			lastTryAgainDraw = draws;
			log.info("[headless-login] reconnect: Try Again attempt {}/{}: synthesizing click at {},{} (scaled to canvas {}x{})",
				tryAgainAttempts, MAX_TRYAGAIN_ATTEMPTS, RECONNECT_X, RECONNECT_Y, canvas.getWidth(), canvas.getHeight());
			synthesizeClickScaled(canvas, RECONNECT_X, RECONNECT_Y);
			return;
		}

		// Legacy (non-Jagex) account: drive the classic username/password form instead of the JX welcome
		// screen (loginIndex never reaches 10 without a JX_* session, so stage 2 below is inert here).
		// Sits BELOW the reconnect stage so a legacy in-session drop shares the Try-Again handling above.
		if (legacyEnabled)
		{
			tickLegacy(client, canvas, loginIndex);
			return;
		}

		// Stage 2 — Play Now on the authenticated welcome screen.
		if (loginIndex != WELCOME_LOGIN_INDEX)
		{
			return;
		}

		if (playAttempts >= MAX_ATTEMPTS)
		{
			if (!done)
			{
				log.warn("[headless-login] still LOGIN_SCREEN after {} Play Now attempt(s) at {},{} — giving up "
					+ "(wrong coords, or the engine rejects synthesized input headless)", playAttempts, CLICK_X, CLICK_Y);
				done = true;
				gaveUp = true;   // UX-LOGIN-01: autologin exhausted — surface "session expired"
				// Bug 4: a hop relogin that can't get past Play Now is over — drop the pending target so it can't
				// hijack a later login (e.g. a future reconnect) into the stale hop world.
				pendingHopActive = false;
			}
			return;
		}

		// Cooldown only gates re-arms — the first click fires as soon as we're warmed up on the welcome screen.
		if (playAttempts > 0 && draws - lastPlayDraw < COOLDOWN_DRAWS)
		{
			return;
		}

		// Point the client at the target world before the first click. Bug 4: a world hop supplies the target via
		// requestWorldHop (it wins over the configured default); otherwise use the configured F2P world so a free
		// account isn't bounced with "You need a members' account to use this world".
		if (!worldSelected && pendingHopActive)
		{
			selectHopWorld(client);
			worldSelected = true;
		}
		else if (!worldSelected && WORLD_ID > 0 && WORLD_ADDRESS != null)
		{
			selectWorld(client);
			worldSelected = true;
		}

		playAttempts++;
		lastPlayDraw = draws;
		log.info("[headless-login] Play Now attempt {}/{}: synthesizing click at {},{} (canvas {}x{} displayable={} reconnect={})",
			playAttempts, MAX_ATTEMPTS, CLICK_X, CLICK_Y, canvas.getWidth(), canvas.getHeight(), canvas.isDisplayable(), reconnectAttempts);
		// FIX-9: on a reconnect the canvas is the resized in-world size (not 765x503), so scale the click to it.
		// Bug 4: a hop relog logs out from in-world, so its login canvas is the resized size too — scale there as
		// well. Initial login (no reconnect, no hop) keeps the exact proven fixed coord — no regression there.
		if (reconnectAttempts > 0 || pendingHopActive)
		{
			synthesizeClickScaled(canvas, CLICK_X, CLICK_Y);
		}
		else
		{
			synthesizeClick(canvas, CLICK_X, CLICK_Y);
		}
	}

	/**
	 * Legacy username/password login. loginIndex 0 = the initial "Welcome to RuneScape" panel, where Enter
	 * activates the Existing User form; loginIndex 2 = the username/password form, where the fields are set
	 * through the Client API and Enter (twice: field-advance, then submit) starts the login. Any other
	 * sub-state (authenticator, error dialog) is left alone — the attempt caps stop runaway input and the
	 * captured frames show where it parked.
	 *
	 * <p>Reconnect (LEGACY-1): an in-session drop lands on the reconnect panel (loginIndex 9), which is
	 * handled by the shared Try-Again stage in {@code tick} BEFORE this method runs — clicking Try Again
	 * returns the client to the legacy welcome panel (loginIndex 0), and this method re-drives the form with
	 * the budgets the CONNECTION_LOST re-arm reset. If Try-Again or the form budgets exhaust, the give-up
	 * latches fire and the shells show the "session expired" card.
	 */
	private static void tickLegacy(Client client, Canvas canvas, int loginIndex)
	{
		if (LEGACY_USER == null || LEGACY_USER.isEmpty() || LEGACY_PASS == null || LEGACY_PASS.isEmpty())
		{
			return;
		}

		if (loginIndex == LEGACY_WELCOME_INDEX)
		{
			if (legacyWelcomeAttempts >= MAX_ATTEMPTS)
			{
				if (!done)
				{
					log.warn("[headless-login] legacy: still on the welcome panel (loginIndex=0) after {} "
						+ "Enter attempt(s) — giving up", legacyWelcomeAttempts);
					done = true;
					gaveUp = true;   // LEGACY-1: surface "session expired" for legacy accounts too
				}
				return;
			}
			if (legacyWelcomeAttempts > 0 && draws - lastLegacyWelcomeDraw < COOLDOWN_DRAWS)
			{
				return;
			}
			legacyWelcomeAttempts++;
			lastLegacyWelcomeDraw = draws;
			log.info("[headless-login] legacy welcome attempt {}/{}: Enter to open the Existing User form",
				legacyWelcomeAttempts, MAX_ATTEMPTS);
			synthesizeEnter(canvas);
			return;
		}

		if (loginIndex == LEGACY_FORM_INDEX)
		{
			if (legacySubmitAttempts >= MAX_ATTEMPTS)
			{
				if (!done)
				{
					log.warn("[headless-login] legacy: still on the login form after {} submit attempt(s) — "
						+ "giving up (bad credentials, or the world rejected the login)", legacySubmitAttempts);
					done = true;
					gaveUp = true;   // LEGACY-1: surface "session expired" for legacy accounts too
				}
				return;
			}
			if (legacySubmitAttempts > 0 && draws - lastLegacySubmitDraw < COOLDOWN_DRAWS)
			{
				return;
			}
			// Point the client at the configured world before the first submit (same reason as the JX path:
			// a remembered members world bounces a free account back to the login screen).
			if (!worldSelected && WORLD_ID > 0 && WORLD_ADDRESS != null)
			{
				selectWorld(client);
				worldSelected = true;
			}
			legacySubmitAttempts++;
			lastLegacySubmitDraw = draws;
			client.setUsername(LEGACY_USER);
			client.setPassword(LEGACY_PASS);
			log.info("[headless-login] legacy submit attempt {}/{}: credentials set, Enter to log in",
				legacySubmitAttempts, MAX_ATTEMPTS);
			synthesizeEnter(canvas);
			synthesizeEnter(canvas);
		}
	}

	private static int welcomeAttempts;
	private static int lastWelcomeDraw;
	private static boolean welcomeDone;
	// UX §4.7: set when the welcome-screen auto-dismiss exhausted its clicks pre-spawn (distinct from a clean
	// in-world spawn — both leave welcomeDone true and return false). Lets tick() log an honest give-up + latch
	// gaveUp instead of reporting a successful login while the player is stranded on the news screen.
	private static boolean welcomeGaveUp;
	// The "CLICK HERE TO PLAY" news welcome screen renders at the fixed 765x503 login canvas anchored top-left; the
	// red play button sits near (390,95) there. Configurable in case it moves.
	private static final int WELCOME_X = Integer.getInteger("runelite.headless.autologin.welcomeX", 390);
	private static final int WELCOME_Y = Integer.getInteger("runelite.headless.autologin.welcomeY", 95);

	/**
	 * Dismiss the post-login "CLICK HERE TO PLAY" news welcome screen so the harness reaches the live scene instead
	 * of stalling on the lobby. Detected by {@code getLocalPlayer() == null} while LOGGED_IN (not spawned yet);
	 * synthesizes a click at the play button. Returns {@code true} while still pre-spawn (caller keeps waiting),
	 * {@code false} once the player has spawned (in-world) or we gave up.
	 */
	private static boolean tryDismissWelcome(Client client)
	{
		if (welcomeDone)
		{
			return false;
		}
		try
		{
			// In-world once the 3D viewport is allocated (it's 0x0 while the post-login news screen is up).
			if (client.getViewportWidth() > 0)
			{
				welcomeDone = true;
				return false;
			}
			if (welcomeAttempts >= MAX_ATTEMPTS)
			{
				welcomeDone = true;
				welcomeGaveUp = true;   // UX §4.7: flag the stranded-pre-spawn give-up for tick() to surface honestly
				return false;
			}
			if (welcomeAttempts > 0 && draws - lastWelcomeDraw < COOLDOWN_DRAWS)
			{
				return true;   // waiting out the cooldown between clicks
			}
			final Canvas canvas = client.getCanvas();
			if (canvas == null)
			{
				return true;
			}
			welcomeAttempts++;
			lastWelcomeDraw = draws;
			log.info("[headless-login] welcome 'Click here to play': synthesizing click at {},{} (attempt {}/{})",
				WELCOME_X, WELCOME_Y, welcomeAttempts, MAX_ATTEMPTS);
			synthesizeClick(canvas, WELCOME_X, WELCOME_Y);
			return true;
		}
		catch (RuntimeException ex)
		{
			return false;
		}
	}

	private static void selectWorld(Client client)
	{
		try
		{
			final World world = client.createWorld();
			world.setId(WORLD_ID);
			world.setAddress(WORLD_ADDRESS);
			world.setActivity("-");
			world.setPlayerCount(-1);
			// F2P = no MEMBERS type. (Same World construction the WorldHopper plugin uses for changeWorld.)
			world.setTypes(EnumSet.noneOf(WorldType.class));
			client.changeWorld(world);
			log.info("[headless-login] changeWorld -> {} ({})", WORLD_ID, WORLD_ADDRESS);
		}
		catch (RuntimeException ex)
		{
			log.warn("[headless-login] changeWorld to {} ({}) failed", WORLD_ID, WORLD_ADDRESS, ex);
		}
	}

	/**
	 * Bug 4: point the client at the requested hop target on the login screen (the known-good headless hop —
	 * {@code client.changeWorld} is honoured here, unlike the inert in-game {@code client.hopToWorld}). Mirrors
	 * {@link #selectWorld} but uses the {@code requestWorldHop} target + its membership type.
	 */
	private static void selectHopWorld(Client client)
	{
		try
		{
			final World world = client.createWorld();
			world.setId(pendingHopWorldId);
			world.setAddress(pendingHopWorldAddress);
			world.setActivity("-");
			world.setPlayerCount(-1);
			world.setTypes(pendingHopMembers ? EnumSet.of(WorldType.MEMBERS) : EnumSet.noneOf(WorldType.class));
			client.changeWorld(world);
			log.info("[headless-login] world-hop changeWorld -> {} ({}) members={}",
				pendingHopWorldId, pendingHopWorldAddress, pendingHopMembers);
		}
		catch (RuntimeException ex)
		{
			log.warn("[headless-login] world-hop changeWorld to {} ({}) failed",
				pendingHopWorldId, pendingHopWorldAddress, ex);
		}
	}

	/** Post an Enter key press to the canvas — the login screen's field-advance / submit key. */
	private static void synthesizeEnter(Canvas canvas)
	{
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();
		q.postEvent(new FocusEvent(canvas, FocusEvent.FOCUS_GAINED, false, null));
		q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_PRESSED, t, 0, KeyEvent.VK_ENTER, '\n'));
		q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_TYPED, t + 1, 0, KeyEvent.VK_UNDEFINED, '\n'));
		q.postEvent(new KeyEvent(canvas, KeyEvent.KEY_RELEASED, t + 2, 0, KeyEvent.VK_ENTER, '\n'));
	}

	/**
	 * FIX-9: like {@link #synthesizeClick} but scales the point from the 765x503 fixed-login space to the LIVE
	 * canvas. The initial login canvas is 765x503, but after the in-world HeadlessResize the canvas is the
	 * resized size (e.g. 1200x540) and does NOT shrink back for the reconnect login screen — so a fixed 765-space
	 * coord lands left of the (now wider) centred buttons. Scaling keeps the reconnect clicks on target at any
	 * canvas size (identity at 765x503, so the initial-login path is unaffected).
	 */
	private static void synthesizeClickScaled(Canvas canvas, int x, int y)
	{
		final int cw = canvas.getWidth();
		final int ch = canvas.getHeight();
		final int sx = cw > 0 ? (int) ((long) x * cw / Constants.GAME_FIXED_WIDTH) : x;
		final int sy = ch > 0 ? (int) ((long) y * ch / Constants.GAME_FIXED_HEIGHT) : y;
		synthesizeClick(canvas, sx, sy);
	}

	private static void synthesizeClick(Canvas canvas, int x, int y)
	{
		final EventQueue q = Toolkit.getDefaultToolkit().getSystemEventQueue();
		final long t = System.currentTimeMillis();

		// Some gamepacks ignore mouse input unless the canvas believes it has focus. There is no native
		// focus owner headless, so assert it explicitly before the click.
		q.postEvent(new FocusEvent(canvas, FocusEvent.FOCUS_GAINED, false, null));

		// Move the pointer onto the target first so the gamepack's recorded mouse position is over the button
		// when it samples the press on the next game tick.
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_ENTERED, t, 0, x, y, 0, false));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_MOVED, t + 1, 0, x, y, 0, false));

		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_PRESSED, t + 2,
			InputEvent.BUTTON1_DOWN_MASK, x, y, 1, false, MouseEvent.BUTTON1));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_RELEASED, t + 3,
			0, x, y, 1, false, MouseEvent.BUTTON1));
		q.postEvent(new MouseEvent(canvas, MouseEvent.MOUSE_CLICKED, t + 4,
			0, x, y, 1, false, MouseEvent.BUTTON1));
	}
}
