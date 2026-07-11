package dev.audaro.runemobile

import android.content.Context
import android.util.Log
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import kotlin.coroutines.coroutineContext

private const val PR_TAG = "MainActivity"
private val PR_PANEL_BG = Color(0xF2121212)

// Shared compact value formatter (123 / 12.3K / 4.5M) for GE prices + loot values.
private fun gp(v: Long): String =
    when {
        v >= 10_000_000 -> "${v / 1_000_000}M"
        v >= 1_000_000 -> "%.1fM".format(v / 1_000_000.0)
        v >= 100_000 -> "${v / 1000}K"
        v >= 1000 -> "%.1fK".format(v / 1000.0)
        else -> v.toString()
    }

// ====================================================================================================
// Finding 14 — Loot Tracker native reflow (read-only). getLootJson = {available, sources:[{name,subTitle,
// type,kills,totalValue,items:[{id,name,qty,ge,ha}]}]}.
// ====================================================================================================
data class LootItem(
    val name: String,
    val qty: Int,
    val ge: Long,
)

data class LootSource(
    val name: String,
    val subTitle: String,
    val kills: Int,
    val totalValue: Long,
    val items: List<LootItem>,
)

@Composable
fun LootTrackerScreen(onBack: () -> Unit) {
    var sources by remember { mutableStateOf<List<LootSource>>(emptyList()) }
    var firstLoad by remember { mutableStateOf(true) }
    var logged by remember { mutableStateOf(false) }
    var showResetConfirm by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        JvmLauncher.onBridge { JvmLauncher.lootSetUiOpen(true) }
        onDispose { JvmLauncher.onBridge { JvmLauncher.lootSetUiOpen(false) } }
    }
    LaunchedEffect(Unit) {
        while (coroutineContext.isActive) {
            val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.lootJson() }.get() }
            sources = parseLoot(json)
            firstLoad = false
            if (!logged) {
                Log.i(PR_TAG, "ANDROID_A5_TIER2_LOOT_UI_GREEN sources=${sources.size}")
                logged = true
            }
            delay(1500)
        }
    }

    Surface(color = PR_PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) { Text("‹ Back") }
                Text("Loot Tracker", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
                if (sources.isNotEmpty()) {
                    TextButton(onClick = { showResetConfirm = true }) {
                        Text("Reset All", color = Color(0xFFEF9A9A), fontSize = 13.sp)
                    }
                }
            }
            when {
                firstLoad -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                }

                sources.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No loot tracked this session.", color = Color(0xFF9E9E9E), fontSize = 14.sp)
                    }
                }

                else -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(sources, key = { it.name + it.subTitle }) { s ->
                            LootSourceItem(s)
                            HorizontalDivider(color = Color(0x22FFFFFF))
                        }
                    }
                }
            }
        }
    }

    if (showResetConfirm) {
        AlertDialog(
            onDismissRequest = { showResetConfirm = false },
            title = { Text("Reset loot tracker?") },
            text = { Text("Clears all tracked loot for this session. This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    showResetConfirm = false
                    // Off the UI thread via the single-threaded bridge executor; the next poll (FIFO after
                    // this write) confirms the cleared state — clear optimistically for immediate feedback.
                    JvmLauncher.onBridgeTouch { JvmLauncher.lootResetAll() }
                    sources = emptyList()
                    Log.i(PR_TAG, "loot-reset: Reset All confirmed")
                }) { Text("Reset All", color = Color(0xFFEF9A9A)) }
            },
            dismissButton = {
                TextButton(onClick = { showResetConfirm = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun LootSourceItem(s: LootSource) {
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(s.name, color = Color.White, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
            if (s.kills > 0) Text("×${s.kills}", color = Color(0xFFB0BEC5), fontSize = 12.sp)
            Text("  ${gp(s.totalValue)} gp", color = Color(0xFFFFD54F), fontSize = 12.sp)
        }
        s.items.forEach {
            Row(Modifier.fillMaxWidth().padding(start = 6.dp, top = 2.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    if (it.qty > 1) "${it.name} ×${it.qty}" else it.name,
                    color = Color(0xFFCFD8DC),
                    fontSize = 12.sp,
                    modifier = Modifier.weight(1f),
                )
                if (it.ge > 0) Text("${gp(it.ge)} gp", color = Color(0xFF81C784), fontSize = 12.sp)
            }
        }
    }
}

private fun parseLoot(json: String): List<LootSource> =
    try {
        val o = JSONObject(json)
        if (!o.optBoolean("available", false)) {
            emptyList()
        } else {
            val arr = o.optJSONArray("sources") ?: return emptyList()
            (0 until arr.length()).map { i ->
                val s = arr.getJSONObject(i)
                val items = s.optJSONArray("items")
                LootSource(
                    name = s.optString("name", "?"),
                    subTitle = s.optString("subTitle", ""),
                    kills = s.optInt("kills"),
                    totalValue = s.optLong("totalValue"),
                    items =
                        if (items == null) {
                            emptyList()
                        } else {
                            (0 until items.length()).map { j ->
                                val it = items.getJSONObject(j)
                                LootItem(it.optString("name", "?"), it.optInt("qty"), it.optLong("ge"))
                            }
                        },
                )
            }
        }
    } catch (t: Throwable) {
        Log.e(PR_TAG, "ANDROID_A5_TIER2_LOOT_UI_RED parse: $t")
        emptyList()
    }

// ====================================================================================================
// Finding 14 — Grand Exchange native reflow (read-only). getGeJson = {available, offers:[{slot,state,itemId,
// name,qty,total,price,spent,progress}], history:[{buy,itemId,qty,price,time}]}.
// ====================================================================================================
data class GeOffer(
    val slot: Int,
    val state: String,
    val name: String,
    val qty: Int,
    val total: Int,
    val price: Int,
    val progress: Double,
)

// AP-0: saved trade history the bridge already emits (history:[{buy,itemId,name,qty,price,time}]).
data class GeTrade(
    val buy: Boolean,
    val name: String,
    val qty: Int,
    val price: Int,
)

@Composable
fun GrandExchangeScreen(onBack: () -> Unit) {
    var offers by remember { mutableStateOf<List<GeOffer>>(emptyList()) }
    var history by remember { mutableStateOf<List<GeTrade>>(emptyList()) }
    var tab by remember { mutableStateOf(0) } // 0 = live offers, 1 = trade history
    var firstLoad by remember { mutableStateOf(true) }
    var logged by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        JvmLauncher.onBridge { JvmLauncher.geSetUiOpen(true) }
        onDispose { JvmLauncher.onBridge { JvmLauncher.geSetUiOpen(false) } }
    }
    LaunchedEffect(Unit) {
        while (coroutineContext.isActive) {
            val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.geJson() }.get() }
            offers = parseGe(json)
            history = parseGeHistory(json)
            firstLoad = false
            if (!logged) {
                Log.i(PR_TAG, "ANDROID_A5_TIER2_GE_UI_GREEN offers=${offers.size} history=${history.size}")
                logged = true
            }
            delay(1500)
        }
    }

    Surface(color = PR_PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) { Text("‹ Back") }
                Text("Grand Exchange", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
                if (tab == 0 && offers.isNotEmpty()) Text("${offers.size}/8", color = Color(0xFFFFD54F), fontSize = 13.sp)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                GeTab("Offers", tab == 0) { tab = 0 }
                GeTab("History", tab == 1) { tab = 1 }
            }
            when {
                firstLoad -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                }

                tab == 0 && offers.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No active Grand Exchange offers.", color = Color(0xFF9E9E9E), fontSize = 14.sp)
                    }
                }

                tab == 1 && history.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No saved trade history.", color = Color(0xFF9E9E9E), fontSize = 14.sp)
                    }
                }

                tab == 0 -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(offers, key = { it.slot }) { ofr ->
                            GeOfferItem(ofr)
                            HorizontalDivider(color = Color(0x22FFFFFF))
                        }
                    }
                }

                else -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(history.size) { i ->
                            GeTradeItem(history[i])
                            HorizontalDivider(color = Color(0x22FFFFFF))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GeTab(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    TextButton(onClick = onClick) {
        Text(
            label,
            color = if (selected) Color(0xFFFFD54F) else Color(0xFF9E9E9E),
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
            fontSize = 14.sp,
        )
    }
}

@Composable
private fun GeTradeItem(t: GeTrade) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(
            if (t.buy) "Bought" else "Sold",
            color = if (t.buy) Color(0xFF64B5F6) else Color(0xFFFFB74D),
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
        )
        Text("  ${t.name}", color = Color.White, fontSize = 13.sp, modifier = Modifier.weight(1f))
        Text("×${t.qty}", color = Color(0xFFBDBDBD), fontSize = 12.sp)
        Text("  @ ${gp(t.price.toLong())} gp", color = Color(0xFF81C784), fontSize = 12.sp)
    }
}

@Composable
private fun GeOfferItem(o: GeOffer) {
    val buying = o.state.contains("BUY", ignoreCase = true) || o.state == "BUYING" || o.state == "BOUGHT"
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (buying) "Buy" else "Sell",
                color = if (buying) Color(0xFF64B5F6) else Color(0xFFFFB74D),
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
            )
            Text("  ${o.name}", color = Color.White, modifier = Modifier.weight(1f))
            Text(prettyState(o.state), color = Color(0xFF9E9E9E), fontSize = 11.sp)
        }
        Row(Modifier.fillMaxWidth().padding(top = 2.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("${o.qty}/${o.total}", color = Color(0xFFBDBDBD), fontSize = 12.sp)
            Text("@ ${gp(o.price.toLong())} gp", color = Color(0xFF81C784), fontSize = 12.sp)
        }
        if (o.progress in 0.0..1.0) {
            LinearProgressIndicator(
                progress = { o.progress.toFloat() },
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                color = if (buying) Color(0xFF42A5F5) else Color(0xFFFFA726),
                trackColor = Color(0x33FFFFFF),
            )
        }
    }
}

private fun prettyState(s: String): String = s.split('_').joinToString(" ") { it.lowercase().replaceFirstChar { c -> c.uppercase() } }

private fun parseGe(json: String): List<GeOffer> =
    try {
        val o = JSONObject(json)
        if (!o.optBoolean("available", false)) {
            emptyList()
        } else {
            val arr = o.optJSONArray("offers") ?: return emptyList()
            (0 until arr.length()).map { i ->
                val g = arr.getJSONObject(i)
                GeOffer(
                    slot = g.optInt("slot"),
                    state = g.optString("state", ""),
                    name = g.optString("name", "?"),
                    qty = g.optInt("qty"),
                    total = g.optInt("total"),
                    price = g.optInt("price"),
                    progress = g.optDouble("progress", 0.0),
                )
            }
        }
    } catch (t: Throwable) {
        Log.e(PR_TAG, "ANDROID_A5_TIER2_GE_UI_RED parse: $t")
        emptyList()
    }

private fun parseGeHistory(json: String): List<GeTrade> =
    try {
        val o = JSONObject(json)
        val arr = o.optJSONArray("history") ?: return emptyList()
        (0 until arr.length())
            .map { i ->
                val h = arr.getJSONObject(i)
                GeTrade(
                    buy = h.optBoolean("buy"),
                    name = h.optString("name", "").ifEmpty { "Item ${h.optInt("itemId")}" },
                    qty = h.optInt("qty"),
                    price = h.optInt("price"),
                )
            }.asReversed() // storage keeps newest last; show newest first
    } catch (t: Throwable) {
        emptyList()
    }

// ====================================================================================================
// Track B #6 — Config Profiles native screen (list + switch). getProfilesJson =
// {available, profiles:[{id,name,active,sync,internal}]}. `internal` engine profiles ($rsprofile) are
// hidden like the desktop panel; tapping a non-active row calls switchProfile(id) (async — the poll
// re-reads and the row flips to active when the background switch lands).
// ====================================================================================================
data class ConfigProfile(
    val id: Long,
    val name: String,
    val active: Boolean,
    val sync: Boolean,
)

@Composable
fun ConfigProfilesScreen(onBack: () -> Unit) {
    var profiles by remember { mutableStateOf<List<ConfigProfile>>(emptyList()) }
    var firstLoad by remember { mutableStateOf(true) }
    var logged by remember { mutableStateOf(false) }
    var switching by remember { mutableStateOf<Long?>(null) } // id mid-switch (async); cleared when it goes active

    LaunchedEffect(Unit) {
        while (coroutineContext.isActive) {
            val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.profilesJson() }.get() }
            profiles = parseProfiles(json)
            firstLoad = false
            // The switch runs on the engine's background executor; once the target reads back active, clear the pip.
            if (switching != null && profiles.any { it.id == switching && it.active }) switching = null
            if (!logged) {
                Log.i(PR_TAG, "ANDROID_TRACKB_PROFILES_UI_GREEN profiles=${profiles.size}")
                logged = true
            }
            delay(1200)
        }
    }

    Surface(color = PR_PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) { Text("‹ Back") }
                Text("Config Profiles", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            when {
                firstLoad -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                }

                profiles.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("No config profiles available.", color = Color(0xFF9E9E9E), fontSize = 14.sp)
                    }
                }

                else -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(profiles, key = { it.id }) { p ->
                            ProfileRow(
                                p,
                                busy = switching == p.id,
                                enabled = !p.active && switching == null,
                                onSelect = {
                                    if (!p.active && switching == null) {
                                        switching = p.id
                                        JvmLauncher.onBridgeTouch { JvmLauncher.switchProfile(p.id) }
                                        Log.i(PR_TAG, "profile-switch: -> ${p.name} (${p.id})")
                                    }
                                },
                            )
                            HorizontalDivider(color = Color(0x22FFFFFF))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ProfileRow(
    p: ConfigProfile,
    busy: Boolean,
    enabled: Boolean,
    onSelect: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled) { onSelect() }
            .padding(vertical = 12.dp)
            .semantics {
                contentDescription = "Profile ${p.name}" + if (p.sync) ", synced" else ""
                stateDescription = if (p.active) "Active" else "Tap to switch"
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (p.active) "●" else "○",
            color = if (p.active) Color(0xFF80CBC4) else Color(0xFF616161),
            modifier = Modifier.padding(end = 10.dp),
        )
        Text(
            p.name,
            color = Color.White,
            modifier = Modifier.weight(1f),
            fontWeight = if (p.active) FontWeight.Bold else FontWeight.Normal,
        )
        if (p.sync) Text("sync", color = Color(0xFF80CBC4), fontSize = 11.sp, modifier = Modifier.padding(end = 8.dp))
        when {
            busy -> Text("switching…", color = Color(0xFFFFD54F), fontSize = 11.sp)
            p.active -> Text("active", color = Color(0xFF9E9E9E), fontSize = 11.sp)
        }
    }
}

private fun parseProfiles(json: String): List<ConfigProfile> =
    try {
        val o = JSONObject(json)
        if (!o.optBoolean("available", false)) {
            emptyList()
        } else {
            val arr = o.optJSONArray("profiles") ?: return emptyList()
            // Hide engine-internal profiles ($rsprofile etc.) exactly like the desktop config panel does.
            (0 until arr.length()).mapNotNull { i ->
                val p = arr.getJSONObject(i)
                if (p.optBoolean("internal", false)) {
                    null
                } else {
                    ConfigProfile(p.optLong("id"), p.optString("name", "?"), p.optBoolean("active"), p.optBoolean("sync"))
                }
            }
        }
    } catch (t: Throwable) {
        Log.e(PR_TAG, "ANDROID_TRACKB_PROFILES_UI_RED parse: $t")
        emptyList()
    }

// ====================================================================================================
// Native Notes panel — the single editable note string on MobileUiBridge (config group "notes"/key "notesData").
// Seeded once from notesGet(); edits persist via notesSet() on a debounce (iOS persists on a 0.7s timer too) plus
// a flush on leave. Mirrors the iOS NotesViewController. Replaces the non-editable rendered Swing screenshot.
// ====================================================================================================
@Composable
fun NotesScreen(
    onBack: () -> Unit,
    onPanelTextActive: (Boolean) -> Unit,
) {
    var text by remember { mutableStateOf<String?>(null) } // null until the initial load returns
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val initial = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.notesGet() }.get() }
        text = initial
        loaded = true
        Log.i(PR_TAG, "ANDROID_NOTES_UI_GREEN len=${initial.length}")
    }

    // Debounced persist: write 700ms after the latest keystroke so we don't hit the config lane on every char.
    val current = text
    LaunchedEffect(current) {
        if (!loaded || current == null) return@LaunchedEffect
        delay(700)
        JvmLauncher.onBridgeTouch { JvmLauncher.notesSet(current) }
    }

    // Flush on leave (an edit-then-back can be shorter than the debounce) + release the IME-suppression latch so
    // the in-game keyboard isn't blocked after the field is disposed without an onFocusChanged(false).
    DisposableEffect(Unit) {
        onDispose {
            val t = text
            if (loaded && t != null) JvmLauncher.onBridgeTouch { JvmLauncher.notesSet(t) }
            onPanelTextActive(false)
        }
    }

    Surface(color = PR_PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) { Text("‹ Back") }
                Text("Notes", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            if (!loaded) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else {
                OutlinedTextField(
                    value = text ?: "",
                    onValueChange = { text = it },
                    // Tell the host the IME is owned by this field while focused — otherwise the per-frame input poll
                    // hides the keyboard every frame (same path ConfigScreen / the plugin search field use).
                    modifier =
                        Modifier
                            .fillMaxSize()
                            .padding(top = 8.dp)
                            .onFocusChanged { onPanelTextActive(it.hasFocus) },
                )
            }
        }
    }
}

// ====================================================================================================
// Track B (finding M-set / Time Tracking) — native Time Tracking reflow (read-only). getTimeTrackingJson =
// {available, farming:[{tab,name,state,readyTime,remainingSec}], contract:{active,...},
// birdhouses:[{name,state,remainingSec}], timers:[{name,active,remainingSec,loop}], stopwatches:[{name,active,
// elapsedSec}]}. Grouped into labelled sections; second-resolution countdowns refresh ~1s with the snapshot.
// ====================================================================================================
data class TtItem(
    val name: String,
    val state: String,
    val remainingSec: Long,
    val ready: Boolean,
    val countUp: Boolean,
)

data class TtSection(
    val title: String,
    val items: List<TtItem>,
)

@Composable
fun TimeTrackingScreen(onBack: () -> Unit) {
    var sections by remember { mutableStateOf<List<TtSection>>(emptyList()) }
    var firstLoad by remember { mutableStateOf(true) }
    var logged by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        JvmLauncher.onBridge { JvmLauncher.timeTrackingSetUiOpen(true) }
        onDispose { JvmLauncher.onBridge { JvmLauncher.timeTrackingSetUiOpen(false) } }
    }
    LaunchedEffect(Unit) {
        while (coroutineContext.isActive) {
            val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.timeTrackingJson() }.get() }
            sections = parseTimeTracking(json)
            firstLoad = false
            if (!logged) {
                Log.i(PR_TAG, "ANDROID_TRACKB_TIME_UI_GREEN sections=${sections.size}")
                logged = true
            }
            delay(1000) // countdowns are second-resolution; the bridge rebuilds on the same cadence
        }
    }

    Surface(color = PR_PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) { Text("‹ Back") }
                Text("Time Tracking", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            when {
                firstLoad -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                }

                sections.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text("Nothing being tracked.", color = Color(0xFF9E9E9E), fontSize = 14.sp)
                    }
                }

                else -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        sections.forEach { sec ->
                            item(key = "h-${sec.title}") {
                                Text(
                                    sec.title,
                                    color = Color(0xFF80CBC4),
                                    fontSize = 12.sp,
                                    modifier = Modifier.padding(top = 12.dp, bottom = 2.dp),
                                )
                            }
                            items(sec.items, key = { sec.title + it.name }) {
                                TtRow(it)
                                HorizontalDivider(color = Color(0x18FFFFFF))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TtRow(it: TtItem) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(it.name, color = Color.White, modifier = Modifier.weight(1f), fontSize = 14.sp)
        val right: String
        val color: Color
        when {
            it.countUp -> {
                right = ttDur(it.remainingSec)
                color = Color(0xFFB0BEC5)
            }

            // stopwatch elapsed
            it.remainingSec > 0 -> {
                right = ttDur(it.remainingSec)
                color = Color(0xFFFFD54F)
            }

            // counting down
            it.ready -> {
                right = "Ready"
                color = Color(0xFF81C784)
            }

            else -> {
                right = ttState(it.state)
                color = ttStateColor(it.state)
            }
        }
        Text(right, color = color, fontSize = 13.sp)
    }
}

/** Compact h/m/s formatter for the countdowns. */
private fun ttDur(sec: Long): String {
    if (sec <= 0) return "0s"
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return when {
        h > 0 -> "${h}h ${m}m"
        m > 0 -> "${m}m ${s}s"
        else -> "${s}s"
    }
}

/** ENUM_NAME -> "Enum name". */
private fun ttState(s: String): String = if (s.isEmpty()) "—" else s.lowercase().replace('_', ' ').replaceFirstChar { it.uppercase() }

private fun ttStateColor(state: String): Color =
    when (state.uppercase()) {
        "HARVESTABLE", "BUILT", "OCCUPIED", "DONE", "FINISHED" -> Color(0xFF81C784)

        // ready/green
        "DISEASED", "DEAD", "STUNTED" -> Color(0xFFE57373)

        // problem/red
        else -> Color(0xFF9E9E9E) // empty/growing/idle/grey
    }

private fun parseTimeTracking(json: String): List<TtSection> =
    try {
        val o = JSONObject(json)
        if (!o.optBoolean("available", false)) {
            emptyList()
        } else {
            buildList {
                // A patch is "ready" when it has no remaining countdown and its state reads as harvestable/grown.
                fun arr(
                    key: String,
                    countUp: Boolean,
                ): List<TtItem> {
                    val a = o.optJSONArray(key) ?: return emptyList()
                    return (0 until a.length()).map { i ->
                        val e = a.getJSONObject(i)
                        val st = e.optString("state", "")
                        val rem = e.optLong("remainingSec")
                        TtItem(
                            name = e.optString("name", "?"),
                            state = st,
                            remainingSec = if (countUp) e.optLong("elapsedSec") else rem,
                            ready = !countUp && rem <= 0L && ttStateColor(st) == Color(0xFF81C784),
                            countUp = countUp,
                        )
                    }
                }
                arr("farming", false).takeIf { it.isNotEmpty() }?.let { add(TtSection("Farming patches", it)) }
                o.optJSONObject("contract")?.takeIf { it.optBoolean("active", false) }?.let { c ->
                    val rem = c.optLong("remainingSec")
                    val st = c.optString("state", "")
                    add(
                        TtSection(
                            "Farming contract",
                            listOf(
                                TtItem(
                                    name = c.optString("name", "Contract"),
                                    state = st,
                                    remainingSec = rem,
                                    ready = rem <= 0L && ttStateColor(st) == Color(0xFF81C784),
                                    countUp = false,
                                ),
                            ),
                        ),
                    )
                }
                arr("birdhouses", false).takeIf { it.isNotEmpty() }?.let { add(TtSection("Bird houses", it)) }
                arr("timers", false).takeIf { it.isNotEmpty() }?.let { add(TtSection("Timers", it)) }
                arr("stopwatches", true).takeIf { it.isNotEmpty() }?.let { add(TtSection("Stopwatches", it)) }
            }
        }
    } catch (t: Throwable) {
        Log.e(PR_TAG, "ANDROID_TRACKB_TIME_UI_RED parse: $t")
        emptyList()
    }

// ====================================================================================================
// Track B (#1) — user-defined hotkey buttons. boundKeybindsJson lists EVERY bound plugin keybind
// [{group,key,label,keyCode,mods,bind}]; the user toggles which appear as on-screen HUD buttons. The active
// set is persisted in MainActivity.PREFS_HOTKEYS ("groupkeylabel" entries) and the HUD strip rebuilds
// reactively (a SharedPreferences listener). A button fires fireHotkey(group,key) off the live binding.
// ====================================================================================================
data class BoundKeybind(
    val group: String,
    val key: String,
    val label: String,
    val bind: String,
)

private fun loadActiveHotkeys(ctx: Context): Set<String> =
    ctx
        .getSharedPreferences(MainActivity.PREFS_HOTKEYS, Context.MODE_PRIVATE)
        .getStringSet(MainActivity.PREF_HOTKEYS_ACTIVE, emptySet()) ?: emptySet()

private fun saveActiveHotkeys(
    ctx: Context,
    set: Set<String>,
) {
    ctx
        .getSharedPreferences(MainActivity.PREFS_HOTKEYS, Context.MODE_PRIVATE)
        .edit()
        .putStringSet(MainActivity.PREF_HOTKEYS_ACTIVE, set)
        .apply()
}

@Composable
fun HotkeysScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    var binds by remember { mutableStateOf<List<BoundKeybind>>(emptyList()) }
    var firstLoad by remember { mutableStateOf(true) }
    var active by remember { mutableStateOf(loadActiveHotkeys(ctx)) }
    var logged by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.boundKeybindsJson() }.get() }
        binds = parseBoundKeybinds(json)
        firstLoad = false
        if (!logged) {
            Log.i(PR_TAG, "ANDROID_TRACKB_HOTKEYS_UI_GREEN binds=${binds.size} active=${active.size}")
            logged = true
        }
    }

    Surface(color = PR_PANEL_BG, modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) { Text("‹ Back") }
                Text("Hotkey Buttons", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            Text(
                "Add a button to the HUD for any keybind you've set in a plugin's config.",
                color = Color(0xFF9E9E9E),
                fontSize = 12.sp,
                modifier = Modifier.padding(bottom = 6.dp),
            )
            when {
                firstLoad -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                }

                binds.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(
                            "No bound plugin keybinds. Set one in a plugin's config first.",
                            color = Color(0xFF9E9E9E),
                            fontSize = 14.sp,
                        )
                    }
                }

                else -> {
                    LazyColumn(Modifier.fillMaxSize()) {
                        items(binds, key = { it.group + it.key }) { b ->
                            val prefix = "${b.group}${b.key}"
                            val on = active.any { it.startsWith(prefix) }
                            HotkeyRow(b, on) {
                                val next = active.toMutableSet()
                                val existing = next.firstOrNull { it.startsWith(prefix) }
                                if (existing != null) next.remove(existing) else next.add(prefix + b.label)
                                active = next
                                saveActiveHotkeys(ctx, next) // MainActivity's prefs listener rebuilds the HUD strip
                            }
                            HorizontalDivider(color = Color(0x18FFFFFF))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HotkeyRow(
    b: BoundKeybind,
    on: Boolean,
    onToggle: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { onToggle() }
            .padding(vertical = 10.dp)
            .semantics {
                contentDescription = "${b.label} hotkey button"
                stateDescription = if (on) "On HUD" else "Not added"
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(b.label, color = Color.White, fontSize = 14.sp)
            Text(b.bind, color = Color(0xFF9E9E9E), fontSize = 12.sp)
        }
        Text(
            if (on) "✓ On HUD" else "+ Add",
            color = if (on) Color(0xFF80CBC4) else Color(0xFFB0BEC5),
            fontSize = 13.sp,
        )
    }
}

private fun parseBoundKeybinds(json: String): List<BoundKeybind> =
    try {
        val arr = org.json.JSONArray(json)
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            BoundKeybind(o.optString("group"), o.optString("key"), o.optString("label", "?"), o.optString("bind", ""))
        }
    } catch (t: Throwable) {
        Log.e(PR_TAG, "ANDROID_TRACKB_HOTKEYS_UI_RED parse: $t")
        emptyList()
    }
