package dev.audaro.runemobile

import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import kotlin.coroutines.coroutineContext

/** One live infobox + its menu options, from InfoBoxBridge.getInfoBoxesJson. */
data class InfoBoxRow(
    val index: Int,
    val name: String,
    val text: String,
    val tooltip: String,
    val menu: List<String>,
)

private const val IB_TAG = "MainActivity"
private val IB_PANEL_BG = Color(0xF2121212)

/**
 * Finding 22 — infobox menu (Detach / Flip / Delete / plugin entries). Desktop surfaces these via a hover-menu
 * on the infobox; touch has no hover, and the InfoBoxBridge snapshot carries no bounds (so a long-press can't
 * hit-test one) — the bridge is index-based, designed for a list UI. This Compose screen lists every live
 * infobox with a button per menu option, firing invokeInfoBoxMenu (which posts the same InfoBoxMenuClicked the
 * desktop right-click does). Reached from the panel list, gated on InfoBoxBridge.isAvailable.
 */
@Composable
fun InfoBoxScreen(onBack: () -> Unit) {
    var boxes by remember { mutableStateOf<List<InfoBoxRow>>(emptyList()) }
    var firstLoad by remember { mutableStateOf(true) }
    var logged by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        JvmLauncher.onBridge { JvmLauncher.infoBoxSetUiOpen(true) }
        onDispose { JvmLauncher.onBridge { JvmLauncher.infoBoxSetUiOpen(false) } }
    }
    LaunchedEffect(Unit) {
        while (coroutineContext.isActive) {
            val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.infoBoxesJson() }.get() }
            boxes = parseInfoBoxes(json)
            firstLoad = false
            if (!logged) {
                Log.i(IB_TAG, "ANDROID_INFOBOX_UI_GREEN boxes=${boxes.size}")
                logged = true
            }
            delay(1000)
        }
    }

    Surface(color = IB_PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ Back") }
                Text("Infoboxes", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            Text(
                "Detach, flip or delete an infobox.",
                color = Color(0xFF9E9E9E),
                fontSize = 12.sp,
                modifier = Modifier.padding(bottom = 4.dp),
            )
            when {
                firstLoad -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                }

                boxes.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No infoboxes on screen.", color = Color(0xFF9E9E9E), fontSize = 14.sp)
                    }
                }

                else -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(boxes, key = { it.index.toString() + it.name }) { b ->
                            InfoBoxRowItem(b, onInvoke = { opt ->
                                JvmLauncher.onBridgeTouch {
                                    JvmLauncher.infoBoxInvoke(b.index, opt)
                                    JvmLauncher.flushConfig()
                                }
                            })
                            HorizontalDivider(color = Color(0x22FFFFFF))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun InfoBoxRowItem(
    b: InfoBoxRow,
    onInvoke: (String) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val label = b.tooltip.ifBlank { b.name }.ifBlank { "Infobox ${b.index}" }
            Text(label, color = Color.White, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
            if (b.text.isNotBlank()) Text(b.text, color = Color(0xFFFFD54F), fontSize = 13.sp)
        }
        if (b.menu.isEmpty()) {
            Text("no menu actions", color = Color(0xFF9A9A9A), fontSize = 12.sp, modifier = Modifier.padding(top = 2.dp))
        } else {
            Row(Modifier.fillMaxWidth().padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                b.menu.forEach { opt ->
                    FilledTonalButton(
                        onClick = { onInvoke(opt) },
                        contentPadding =
                            androidx.compose.foundation.layout
                                .PaddingValues(horizontal = 12.dp, vertical = 0.dp),
                    ) { Text(opt, fontSize = 12.sp) }
                }
            }
        }
    }
}

private fun parseInfoBoxes(json: String): List<InfoBoxRow> =
    try {
        val o = JSONObject(json)
        if (!o.optBoolean("available", false)) {
            emptyList()
        } else {
            val arr = o.optJSONArray("infoboxes") ?: return emptyList()
            (0 until arr.length()).map { i ->
                val b = arr.getJSONObject(i)
                val m = b.optJSONArray("menu")
                InfoBoxRow(
                    index = b.optInt("index"),
                    name = b.optString("name", ""),
                    text = b.optString("text", ""),
                    tooltip = b.optString("tooltip", ""),
                    menu = if (m == null) emptyList() else (0 until m.length()).map { m.optString(it) }.filter { it.isNotBlank() },
                )
            }
        }
    } catch (t: Throwable) {
        Log.e(IB_TAG, "ANDROID_INFOBOX_UI_RED parse: $t")
        emptyList()
    }
