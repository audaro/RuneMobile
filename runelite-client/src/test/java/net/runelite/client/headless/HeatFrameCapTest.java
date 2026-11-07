package net.runelite.client.headless;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import org.junit.Test;

public class HeatFrameCapTest
{
	private static final long MS = 1_000_000L;

	private final HeatFrameCap cap = new HeatFrameCap();

	/** Frames that take {@code drawMs} each, held back as the cap asks: the number drawn in ten simulated seconds. */
	private int framesInTenSeconds(long drawMs)
	{
		long now = 0;
		int frames = 0;
		while (now < 10_000 * MS)
		{
			now += drawMs * MS;
			now += cap.waitNs(now);
			frames++;
		}
		return frames;
	}

	@Test
	public void noLimitHoldsNothingBack()
	{
		assertEquals(0, cap.waitNs(0));
		assertEquals(0, cap.waitNs(5 * MS));
		assertEquals(500, framesInTenSeconds(20));
	}

	@Test
	public void quickFramesAreHeldToTheLimit()
	{
		cap.setFps(30);
		assertEquals(300, framesInTenSeconds(20), 1);
	}

	@Test
	public void framesSlowerThanTheLimitAreLeftAlone()
	{
		cap.setFps(30);
		assertEquals(200, framesInTenSeconds(50));
	}

	@Test
	public void aFrameALittleLateTakesItsTimeBackFromTheNext()
	{
		cap.setFps(50);
		assertEquals(0, cap.waitNs(0));
		assertEquals(0, cap.waitNs(25 * MS));
		assertEquals(15 * MS, cap.waitNs(25 * MS));
	}

	@Test
	public void aStallIsNotFollowedByABurst()
	{
		cap.setFps(50);
		assertEquals(0, cap.waitNs(0));
		assertEquals(0, cap.waitNs(500 * MS));
		assertTrue(cap.waitNs(501 * MS) >= 19 * MS);
	}

	@Test
	public void liftingTheLimitLetsFramesGoAndANewOneStartsFresh()
	{
		cap.setFps(30);
		cap.waitNs(0);
		assertTrue(cap.waitNs(MS) > 0);
		cap.setFps(0);
		assertEquals(0, cap.waitNs(2 * MS));
		cap.setFps(30);
		assertEquals(0, cap.waitNs(3 * MS));
		assertTrue(cap.waitNs(4 * MS) > 0);
	}

	@Test
	public void aNegativeLimitMeansNoLimit()
	{
		cap.setFps(-5);
		assertEquals(500, framesInTenSeconds(20));
	}
}
