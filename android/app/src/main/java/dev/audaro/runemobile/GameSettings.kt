package dev.audaro.runemobile

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.util.Locale
import kotlin.math.roundToInt

internal fun prefs(ctx: Context): SharedPreferences = ctx.getSharedPreferences("game_settings", Context.MODE_PRIVATE)

/**
 * The phone-side game settings behind the launcher's Game settings screen. They live in their own
 * SharedPreferences file and MainActivity reads them live, so a change applies without a restart.
 */
object GameSettings {
    private const val KEY_HAPTIC_STRENGTH = "haptic_strength"
    private const val KEY_LONG_PRESS_MS = "long_press_ms"
    private const val KEY_CAMERA_SENSITIVITY = "camera_sensitivity"

    /** The four haptic triggers, each with its own switch. All default on. */
    enum class Haptic(
        val key: String,
        val label: String,
        val detail: String,
    ) {
        OP("haptic_op", "Actions", "Tapping something you can interact with"),
        DRAG("haptic_drag", "Drag start", "Picking up an item to move it"),
        MENU_OPEN("haptic_menu_open", "Menu open", "The long-press menu appearing"),
        MENU_HOVER("haptic_menu_hover", "Menu rows", "Sliding over the menu's options"),
    }

    val STRENGTH_LABELS = listOf("Light", "Medium", "Heavy")
    private val STRENGTH_MS = longArrayOf(5, 20, 50) // one-shot length per strength
    private const val STRENGTH_DEFAULT = 1

    const val LONG_PRESS_MIN_MS = 200
    const val LONG_PRESS_MAX_MS = 1000
    const val LONG_PRESS_STEP_MS = 50
    const val LONG_PRESS_DEFAULT_MS = 400 // the hold the app has always used
    const val DRAG_HOLD_MAX_MS = 150L

    const val CAMERA_SENS_MIN = 0.1f
    const val CAMERA_SENS_MAX = 4.0f
    const val CAMERA_SENS_DEFAULT = 2.0f // the drag speed the app has always used

    /** Frame-rate cap choices; 0 is no cap. */
    val FPS_CAP_CHOICES = listOf(0, 20, 30, 40, 50, 60)

    fun hapticOn(
        ctx: Context,
        h: Haptic,
    ): Boolean = prefs(ctx).getBoolean(h.key, true)

    fun setHapticOn(
        ctx: Context,
        h: Haptic,
        on: Boolean,
    ) = prefs(ctx).edit().putBoolean(h.key, on).apply()

    fun hapticStrength(ctx: Context): Int = prefs(ctx).getInt(KEY_HAPTIC_STRENGTH, STRENGTH_DEFAULT).coerceIn(0, STRENGTH_MS.size - 1)

    fun setHapticStrength(
        ctx: Context,
        s: Int,
    ) = prefs(ctx).edit().putInt(KEY_HAPTIC_STRENGTH, s.coerceIn(0, STRENGTH_MS.size - 1)).apply()

    /** One buzz at the chosen strength. */
    fun buzz(
        ctx: Context,
        v: Vibrator?,
    ) {
        if (v == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        // Guard the vibrate: it needs the VIBRATE permission and some devices restrict the vibrator outright — a
        // SecurityException here must never take down the UI thread (it once did, on the menu-highlight haptic).
        try {
            v.vibrate(VibrationEffect.createOneShot(STRENGTH_MS[hapticStrength(ctx)], VibrationEffect.DEFAULT_AMPLITUDE))
        } catch (_: Exception) {
            // haptics are best-effort; ignore
        }
    }

    /** How long a finger has to stay put before the long-press menu opens. */
    fun longPressMs(ctx: Context): Long =
        prefs(ctx).getInt(KEY_LONG_PRESS_MS, LONG_PRESS_DEFAULT_MS).coerceIn(LONG_PRESS_MIN_MS, LONG_PRESS_MAX_MS).toLong()

    fun setLongPressMs(
        ctx: Context,
        ms: Int,
    ) = prefs(ctx).edit().putInt(KEY_LONG_PRESS_MS, ms.coerceIn(LONG_PRESS_MIN_MS, LONG_PRESS_MAX_MS)).apply()

    fun cameraSensitivity(ctx: Context): Float =
        prefs(ctx).getFloat(KEY_CAMERA_SENSITIVITY, CAMERA_SENS_DEFAULT).coerceIn(CAMERA_SENS_MIN, CAMERA_SENS_MAX)

    fun setCameraSensitivity(
        ctx: Context,
        v: Float,
    ) = prefs(ctx).edit().putFloat(KEY_CAMERA_SENSITIVITY, v.coerceIn(CAMERA_SENS_MIN, CAMERA_SENS_MAX)).apply()

    /** The camera drag multiplier: 1 at the default sensitivity. */
    fun cameraGain(ctx: Context): Float = cameraSensitivity(ctx) / CAMERA_SENS_DEFAULT
}

/**
 * How long a finger has to rest on an item before dragging it moves the item: two thirds of the long-press time,
 * at most 150 ms. A quicker swipe never picks the item up.
 */
fun GameSettings.dragHoldMs(ctx: Context): Long = minOf(longPressMs(ctx) * 2 / 3, GameSettings.DRAG_HOLD_MAX_MS)

internal val GS_DIM = Color(0xFF9E9E9E)
private val GS_ACCENT = Color(0xFFF29E1C)

/** The native Game settings screen, reached from the launcher's More tiles. */
@Composable
fun GameSettingsScreen(onBack: () -> Unit) {
    Surface(color = Color(0xFF121212), modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp).verticalScroll(rememberScrollState())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) { Text("‹ Back") }
                Text("Game settings", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            GsScreenSection()
            GsTouchSection()
            GsGameSection()
            GsLoginSection()
            GsHapticsSection()
            Spacer(Modifier.heightIn(min = 16.dp))
        }
    }
}

@Composable
private fun GsTouchSection() {
    val ctx = LocalContext.current
    GsSectionHeader("Touch")
    GsSlider(
        label = "Long-press time",
        initial = GameSettings.longPressMs(ctx).toFloat(),
        span =
            GsSpan(
                GameSettings.LONG_PRESS_MIN_MS.toFloat(),
                GameSettings.LONG_PRESS_MAX_MS.toFloat(),
                GameSettings.LONG_PRESS_STEP_MS.toFloat(),
            ),
        format = { "${it.roundToInt()} ms" },
        onDone = { GameSettings.setLongPressMs(ctx, it.roundToInt()) },
    )
    GsSlider(
        label = "Camera sensitivity",
        initial = GameSettings.cameraSensitivity(ctx),
        span = GsSpan(GameSettings.CAMERA_SENS_MIN, GameSettings.CAMERA_SENS_MAX, 0.1f),
        format = { String.format(Locale.US, "%.1f", it) },
        onDone = { GameSettings.setCameraSensitivity(ctx, it) },
    )
}

/** Idle logout and the frame-rate cap ride on RuneLite plugins, so they need the game running to read or change. */
@Composable
private fun GsGameSection() {
    var loaded by remember { mutableStateOf(false) }
    var fpsCap by remember { mutableIntStateOf(0) }
    var idle by remember { mutableIntStateOf(5) }
    LaunchedEffect(Unit) {
        val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.gameSettings() }.get() }
        val d = runCatching { JSONObject(json) }.getOrNull()
        if (d != null) {
            fpsCap = d.optInt("fpsCap", 0)
            idle = d.optInt("idleLogoutMinutes", 5)
            loaded = true
        }
    }
    GsSectionHeader("Game")
    if (!loaded) {
        Text("Available once the game is running.", color = GS_DIM, fontSize = 12.sp)
        return
    }
    GsSlider(
        label = "Idle logout",
        initial = idle.toFloat(),
        span = GsSpan(5f, 30f, 1f), // the Logout Timer plugin's range
        format = { "${it.roundToInt()} min" },
        onDone = {
            val m = it.roundToInt()
            idle = m
            JvmLauncher.onBridge { JvmLauncher.setIdleLogoutMinutes(m) }
        },
    )
    Text("Frame-rate cap", color = Color.White, fontSize = 14.sp, modifier = Modifier.padding(top = 10.dp, bottom = 6.dp))
    val choices = (GameSettings.FPS_CAP_CHOICES + fpsCap).distinct().sorted()
    GsSegments(choices.map { if (it == 0) "Off" else "$it" }, choices.indexOf(fpsCap)) { i ->
        fpsCap = choices[i]
        val cap = fpsCap
        JvmLauncher.onBridge { JvmLauncher.setFpsCap(cap) }
    }
}

@Composable
private fun GsHapticsSection() {
    val ctx = LocalContext.current
    GsSectionHeader("Haptics")
    for (h in GameSettings.Haptic.entries) {
        var on by remember { mutableStateOf(GameSettings.hapticOn(ctx, h)) }
        GsSwitchRow(h.label, h.detail, on) {
            on = it
            GameSettings.setHapticOn(ctx, h, it)
        }
        HorizontalDivider(color = Color(0x18FFFFFF))
    }
    var strength by remember { mutableIntStateOf(GameSettings.hapticStrength(ctx)) }
    Text("Strength", color = Color.White, fontSize = 14.sp, modifier = Modifier.padding(top = 10.dp, bottom = 6.dp))
    GsSegments(GameSettings.STRENGTH_LABELS, strength) { i ->
        strength = i
        GameSettings.setHapticStrength(ctx, i)
        GameSettings.buzz(ctx, ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator) // a sample
    }
}

@Composable
internal fun GsSectionHeader(title: String) {
    Text(
        title.uppercase(),
        color = GS_ACCENT,
        fontSize = 12.sp,
        modifier = Modifier.padding(top = 14.dp, bottom = 4.dp),
    )
}

@Composable
internal fun GsSwitchRow(
    label: String,
    detail: String,
    on: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { onChange(!on) }
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, color = Color.White, fontSize = 14.sp)
            Text(detail, color = GS_DIM, fontSize = 12.sp)
        }
        Switch(checked = on, onCheckedChange = onChange)
    }
}

/** A slider's span and the gap between its stops. */
private class GsSpan(
    val lo: Float,
    val hi: Float,
    step: Float,
) {
    val steps = ((hi - lo) / step).roundToInt() - 1 // the stops between the two ends
}

/** A labelled slider showing its value; [onDone] gets the value once the finger lifts. */
@Composable
private fun GsSlider(
    label: String,
    initial: Float,
    span: GsSpan,
    format: (Float) -> String,
    onDone: (Float) -> Unit,
) {
    var value by remember(initial) { mutableFloatStateOf(initial) }
    val valueText = format(value)
    Column(Modifier.fillMaxWidth().padding(top = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = Color.White, fontSize = 14.sp, modifier = Modifier.weight(1f))
            Text(valueText, color = GS_DIM, fontSize = 14.sp)
        }
        Slider(
            value = value,
            valueRange = span.lo..span.hi,
            steps = span.steps,
            onValueChange = { value = it },
            onValueChangeFinished = { onDone(value) },
            modifier =
                Modifier.fillMaxWidth().semantics {
                    contentDescription = label
                    stateDescription = valueText
                },
        )
    }
}

@Composable
internal fun GsSegments(
    labels: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        labels.forEachIndexed { i, label ->
            SegmentedButton(
                selected = selected == i,
                onClick = { onSelect(i) },
                shape = SegmentedButtonDefaults.itemShape(i, labels.size),
            ) { Text(label) }
        }
    }
}
