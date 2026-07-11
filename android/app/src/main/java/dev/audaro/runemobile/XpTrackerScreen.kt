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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
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

/** One tracked skill (or the overall row) from XpTrackerBridge.getXpJson. */
data class XpRow(
    val skill: String,
    val xpGained: Int,
    val xpHr: Int,
    val xpLeft: Int,
    val actions: Int,
    val actionsLeft: Int,
    val actionsHr: Int,
    val timeToLevelSec: Int,
    val startLevel: Int,
    val endLevel: Int,
    val progress: Double, // 0..1 toward the next level / goal
)

private const val XP_TAG = "MainActivity"
private val XP_PANEL_BG = Color(0xF2121212)

/**
 * Finding 14 — XP Tracker native reflow (read-only). Mirrors the Quest/World Tier-2 pattern over the shared
 * XpTrackerBridge: setUiOpen brackets the screen (the bridge only rebuilds the per-skill snapshot while shown),
 * and a ~1.5 s poll refreshes the live XP/hr + time-to-level. Replaces the OOM-prone rendered-Swing-image
 * fallback for one of the highest-traffic panels.
 */
@Composable
fun XpTrackerScreen(onBack: () -> Unit) {
    var skills by remember { mutableStateOf<List<XpRow>>(emptyList()) }
    var overall by remember { mutableStateOf<XpRow?>(null) }
    var firstLoad by remember { mutableStateOf(true) }
    var logged by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        JvmLauncher.onBridge { JvmLauncher.xpSetUiOpen(true) }
        onDispose { JvmLauncher.onBridge { JvmLauncher.xpSetUiOpen(false) } }
    }
    LaunchedEffect(Unit) {
        while (coroutineContext.isActive) {
            val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.xpJson() }.get() }
            val (sk, ov) = parseXp(json)
            skills = sk
            overall = ov
            firstLoad = false
            if (!logged) {
                Log.i(XP_TAG, "ANDROID_A5_TIER2_XP_UI_GREEN skills=${sk.size}")
                logged = true
            }
            delay(1500)
        }
    }

    Surface(color = XP_PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ Back") }
                Text("XP Tracker", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
                overall?.let { if (it.xpHr > 0) Text("${fmt(it.xpHr)}/hr", color = Color(0xFFFFD54F), fontSize = 13.sp) }
            }
            when {
                firstLoad -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                }

                skills.isEmpty() && overall == null -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            "No XP gained this session.\nTrain a skill to start tracking.",
                            color = Color(0xFF9E9E9E),
                            fontSize = 14.sp,
                        )
                    }
                }

                else -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        overall?.let { ov ->
                            item("overall") {
                                XpRowItem(ov, isOverall = true)
                                HorizontalDivider(color = Color(0x22FFFFFF))
                            }
                        }
                        items(skills, key = { it.skill }) { s ->
                            XpRowItem(s, isOverall = false)
                            HorizontalDivider(color = Color(0x14FFFFFF))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun XpRowItem(
    s: XpRow,
    isOverall: Boolean,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (isOverall) "Overall" else prettifyXp(s.skill),
                color = if (isOverall) Color(0xFFFFD54F) else Color.White,
                fontWeight = if (isOverall) FontWeight.Bold else FontWeight.Normal,
                modifier = Modifier.weight(1f),
            )
            if (!isOverall && s.endLevel > 0) {
                Text("Lvl ${s.startLevel}→${s.endLevel}", color = Color(0xFFB0BEC5), fontSize = 12.sp)
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("+${fmt(s.xpGained)} xp", color = Color(0xFF81C784), fontSize = 12.sp)
            Text("${fmt(s.xpHr)}/hr", color = Color(0xFFBDBDBD), fontSize = 12.sp)
            if (s.timeToLevelSec > 0) Text(fmtTime(s.timeToLevelSec), color = Color(0xFFBDBDBD), fontSize = 12.sp)
        }
        if (!isOverall) {
            Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                if (s.actionsLeft > 0) Text("${fmt(s.actionsLeft)} actions left", color = Color(0xFF9E9E9E), fontSize = 11.sp)
                if (s.xpLeft > 0) Text("${fmt(s.xpLeft)} xp to go", color = Color(0xFF9E9E9E), fontSize = 11.sp)
            }
            if (s.progress in 0.0..1.0) {
                LinearProgressIndicator(
                    progress = { s.progress.toFloat() },
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                    color = Color(0xFF66BB6A),
                    trackColor = Color(0x33FFFFFF),
                )
            }
        }
    }
}

// ---- formatting + parsing ----------------------------------------------------------------------------
private fun fmt(n: Int): String =
    if (n < 1000) {
        n.toString()
    } else {
        "%,d".format(n)
    }

private fun fmtTime(sec: Int): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return when {
        h > 0 -> "${h}h ${m}m"
        m > 0 -> "${m}m ${s}s"
        else -> "${s}s"
    }
}

private fun prettifyXp(enumName: String): String =
    enumName.split('_').joinToString(" ") { it.lowercase().replaceFirstChar { c -> c.uppercase() } }

private fun parseXp(json: String): Pair<List<XpRow>, XpRow?> =
    try {
        val o = JSONObject(json)
        if (!o.optBoolean("available", false)) {
            emptyList<XpRow>() to null
        } else {
            val arr = o.optJSONArray("skills")
            val skills =
                if (arr == null) {
                    emptyList()
                } else {
                    (0 until arr.length())
                        .map { xpRowOf(arr.getJSONObject(it)) }
                        .sortedByDescending { it.xpGained }
                }
            val overall = o.optJSONObject("overall")?.let { xpRowOf(it, "Overall") }
            skills to overall
        }
    } catch (t: Throwable) {
        Log.e(XP_TAG, "ANDROID_A5_TIER2_XP_UI_RED parse: $t")
        emptyList<XpRow>() to null
    }

private fun xpRowOf(
    j: JSONObject,
    skillFallback: String = "",
): XpRow =
    XpRow(
        skill = j.optString("skill", skillFallback),
        xpGained = j.optInt("xpGained"),
        xpHr = j.optInt("xpHr"),
        xpLeft = j.optInt("xpLeft"),
        actions = j.optInt("actions"),
        actionsLeft = j.optInt("actionsLeft"),
        actionsHr = j.optInt("actionsHr"),
        timeToLevelSec = j.optInt("timeToLevelSec"),
        startLevel = j.optInt("startLevel"),
        endLevel = j.optInt("endLevel"),
        progress = j.optDouble("progress", 0.0),
    )
