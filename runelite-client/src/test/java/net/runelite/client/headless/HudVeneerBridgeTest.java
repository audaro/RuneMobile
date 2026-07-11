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

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import org.junit.Before;
import org.junit.Test;

/**
 * Unit tests for {@link HudVeneerBridge}'s overlay snap-corner safe-frame geometry — the rect the native
 * shells use to keep RuneLite overlays clear of the relocated chat box. The math is pure (native pushes the
 * chat position/size via setters; no engine read), and a wrong rect silently lets overlays render under the
 * chat on both ports. Covered: the {@code chatX < 0} "not relocating" null guard, the default fallbacks
 * (row height -> CONTROLS_H=23, width -> CHAT_DEFAULT_W=519), and the collapsed-vs-open height
 * (collapsed = the tab row only; open = the row + the message area ORIG_CHAT_CONTENT_H=142 + 2).
 *
 * <p>{@code ENABLED} is read once at class load from {@code -Drunelite.hudveneer}; set in the static
 * initialiser before the class loads (reliable — no other module test references the headless bridges).
 * The chat geometry is shared static state, so every test sets the full state it needs (it never relies on
 * a default left by another test).
 */
public class HudVeneerBridgeTest
{
	static
	{
		System.setProperty("runelite.hudveneer", "true");
	}

	// Mirrors of the layout-dump constants in HudVeneerBridge (the contract the rect math is built on).
	private static final int CONTROLS_H = 23;
	private static final int CHAT_DEFAULT_W = 519;
	private static final int ORIG_CHAT_CONTENT_H = 142;

	/**
	 * Full reset of the shared static chat geometry before each test, so the suite is order-independent
	 * regardless of how JUnit sequences the methods. Tests still set the specific state they assert on; this
	 * is the safety net so a value left by one test can never leak into the next.
	 */
	@Before
	public void resetState()
	{
		HudVeneerBridge.relocateChat(-1, -1, false);   // chatX < 0 = not relocating
		HudVeneerBridge.setChatTabRowHeight(0);         // 0 = fall back to CONTROLS_H
		HudVeneerBridge.setChatAreaWidth(0);            // 0 = fall back to CHAT_DEFAULT_W
		HudVeneerBridge.setChatCollapsed(false);
	}

	@Test
	public void enabledFlagIsSet()
	{
		assertTrue("runelite.hudveneer must be enabled before HudVeneerBridge loads", HudVeneerBridge.isEnabled());
	}

	@Test
	public void overlaySafeInsetsRoundTrip()
	{
		HudVeneerBridge.setOverlaySafeInsets(1, 2, 3, 4);
		assertArrayEquals(new int[]{1, 2, 3, 4}, HudVeneerBridge.getOverlayInsets());
	}

	@Test
	public void chatAvoidIsNullWhenNotRelocating()
	{
		HudVeneerBridge.relocateChat(-1, -1, false);   // x < 0 = veneer is not relocating the chat
		assertNull("no avoidance rect when the veneer isn't moving the chat", HudVeneerBridge.getOverlayChatAvoid());
	}

	@Test
	public void chatAvoidZeroRowAndWidthFallBackToHardcodedDefaults()
	{
		// Explicitly drive 0 in for both -> the rect must use the hardcoded fallbacks CONTROLS_H (23) and
		// CHAT_DEFAULT_W (519), open height = rowH + ORIG_CHAT_CONTENT_H + 2.
		HudVeneerBridge.setChatTabRowHeight(0);
		HudVeneerBridge.setChatAreaWidth(0);
		HudVeneerBridge.setChatCollapsed(false);
		HudVeneerBridge.relocateChat(10, 20, false);

		final int expectedH = CONTROLS_H + ORIG_CHAT_CONTENT_H + 2;
		assertArrayEquals(new int[]{10, 20, CHAT_DEFAULT_W, expectedH}, HudVeneerBridge.getOverlayChatAvoid());
	}

	@Test
	public void chatAvoidCollapsedIsTheTabRowOnly()
	{
		HudVeneerBridge.setChatCollapsed(true);        // row height/width left at the @Before defaults (0)
		HudVeneerBridge.relocateChat(10, 20, false);

		// Collapsed: just the tab row (no message area added), width still the default fallback.
		assertArrayEquals(new int[]{10, 20, CHAT_DEFAULT_W, CONTROLS_H}, HudVeneerBridge.getOverlayChatAvoid());
	}

	@Test
	public void chatAvoidHonoursProvidedRowHeightAndWidth()
	{
		HudVeneerBridge.setChatTabRowHeight(30);   // native enlarged tab row
		HudVeneerBridge.setChatAreaWidth(600);
		HudVeneerBridge.setChatCollapsed(false);
		HudVeneerBridge.relocateChat(5, 6, false);

		final int expectedH = 30 + ORIG_CHAT_CONTENT_H + 2;
		assertArrayEquals(new int[]{5, 6, 600, expectedH}, HudVeneerBridge.getOverlayChatAvoid());
	}
}
