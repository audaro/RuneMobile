package dev.audaro.runemobile

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Where the hot-phone notice goes. The same cases as the iOS heat check's checkNoticeSpot. */
class HeatNoticeTest {
    private val area = intArrayOf(0, 0, 900, 400)

    private fun spot(vararg blockers: IntArray) = HeatNotice.spot(area, 300, 100, blockers.toList(), 8)

    // [left, top, width, height], as the iOS cases are written.
    private fun box(
        x: Int,
        y: Int,
        w: Int,
        h: Int,
    ) = intArrayOf(x, y, x + w, y + h)

    @Test
    fun bottomCentreOnAnEmptyScreen() = assertArrayEquals(intArrayOf(300, 300), spot())

    @Test
    fun bottomCentreBetweenAKeyBarAndAnInventory() =
        assertArrayEquals(intArrayOf(300, 300), spot(box(0, 340, 200, 60), box(700, 200, 200, 200)))

    @Test
    fun offCentreAsNearItAsTheGapAllows() = assertArrayEquals(intArrayOf(388, 300), spot(box(0, 340, 380, 60), box(700, 200, 200, 200)))

    @Test
    fun aboveTheKeyBarWhenTheGapBesideItIsTooNarrow() =
        assertArrayEquals(intArrayOf(300, 232), spot(box(0, 340, 420, 60), box(700, 200, 200, 200)))

    @Test
    fun besideAButtonInTheMiddleOfTheBottomEdge() = assertArrayEquals(intArrayOf(92, 300), spot(box(400, 350, 100, 50)))

    @Test
    fun justAboveAFullWidthBarAlongTheBottom() = assertArrayEquals(intArrayOf(300, 222), spot(box(0, 330, 900, 70)))

    @Test
    fun aboveTheBarBetweenWhatSitsOnIt() =
        assertArrayEquals(
            intArrayOf(300, 222),
            spot(box(0, 330, 900, 70), box(0, 250, 200, 50), box(700, 240, 200, 60)),
        )

    @Test
    fun noSpotWhenNothingFits() = assertNull(spot(box(0, 330, 900, 70), box(0, 0, 900, 250)))

    @Test
    fun noSpotOnAScreenNarrowerThanIt() = assertNull(HeatNotice.spot(intArrayOf(0, 0, 250, 400), 300, 100, emptyList(), 8))
}
