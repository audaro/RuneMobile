package dev.audaro.runemobile

import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
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
import androidx.compose.ui.draw.clip
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

// ---- A5 Tier-2 view models (parsed from the curated bridge JSON; see QuestHelperBridge/WorldSwitcherBridge) -
data class QuestRow(
    val name: String,
    val difficulty: String,
    val type: String,
    val state: String,
)

data class ActiveQuestVm(
    val name: String,
    val steps: List<String>,
    val items: List<String>,
    val general: List<String>,
)

data class WorldRow(
    val id: Int,
    val players: Int,
    val location: Int,
    val members: Boolean,
    val pvp: Boolean,
    val highRisk: Boolean,
    val activity: String,
    val favourite: Boolean,
)

private const val T2 = "MainActivity"
private val PANEL_BG = Color(0xF2121212)

/**
 * A5 Tier-2 native Quest Helper. Reads QuestHelperBridge over the rl-bridge thread: the quest list (2.5s
 * cadence engine-side) + the active quest's steps/requirements (700ms). Tapping a quest calls startQuest;
 * the active card shows its current step + item/general requirements with a Stop button. setUiOpen(true/false)
 * brackets the screen so the bridge only ticks while it's open. (Falls back to Tier-1 upstream when
 * isAvailable()==false — this screen is only routed to when the Quest Helper plugin is present.)
 */
@Composable
fun QuestHelperScreen(onBack: () -> Unit) {
    var quests by remember { mutableStateOf<List<QuestRow>>(emptyList()) }
    var active by remember { mutableStateOf<ActiveQuestVm?>(null) }
    var available by remember { mutableStateOf(true) }
    var firstLoad by remember { mutableStateOf(true) }
    var logged by remember { mutableStateOf(false) }
    var stateFilter by remember { mutableStateOf("IN_PROGRESS") } // default to in-progress quests

    DisposableEffect(Unit) {
        JvmLauncher.onBridge { JvmLauncher.questSetUiOpen(true) }
        onDispose { JvmLauncher.onBridge { JvmLauncher.questSetUiOpen(false) } }
    }
    LaunchedEffect(Unit) {
        while (coroutineContext.isActive) {
            val (listJson, activeJson) =
                withContext(Dispatchers.IO) {
                    JvmLauncher.onBridge { JvmLauncher.questListJson() to JvmLauncher.questActiveJson() }.get()
                }
            available = JSONObject(listJson).optBoolean("available", false)
            quests = parseQuestList(listJson)
            active = parseActiveQuest(activeJson)
            firstLoad = false
            if (!logged && quests.isNotEmpty()) {
                Log.i(T2, "ANDROID_A5_TIER2_QUEST_UI_GREEN quests=${quests.size} active=${active != null}")
                logged = true
            }
            delay(700)
        }
    }

    Surface(color = PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ Back") }
                Text("Quest Helper", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            val act = active
            if (act != null) {
                ActiveQuestCard(act, onStop = { JvmLauncher.onBridgeTouch { JvmLauncher.questStop() } })
                HorizontalDivider(color = Color(0x22FFFFFF), modifier = Modifier.padding(vertical = 8.dp))
            }
            if (firstLoad) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else if (!available) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text("Quest Helper isn't available.", color = Color(0xFFBDBDBD))
                }
            } else {
                Row(Modifier.padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for (f in listOf("IN_PROGRESS", "NOT_STARTED", "FINISHED")) {
                        FilterChip(
                            selected = stateFilter == f,
                            onClick = { stateFilter = f },
                            label = { Text(f.replace('_', ' ').lowercase().replaceFirstChar { it.uppercase() }, fontSize = 12.sp) },
                        )
                    }
                }
                val shown = quests.filter { it.state == stateFilter }
                Text("${shown.size} quests", color = Color(0xFF9E9E9E), fontSize = 12.sp)
                LazyColumn(Modifier.fillMaxSize()) {
                    items(shown, key = { it.name }) { q ->
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clickable { JvmLauncher.onBridgeTouch { JvmLauncher.questStart(q.name) } }
                                .padding(vertical = 8.dp),
                        ) {
                            Text(q.name, color = Color.White)
                            Text("${prettify(q.difficulty)} · ${prettify(q.type)}", color = Color(0xFF9E9E9E), fontSize = 12.sp)
                        }
                        HorizontalDivider(color = Color(0x14FFFFFF))
                    }
                }
            }
        }
    }
}

@Composable
private fun ActiveQuestCard(
    act: ActiveQuestVm,
    onStop: () -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(act.name, color = Color(0xFFFFD54F), fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            TextButton(onClick = onStop) { Text("Stop", color = Color(0xFFEF9A9A)) }
        }
        for (line in act.steps) Text("• $line", color = Color.White, fontSize = 13.sp, modifier = Modifier.padding(top = 2.dp))
        if (act.items.isNotEmpty()) {
            Text("Items needed", color = Color(0xFF80CBC4), fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
            for (line in act.items) Text("  - $line", color = Color(0xFFCFD8DC), fontSize = 12.sp)
        }
        if (act.general.isNotEmpty()) {
            Text("Requirements", color = Color(0xFF80CBC4), fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
            for (line in act.general) Text("  - $line", color = Color(0xFFCFD8DC), fontSize = 12.sp)
        }
    }
}

/**
 * A5 Tier-2 native World Switcher. Reads WorldSwitcherBridge.getWorldListJson (1.5s cadence) into a filterable
 * world list; the current world is highlighted; tapping a row calls hop(id). setUiOpen brackets the screen
 * (it triggers the async WorldService refresh on open). World Switcher is built-in, so this is the live path.
 */
@Composable
fun WorldSwitcherScreen(onBack: () -> Unit) {
    var worlds by remember { mutableStateOf<List<WorldRow>>(emptyList()) }
    var current by remember { mutableStateOf(-1) }
    var firstLoad by remember { mutableStateOf(true) }
    var logged by remember { mutableStateOf(false) }
    var membersOnly by remember { mutableStateOf(false) }
    var f2pOnly by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        JvmLauncher.onBridge { JvmLauncher.worldSetUiOpen(true) }
        onDispose { JvmLauncher.onBridge { JvmLauncher.worldSetUiOpen(false) } }
    }
    LaunchedEffect(Unit) {
        while (coroutineContext.isActive) {
            val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.worldListJson() }.get() }
            val o = JSONObject(json)
            current = o.optInt("current", -1)
            worlds = parseWorldList(json)
            firstLoad = false
            if (!logged && worlds.isNotEmpty()) {
                Log.i(T2, "ANDROID_A5_TIER2_WORLD_UI_GREEN worlds=${worlds.size} current=$current")
                logged = true
            }
            delay(1500)
        }
    }

    Surface(color = PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack) { Text("‹ Back") }
                Text("World Switcher", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
                // SC-5 quick-hop: previous / next world in the WorldHopper filter (WorldHopperPlugin.hop(boolean)).
                // ENH-B06: the hop is a relog under the hood — arm the host "Hopping…" scrim before firing it.
                TextButton(onClick = {
                    MainActivity.armHopScrimHook?.invoke("Switching worlds…")
                    JvmLauncher.onBridgeTouch { JvmLauncher.worldHopDirection(true) }
                }) { Text("◀ Prev") }
                TextButton(onClick = {
                    MainActivity.armHopScrimHook?.invoke("Switching worlds…")
                    JvmLauncher.onBridgeTouch { JvmLauncher.worldHopDirection(false) }
                }) { Text("Next ▶") }
                if (current > 0) Text(" W$current", color = Color(0xFFFFD54F), fontSize = 14.sp)
            }
            Row(Modifier.padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                FilterChip(
                    selected = membersOnly,
                    onClick = {
                        membersOnly = !membersOnly
                        if (membersOnly) f2pOnly = false
                    },
                    label = { Text("Members", fontSize = 12.sp) },
                )
                FilterChip(
                    selected = f2pOnly,
                    onClick = {
                        f2pOnly = !f2pOnly
                        if (f2pOnly) membersOnly = false
                    },
                    label = { Text("Free", fontSize = 12.sp) },
                )
            }
            if (firstLoad) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else {
                val shown =
                    worlds
                        .filter { (!membersOnly || it.members) && (!f2pOnly || !it.members) }
                        .sortedWith(compareByDescending<WorldRow> { it.favourite }.thenBy { it.id }) // favourites float to the top
                LazyColumn(Modifier.fillMaxSize()) {
                    items(shown, key = { it.id }) { w ->
                        WorldRowItem(
                            w,
                            w.id == current,
                            // ENH-B06: cover the relog hop's ~8 s login flash with the host "Hopping…" scrim;
                            // the target world is known here, so name it on the card.
                            onHop = {
                                MainActivity.armHopScrimHook?.invoke("Hopping to world ${w.id}…")
                                JvmLauncher.onBridgeTouch { JvmLauncher.worldHop(w.id) }
                            },
                            onToggleFav = { JvmLauncher.onBridgeTouch { JvmLauncher.worldSetFavourite(w.id, !w.favourite) } },
                        )
                        HorizontalDivider(color = Color(0x14FFFFFF))
                    }
                }
            }
        }
    }
}

@Composable
private fun WorldRowItem(
    w: WorldRow,
    isCurrent: Boolean,
    onHop: () -> Unit,
    onToggleFav: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = !isCurrent) { onHop() }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // SC-5 favourite toggle (shared worldhopper.favorite_<id>); favourites float to the top of the list.
        Text(
            if (w.favourite) "★" else "☆",
            color = if (w.favourite) Color(0xFFFFC107) else Color(0xFF777777),
            fontSize = 18.sp,
            modifier = Modifier.clickable { onToggleFav() }.padding(end = 10.dp),
        )
        Box(
            Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(
                    if (isCurrent) {
                        Color(0xFF66BB6A)
                    } else if (w.members) {
                        Color(0xFFFFB300)
                    } else {
                        Color(0xFF64B5F6)
                    },
                ),
        )
        Column(Modifier.weight(1f).padding(start = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "World ${w.id}",
                    color = if (isCurrent) Color(0xFF66BB6A) else Color.White,
                    fontWeight = if (isCurrent) FontWeight.Bold else FontWeight.Normal,
                )
                if (w.pvp) Text("  PvP", color = Color(0xFFEF9A9A), fontSize = 11.sp)
                if (w.highRisk) Text("  High-risk", color = Color(0xFFEF5350), fontSize = 11.sp)
            }
            if (w.activity.isNotBlank() && w.activity != "-") Text(w.activity, color = Color(0xFF9E9E9E), fontSize = 12.sp)
        }
        Text("${w.players}", color = Color(0xFFBDBDBD), fontSize = 13.sp)
        Text(if (w.members) "  P2P" else "  F2P", color = if (w.members) Color(0xFFFFB300) else Color(0xFF64B5F6), fontSize = 11.sp)
    }
}

// ---- JSON parsers (schemas verified against the bridge source) ---------------------------------------
private fun prettify(enumName: String): String =
    enumName.split('_').joinToString(" ") { it.lowercase().replaceFirstChar { c -> c.uppercase() } }

private fun parseQuestList(json: String): List<QuestRow> =
    try {
        val o = JSONObject(json)
        val arr = o.optJSONArray("quests") ?: return emptyList()
        (0 until arr.length()).map { i ->
            val q = arr.getJSONObject(i)
            QuestRow(q.optString("name"), q.optString("difficulty"), q.optString("type"), q.optString("state"))
        }
    } catch (t: Throwable) {
        Log.e(T2, "ANDROID_A5_TIER2_QUEST_UI_RED list parse: $t")
        emptyList()
    }

private fun parseActiveQuest(json: String): ActiveQuestVm? =
    try {
        val o = JSONObject(json)
        if (!o.optBoolean("active", false)) {
            null
        } else {
            ActiveQuestVm(
                name = o.optString("name", "Quest"),
                steps = jsonStrings(o, "steps"),
                items = jsonStrings(o, "items"),
                general = jsonStrings(o, "general"),
            )
        }
    } catch (t: Throwable) {
        Log.e(T2, "ANDROID_A5_TIER2_QUEST_UI_RED active parse: $t")
        null
    }

private fun parseWorldList(json: String): List<WorldRow> =
    try {
        val o = JSONObject(json)
        val arr = o.optJSONArray("worlds") ?: return emptyList()
        (0 until arr.length()).map { i ->
            val w = arr.getJSONObject(i)
            WorldRow(
                id = w.optInt("id"),
                players = w.optInt("players"),
                location = w.optInt("location"),
                members = w.optBoolean("members"),
                pvp = w.optBoolean("pvp"),
                highRisk = w.optBoolean("highRisk"),
                activity = w.optString("activity", ""),
                favourite = w.optBoolean("favourite"),
            )
        }
    } catch (t: Throwable) {
        Log.e(T2, "ANDROID_A5_TIER2_WORLD_UI_RED parse: $t")
        emptyList()
    }

private fun jsonStrings(
    o: JSONObject,
    key: String,
): List<String> {
    val a = o.optJSONArray(key) ?: return emptyList()
    return (0 until a.length()).map { a.optString(it) }.filter { it.isNotBlank() }
}
