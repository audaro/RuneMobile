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

import java.util.concurrent.ConcurrentHashMap;
import lombok.extern.slf4j.Slf4j;

/**
 * Rate-limited fault sink for the per-frame headless bridge ticks (called from {@link HeadlessSeams} on the
 * engine/client thread). A bridge tick that throws must do neither of the two bad things:
 * <ul>
 *   <li><b>escape</b> into the gamepack's render loop (a throw out of {@code Hooks.draw} crashes the frame), or</li>
 *   <li>be <b>swallowed silently</b> — which hides a post-merge regression (e.g. a changed widget id) behind a
 *       frozen HUD, the exact failure this port keeps debugging on-device.</li>
 * </ul>
 *
 * <p>{@link #note} logs the first occurrence per {@code site} with its stack at {@code warn}, then suppresses
 * repeats for a short window and reports the suppressed count on the next window — so a fault that fires every
 * frame yields one line every few seconds, not ~50/s. Package-private; not part of the shared iOS/Android
 * bridge contract.
 */
@Slf4j
final class BridgeFaults
{
	private BridgeFaults()
	{
	}

	private static final long WINDOW_MS = 5000L;

	// site -> [last-log epoch ms, count suppressed since]. The ticks run on the client thread, but keep this
	// thread-safe so a future caller on another thread can't corrupt the bookkeeping.
	private static final ConcurrentHashMap<String, long[]> SITES = new ConcurrentHashMap<>();

	static void note(String site, Throwable t)
	{
		final long now = System.currentTimeMillis();
		final long[] s = SITES.computeIfAbsent(site, k -> new long[]{Long.MIN_VALUE, 0L});
		synchronized (s)
		{
			if (now - s[0] < WINDOW_MS)
			{
				s[1]++;
				return;
			}
			final long suppressed = s[1];
			s[0] = now;
			s[1] = 0L;
			if (suppressed > 0)
			{
				log.warn("[bridge-fault] {} threw ({} more suppressed in the last {}ms)", site, suppressed, WINDOW_MS, t);
			}
			else
			{
				log.warn("[bridge-fault] {} threw", site, t);
			}
		}
	}
}
