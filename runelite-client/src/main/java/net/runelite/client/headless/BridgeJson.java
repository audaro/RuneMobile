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

/**
 * DEDUP-1: one home for the hand-rolled JSON string escaping the bridge classes each used to copy privately
 * (~13 near-identical helpers). The native iOS/Android UIs parse these snapshots, so the exact escaping is a
 * contract — the three methods below preserve, byte-for-byte, the three distinct behaviours the bridges
 * historically used. Do NOT collapse them into one without re-checking every consumer.
 */
final class BridgeJson
{
	private BridgeJson()
	{
	}

	/**
	 * A fully-quoted JSON string literal: wraps in double quotes, escapes {@code " \ \n \r \t}, and emits any
	 * other control char (&lt; 0x20) as {@code \\uXXXX}. {@code null} becomes {@code ""} (an empty JSON string).
	 * This is the {@code quote(...)} helper the object-building bridges shared (10 identical copies).
	 */
	static String quoted(String s)
	{
		if (s == null)
		{
			return "\"\"";
		}
		final StringBuilder sb = new StringBuilder(s.length() + 2);
		sb.append('"');
		for (int i = 0; i < s.length(); i++)
		{
			final char ch = s.charAt(i);
			switch (ch)
			{
				case '"': sb.append("\\\""); break;
				case '\\': sb.append("\\\\"); break;
				case '\n': sb.append("\\n"); break;
				case '\r': sb.append("\\r"); break;
				case '\t': sb.append("\\t"); break;
				default:
					if (ch < 0x20)
					{
						sb.append(String.format("\\u%04x", (int) ch));
					}
					else
					{
						sb.append(ch);
					}
			}
		}
		sb.append('"');
		return sb.toString();
	}

	/**
	 * Escapes the CONTENT of a JSON string (no surrounding quotes): {@code "} and {@code \} are backslash-escaped
	 * and {@code \n \r \t} collapse to a single space. {@code null}/empty become {@code ""}. Callers add their own
	 * quotes. This is the {@code jsonEscape}/{@code jsonEsc} helper MobileUiBridge + MenuPeekBridge shared.
	 */
	static String escaped(String s)
	{
		if (s == null || s.isEmpty())
		{
			return "";
		}
		final StringBuilder b = new StringBuilder(s.length() + 4);
		for (int i = 0; i < s.length(); i++)
		{
			final char c = s.charAt(i);
			switch (c)
			{
				case '"':
					b.append("\\\"");
					break;
				case '\\':
					b.append("\\\\");
					break;
				case '\n':
				case '\r':
				case '\t':
					b.append(' ');
					break;
				default:
					b.append(c);
					break;
			}
		}
		return b.toString();
	}

	/**
	 * Like {@link #escaped(String)} but control chars (&lt; 0x20) are DROPPED rather than turned into spaces —
	 * HudVeneerBridge's variant, kept distinct so its native-chat output is unchanged.
	 */
	static String escapedDropControls(String s)
	{
		if (s == null || s.isEmpty())
		{
			return "";
		}
		final StringBuilder out = new StringBuilder(s.length() + 8);
		for (int i = 0; i < s.length(); i++)
		{
			final char ch = s.charAt(i);
			if (ch == '"' || ch == '\\')
			{
				out.append('\\').append(ch);
			}
			else if (ch >= 0x20)
			{
				out.append(ch);
			}
		}
		return out.toString();
	}
}
