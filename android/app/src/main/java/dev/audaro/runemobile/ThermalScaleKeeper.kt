package dev.audaro.runemobile

/** The game's config and the throttle marker, as [ThermalScaleKeeper] sees them. Apart so its test runs on the desktop. */
internal interface ThermalScaleStore {
    /** The live sceneResolutionScale, or -1 if the config can't be read yet. */
    fun readScale(): Int

    /** Queues a write on the client thread. False if the bridge didn't take it, as it won't before the JVM is up. */
    fun writeScale(scale: Int): Boolean

    /** True once no config write is still queued on the client thread. */
    fun writesLanded(): Boolean

    /** Saves the config as it is in memory right now, returning once the file is written. False if that didn't happen. */
    fun save(): Boolean

    /** The player's value from the marker, or -1 when there is no marker. */
    fun readMarker(): Int

    /** False if the marker couldn't be written. */
    fun writeMarker(baseline: Int): Boolean

    fun clearMarker()
}

/**
 * Lowers 117HD's sceneResolutionScale for a thermal status and gives the player's value back afterwards. It has to get
 * that right through three things the game does to config writes:
 *  - Before the JVM is up the bridge takes nothing, so the write that recovers a killed session can't happen yet. The
 *    marker stays until the bridge has taken it.
 *  - Writes queue on the client thread, which can stall for minutes in a scene load or a shader compile. While any wait,
 *    the live value isn't what it will be, and a write now would land on top of a player's. So this waits for them.
 *  - A write that has landed is only in memory until something saves it, and a save takes what is in memory right then,
 *    without waiting for the queue. So the marker goes only after a save made once the queue is empty. A session killed
 *    before that still has its marker, and the next launch finishes the job.
 *
 * All of it is on the rl-bridge thread.
 */
internal class ThermalScaleKeeper(
    private val store: ThermalScaleStore,
    private val log: (String) -> Unit,
) {
    private var baseline = -1 // the player's value, -1 until the marker or the config says what it is
    private var applied = -1 // what the config should hold once the queue has drained
    private var retiringMarker = false // the marker can go once the player's value is on disk

    /** One pass at thermal [status]. True if there's more to do, so call again soon: no status change may ever come. */
    fun step(status: Int): Boolean {
        val limit = limitFor(status)
        if (baseline < 0 && !arm()) return limit > 0 || store.readMarker() > 0
        settleMarker()
        // Cool, with nothing to put back, is the one time there's nothing to look at. Under a limit a player's move has
        // to reach the marker before a kill can come, and the limit has to go over it, wherever the scale was before.
        val idle = limit == 0 && applied == baseline
        // No write can be judged, or made, until the queue is empty. Adopting a stale value could make a throttle
        // permanent, and no timer can stand in for this.
        val inPlace = idle || (store.writesLanded() && applyLimit(status, limit))
        return !inPlace || retiringMarker || limit > 0
    }

    // False while the player's value isn't known. A marker comes first: it's from a session killed mid-throttle, so the
    // config holds the lowered value.
    private fun arm(): Boolean {
        val leaked = store.readMarker()
        val known = if (leaked > 0) leaked else store.readScale()
        // Never guess a baseline: a wrong default could raise a player's lower scale.
        if (known <= 0 || (leaked > 0 && !store.writeScale(leaked))) return false
        baseline = known
        applied = known
        if (leaked > 0) {
            retiringMarker = true
            log("thermal: recovered a leaked throttle -> restored sceneResolutionScale=$leaked")
        } else {
            log("thermal: baseline sceneResolutionScale=$known")
        }
        return true
    }

    // False if the scale couldn't be put in place on this pass.
    private fun applyLimit(
        status: Int,
        limit: Int,
    ): Boolean {
        val live = store.readScale()
        // The player has moved the setting since the last write: theirs is the new baseline, or cooling down would put
        // the old value back.
        if (live <= 0 || (live != applied && !adoptPlayersScale(live))) return false
        return moveTo(scaleFor(limit), status)
    }

    private fun moveTo(
        target: Int,
        status: Int,
    ): Boolean {
        if (target != applied) return write(target, status)
        if (target == baseline) retireMarker() // a player's own value, and otherwise a throttle that's holding
        return true
    }

    private fun write(
        target: Int,
        status: Int,
    ): Boolean {
        val throttling = target < baseline
        // The marker goes down first and has to take: a lowered value must never reach the disk without one.
        if (throttling && !store.writeMarker(baseline)) return false
        val taken = store.writeScale(target)
        if (taken) {
            val prev = applied
            applied = target
            if (throttling) retiringMarker = false else retireMarker()
            log("thermal status=$status -> sceneResolutionScale $prev->$target (baseline=$baseline)")
        } else if (applied == baseline) {
            retireMarker() // nothing was lowered after all, and a stale marker could overwrite a player's later move
        }
        return taken
    }

    // False if the marker can't follow, because a kill would then bring back the old value. Nothing moves until it can.
    private fun adoptPlayersScale(live: Int): Boolean {
        if (store.readMarker() > 0 && !store.writeMarker(live)) return false
        log("thermal: player set sceneResolutionScale=$live (was $applied)")
        baseline = live
        applied = live
        return true
    }

    private fun retireMarker() {
        if (store.readMarker() > 0) retiringMarker = true
    }

    private fun settleMarker() {
        if (!retiringMarker || !store.writesLanded() || !store.save()) return
        store.clearMarker()
        retiringMarker = false
    }

    // Never above the baseline, so a low-res user config is honoured.
    private fun scaleFor(limit: Int) = if (limit > 0) minOf(baseline, limit) else baseline

    private fun limitFor(status: Int) =
        when {
            status >= STATUS_SEVERE -> SCALE_SEVERE
            status >= STATUS_MODERATE -> SCALE_MODERATE
            else -> 0
        }

    private companion object {
        const val STATUS_MODERATE = 2
        const val STATUS_SEVERE = 3 // and CRITICAL, EMERGENCY, SHUTDOWN
        const val SCALE_MODERATE = 65
        const val SCALE_SEVERE = 50
    }
}
