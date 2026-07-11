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

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import lombok.extern.slf4j.Slf4j;
import net.runelite.client.callback.ClientThread;
import net.runelite.client.config.ConfigManager;
import net.runelite.client.config.ConfigProfile;
import net.runelite.client.config.ProfileManager;

/**
 * Native-UI bridge for <b>config profiles</b> — the shared-core seam the mobile shell uses to list the user's
 * config profiles and switch the active one, mirroring the desktop {@code ProfilePanel}. Reads of the profile
 * list take a {@link ProfileManager.Lock} inline. A switch runs {@link ConfigManager#switchProfile(ConfigProfile)}
 * on the <b>client thread</b> (via {@link ClientThread#invokeLater}) so its {@code ConfigChanged}/{@code
 * ProfileChanged} fan-out — dispatched inline on the calling thread by the EventBus — mutates the engine on the
 * engine thread; a remote-sync switch (which blocks on a network fetch) instead runs on a background executor so
 * it never stalls a frame. Wired from {@code HeadlessClientUI} alongside the rest of the mobile-UI facade.
 *
 * <p>Reads ({@link #getProfilesJson()}) take the profile-store file lock inline — not a per-frame hot path
 * (the native side reads only while the profiles screen is open), so no client-thread snapshot is needed.
 */
@Slf4j
public final class ConfigProfileBridge
{
	private static volatile ConfigManager configManager;
	private static volatile ProfileManager profileManager;
	private static volatile ClientThread clientThread;
	// Fallback executor for the one switch that DOES block on the network — a remote-sync profile (account session
	// + isSync). Those must stay off the client thread, exactly as the desktop ProfilePanel runs them on its
	// background executor. The common local switch instead runs on the client thread (see switchProfile).
	private static volatile ExecutorService switchExecutor;

	private ConfigProfileBridge()
	{
	}

	public static void init(ConfigManager cm, ProfileManager pm, ClientThread ct)
	{
		configManager = cm;
		profileManager = pm;
		clientThread = ct;
	}

	/** Whether the native shell should offer the profiles screen (both singletons wired). */
	public static boolean isAvailable()
	{
		return configManager != null && profileManager != null;
	}

	/**
	 * Snapshot of the config profiles as JSON:
	 * <pre>
	 * {"available":true,"profiles":[
	 *   {"id":123,"name":"default","active":true,"sync":false,"internal":false}, ...]}
	 * </pre>
	 * {@code internal} flags the engine's own profiles (e.g. {@code $rsprofile}) so the native side can hide
	 * them like the desktop panel does. {@code active} marks the currently-loaded profile.
	 */
	public static String getProfilesJson()
	{
		final ConfigManager cm = configManager;
		final ProfileManager pm = profileManager;
		if (cm == null || pm == null)
		{
			return "{\"available\":false}";
		}
		try (ProfileManager.Lock lock = pm.lock())
		{
			final ConfigProfile active = cm.getProfile();
			final long activeId = active == null ? -1 : active.getId();
			final List<ConfigProfile> profiles = lock.getProfiles();
			final StringBuilder sb = new StringBuilder(256);
			sb.append("{\"available\":true,\"profiles\":[");
			boolean first = true;
			for (ConfigProfile p : profiles)
			{
				if (p == null)
				{
					continue;
				}
				if (!first)
				{
					sb.append(',');
				}
				first = false;
				sb.append('{')
					.append("\"id\":").append(p.getId()).append(',')
					.append("\"name\":").append(BridgeJson.quoted(p.getName())).append(',')
					.append("\"active\":").append(p.getId() == activeId).append(',')
					.append("\"sync\":").append(p.isSync()).append(',')
					.append("\"internal\":").append(p.isInternal())
					.append('}');
			}
			sb.append("]}");
			return sb.toString();
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("ConfigProfileBridge.getProfilesJson", ex);
			return "{\"available\":false}";
		}
	}

	/**
	 * Switch the active config profile by id. Returns a JSON ack immediately; the switch itself runs on the
	 * background executor and completes asynchronously (the native side re-reads {@link #getProfilesJson()} to
	 * pick up the new active flag). {@code ok:false} when the bridge is unwired, the id is unknown, or it is
	 * already the active profile.
	 */
	public static String switchProfile(long id)
	{
		final ConfigManager cm = configManager;
		final ProfileManager pm = profileManager;
		if (cm == null || pm == null)
		{
			return ack(false, "unavailable");
		}
		final ConfigProfile active = cm.getProfile();
		if (active != null && active.getId() == id)
		{
			return ack(false, "already-active");
		}
		final ConfigProfile target;
		try (ProfileManager.Lock lock = pm.lock())
		{
			target = lock.findProfile(id);
		}
		catch (Throwable ex)
		{
			BridgeFaults.note("ConfigProfileBridge.switchProfile.find", ex);
			return ack(false, "lookup-failed");
		}
		if (target == null)
		{
			return ack(false, "unknown");
		}
		// Root-cause fix for the welcome-screen wedge: ConfigManager#switchProfile fans ConfigChanged +
		// ProfileChanged out via EventBus#post, which dispatches subscribers INLINE on the calling thread. Running
		// the whole switch on this background executor mutated the engine/live-interface stack off the client
		// thread — switching profiles while an interface was up (e.g. the "Welcome to Gielinor" screen) raced it
		// non-interactive: it kept rendering but taps fell through to the world. So drive the split variant: the
		// I/O-heavy prepare (incl. the optional blocking remote-sync fetch) stays on this executor, while the
		// engine-touching swap + event fan-out is marshalled onto the client thread, where it is engine-safe.
		final ClientThread ct = clientThread;
		executor().submit(() ->
		{
			try
			{
				cm.switchProfileMobile(target, apply ->
				{
					if (ct != null)
					{
						ct.invokeLater(apply);
					}
					else
					{
						apply.run(); // no client thread wired (shouldn't happen post-init); run inline
					}
				});
			}
			catch (Throwable ex)
			{
				BridgeFaults.note("ConfigProfileBridge.switchProfile", ex);
			}
		});
		return ack(true, null);
	}

	private static synchronized ExecutorService executor()
	{
		if (switchExecutor == null)
		{
			switchExecutor = Executors.newSingleThreadExecutor(r ->
			{
				final Thread t = new Thread(r, "mobile-profile-switch");
				t.setDaemon(true);
				return t;
			});
		}
		return switchExecutor;
	}

	private static String ack(boolean ok, String error)
	{
		final StringBuilder sb = new StringBuilder(48);
		sb.append("{\"ok\":").append(ok);
		if (error != null)
		{
			sb.append(",\"error\":").append(BridgeJson.quoted(error));
		}
		sb.append('}');
		return sb.toString();
	}

}
