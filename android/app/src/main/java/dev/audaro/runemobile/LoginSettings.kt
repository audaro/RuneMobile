package dev.audaro.runemobile

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext

private const val KEY_AUTO_LOGIN = "auto_login"

/**
 * Auto-login: press Play Now when the game starts. Off by default, so the player logs in. Unlike the rest of Game
 * settings this one decides how the game starts, so it is read at boot and applies at the next launch.
 */
internal fun autoLoginOn(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_AUTO_LOGIN, false)

@Composable
internal fun GsLoginSection() {
    val ctx = LocalContext.current
    GsSectionHeader("Login")
    var on by remember { mutableStateOf(autoLoginOn(ctx)) }
    GsSwitchRow(
        "Auto-login",
        "Presses Play Now when the game starts, on your Default World plugin's world. Applies at the next launch.",
        on,
    ) {
        on = it
        prefs(ctx).edit().putBoolean(KEY_AUTO_LOGIN, it).apply()
    }
}
