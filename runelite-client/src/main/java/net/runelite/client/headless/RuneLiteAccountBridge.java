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

import lombok.extern.slf4j.Slf4j;
import net.runelite.client.account.AccountSession;
import net.runelite.client.account.SessionManager;

/**
 * Native-shell bridge for the <b>RuneLite account</b> (config sync), distinct from the Jagex game login. Lets the
 * mobile UI start/stop the runelite.net OAuth login and read the current session. {@link SessionManager#login()}
 * starts a local {@code localhost:<port>} server, fetches the OAuth url, and hands it to the native shell through
 * {@link net.runelite.client.util.LinkBrowser} (Custom Tab / SFSafariViewController). When the loopback redirect
 * completes, the session opens and {@code ConfigManager} syncs the user's profiles + installed external plugins.
 *
 * <p>All methods are defensive + no-op until {@link #init(SessionManager)} runs at boot. Reads are lock-free.
 */
@Slf4j
public final class RuneLiteAccountBridge
{
	private static volatile SessionManager sessionManager;

	private RuneLiteAccountBridge()
	{
	}

	public static void init(SessionManager sm)
	{
		sessionManager = sm;
	}

	/** Whether the native shell should offer the RuneLite-account login (the session manager is wired). */
	public static boolean isAvailable()
	{
		return sessionManager != null;
	}

	/** Begin the RuneLite-account OAuth login. Opens the OAuth url in the native browser; completes asynchronously
	 *  when the localhost redirect returns. Safe to call repeatedly. */
	public static void startLogin()
	{
		final SessionManager sm = sessionManager;
		if (sm == null)
		{
			return;
		}
		try
		{
			sm.login();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("RuneLiteAccountBridge.startLogin", ex);
		}
	}

	/** Sign out of the RuneLite account (closes the session server-side + deletes the saved session). */
	public static void logout()
	{
		final SessionManager sm = sessionManager;
		if (sm == null)
		{
			return;
		}
		try
		{
			sm.logout();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("RuneLiteAccountBridge.logout", ex);
		}
	}

	/** {@code {"available":bool,"loggedIn":bool,"username":".."}} — the current session, read off-thread. */
	public static String getSessionJson()
	{
		final SessionManager sm = sessionManager;
		if (sm == null)
		{
			return "{\"available\":false}";
		}
		try
		{
			final AccountSession s = sm.getAccountSession();
			if (s == null)
			{
				return "{\"available\":true,\"loggedIn\":false}";
			}
			return "{\"available\":true,\"loggedIn\":true,\"username\":" + BridgeJson.quoted(s.getUsername()) + "}";
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("RuneLiteAccountBridge.getSessionJson", ex);
			return "{\"available\":false}";
		}
	}

}
