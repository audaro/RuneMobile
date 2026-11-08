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

import net.runelite.api.Client;
import net.runelite.api.HashTable;
import net.runelite.api.WidgetNode;
import net.runelite.api.gameval.VarbitID;

/**
 * Reads of the engine's interface state that more than one bridge needs. Kept apart from the bridges because
 * those read their on/off switches once, at class load: a test that reached a helper through a bridge would load
 * that bridge with its switch off, and the bridge's own tests in the same JVM would then fail. Client thread.
 */
final class Interfaces
{
	private Interfaces()
	{
	}

	/**
	 * Whether interface {@code group} is open: it is the top level, or the component table holds a node for it. That
	 * table is what opening and closing an interface changes, so it answers "has the server opened this";
	 * {@code getWidget(...) != null} only says the group is loaded, and a closed group can be loaded. The engine
	 * refuses {@code getComponentTable()} off the client thread.
	 */
	static boolean mounted(Client c, int group)
	{
		if (group == c.getTopLevelInterfaceId())
		{
			return true;
		}
		final HashTable<WidgetNode> open = c.getComponentTable();
		if (open == null)
		{
			return false;
		}
		for (final WidgetNode n : open)
		{
			if (n != null && n.getId() == group)
			{
				return true;
			}
		}
		return false;
	}

	/**
	 * Whether a resizable game screen has its tab stones on ToplevelPreEoc rather than ToplevelOsrsStretch. This is the
	 * engine's arrangement setting, not which toplevel is loaded: after a layout switch the old toplevel can still
	 * resolve, and pressing its stones does nothing.
	 */
	static boolean stonesOnPreEoc(Client c)
	{
		return c.getVarbitValue(VarbitID.RESIZABLE_STONE_ARRANGEMENT) == 1;
	}
}
