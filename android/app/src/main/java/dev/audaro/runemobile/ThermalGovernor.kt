package dev.audaro.runemobile

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import org.json.JSONObject
import java.io.File

/**
 * PERF-MEMORY-THERMAL-01: protect sustained 117HD play from silent thermal throttling. Registers a PowerManager
 * thermal-status listener (API 29+) and, while the 117HD renderer is active, has [ThermalScaleKeeper] step the 117HD
 * sceneResolutionScale DOWN under thermal pressure (MODERATE+) and give the player's value back once the device cools.
 * CPU and base-GPU renderers are light enough to leave untouched, so the governor no-ops unless 117HD is the live
 * renderer.
 *
 * The lever is sceneResolutionScale — the project's established 117HD load knob (fewer shaded fragments = less GPU
 * work = less heat; cf. FIX-13 where sceneScale 85 ≈ +35% fps) — applied via JvmLauncher.setConfig on the bridge
 * (client) thread. All work runs inside the bridge executor: the listener callback fires on the main thread, so a
 * direct getPluginConfig().get() there would block the UI; instead every pass submits one bridge task.
 *
 * Status changes can be hours apart, and the keeper often can't finish in one pass: the governor arms before the JVM
 * is up, and config writes wait on the client thread. So while it has more to do, a pass is run again every RETRY_MS.
 * While throttled, a marker file records the TRUE baseline, so a kill mid-throttle can't make the lowered value the
 * player's: the keeper's doc has how that holds up.
 */
class ThermalGovernor(
    private val pm: PowerManager,
    private val is117hd: Boolean,
    private val markerFile: File,
) {
    private val store =
        object : ThermalScaleStore {
            override fun readScale() = readBaselineScale()

            override fun writeScale(scale: Int) = JvmLauncher.setConfig("hd", "sceneResolutionScale", scale.toString()).startsWith(ACK_OK)

            override fun writesLanded() = JvmLauncher.configWritesLanded()

            override fun save() = JvmLauncher.flushConfig().startsWith(ACK_OK)

            override fun readMarker() = this@ThermalGovernor.readMarker()

            override fun writeMarker(baseline: Int) = this@ThermalGovernor.writeMarker(baseline)

            override fun clearMarker() = this@ThermalGovernor.clearMarker()
        }
    private val keeper = ThermalScaleKeeper(store) { Log.i(TAG, it) }
    private val retries = Handler(Looper.getMainLooper())

    @Volatile private var sensorStatus = 0

    @Volatile private var forcedStatus = -1 // DEBUG override (-1 = follow the real sensor)

    @Volatile private var stopped = false
    private var listener: Any? = null // PowerManager.OnThermalStatusChangedListener (API 29+); Any keeps the field API-safe

    fun start() {
        if (!is117hd || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        registerQ()
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun registerQ() {
        val l = PowerManager.OnThermalStatusChangedListener { status -> onStatus(status) }
        pm.addThermalStatusListener(l)
        listener = l
        Log.i(TAG, "thermal governor armed (117HD); current status=${pm.currentThermalStatus}")
        onStatus(pm.currentThermalStatus) // apply the starting status immediately
    }

    fun stop() {
        if (!is117hd) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            (listener as? PowerManager.OnThermalStatusChangedListener)?.let { pm.removeThermalStatusListener(it) }
        }
        listener = null
        // Never let a throttle persist past the session. If the process goes before this is done, the marker is still
        // there for the next launch.
        stopped = true
        pass()
    }

    /** DEBUG: force a thermal status for verification (SET_THERMAL_STATUS broadcast). Pass -1 to follow the sensor. */
    fun forceStatus(status: Int) {
        forcedStatus = status
        onStatus(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) pm.currentThermalStatus else 0)
    }

    private fun onStatus(rawStatus: Int) {
        if (!is117hd) return
        sensorStatus = rawStatus
        pass()
    }

    private fun pass() {
        JvmLauncher.onBridge {
            val status =
                when {
                    stopped -> 0
                    forcedStatus >= 0 -> forcedStatus
                    else -> sensorStatus
                }
            val moreToDo = keeper.step(status)
            retries.removeCallbacksAndMessages(null)
            if (moreToDo) retries.postDelayed(::pass, RETRY_MS)
        }
    }

    /** Read the live 117HD sceneResolutionScale (already on the bridge thread). -1 when the config isn't readable
     *  yet (no items / key absent) so the caller can defer instead of restoring a wrong default. */
    private fun readBaselineScale(): Int =
        try {
            val arr = JSONObject(JvmLauncher.getPluginConfig("hd")).optJSONArray("items")
            var v = -1
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    if (o.optString("key") == "sceneResolutionScale") {
                        v = o.optString("value", "").toIntOrNull() ?: -1
                        break
                    }
                }
            }
            v
        } catch (e: Throwable) {
            -1
        }

    private fun readMarker(): Int =
        try {
            if (markerFile.exists()) markerFile.readText().trim().toIntOrNull() ?: -1 else -1
        } catch (e: Throwable) {
            -1
        }

    private fun writeMarker(baseline: Int) {
        runCatching { markerFile.writeText(baseline.toString()) }
    }

    private fun clearMarker() {
        runCatching { if (markerFile.exists()) markerFile.delete() }
    }

    companion object {
        private const val TAG = "MainActivity"
        private const val RETRY_MS = 2_000L
        private const val ACK_OK = "{\"ok\":true"
    }
}
