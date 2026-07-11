package dev.audaro.runemobile

import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** One Plugin-Hub catalog entry, parsed from MobileUiBridge.hubManifest(). */
data class HubRow(
    val internalName: String,
    val displayName: String,
    val author: String?,
    val description: String?,
    val version: String?,
    val unavailable: String?, // non-null/non-blank = can't run on this platform (native libs, etc.)
    val installed: Boolean,
    val installing: Boolean = false,
)

/**
 * Finding 17 — the net-new Plugin Hub browse/install screen (Android had only the enable/toggle list before).
 * Mirrors iOS's PluginHubViewController over the same shared bridge: poll MobileUiBridge.hubManifest() until the
 * one-time async catalog download settles, then list every hub plugin with an Install/Remove button. Install /
 * uninstall register synchronously then download+load async, so on a tap we flip optimistically, then poll
 * hubState() (refreshing/seq) until the change settles and reconcile the real installed flags from a fresh
 * manifest (catches a silent failure). All bridge calls go over the rl-bridge thread (HotSpot-attached).
 */
@Composable
fun PluginHubScreen(
    onBack: () -> Unit,
    onPanelTextActive: (Boolean) -> Unit = {},
) {
    var status by remember { mutableStateOf("loading") } // loading | ok | error:* | off | not-ready
    var rows by remember { mutableStateOf<List<HubRow>>(emptyList()) }
    var filter by remember { mutableStateOf("") }
    var statusLine by remember { mutableStateOf("Loading manifest…") }
    val scope = rememberCoroutineScope()

    // Leaving the Hub (or closing the panel from it) must release the IME-suppression latch even if the search
    // field was focused — onFocusChanged(false) isn't guaranteed to fire on dispose, and a stuck-true latch would
    // block the in-game ⌨ / chat keyboard. (Same guard as PluginPanel/ConfigScreen/PanelView.)
    DisposableEffect(Unit) { onDispose { onPanelTextActive(false) } }

    // Manifest poll: hubManifest() kicks off a one-time background download and returns {status:loading} until
    // ready. Poll ~1 Hz until status leaves "loading", then parse once (or surface the terminal error).
    LaunchedEffect(Unit) {
        while (true) {
            val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.hubManifest() }.get() }
            val st = runCatching { JSONObject(json).optString("status", "") }.getOrDefault("")
            when (st) {
                "loading" -> {
                    statusLine = "Downloading manifest…"
                    delay(1000)
                }

                "ok" -> {
                    rows = parseHub(json)
                    status = "ok"
                    statusLine = "${rows.size} plugins"
                    Log.i("MainActivity", "ANDROID_HUB_UI_GREEN manifest loaded rows=${rows.size}")
                    break
                }

                else -> {
                    status = if (st.isEmpty()) "not-ready" else st
                    statusLine = if (st.isEmpty()) "Bridge not ready…" else "Manifest unavailable ($st)"
                    if (st.isNotEmpty()) break else delay(1000) // keep waiting while the facade comes up
                }
            }
        }
    }

    // On close, persist the installed-plugins list (the install/remove config write only flushes on settle, but
    // a fast back-out before settle would otherwise lose it).
    fun close() {
        JvmLauncher.onBridge { JvmLauncher.flushConfig() }
        onBack()
    }

    fun toggleInstall(p: HubRow) {
        if (p.installing) return
        val target = !p.installed
        // Optimistic flip + mark in-flight.
        rows = rows.map { if (it.internalName == p.internalName) it.copy(installed = target, installing = true) else it }
        statusLine = if (target) "Installing ${p.displayName}…" else "Removing ${p.displayName}…"
        scope.launch {
            withContext(Dispatchers.IO) {
                JvmLauncher
                    .onBridgeTouch {
                        if (target) JvmLauncher.hubInstall(p.internalName) else JvmLauncher.hubUninstall(p.internalName)
                    }.get()
            }
            // hubInstall set refreshing=true synchronously; poll hubState until a readable refreshing=false (the
            // async download+load fired ExternalPluginsChanged) or a generous deadline (never hang).
            val deadlineMs = 25_000L
            var waited = 0L
            while (waited < deadlineMs) {
                delay(400)
                waited += 400
                val sj = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.hubState() }.get() }
                val d = runCatching { JSONObject(sj) }.getOrNull()
                val haveState = d != null && d.has("refreshing")
                if (haveState && !d!!.optBoolean("refreshing")) break
                if (!haveState && waited >= 2_500L) break // can't report state (older jar) → settle fast
            }
            // Reconcile the true installed flag from a fresh manifest (corrects a silent install/remove failure).
            val mj = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.hubManifest() }.get() }
            val truth = parseHub(mj).associate { it.internalName to it.installed }
            rows =
                rows.map {
                    if (it.internalName == p.internalName) {
                        it.copy(installed = truth[it.internalName] ?: it.installed, installing = false)
                    } else {
                        it
                    }
                }
            statusLine = "${rows.size} plugins"
            JvmLauncher.onBridge { JvmLauncher.flushConfig() }
        }
    }

    Surface(color = Color(0xF2121212), modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Plugin Hub",
                    color = Color.White,
                    fontSize = 20.sp,
                    modifier = Modifier.weight(1f),
                    style = MaterialTheme.typography.titleLarge,
                )
                TextButton(onClick = { close() }) { Text("Close") }
            }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 2.dp)) {
                Text(statusLine, color = Color(0xFFB0B0B0), fontSize = 13.sp)
                if (status == "loading") {
                    Spacer(Modifier.width(8.dp))
                    CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp, color = Color(0xFFB0B0B0))
                }
            }
            if (status == "ok") {
                OutlinedTextField(
                    value = filter,
                    onValueChange = { filter = it },
                    label = { Text("Search") },
                    singleLine = true,
                    // Tell the host the IME is owned by this field while focused — else the per-frame input poll
                    // hides the soft keyboard every frame and it opens-then-closes. Same path the other panels use.
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .padding(vertical = 6.dp)
                            .onFocusChanged { onPanelTextActive(it.hasFocus) },
                )
                val shown =
                    rows.filter {
                        filter.isBlank() || it.displayName.contains(filter, ignoreCase = true) ||
                            (it.description?.contains(filter, ignoreCase = true) == true)
                    }
                LazyColumn(Modifier.fillMaxSize()) {
                    items(shown, key = { it.internalName }) { p ->
                        HubRowItem(p, onToggle = { toggleInstall(p) })
                        HorizontalDivider(color = Color(0x22FFFFFF))
                    }
                }
            } else if (status != "loading") {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(statusLine, color = Color(0xFFE57373))
                }
            }
        }
    }
}

@Composable
private fun HubRowItem(
    p: HubRow,
    onToggle: () -> Unit,
) {
    val unavailable = !p.unavailable.isNullOrBlank()
    Row(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(Modifier.weight(1f).padding(end = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.displayName, color = if (unavailable) Color(0xFF9E9E9E) else Color.White, fontSize = 15.sp)
                if (!p.author.isNullOrBlank()) {
                    Text("  by ${p.author}", color = Color(0xFF9A9A9A), fontSize = 12.sp)
                }
                if (!p.version.isNullOrBlank()) {
                    Text("  v${p.version}", color = Color(0xFF9A9A9A), fontSize = 12.sp)
                }
            }
            if (!p.description.isNullOrBlank()) {
                Text(
                    p.description,
                    color = Color(0xFFB0B0B0),
                    fontSize = 12.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (unavailable) {
                Text("✕ ${p.unavailable}", color = Color(0xFFE57373), fontSize = 11.sp)
            }
        }
        when {
            p.installing -> {
                CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            }

            unavailable -> {}

            // no action — can't run here
            p.installed -> {
                OutlinedButton(onClick = onToggle) { Text("Remove") }
            }

            else -> {
                Button(
                    onClick = onToggle,
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF2E7D32)),
                ) { Text("Install") }
            }
        }
    }
}

private fun parseHub(json: String): List<HubRow> =
    try {
        val arr = JSONObject(json).optJSONArray("plugins")
        if (arr == null) {
            emptyList()
        } else {
            (0 until arr.length())
                .map { i ->
                    val o = arr.getJSONObject(i)
                    HubRow(
                        internalName = o.getString("internalName"),
                        displayName = o.optString("displayName", o.getString("internalName")),
                        author = if (o.isNull("author")) null else o.optString("author", null),
                        description = if (o.isNull("description")) null else o.optString("description", null),
                        version = if (o.isNull("version")) null else o.optString("version", null),
                        unavailable = if (o.isNull("unavailable")) null else o.optString("unavailable", null),
                        installed = o.optBoolean("installed"),
                    )
                }.sortedWith(compareByDescending<HubRow> { it.installed }.thenBy { it.displayName.lowercase() })
        }
    } catch (t: Throwable) {
        Log.e("MainActivity", "ANDROID_HUB_UI_RED parse failed: $t")
        emptyList()
    }
