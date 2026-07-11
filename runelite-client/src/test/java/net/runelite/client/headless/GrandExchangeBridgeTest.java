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

import java.lang.reflect.Method;
import net.runelite.api.Client;
import net.runelite.api.ItemComposition;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import org.junit.Test;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link GrandExchangeBridge}'s hand-written JSON reader — the helpers that turn a stored GE
 * trade record (a flat JSON object string) into the public history JSON the native shells consume. Unlike the
 * other bridges, these helpers are {@code private static} and are only reached through reflection-heavy engine
 * code, so this suite invokes them <b>reflectively</b>. That is a deliberate, contained exception to the
 * project's mock-based convention: a hand-rolled parser with escape handling is exactly where silent edge-case
 * bugs hide (an unbalanced quote, a dropped key, a botched unescape), the helpers are pure and deterministic,
 * and a rename surfaces as a crisp "reflective call failed" rather than a wrong answer. If you rename one of
 * these, update the reflection target here in the same change.
 *
 * <p>Covered: {@code asLong} (safe parse + default), {@code unescapeSimple} (the \n/\r/\t + unknown-escape +
 * trailing-backslash cases), {@code skipString} (escape-aware string-bound scan), {@code rawValue} (the
 * key→raw-token extraction over numbers, quoted strings and missing keys) and {@code parseTradeObject} (the
 * full record assembly, including the item-name lookup, which is the one place a {@link Client} is needed).
 */
public class GrandExchangeBridgeTest
{
	@Test
	public void asLongParsesTrimsAndFallsBackToDefault()
	{
		assertEquals(7L, asLong(null, 7L));
		assertEquals(7L, asLong("", 7L));
		assertEquals(42L, asLong("  42 ", 0L));     // trimmed
		assertEquals(-5L, asLong("-5", 0L));
		assertEquals(9L, asLong("abc", 9L));        // non-numeric -> default
		assertEquals(3L, asLong("12.5", 3L));       // not a long -> default
		assertEquals(9_000_000_000L, asLong("9000000000", 0L));   // beyond int range -> proves long
	}

	@Test
	public void unescapeSimpleHandlesKnownUnknownAndTrailingEscapes()
	{
		// The source is RuneLite's OWN persisted GE history (written + re-read via its ConfigManager), so it is
		// trusted, well-formed JSON — a lenient reader is correct. The unknown-escape and trailing-backslash
		// cases below pin that robustness behaviour (the reader never throws on a malformed token); they are not
		// a claim that the parser validates arbitrary/untrusted JSON.
		assertEquals("plain", unescapeSimple("plain"));          // no backslash -> returned as-is
		assertEquals("a\nb", unescapeSimple("a\\nb"));           // \n -> newline
		assertEquals("a\tb", unescapeSimple("a\\tb"));           // \t -> tab
		assertEquals("\r", unescapeSimple("\\r"));               // \r -> carriage return
		assertEquals("\"", unescapeSimple("\\\""));              // \" -> a bare quote
		assertEquals("x\\y", unescapeSimple("x\\\\y"));          // \\ -> a single backslash
		assertEquals("z", unescapeSimple("\\z"));                // unknown escape -> drop the backslash
		assertEquals("ab\\", unescapeSimple("ab\\"));            // trailing lone backslash -> kept literally
	}

	@Test
	public void skipStringIsEscapeAware()
	{
		assertEquals(4, skipString("\"ab\"", 0));          // "ab" -> index past the closing quote
		assertEquals(6, skipString("\"a\\\"b\"", 0));      // "a\"b" -> the escaped inner quote is skipped
		assertEquals(4, skipString("\"abc", 0));           // unterminated -> the string length
	}

	@Test
	public void rawValueExtractsNumbersAndLiteralsAndNullsMissingKeys()
	{
		final String obj = "{\"i\":4151,\"q\":10}";
		assertEquals("4151", rawValue(obj, "i"));
		assertEquals("10", rawValue(obj, "q"));
		assertNull("a missing key yields null", rawValue(obj, "x"));

		assertEquals("true", rawValue("{\"b\" : true}", "b"));   // whitespace + colon between key and value
		assertEquals("99", rawValue("{\"p\":99}", "p"));          // value terminated by the closing brace
	}

	@Test
	public void rawValueUnquotesAndUnescapesStringValues()
	{
		assertEquals("12:30", rawValue("{\"t\":\"12:30\"}", "t"));      // quotes stripped
		assertEquals("a\"b", rawValue("{\"t\":\"a\\\"b\"}", "t"));      // escaped inner quote unescaped
	}

	@Test
	public void rawValueDoesNotCollideOnSubstringKeys()
	{
		// The key needle is quoted on BOTH sides ("\"" + key + "\""), so a key that is a suffix or prefix of
		// another key cannot false-match: searching "id" must not pick up "trade_id" or "identifier".
		assertNull("a suffix-key must not collide", rawValue("{\"trade_id\":2}", "id"));
		assertNull("a prefix-key must not collide", rawValue("{\"identifier\":2}", "id"));
		// And when the real key is also present alongside a colliding-looking one, it still resolves correctly.
		assertEquals("7", rawValue("{\"id\":7,\"trade_id\":2}", "id"));
	}

	@Test
	public void parseTradeObjectBuildsTheFullRecord()
	{
		final Client client = clientWithItem(4151, "Abyssal whip");
		final String obj = "{\"b\":true,\"i\":4151,\"q\":5,\"p\":1000,\"t\":\"2026\"}";

		assertEquals(
			"{\"buy\":true,\"itemId\":4151,\"name\":\"Abyssal whip\",\"qty\":5,\"price\":1000,\"time\":\"2026\"}",
			parseTradeObject(obj, client));
	}

	@Test
	public void parseTradeObjectReturnsNullWithoutAnItemId()
	{
		assertNull(parseTradeObject("{\"b\":true,\"q\":5}", clientWithItem(0, "")));
	}

	@Test
	public void parseTradeObjectOmitsAbsentTimeAndQuotesAnEmptyName()
	{
		// No "t" key -> the time field is dropped; an unresolved item -> itemName "" -> name:"".
		final Client client = mock(Client.class);   // getItemDefinition(..) defaults to null -> itemName ""
		final String obj = "{\"b\":false,\"i\":10,\"q\":2,\"p\":3}";

		assertEquals(
			"{\"buy\":false,\"itemId\":10,\"name\":\"\",\"qty\":2,\"price\":3}",
			parseTradeObject(obj, client));
	}

	// ---- reflection plumbing (the helpers are private static; see the class javadoc for why) -----------

	private static Client clientWithItem(int itemId, String name)
	{
		final Client client = mock(Client.class);
		final ItemComposition comp = mock(ItemComposition.class);
		when(comp.getMembersName()).thenReturn(name);
		when(client.getItemDefinition(itemId)).thenReturn(comp);
		return client;
	}

	private static Object invoke(String name, Class<?>[] types, Object... args)
	{
		try
		{
			final Method m = GrandExchangeBridge.class.getDeclaredMethod(name, types);
			m.setAccessible(true);
			return m.invoke(null, args);
		}
		catch (ReflectiveOperationException e)
		{
			throw new AssertionError("reflective call to GrandExchangeBridge." + name + " failed "
				+ "(was the private helper renamed? keep this test in lockstep)", e);
		}
	}

	private static long asLong(String s, long def)
	{
		return (Long) invoke("asLong", new Class<?>[]{String.class, long.class}, s, def);
	}

	private static String unescapeSimple(String s)
	{
		return (String) invoke("unescapeSimple", new Class<?>[]{String.class}, s);
	}

	private static int skipString(String s, int quoteIndex)
	{
		return (Integer) invoke("skipString", new Class<?>[]{String.class, int.class}, s, quoteIndex);
	}

	private static String rawValue(String obj, String key)
	{
		return (String) invoke("rawValue", new Class<?>[]{String.class, String.class}, obj, key);
	}

	private static String parseTradeObject(String obj, Client client)
	{
		return (String) invoke("parseTradeObject", new Class<?>[]{String.class, Client.class}, obj, client);
	}
}
