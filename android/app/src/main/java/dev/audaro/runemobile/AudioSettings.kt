package dev.audaro.runemobile

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext

private const val KEY_GAME_SOUND = "game_sound"

/** The master switch for game audio. The boot reads it, so the engine's first line is already muted if it's off. */
internal fun gameSoundOn(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_GAME_SOUND, true)

@Composable
internal fun GsAudioSection() {
    val ctx = LocalContext.current
    GsSectionHeader("Sound")
    var on by remember { mutableStateOf(gameSoundOn(ctx)) }
    GsSwitchRow(
        "Game sound",
        "Music, sound effects and area sounds. Their volumes are in the game's own settings.",
        on,
    ) {
        on = it
        prefs(ctx).edit().putBoolean(KEY_GAME_SOUND, it).apply()
        JvmLauncher.onBridge { JvmLauncher.nativeSetGameAudioMuted(!it) }
    }
}
