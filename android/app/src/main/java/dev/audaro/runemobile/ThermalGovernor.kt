package dev.audaro.runemobile

import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import org.json.JSONObject
import java.io.File

/**
 * PERF-MEMORY-THERMAL-01: protect sustained 117HD play from silent thermal throttling. Registers a PowerManager
 * thermal-status listener (API 29+) and, while the 117HD renderer is active, steps the 117HD sceneResolutionScale
 * DOWN under thermal pressure (MODERATE+) and restores the captured baseline once the device cools. CPU and
 * base-GPU renderers are light enough to leave untouched, so the governor no-ops unless 117HD is the live renderer.
 *
 * The lever is sceneResolutionScale — the project's established 117HD load knob (fewer shaded fragments = less GPU
 * work = less heat; cf. FIX-13 where sceneScale 85 ≈ +35% fps) — applied via JvmLauncher.setConfig on the bridge
 * (client) thread. All work runs inside the bridge executor: the listener callback fires on the main thread, so a
 * direct getPluginConfig().get() there would block the UI; instead every status change submits one bridge task.
 *
 * Two correctness guards (a thrown thermal event can land before the 117HD config is loaded, and setConfig writes
 * PERSISTED config):
 *  - the baseline is captured ONLY from a real live sceneResolutionScale; if the config isn't readable yet the
 *    governor defers (no throttle) rather than restore a wrong default — so it never raises a user's lower scale.
 *  - while throttled, a marker file records the TRUE baseline; on start, a leftover marker (a prior session killed
 *    mid-throttle, so onDestroy's restore never ran) restores that baseline before arming. The persisted throttle
 *    can therefore never become the next session's "baseline".
 */
class ThermalGovernor(
    private val pm: PowerManager,
    private val is117hd: Boolean,
    private val markerFile: File,
) {
    // Touched only on the single-threaded bridge executor -> no synchronization needed.
    private var baselineScale = -1 // -1 = not captured yet (config not readable)
    private var appliedScale = -1

    @Volatile private var forcedStatus = -1 // DEBUG override (-1 = follow the real sensor)
    private var listener: Any? = null // PowerManager.OnThermalStatusChangedListener (API 29+); Any keeps the field API-safe

    fun start() {
        if (!is117hd || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        // Self-heal a leaked throttle from a prior session that was killed mid-throttle (onDestroy never ran).
        JvmLauncher.onBridgeTouch {
            val leaked = readMarker()
            if (leaked > 0) {
                baselineScale = leaked
                appliedScale = leaked
                JvmLauncher.setConfig("hd", "sceneResolutionScale", leaked.toString())
                clearMarker()
                Log.i(TAG, "thermal: recovered a leaked throttle -> restored sceneResolutionScale=$leaked")
            }
        }
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
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            (listener as? PowerManager.OnThermalStatusChangedListener)?.let { pm.removeThermalStatusListener(it) }
        }
        listener = null
        // Never let a throttle persist past the session — restore the captured baseline + drop the marker.
        JvmLauncher.onBridgeTouch {
            if (baselineScale > 0 && appliedScale != baselineScale) {
                appliedScale = baselineScale
                JvmLauncher.setConfig("hd", "sceneResolutionScale", baselineScale.toString())
            }
            clearMarker()
        }
    }

    /** DEBUG: force a thermal status for verification (SET_THERMAL_STATUS broadcast). Pass -1 to follow the sensor. */
    fun forceStatus(status: Int) {
        forcedStatus = status
        val effective =
            if (status >= 0) {
                status
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                pm.currentThermalStatus
            } else {
                0
            }
        onStatus(effective)
    }

    private fun onStatus(rawStatus: Int) {
        if (!is117hd) return
        val status = forcedStatus.let { if (it >= 0) it else rawStatus }
        JvmLauncher.onBridgeTouch {
            if (baselineScale < 0) {
                baselineScale = readBaselineScale()
                if (baselineScale < 0) return@onBridgeTouch // config not ready — defer rather than guess a baseline
            }
            val target = targetScaleFor(status, baselineScale)
            if (target == appliedScale) return@onBridgeTouch
            val prev = appliedScale
            appliedScale = target
            JvmLauncher.setConfig("hd", "sceneResolutionScale", target.toString())
            if (target < baselineScale) writeMarker(baselineScale) else clearMarker()
            Log.i(TAG, "thermal status=$status -> sceneResolutionScale $prev->$target (baseline=$baselineScale)")
        }
    }

    // Pressure -> scale. NONE/LIGHT keep the baseline; MODERATE and SEVERE+ cap progressively lower (never above
    // the baseline, so a low-res user config is honoured).
    private fun targetScaleFor(
        status: Int,
        baseline: Int,
    ): Int =
        when {
            status >= 3 -> minOf(baseline, SCALE_SEVERE)

            // SEVERE / CRITICAL / EMERGENCY / SHUTDOWN
            status >= 2 -> minOf(baseline, SCALE_MODERATE)

            // MODERATE
            else -> baseline // NONE / LIGHT
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
        private const val SCALE_MODERATE = 65
        private const val SCALE_SEVERE = 50
    }
}
