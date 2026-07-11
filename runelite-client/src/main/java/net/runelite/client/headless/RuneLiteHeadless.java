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

import net.runelite.client.RuneLite;

/**
 * Gate 1c entrypoint: boots the real RuneLite client with {@link HeadlessModule} layered on top of the
 * normal {@code RuneLiteModule}, so the Swing {@code ClientUI} is replaced by the window-less
 * {@code HeadlessClientUI}. Reuses {@link RuneLite#main(String[])} verbatim — same gamepack load, same
 * plugin/overlay pipeline, same option parsing — so this is the honest client, not a reimplementation.
 *
 * <p>Pass {@code --safe-mode} to disable the GPU plugin (so the engine's software renderer drives the
 * software-blit branch of {@code Hooks.draw}, which is the path the capture instrumentation observes).
 * Set {@code -Drunelite.headless.capture.dir=<dir>} to dump frames; see {@link HeadlessCapture}.
 *
 * <p>For the no-OS-window (CACIO CTC) run, this main is invoked after
 * {@code CacioExtension.injectCTCGraphicsEnvironment()} has installed the virtual display; see
 * {@code ios/dev-tools/headless/}.
 */
public class RuneLiteHeadless
{
	public static void main(String[] args) throws Exception
	{
		// Privacy: stock RuneLite's ClientSessionManager pings api.runelite.net every 10 minutes with a
		// random session UUID + a logged-in flag, unconditionally (RuneLite.java start()). Point the session
		// endpoint at a local sink so the shipped default sends nothing — the ping fails soft (a warn log)
		// and nothing else consumes the "runelite.session" endpoint. A dev run can still override the
		// property explicitly, in which case we leave it alone. See PRIVACY.md ("What this app sends").
		if (System.getProperty("runelite.session.url") == null)
		{
			System.setProperty("runelite.session.url", "http://127.0.0.1:1");
		}
		RuneLite.setOverrideModule(new HeadlessModule());
		// Phase-6 STEP-0: arm the (dormant unless -Drunelite.mobileui.smoke=true) facade self-test BEFORE the
		// engine starts, so its daemon is already polling for the injector. Runs on both desktop (CACIO/JUnit)
		// and device (UnsafePoke/DeviceHeadlessBoot) from this one path.
		MobileUiSmokeRunner.arm();
		RuneLite.main(args);
	}
}
