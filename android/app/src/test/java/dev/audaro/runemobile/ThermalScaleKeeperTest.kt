package dev.audaro.runemobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** ThermalScaleKeeper against a game that behaves like the real one: writes queue, and a save takes what's in memory. */
class ThermalScaleKeeperTest {
    private class FakeGame(
        var live: Int,
    ) : ThermalScaleStore {
        var disk = live
        var marker = -1
        var bridgeUp = true
        var refuseWrites = false
        var refuseSaves = false
        var configUnreadable = false
        var refuseMarker = false
        var reads = 0
        val queue = ArrayDeque<Int>()
        val markerWhenQueued = mutableListOf<Int>()

        fun land() {
            while (queue.isNotEmpty()) live = queue.removeFirst()
        }

        fun playerSets(scale: Int) {
            queue.addLast(scale)
        }

        fun appSaves() {
            disk = live
        }

        override fun readScale(): Int {
            reads++
            return if (bridgeUp && !configUnreadable) live else -1
        }

        override fun writeScale(scale: Int): Boolean {
            if (!bridgeUp || refuseWrites) return false
            queue.addLast(scale)
            markerWhenQueued += marker
            return true
        }

        override fun writesLanded() = bridgeUp && queue.isEmpty()

        override fun save(): Boolean {
            if (!bridgeUp || refuseSaves) return false
            appSaves()
            return true
        }

        override fun readMarker() = marker

        override fun writeMarker(baseline: Int): Boolean {
            if (refuseMarker) return false
            marker = baseline
            return true
        }

        override fun clearMarker() {
            marker = -1
        }
    }

    private val logs = mutableListOf<String>()

    private fun keeper(game: FakeGame) = ThermalScaleKeeper(game) { logs += it }

    /** Armed at [scale] and throttled to severe, with that throttle in memory and on disk. */
    private fun throttled(
        game: FakeGame,
        keeper: ThermalScaleKeeper,
    ) {
        keeper.step(0)
        keeper.step(3)
        game.land()
        game.appSaves()
        assertEquals(50, game.disk)
    }

    @Test
    fun aThrottleComesOnWithTheMarkerHoldingThePlayersValue() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        assertFalse(keeper.step(0))
        assertTrue("a throttle keeps being looked at", keeper.step(2))
        game.land()
        assertEquals(65, game.live)
        assertEquals(100, game.marker)
        assertTrue(keeper.step(3))
        game.land()
        assertEquals(50, game.live)
        assertEquals(100, game.marker)
    }

    @Test
    fun theLogLinesFpsMeasureReadsKeepTheirShape() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(2)
        assertTrue(logs.toString(), "thermal status=2 -> sceneResolutionScale 100->65 (baseline=100)" in logs)
        val killed = FakeGame(50).apply { marker = 85 }
        keeper(killed).step(0)
        assertTrue(logs.toString(), "thermal: recovered a leaked throttle -> restored sceneResolutionScale=85" in logs)
    }

    @Test
    fun coolingDownKeepsTheMarkerUntilThePlayersValueIsOnDisk() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)

        assertTrue(keeper.step(0))
        assertEquals("queued, not landed", 50, game.live)
        assertEquals(100, game.marker)
        assertTrue("a stalled client thread is waited for", keeper.step(0))
        assertEquals("a save now would keep the throttle", 50, game.disk)
        assertEquals(100, game.marker)

        game.land()
        assertFalse(keeper.step(0))
        assertEquals(100, game.disk)
        assertEquals(-1, game.marker)
    }

    @Test
    fun aSaveThatFailsKeepsTheMarkerAndIsTriedAgain() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        keeper.step(0)
        game.land()
        game.refuseSaves = true
        assertTrue(keeper.step(0))
        assertEquals(100, game.marker)
        game.refuseSaves = false
        assertFalse(keeper.step(0))
        assertEquals(-1, game.marker)
    }

    @Test
    fun recoveryWaitsForTheBridgeAndKeepsTheMarkerUntilThePlayersValueIsOnDisk() {
        val game = FakeGame(50).apply { marker = 85 }
        game.bridgeUp = false
        val keeper = keeper(game)
        assertTrue("the JVM isn't up at launch", keeper.step(0))
        assertEquals(85, game.marker)
        assertTrue(keeper.step(0))
        assertTrue(game.queue.isEmpty())

        game.bridgeUp = true
        assertTrue(keeper.step(0))
        assertEquals(85, game.marker)
        assertEquals(50, game.disk)

        game.land()
        assertFalse(keeper.step(0))
        assertEquals(85, game.disk)
        assertEquals(-1, game.marker)
    }

    @Test
    fun aRecoveryIntoAHotPhoneThrottlesAgainFromThePlayersValue() {
        val game = FakeGame(50).apply { marker = 100 }
        val keeper = keeper(game)
        assertTrue(keeper.step(2))
        game.land()
        keeper.step(2)
        assertEquals("the player's value saved before the next throttle", 100, game.disk)
        game.land()
        assertEquals(65, game.live)
        assertEquals(100, game.marker)
    }

    @Test
    fun aWriteTheBridgeRefusesIsTriedAgainAndLeavesNoMarker() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(0)
        game.refuseWrites = true
        assertTrue(keeper.step(2))
        game.refuseWrites = false
        keeper.step(2)
        game.land()
        assertEquals(65, game.live)
        assertEquals(100, game.marker)
        assertTrue("a refused write isn't a player's move", logs.none { "player set" in it })
    }

    @Test
    fun aThrottleThatWasRefusedLeavesNoMarkerToOverwriteAPlayerLater() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(0)
        game.refuseWrites = true
        keeper.step(2)
        game.refuseWrites = false
        assertFalse(keeper.step(0))
        assertEquals(-1, game.marker)
        assertEquals(100, game.live)
    }

    @Test
    fun aRefusedSecondStepKeepsTheMarkerOfTheThrottleInForce() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(2)
        game.land()
        game.appSaves()
        game.refuseWrites = true
        assertTrue(keeper.step(3))
        // Easing back to the throttle in force writes nothing, so nothing would put a lost marker back.
        keeper.step(2)
        assertEquals(100, game.marker)
        assertEquals(65, game.disk)
    }

    @Test
    fun theMarkerIsDownBeforeAThrottleIsQueued() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(2)
        assertEquals(listOf(100), game.markerWhenQueued)
    }

    @Test
    fun noThrottleWithoutAMarker() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(0)
        game.refuseMarker = true
        assertTrue(keeper.step(3))
        assertTrue(game.queue.isEmpty())
        game.refuseMarker = false
        keeper.step(3)
        game.land()
        assertEquals(50, game.live)
        assertEquals(100, game.marker)
    }

    @Test
    fun aPlayersQueuedWriteIsWaitedForNotOverwritten() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(0)
        game.playerSets(80)
        assertTrue(keeper.step(2))
        assertEquals("nothing queued behind the player's", listOf(80), game.queue.toList())

        game.land()
        keeper.step(2)
        game.land()
        assertEquals(65, game.live)
        assertEquals(80, game.marker)

        keeper.step(0)
        game.land()
        assertFalse(keeper.step(0))
        assertEquals(80, game.disk)
    }

    @Test
    fun aPlayerWhoMovesItBeforeAThrottleGetsTheirValueBack() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(0)
        game.playerSets(80)
        game.land()
        keeper.step(2)
        game.land()
        keeper.step(0)
        game.land()
        keeper.step(0)
        assertEquals(80, game.live)
        assertEquals(80, game.disk)
    }

    @Test
    fun aPlayerWhoMovesItMidThrottleKeepsTheirValueWithoutAWrite() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        game.playerSets(90)
        game.land()

        assertTrue(keeper.step(0))
        assertTrue("theirs needs no write", game.queue.isEmpty())
        assertEquals("not gone yet: disk still has the throttle", 90, game.marker)
        assertFalse(keeper.step(0))
        assertEquals(90, game.disk)
        assertEquals(-1, game.marker)
        assertEquals(90, game.live)
    }

    @Test
    fun aPlayerWhoMovesItMidThrottleIsStillThrottledFromTheirValue() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(2)
        game.land()
        game.playerSets(90)
        game.land()
        keeper.step(3)
        game.land()
        assertEquals(50, game.live)
        assertEquals(90, game.marker)
    }

    @Test
    fun aSteadyThrottleWritesNothingAndKeepsItsMarker() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        repeat(3) { assertTrue(keeper.step(3)) }
        assertTrue(game.queue.isEmpty())
        assertEquals(100, game.marker)
        assertEquals(50, game.live)
    }

    @Test
    fun aPlayersMoveDuringASteadyThrottleReachesTheMarkerBeforeAKill() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        game.playerSets(90)
        assertTrue("queued: not judged yet", keeper.step(3))
        assertEquals(100, game.marker)
        game.land()

        keeper.step(3)
        assertEquals(90, game.marker)
        game.land()
        assertEquals("the limit still holds", 50, game.live)
        game.appSaves()

        val nextLaunch = keeper(game)
        nextLaunch.step(0)
        game.land()
        assertFalse(nextLaunch.step(0))
        assertEquals(90, game.disk)
        assertEquals(-1, game.marker)
    }

    @Test
    fun aMoveTheMarkerCantFollowChangesNothingUntilItCan() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        game.playerSets(90)
        game.land()
        game.refuseMarker = true
        assertTrue(keeper.step(3))
        assertTrue("no limit over a move the marker doesn't have", game.queue.isEmpty())
        assertTrue("not adopted yet", logs.none { "player set" in it })
        assertEquals(100, game.marker)

        game.refuseMarker = false
        keeper.step(3)
        assertEquals(90, game.marker)
        game.land()
        assertEquals(50, game.live)
    }

    @Test
    fun aPlayerWhoDropsBelowTheLimitDuringAThrottleEndsIt() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        game.playerSets(40)
        game.land()
        assertTrue("the marker has to go, once their value is saved", keeper.step(3))
        assertTrue(game.queue.isEmpty())
        assertTrue("a limit in force is still looked at", keeper.step(3))
        assertEquals(40, game.disk)
        assertEquals(-1, game.marker)
    }

    @Test
    fun aScaleBelowTheLimitIsLeftAlone() {
        val game = FakeGame(40)
        val keeper = keeper(game)
        keeper.step(0)
        assertTrue("a limit in force is still looked at", keeper.step(3))
        assertTrue(game.queue.isEmpty())
        assertEquals(-1, game.marker)
    }

    @Test
    fun aPlayerWhoDropsBelowTheLimitIsLeftAlone() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(0)
        game.playerSets(40)
        game.land()
        assertTrue("a limit in force is still looked at", keeper.step(3))
        assertTrue(game.queue.isEmpty())
        assertEquals(40, game.live)
        assertEquals(-1, game.marker)
    }

    @Test
    fun aCoolPhoneDoesntReadTheConfig() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(0)
        val armed = game.reads
        repeat(5) { keeper.step(0) }
        assertEquals(armed, game.reads)
    }

    @Test
    fun aPlayerWhoRaisesItFromUnderALimitInForceGetsTheLimit() {
        val game = FakeGame(40)
        val keeper = keeper(game)
        keeper.step(0)
        keeper.step(3)
        game.playerSets(100)
        game.land()
        assertTrue("under a limit it keeps being looked at", keeper.step(3))
        game.land()
        assertEquals(50, game.live)
        assertEquals(100, game.marker)

        keeper.step(0)
        game.land()
        assertFalse(keeper.step(0))
        assertEquals(100, game.disk)
        assertEquals(-1, game.marker)
    }

    @Test
    fun aPlayerWhoRaisedItFromUnderTheLimitOnACoolPhoneGetsTheLimit() {
        val game = FakeGame(40)
        val keeper = keeper(game)
        keeper.step(0)
        game.playerSets(100)
        game.land()
        assertFalse(keeper.step(0))
        keeper.step(2)
        game.land()
        assertEquals(65, game.live)
        assertEquals(100, game.marker)
    }

    @Test
    fun aPlayerExactlyAtTheLimitWhoRaisesItGetsTheLimit() {
        val game = FakeGame(50)
        val keeper = keeper(game)
        keeper.step(3)
        game.playerSets(100)
        game.land()
        keeper.step(3)
        game.land()
        assertEquals(50, game.live)
        assertEquals(100, game.marker)
    }

    @Test
    fun heatComingBackDuringARestoreThrottlesAgainWithTheMarkerKept() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        keeper.step(0)
        assertTrue(keeper.step(3))
        game.land()
        keeper.step(3)
        game.land()
        assertEquals(50, game.live)
        assertEquals(100, game.marker)
        assertEquals("saved before it came back on", 100, game.disk)
    }

    @Test
    fun aThrottleWhileASaveIsFailingKeepsTheMarker() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        keeper.step(0)
        game.land()
        game.refuseSaves = true
        keeper.step(3)
        game.land()
        game.refuseSaves = false
        keeper.step(3)
        assertEquals(50, game.live)
        assertEquals(100, game.marker)
    }

    @Test
    fun anUnreadableConfigIsNeverGuessedAtAndOnlyRetriedIfThereIsSomethingToDo() {
        val game = FakeGame(80)
        game.bridgeUp = false
        val keeper = keeper(game)
        assertFalse("calm, and no marker: nothing to wait for", keeper.step(0))
        assertTrue("hot: come back", keeper.step(3))
        assertEquals(-1, game.marker)
        assertTrue(game.queue.isEmpty())
        assertTrue("nothing armed yet", logs.isEmpty())

        game.bridgeUp = true
        keeper.step(3)
        game.land()
        assertEquals(50, game.live)
        assertEquals(80, game.marker)
        assertTrue("armed on the real value", logs.none { "player set" in it })
    }

    @Test
    fun anUnreadableConfigWhileCoolingDownIsTriedAgain() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        throttled(game, keeper)
        game.configUnreadable = true
        assertTrue("the throttle still has to come off", keeper.step(0))
        assertTrue(game.queue.isEmpty())
        game.configUnreadable = false
        keeper.step(0)
        game.land()
        assertEquals(100, game.live)
    }

    @Test
    fun anUnreadableConfigAfterArmingIsTriedAgain() {
        val game = FakeGame(100)
        val keeper = keeper(game)
        keeper.step(0)
        game.configUnreadable = true
        assertTrue(keeper.step(3))
        assertEquals(-1, game.marker)
        assertTrue(game.queue.isEmpty())
        game.configUnreadable = false
        keeper.step(3)
        game.land()
        assertEquals(50, game.live)
        assertEquals(100, game.marker)
    }
}
