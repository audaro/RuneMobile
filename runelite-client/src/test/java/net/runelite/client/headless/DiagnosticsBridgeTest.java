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

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.util.concurrent.CountDownLatch;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import org.junit.Test;

public class DiagnosticsBridgeTest
{
	@Test
	public void engineReportIsJsonWithoutAnEngine()
	{
		// Before init (the cover screen, or a boot that failed early) it still answers, as JSON the shells parse.
		final JsonObject o = new JsonParser().parse(DiagnosticsBridge.engineReport()).getAsJsonObject();
		assertTrue(o.get("names").isJsonArray());
		final String text = o.get("text").getAsString();
		assertTrue(text, text.startsWith("RuneLite "));
		assertTrue(text, text.contains("Plugins: (not loaded yet)"));
		assertTrue(text, text.contains("Threads ("));
		assertTrue(text, text.contains('"' + Thread.currentThread().getName() + '"'));
	}

	@Test
	public void threadDumpPutsADeadlockFirst() throws Exception
	{
		final Object a = new Object();
		final Object b = new Object();
		final CountDownLatch bothHold = new CountDownLatch(2);
		final Thread t1 = lockPair("zz-deadlock-one", a, b, bothHold);
		final Thread t2 = lockPair("zz-deadlock-two", b, a, bothHold);
		t1.start();
		t2.start();
		bothHold.await();
		String dump = "";
		for (int i = 0; i < 100 && !dump.contains("DEADLOCKED"); i++)
		{
			Thread.sleep(20); // until both threads are parked on the other's lock
			dump = DiagnosticsBridge.threadDump();
		}
		assertTrue(dump, dump.contains("deadlocked: 2 threads"));
		// Sorted ahead of every other thread despite the "zz" names, each with the lock and its holder.
		final String firstThread = dump.split("\n")[1];
		assertTrue(firstThread, firstThread.startsWith("\"zz-deadlock-"));
		assertTrue(firstThread, firstThread.contains("DEADLOCKED on java.lang.Object@"));
		assertTrue(dump, dump.contains("held by \"zz-deadlock-"));
		assertTrue(dump, dump.contains("- holds java.lang.Object@"));
		assertEquals(2, dump.split("DEADLOCKED", -1).length - 1);
	}

	@Test
	public void findThreadSeesALiveThreadOnly() throws Exception
	{
		// How the watchdog tells "the game thread has exited" from "it is slow": it holds the thread it found.
		final CountDownLatch release = new CountDownLatch(1);
		final Thread t = new Thread(() ->
		{
			try
			{
				release.await();
			}
			catch (InterruptedException e)
			{
				// ends the thread either way
			}
		}, "zz-find-me");
		t.setDaemon(true);
		t.start();
		assertSame(t, DiagnosticsBridge.findThread("zz-find-me"));
		release.countDown();
		t.join(5_000);
		assertFalse(t.isAlive());
		assertNull(DiagnosticsBridge.findThread("zz-find-me"));
	}

	private static Thread lockPair(String name, Object first, Object second, CountDownLatch bothHold)
	{
		final Thread t = new Thread(() ->
		{
			synchronized (first)
			{
				bothHold.countDown();
				try
				{
					bothHold.await();
				}
				catch (InterruptedException e)
				{
					return;
				}
				synchronized (second)
				{
					bothHold.countDown(); // never reached
				}
			}
		}, name);
		t.setDaemon(true); // left deadlocked; daemon so the test JVM still exits
		return t;
	}
}
