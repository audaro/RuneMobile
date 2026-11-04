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

import java.awt.Component;
import java.awt.Window;
import java.util.concurrent.TimeUnit;
import javax.swing.SwingUtilities;

/**
 * Makes a tap on a plugin panel arrive the way a mouse click does on desktop. The panel bridge builds its own mouse
 * events, so it has to do the two jobs AWT does for a real mouse, and plugins depend on both: a Star Miners row hops
 * on a double-click of the row, whose text labels listen for nothing, and it is the same in World Hopper.
 *
 * <p>The event goes to the nearest component that listens, not the deepest one: a listener-less label drops whatever
 * it is handed. And taps on one thing in quick succession count up. A third tap is 3 rather than a new 1, as on
 * desktop, so mashing a row hops once.
 *
 * <p>Not a distance check: rows are close enough that any distance forgiving of a thumb also lets a double tap near
 * the edge of a row land on the next one and hop to the wrong world. Taps count together when the smallest component
 * holding them both is no taller than a row, which covers the row's separate columns and never two rows. A row that
 * was rebuilt between the taps is out of the tree, so a list refreshing under the thumb can't turn the second tap into
 * a double-click on some other star.
 */
final class PanelClicks
{
	/** The usual desktop double-click time. Measured tap to tap, so it has to allow for the finger's time on the glass. */
	static final long DOUBLE_TAP_NANOS = TimeUnit.MILLISECONDS.toNanos(500);
	/** In the panel's logical px. Star Miners' rows are 34. */
	static final int MAX_ROW_HEIGHT = 48;

	private Component last;
	private long lastNanos;
	private int count;

	/** What a real mouse would reach: the nearest component at or above {@code deepest} that listens for the mouse. */
	static Component target(Component deepest)
	{
		for (Component c = deepest; c != null && !(c instanceof Window); c = c.getParent())
		{
			if (c.getMouseListeners().length > 0 || c.getMouseMotionListeners().length > 0
				|| c.getMouseWheelListeners().length > 0)
			{
				return c;
			}
		}
		return deepest;
	}

	/** The click count for a tap on {@code target}. EDT only, like everything else that touches the panel tree. */
	int count(Component target, long nowNanos)
	{
		final boolean again = last != null && nowNanos - lastNanos <= DOUBLE_TAP_NANOS && sameThing(last, target);
		count = again ? count + 1 : 1;
		last = target;
		lastNanos = nowNanos;
		return count;
	}

	/** Forget the last tap, which also lets go of its component. */
	void reset()
	{
		last = null;
		count = 0;
	}

	private static boolean sameThing(Component a, Component b)
	{
		if (a == b)
		{
			return true;
		}
		Component holder = a;
		while (holder != null && !SwingUtilities.isDescendingFrom(b, holder))
		{
			holder = holder.getParent();
		}
		return holder != null && holder.getHeight() <= MAX_ROW_HEIGHT;
	}
}
