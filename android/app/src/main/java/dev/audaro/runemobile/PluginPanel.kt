package dev.audaro.runemobile

import android.graphics.Bitmap
import android.util.Log
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.Animatable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** One row of the A4 plugin list, parsed from MobileUiBridge.listPlugins(). */
data class PluginRow(
    val className: String,
    val name: String,
    val description: String, // for search parity with desktop (name + description + tags)
    val tags: String, // space-joined PluginDescriptor.tags()
    val enabled: Boolean,
    val active: Boolean, // engine actually started it; enabled && !active (after grace) = couldn't start
    val hasConfig: Boolean,
    val configGroup: String?,
    val pinned: Boolean,
    val configOnly: Boolean, // desktop config-only fake-plugin (RuneLite / Chat Color): no enable toggle, tap = config
)

/*
 * A4 plugin list — the first native plugin-control screen. Reads the live plugin list from the engine over
 * the rl-bridge thread (JvmLauncher.onBridge -> MobileUiBridge.listPlugins) and renders a toggle per plugin;
 * flipping a switch calls setPluginEnabled on the bridge thread (optimistic UI). Compose for this data screen
 * per the hybrid UI decision; the live game overlays stay classic Views.
 */

/** Phase-2 renderer-as-plugins: the two renderer rows are special-cased — their switch shows the SAVED
 *  LAUNCH PREFERENCE (not live plugin state, which is meaningless pre-restart) and toggling writes the
 *  preference instead of setPluginEnabled. RendererPanelStarter loads both into the list without starting. */
private const val GPU_PLUGIN_CLASS = "net.runelite.client.plugins.gpu.GpuPlugin"
private const val HD_PLUGIN_CLASS = "rs117.hd.HdPlugin"

@Composable
fun PluginPanel(
    onClose: () -> Unit,
    rendererPref: String = "cpu",
    onRendererSelect: (String) -> Unit = {},
    // §4 cutover: the scattered devBar toolbar actions now have a home as fixed launcher tiles (audit #9).
    onScreenshot: () -> Unit = {},
    // PARITY-ANDROID-SHOT: long-press the Screenshot tile toggles auto-saving the engine's event screenshots
    // (level-ups, drops, clues, kills) to the gallery — mirrors iOS long-press on the 📷 button.
    onScreenshotLongPress: () -> Unit = {},
    onAccount: () -> Unit = {},
    onLogout: () -> Unit = {},
    onDiscord: () -> Unit = {},
    onPanelTextActive: (Boolean) -> Unit = {}, // FIX-11: forwarded to PanelView so the host can free the IME
    onEnterOverlayEdit: () -> Unit = {}, // overlay layout is now edited ON the live game (host drag mode)
) {
    var rows by remember { mutableStateOf<List<PluginRow>>(emptyList()) }
    var renderer by remember { mutableStateOf(rendererPref) }
    var loading by remember { mutableStateOf(true) }
    var filter by remember { mutableStateOf("") }
    // §4 redesign (increment 2): the launcher LANDING is now a labelled tile grid (renderers / pinned / panels /
    // config) instead of a 131-row scroll. The full plugin list is one tile away ("All plugins") and is also
    // revealed automatically while the user is typing in the search field (config-search parity for the long tail).
    var listMode by remember { mutableStateOf(false) }
    // Panel data for the Panels section of the grid (lifted from PanelList so panels become first-class tiles).
    var panels by remember { mutableStateOf<List<PanelEntry>>(emptyList()) }
    var panelAvail by remember { mutableStateOf(BooleanArray(7)) } // [quest,world,xp,loot,ge,overlay,infobox]
    var configFor by remember { mutableStateOf<Pair<String, String>?>(null) } // (configGroup, pluginName)
    var panelOpen by remember { mutableStateOf<Pair<Int, String>?>(null) } // (panelIndex, tooltip)
    var questOpen by remember { mutableStateOf(false) } // A5 Tier-2 native screens
    var worldOpen by remember { mutableStateOf(false) }
    var xpOpen by remember { mutableStateOf(false) } // Finding 14 XP Tracker reflow
    var lootOpen by remember { mutableStateOf(false) } // Finding 14 Loot Tracker reflow
    var geOpen by remember { mutableStateOf(false) } // Finding 14 Grand Exchange reflow
    var timeOpen by remember { mutableStateOf(false) } // Track B Time Tracking reflow
    var timeAvail by remember { mutableStateOf(false) }
    var infoBoxOpen by remember { mutableStateOf(false) } // Finding 22 infobox menu
    var profilesOpen by remember { mutableStateOf(false) } // Track B #6 config profiles
    var profilesAvail by remember { mutableStateOf(false) }
    var hotkeysOpen by remember { mutableStateOf(false) } // Track B #1 user-defined hotkeys
    var notesOpen by remember { mutableStateOf(false) } // native editable Notes panel
    var notesAvail by remember { mutableStateOf(false) }
    var hubOpen by remember { mutableStateOf(false) } // Finding 17 hub browse/install
    var aboutOpen by remember { mutableStateOf(false) } // PROD-QA-07 identity/disclosure
    // Finding 8: a plugin just toggled ON is starting — suppress the "couldn't start" badge during a grace
    // window, then re-fetch the true active state. A row is incompatible = enabled && !active && not pending.
    var pending by remember { mutableStateOf(setOf<String>()) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()

    // Safety: closing the whole panel while the search field (or any inner field) is focused must release the
    // IME-suppression latch — onFocusChanged(false) isn't guaranteed to fire when a focused node is disposed, and a
    // stuck-true latch would then block the in-game ⌨ / chat keyboard. (ConfigScreen/PanelView guard the same way.)
    DisposableEffect(Unit) { onDispose { onPanelTextActive(false) } }

    suspend fun reload() {
        // listPlugins() must run off the UI thread + on a HotSpot-attached thread -> the rl-bridge executor.
        val json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.listPlugins() }.get() }
        rows = parsePlugins(json)
        loading = false
    }

    LaunchedEffect(Unit) {
        reload()
        // Panel tiles for the grid: the same data the old PanelList consumed (listPanels + curated availability).
        val pjson = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.listPanels() }.get() }
        panels = parsePanels(pjson)
        panelAvail =
            withContext(Dispatchers.IO) {
                JvmLauncher
                    .onBridge {
                        booleanArrayOf(
                            JvmLauncher.questAvailable(),
                            JvmLauncher.worldAvailable(),
                            JvmLauncher.xpAvailable(),
                            JvmLauncher.lootAvailable(),
                            JvmLauncher.geAvailable(),
                            JvmLauncher.overlayAvailable(),
                            JvmLauncher.infoBoxAvailable(),
                        )
                    }.get()
            }
        profilesAvail = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.profilesAvailable() }.get() }
        timeAvail = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.timeTrackingAvailable() }.get() }
        notesAvail = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.notesAvailable() }.get() }
        Log.i(
            "MainActivity",
            "ANDROID_LAUNCHER_GRID_GREEN rows=${rows.size} pinned=${rows.count { it.pinned }} " +
                "panels=${panels.size} avail=${panelAvail.count { it }}",
        )
    }

    // §4 increment 3: the launcher + every panel now live INSIDE a PEEK/EXPAND bottom sheet (SheetScaffold) so
    // the live game stays visible above it (the desktop slide-out parity win) — drag the grab handle DOWN to
    // PEEK past any sub-screen and watch the game above it.

    // §4 dismiss model (d): back pops ONE level — close the active sub-screen back to the launcher, else dismiss
    // the whole sheet. Honoured here so the Compose back-stack works (the MainActivity dispatcher disposes this
    // composition on close, so this handler only exists while the sheet is genuinely open).
    // Order matches the render `when` below so back always clears the screen actually showing (only ever one
    // sub-screen is set at a time today, but keeping the orders aligned avoids a latent mismatch).
    fun popSub(): Boolean {
        when {
            questOpen -> {
                questOpen = false
            }

            worldOpen -> {
                worldOpen = false
            }

            xpOpen -> {
                xpOpen = false
            }

            lootOpen -> {
                lootOpen = false
            }

            geOpen -> {
                geOpen = false
            }

            timeOpen -> {
                timeOpen = false
            }

            infoBoxOpen -> {
                infoBoxOpen = false
            }

            profilesOpen -> {
                profilesOpen = false
            }

            hotkeysOpen -> {
                hotkeysOpen = false
            }

            notesOpen -> {
                notesOpen = false
            }

            hubOpen -> {
                hubOpen = false
                scope.launch { reload() }
            }

            aboutOpen -> {
                aboutOpen = false
            }

            panelOpen != null -> {
                panelOpen = null
            }

            configFor != null -> {
                configFor = null
            }

            else -> {
                return false
            }
        }
        return true
    }
    BackHandler(enabled = true) { if (!popSub()) onClose() }

    // UX-XCUT-05: apply the OSRS Compose theme (palette + RuneScape typeface) to the whole panel + its sub-screens
    // so the Material defaults stop reading as generic dark Material. Wraps the panel root so the host ComposeView
    // (set in MainActivity) gets the theme without changing the call site.
    RuneMobileTheme {
        // Every sub-screen opens at EXPAND so its scrollable content fills the window. Opening the passive
        // monitors (XP / loot / GE / time) at the old half-height PEEK read as "the content only uses half the
        // window"; the grab handle still drags DOWN to PEEK (or dismiss), keeping watch-the-game as a gesture.
        SheetScaffold(atPeek = false, onDismiss = onClose) {
            when {
                questOpen -> {
                    QuestHelperScreen(onBack = { questOpen = false })
                }

                worldOpen -> {
                    WorldSwitcherScreen(onBack = { worldOpen = false })
                }

                xpOpen -> {
                    XpTrackerScreen(onBack = { xpOpen = false })
                }

                lootOpen -> {
                    LootTrackerScreen(onBack = { lootOpen = false })
                }

                geOpen -> {
                    GrandExchangeScreen(onBack = { geOpen = false })
                }

                timeOpen -> {
                    TimeTrackingScreen(onBack = { timeOpen = false })
                }

                infoBoxOpen -> {
                    InfoBoxScreen(onBack = { infoBoxOpen = false })
                }

                profilesOpen -> {
                    ConfigProfilesScreen(onBack = { profilesOpen = false })
                }

                hotkeysOpen -> {
                    HotkeysScreen(onBack = { hotkeysOpen = false })
                }

                notesOpen -> {
                    NotesScreen(onBack = { notesOpen = false }, onPanelTextActive = onPanelTextActive)
                }

                hubOpen -> {
                    PluginHubScreen(onBack = {
                        hubOpen = false
                        scope.launch { reload() }
                    }, onPanelTextActive = onPanelTextActive)
                }

                aboutOpen -> {
                    AboutScreen(onBack = { aboutOpen = false })
                }

                panelOpen != null -> {
                    val po = panelOpen!!
                    PanelView(po.first, po.second, onBack = { panelOpen = null }, onPanelTextActive = onPanelTextActive)
                }

                configFor != null -> {
                    val cf = configFor!!
                    ConfigScreen(cf.first, cf.second, onBack = { configFor = null }, onTextActive = onPanelTextActive)
                }

                else -> {
                    Column(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
                        val inList = listMode || filter.isNotEmpty()
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (inList) {
                                // Back to the landing grid (clears any active filter so the grid isn't masked by it).
                                TextButton(onClick = {
                                    listMode = false
                                    filter = ""
                                }) { Text("‹ Grid") }
                            }
                            Text(
                                "Plugins" +
                                    if (rows.isNotEmpty()) {
                                        "  (${rows.count { it.enabled && !it.configOnly }}/${rows.count { !it.configOnly }})"
                                    } else {
                                        ""
                                    },
                                color = Color.White,
                                fontSize = 20.sp,
                                modifier = Modifier.weight(1f),
                                style = MaterialTheme.typography.titleLarge,
                            )
                            TextButton(onClick = { hubOpen = true }) { Text("Hub") }
                            TextButton(onClick = onClose) { Text("Close") }
                        }
                        OutlinedTextField(
                            value = filter,
                            onValueChange = { filter = it },
                            label = { Text("Search plugins") },
                            singleLine = true,
                            // Tell the host the IME is owned by this field while it's focused — otherwise the per-frame input
                            // poll (startInputPolling) sees no engine/manual text target, calls hideSoftInput every frame, and
                            // the keyboard opens-then-closes instantly. Same path ConfigScreen/PanelView use.
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 4.dp)
                                    .onFocusChanged { onPanelTextActive(it.hasFocus) },
                        )
                        // The RuneLite-account row used to sit here, fixed — on the short landscape window the title +
                        // search + account chrome ate ~60% of the sheet, leaving the scrollable options crammed into the
                        // bottom. It now scrolls with the grid (see LauncherGrid), so only the title + search stay pinned.
                        if (loading) {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                        } else if (inList) {
                            PluginListBody(
                                rows = rows,
                                filter = filter,
                                pending = pending,
                                renderer = renderer,
                                listState = listState,
                                onToggleRow = { p, checked ->
                                    rows = rows.map { if (it.className == p.className) it.copy(enabled = checked) else it }
                                    JvmLauncher.onBridgeTouch { JvmLauncher.setPluginEnabled(p.className, checked) }
                                    if (checked) {
                                        pending = pending + p.className
                                        scope.launch {
                                            kotlinx.coroutines.delay(4000)
                                            reload()
                                            pending = pending - p.className
                                        }
                                    } else {
                                        pending = pending - p.className
                                    }
                                },
                                onTogglePin = { p ->
                                    val nowPinned = !p.pinned
                                    rows =
                                        rows
                                            .map { if (it.className == p.className) it.copy(pinned = nowPinned) else it }
                                            .sortedWith(compareByDescending<PluginRow> { it.pinned }.thenBy { it.name.lowercase() })
                                    // Persist immediately so a deliberate pin survives even a hard kill. setPinned ENQUEUES a
                                    // client-thread write and returns a writeId; flush only AFTER that write is processed (else
                                    // sendConfig races ahead and flushes stale state).
                                    JvmLauncher.onBridgeTouch {
                                        val ack = JvmLauncher.setPinned(p.name, nowPinned)
                                        val wid =
                                            Regex("\"writeId\":(\\d+)")
                                                .find(ack)
                                                ?.groupValues
                                                ?.get(1)
                                                ?.toLongOrNull()
                                        var i = 0
                                        while (wid != null && JvmLauncher.processedWriteId() < wid && i++ < 40) Thread.sleep(25)
                                        JvmLauncher.flushConfig()
                                    }
                                    if (nowPinned) scope.launch { listState.animateScrollToItem(0) }
                                },
                                onRendererSelect = { mode, checked ->
                                    renderer = if (checked) mode else "cpu"
                                    onRendererSelect(renderer)
                                },
                                onOpenConfig = { p -> configFor = p.configGroup!! to p.name },
                            )
                        } else {
                            LauncherGrid(
                                rows = rows,
                                renderer = renderer,
                                panels = panels,
                                avail = panelAvail,
                                pending = pending,
                                onRendererSelect = { mode ->
                                    renderer = mode
                                    onRendererSelect(mode)
                                },
                                onOpenConfig = { p -> configFor = p.configGroup!! to p.name },
                                onOpenList = { listMode = true },
                                onOpenPanel = { i, t -> panelOpen = i to t },
                                onOpenQuest = { questOpen = true },
                                onOpenWorld = { worldOpen = true },
                                onOpenXp = { xpOpen = true },
                                onOpenLoot = { lootOpen = true },
                                onOpenGe = { geOpen = true },
                                timeAvail = timeAvail,
                                onOpenTime = { timeOpen = true },
                                onOpenOverlay = {
                                    onEnterOverlayEdit()
                                    onClose()
                                },
                                onOpenInfoBox = { infoBoxOpen = true },
                                onOpenHub = { hubOpen = true },
                                profilesAvail = profilesAvail,
                                onOpenProfiles = { profilesOpen = true },
                                notesAvail = notesAvail,
                                onOpenNotes = { notesOpen = true },
                                onOpenHotkeys = { hotkeysOpen = true },
                                onOpenAbout = { aboutOpen = true },
                                // FIX-5: open the world map via op-replay, then dismiss the launcher so the fullscreen map shows.
                                onOpenWorldMap = {
                                    JvmLauncher.onBridgeTouch { JvmLauncher.openWorldMap() }
                                    onClose()
                                },
                                onScreenshot = onScreenshot,
                                onScreenshotLongPress = onScreenshotLongPress,
                                onAccount = onAccount,
                                onLogout = onLogout,
                                onDiscord = onDiscord,
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * RuneLite-account (config sync) status + login/logout — distinct from the Jagex game login. Logging in opens the
 * runelite.net OAuth in a Custom Tab; on completion ConfigManager syncs the user's profiles + installed hub
 * plugins. Polls the session each ~2s (off the UI thread). Hidden entirely when the bridge isn't available.
 */
@Composable
private fun RuneLiteAccountRow() {
    var json by remember { mutableStateOf("{}") }
    LaunchedEffect(Unit) {
        while (true) {
            json = withContext(Dispatchers.IO) { JvmLauncher.onBridge { JvmLauncher.accountSessionJson() }.get() }
            delay(2000)
        }
    }
    val o =
        remember(json) {
            try {
                JSONObject(json)
            } catch (e: Exception) {
                JSONObject()
            }
        }
    if (!o.optBoolean("available", false)) return // session manager not wired (older jar) -> hide the row
    val loggedIn = o.optBoolean("loggedIn", false)
    val username = o.optString("username", "")
    Surface(
        color = Color(0xFF1B1B1B),
        shape = RoundedCornerShape(10.dp),
        modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text("RuneLite account", color = Color(0xFF80CBC4), fontSize = 11.sp)
                Text(
                    if (loggedIn) username.ifEmpty { "Signed in" } else "Sync your profiles + installed plugins",
                    color = Color.White,
                    fontSize = 13.sp,
                )
            }
            if (loggedIn) {
                TextButton(onClick = { JvmLauncher.onBridgeTouch { JvmLauncher.accountLogout() } }) {
                    Text("Log out", color = Color(0xFFEF9A9A))
                }
            } else {
                FilledTonalButton(onClick = { JvmLauncher.onBridgeTouch { JvmLauncher.accountLogin() } }) {
                    Text("Log in")
                }
            }
        }
    }
}

/**
 * PROD-QA-07 (GATE row 9) — the on-device identity/disclosure surface. The honest unofficial / not-affiliated /
 * ban-risk framing + open-source attribution previously lived only in the README (invisible on the phone); this
 * is the same text rendered in-app, reachable from the launcher's "More" grid. Pairs with the RuneMobile name +
 * icon (UX-ONBOARD-03) so the shipped app does not imply a Jagex-official client.
 */
@Composable
private fun AboutScreen(onBack: () -> Unit) {
    Surface(color = Color(0xFF121212), modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(12.dp).verticalScroll(rememberScrollState())) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onBack, modifier = Modifier.semantics { contentDescription = "Back" }) { Text("‹ Back") }
                Text("About", color = Color.White, fontSize = 18.sp, modifier = Modifier.weight(1f))
            }
            Text(
                "RuneMobile",
                color = Color.White,
                fontSize = 22.sp,
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(top = 4.dp),
            )
            Text(
                "Version ${BuildConfig.VERSION_NAME}",
                color = Color(0xFF9E9E9E),
                fontSize = 12.sp,
                modifier = Modifier.padding(bottom = 8.dp),
            )

            AboutSection(
                "Unofficial fan client",
                "RuneMobile is an unofficial, fan-made client. It is not affiliated with, endorsed by, or " +
                    "sponsored by Jagex Ltd. or the RuneLite project.",
            )
            AboutSection(
                "Account-ban risk",
                "This is an unapproved third-party client for live Old School RuneScape. It is not on Jagex's " +
                    "approved-client list, so playing on it puts your account at risk of a ban. Use a throwaway " +
                    "account — never your main.",
            )
            AboutSection(
                "Built on open source",
                "Derived from RuneLite (BSD 2-Clause) and runs the game on an on-device OpenJDK 21 VM (GPLv2 with " +
                    "Classpath Exception). The 117HD renderer is by the rs117 project (BSD 2-Clause). The plugin " +
                    "ecosystem is unmodified. Full third-party attribution is in THIRD-PARTY-NOTICES.md in the project " +
                    "repository.",
            )
            AboutSection(
                "Trademarks & game art",
                "RuneScape and Old School RuneScape, and their interface art, are property of Jagex Ltd. This app " +
                    "bundles no Jagex art assets: the mobile chrome draws those interface sprites from your own live " +
                    "game cache at runtime — the same way the upstream RuneLite client does — so the art is never " +
                    "redistributed.",
            )
            Spacer(Modifier.heightIn(min = 16.dp))
        }
    }
}

@Composable
private fun AboutSection(
    title: String,
    body: String,
) {
    Column(Modifier.fillMaxWidth().padding(top = 14.dp)) {
        Text(title, color = Color(0xFF80CBC4), fontSize = 13.sp)
        Text(body, color = Color(0xFFCFCFCF), fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp))
    }
}

/**
 * §4 increment 3 — the PEEK/EXPAND bottom sheet. Hosts the launcher + panels in a bottom-anchored sheet so the
 * live game stays visible (and watchable) above it — the desktop slide-out parity win. A light scrim over the
 * game dims with how open the sheet is and dismisses on tap; the grab handle drags between the two detents (or
 * below PEEK to dismiss) and a tap toggles them. [atPeek] requests PEEK (a sub-screen is open, game watchable)
 * or EXPAND (the launcher grid). The ComposeView host is transparent so the SurfaceView game composites through.
 */
@Composable
private fun SheetScaffold(
    atPeek: Boolean,
    onDismiss: () -> Unit,
    content: @Composable () -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val fullPx = with(density) { maxHeight.toPx() }
        val peekPx = fullPx * 0.46f
        val expandPx = fullPx * 0.92f
        val sheetPx = remember { Animatable(if (atPeek) peekPx else expandPx) }
        val scope = rememberCoroutineScope()
        // Follow the external detent request (launcher<->panel), and re-derive on any detent-size change (e.g.
        // multi-window/free-form resize, or the very first measure when fullPx may briefly be 0) so the
        // absolute-px sheet height never goes stale vs its detent.
        LaunchedEffect(atPeek, peekPx, expandPx) { sheetPx.animateTo(if (atPeek) peekPx else expandPx) }
        // Scrim darkens with how open the sheet is; the game stays watchable through it. Tap = dismiss.
        val scrimAlpha = (sheetPx.value / fullPx).coerceIn(0f, 1f) * 0.5f
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = scrimAlpha))
                .pointerInput(Unit) { detectTapGestures { onDismiss() } },
        )
        Surface(
            color = Color(0xFF141414),
            modifier =
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(with(density) { sheetPx.value.toDp() })
                    // No imePadding on the SHEET: it must not float up by the keyboard height (that exposed the
                    // game beneath it). The window is adjustResize + decorFits(false) — a no-op for layout — so
                    // IME insets reach the config editor inside, which opts into imePadding itself (UX-KBD-1);
                    // the search fields sit at the top of the sheet and stay visible above the keyboard anyway.
                    // Consume taps that land on the sheet (but not on a child) so they never fall through to the
                    // dismiss scrim behind it.
                    .pointerInput(Unit) { detectTapGestures { } },
        ) {
            Column(Modifier.fillMaxSize()) {
                // Grab handle: a tap toggles PEEK<->EXPAND; a drag resizes and snaps to the nearest detent (or
                // below PEEK to dismiss). detectTapGestures + detectVerticalDragGestures compose on one node —
                // the tap fires on an up without slop, the drag on slop-crossing — so both affordances are live
                // (a tap alone never triggers the drag gesture's onDragEnd, so the toggle needs its own detector).
                Box(
                    Modifier
                        .fillMaxWidth()
                        // TOUCH-1: ≥44dp gesture strip (was 28dp); the visual pill inside stays 40×5.
                        .height(44.dp)
                        .pointerInput(peekPx, expandPx) {
                            detectTapGestures {
                                val target = if (sheetPx.value < (peekPx + expandPx) / 2f) expandPx else peekPx
                                scope.launch { sheetPx.animateTo(target) }
                            }
                        }.pointerInput(peekPx, expandPx) {
                            // FIX-6: a drag that STARTS above peek (i.e. from EXPAND) snaps down to PEEK and never
                            // dismisses in one go — only a continued drag-down FROM peek dismisses. Stops an
                            // accidental swipe from nuking an open config editor.
                            var startedAbovePeek = false
                            detectVerticalDragGestures(
                                onDragStart = { startedAbovePeek = sheetPx.value > peekPx * 1.15f },
                                onVerticalDrag = { change, delta ->
                                    change.consume()
                                    scope.launch { sheetPx.snapTo((sheetPx.value - delta).coerceIn(0f, expandPx)) }
                                },
                                onDragEnd = {
                                    val v = sheetPx.value
                                    when {
                                        v < peekPx * 0.55f && !startedAbovePeek -> onDismiss()
                                        v < (peekPx + expandPx) / 2f -> scope.launch { sheetPx.animateTo(peekPx) }
                                        else -> scope.launch { sheetPx.animateTo(expandPx) }
                                    }
                                },
                            )
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier
                            .size(width = 40.dp, height = 5.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(Color(0x66FFFFFF)),
                    )
                }
                // UX-XCUT-03: inset the sheet body so the ‹ Back chevron, Reset/Close, search and the LazyColumn
                // rows clear a landscape display cutout (horizontal) and the bottom gesture inset. displayCutout ∪
                // navigationBars deliberately AVOIDS the IME — preserving the existing no-imePadding behavior (the
                // keyboard still OVERLAYS the sheet, the top search field stays visible above it). 0 insets are a
                // no-op. The grab handle above stays full-width; only the content gets the safe-area padding.
                Box(
                    Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .windowInsetsPadding(
                            WindowInsets.displayCutout
                                .union(WindowInsets.navigationBars)
                                .only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom),
                        ),
                ) { content() }
            }
        }
    }
}

/**
 * §4 increment 2 — the labelled tile grid landing. Sections: Renderers (CPU/GPU/117HD radio), Pinned ★ (quick
 * config access to favourites), Panels (curated native screens + rendered-image panels as labelled tiles), and
 * More (All plugins / Plugin Hub). Replaces the deep 131-row scroll as the first thing the launcher shows.
 */
@Composable
private fun LauncherGrid(
    rows: List<PluginRow>,
    renderer: String,
    panels: List<PanelEntry>,
    avail: BooleanArray,
    pending: Set<String>,
    onRendererSelect: (String) -> Unit,
    onOpenConfig: (PluginRow) -> Unit,
    onOpenList: () -> Unit,
    onOpenPanel: (Int, String) -> Unit,
    onOpenQuest: () -> Unit,
    onOpenWorld: () -> Unit,
    onOpenXp: () -> Unit,
    onOpenLoot: () -> Unit,
    onOpenGe: () -> Unit,
    timeAvail: Boolean,
    onOpenTime: () -> Unit,
    onOpenOverlay: () -> Unit,
    onOpenInfoBox: () -> Unit,
    onOpenHub: () -> Unit,
    profilesAvail: Boolean,
    onOpenProfiles: () -> Unit,
    notesAvail: Boolean,
    onOpenNotes: () -> Unit,
    onOpenHotkeys: () -> Unit,
    onOpenAbout: () -> Unit,
    onOpenWorldMap: () -> Unit,
    onScreenshot: () -> Unit,
    onScreenshotLongPress: () -> Unit,
    onAccount: () -> Unit,
    onLogout: () -> Unit,
    onDiscord: () -> Unit,
) {
    // Native curated screens, gated on the curated bridge's availability (same gating PanelList used). Each
    // borrows the matching engine panel's icon when one exists so the tile isn't a bare glyph.
    fun iconFor(tooltip: String): Bitmap? = panels.firstOrNull { it.tooltip == tooltip }?.icon
    val nativeTiles =
        buildList {
            if (avail.getOrElse(2) { false }) add(TileSpec("XP Tracker", iconFor("XP Tracker"), onClick = onOpenXp))
            if (avail.getOrElse(3) { false }) add(TileSpec("Loot Tracker", iconFor("Loot Tracker"), onClick = onOpenLoot))
            if (avail.getOrElse(4) { false }) add(TileSpec("Grand Exchange", iconFor("Grand Exchange"), onClick = onOpenGe))
            if (timeAvail) add(TileSpec("Time Tracking", iconFor("Time Tracking"), glyph = "⏱", onClick = onOpenTime))
            if (avail.getOrElse(1) { false }) add(TileSpec("World Switcher", iconFor("World Switcher"), onClick = onOpenWorld))
            if (avail.getOrElse(0) { false }) add(TileSpec("Quest Helper", iconFor("Quest Helper"), onClick = onOpenQuest))
            if (avail.getOrElse(5) { false }) add(TileSpec("Overlay Layout", glyph = "▦", onClick = onOpenOverlay))
            if (avail.getOrElse(6) { false }) add(TileSpec("Infoboxes", glyph = "◳", onClick = onOpenInfoBox))
            // Native editable Notes screen supersedes the rendered Notes panel (added to `covered`, see below).
            if (notesAvail) add(TileSpec("Notes", iconFor("Notes"), glyph = "✎", onClick = onOpenNotes))
        }
    // Rendered-image panels for everything not covered by an available native screen (so no panel is lost when a
    // native reflow exists; if the native screen is unavailable the rendered tile remains as the fallback).
    val covered = nativeTiles.map { it.label }.toSet()
    val renderedTiles =
        panels
            .filter { it.tooltip !in covered }
            .map { p -> TileSpec(p.tooltip, p.icon) { onOpenPanel(p.index, p.tooltip) } }

    val pinnedTiles =
        rows
            .filter { it.pinned && it.className != GPU_PLUGIN_CLASS && it.className != HD_PLUGIN_CLASS }
            .map { p ->
                TileSpec(
                    p.name,
                    glyph = "★",
                    star = true,
                    incompatible = p.enabled && !p.active && p.className !in pending,
                ) { if (p.hasConfig && p.configGroup != null) onOpenConfig(p) else onOpenList() }
            }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        // Scrolls with the grid (was a fixed row above the list) so the pinned chrome stays just title + search.
        RuneLiteAccountRow()
        SectionLabel("Renderers")
        TileGrid(
            listOf(
                TileSpec("CPU", glyph = "▣", selected = renderer == "cpu") { onRendererSelect("cpu") },
                TileSpec("GPU", glyph = "▤", selected = renderer == "gpu") { onRendererSelect("gpu") },
                TileSpec("117HD", glyph = "✦", selected = renderer == "117hd") { onRendererSelect("117hd") },
            ),
        )
        if (renderer != "cpu") {
            Text(
                "Renderer change applies on next launch.",
                color = Color(0xFF9E9E9E),
                fontSize = 11.sp,
                modifier = Modifier.padding(start = 4.dp, top = 2.dp),
            )
        }

        if (pinnedTiles.isNotEmpty()) {
            SectionLabel("Pinned ★")
            TileGrid(pinnedTiles)
        }

        // Guard the header so the user never sees a bare "Panels" heading on the first frame (before the
        // LaunchedEffect bridge fetch returns panels/availability) or if there are genuinely no panels.
        val panelTiles = nativeTiles + renderedTiles
        if (panelTiles.isNotEmpty()) {
            SectionLabel("Panels")
            TileGrid(panelTiles)
        }

        SectionLabel("More")
        TileGrid(
            buildList {
                add(TileSpec("All plugins", glyph = "≡", onClick = onOpenList))
                add(TileSpec("Plugin Hub", glyph = "⬇", onClick = onOpenHub))
                // Track B #6: native config-profiles list/switch (gated on the bridge being wired).
                if (profilesAvail) add(TileSpec("Profiles", glyph = "⚙", onClick = onOpenProfiles))
                add(TileSpec("Hotkeys", glyph = "⌨", onClick = onOpenHotkeys))
                // FIX-5: a discoverable native open-map control (the engine globe orb is ~25px and undiscoverable;
                // this opens the map via op-replay regardless of orb position/account).
                add(TileSpec("World Map", glyph = "◉", onClick = onOpenWorldMap))
                // §4 cutover: the toolbar-only nav buttons that had no Android home (audit §4.3) — fixed native
                // tiles wired to existing handlers. Discord becomes reachable for the first time.
                add(TileSpec("Screenshot", glyph = "▣", onClick = onScreenshot, onLongClick = onScreenshotLongPress))
                add(TileSpec("Account", glyph = "⎆", onClick = onAccount))
                // ✕ (the device font lacks the ⏻ power glyph -> tofu); reads as "exit session".
                add(TileSpec("Log out", glyph = "✕", onClick = onLogout))
                add(TileSpec("Discord", glyph = "✦", onClick = onDiscord))
                // PROD-QA-07: the honest unofficial/not-affiliated + attribution disclosure, on-device (was README-only).
                add(TileSpec("About", glyph = "ⓘ", onClick = onOpenAbout))
            },
        )
        Spacer(Modifier.heightIn(min = 12.dp))
    }
}

/** Section heading inside the launcher grid. */
@Composable
private fun SectionLabel(text: String) {
    Text(
        text,
        color = Color(0xFF80CBC4),
        fontSize = 12.sp,
        modifier = Modifier.padding(top = 14.dp, bottom = 2.dp),
    )
}

/** One launcher tile: an icon (engine PNG) or a glyph, a label, and optional selected/star/incompatible state. */
private data class TileSpec(
    val label: String,
    val icon: Bitmap? = null,
    val glyph: String? = null,
    val selected: Boolean = false,
    val star: Boolean = false,
    val incompatible: Boolean = false,
    // onLongClick sits BEFORE onClick so the many trailing-lambda call sites keep binding their lambda to onClick.
    val onLongClick: (() -> Unit)? = null,
    val onClick: () -> Unit,
)

/** Lay tiles out in fixed-width columns, padding the last row so widths stay even. */
@Composable
private fun TileGrid(
    tiles: List<TileSpec>,
    cols: Int = 3,
) {
    Column(Modifier.fillMaxWidth()) {
        tiles.chunked(cols).forEach { rowTiles ->
            Row(Modifier.fillMaxWidth()) {
                rowTiles.forEach { LaunchTile(it) }
                repeat(cols - rowTiles.size) { Spacer(Modifier.weight(1f).padding(4.dp)) }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun RowScope.LaunchTile(t: TileSpec) {
    Column(
        Modifier
            .weight(1f)
            .padding(4.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(if (t.selected) Color(0xFF24403D) else Color(0xFF1E1E1E))
            .border(
                width = if (t.selected) 1.5.dp else 0.5.dp,
                color = if (t.selected) Color(0xFF80CBC4) else Color(0x33FFFFFF),
                shape = RoundedCornerShape(10.dp),
            ).combinedClickable(onClick = { t.onClick() }, onLongClick = t.onLongClick)
            .semantics {
                contentDescription = t.label +
                    when {
                        t.incompatible -> ", can't start"
                        t.selected -> ", selected"
                        else -> ""
                    }
                if (t.selected) stateDescription = "Selected"
            }.heightIn(min = 78.dp)
            .padding(vertical = 10.dp, horizontal = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(Modifier.size(28.dp), contentAlignment = Alignment.Center) {
            val ic = t.icon
            if (ic != null) {
                Image(ic.asImageBitmap(), null, Modifier.size(28.dp))
            } else {
                Text(t.glyph ?: t.label.take(1), color = Color(0xFFCCCCCC), fontSize = 20.sp)
            }
        }
        Spacer(Modifier.heightIn(min = 5.dp))
        Text(
            t.label,
            color = if (t.incompatible) Color(0xFF9E9E9E) else Color.White,
            fontSize = 12.sp,
            textAlign = TextAlign.Center,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (t.incompatible) Text("✕ can't start", color = Color(0xFFE57373), fontSize = 9.sp)
    }
}

/** The full searchable/toggleable plugin list — the long-tail config surface reached via search or "All plugins". */
@Composable
private fun PluginListBody(
    rows: List<PluginRow>,
    filter: String,
    pending: Set<String>,
    renderer: String,
    listState: androidx.compose.foundation.lazy.LazyListState,
    onToggleRow: (PluginRow, Boolean) -> Unit,
    onTogglePin: (PluginRow) -> Unit,
    onRendererSelect: (String, Boolean) -> Unit,
    onOpenConfig: (PluginRow) -> Unit,
) {
    val q = filter.trim()
    val shown =
        rows.filter {
            q.isEmpty() || it.name.contains(q, ignoreCase = true) ||
                it.description.contains(q, ignoreCase = true) || it.tags.contains(q, ignoreCase = true)
        }
    LazyColumn(Modifier.fillMaxSize(), state = listState) {
        items(shown, key = { it.className }) { p ->
            val rendererMode =
                when (p.className) {
                    GPU_PLUGIN_CLASS -> "gpu"
                    HD_PLUGIN_CLASS -> "117hd"
                    else -> null
                }
            if (rendererMode != null) {
                // Renderer row: switch state = the saved launch preference; toggle = save it.
                // Never marked incompatible (it is deliberately not running on this boot).
                PluginRowItem(
                    p.copy(enabled = renderer == rendererMode),
                    incompatible = false,
                    onToggle = { checked -> onRendererSelect(rendererMode, checked) },
                    onTogglePin = {},
                    onOpenConfig =
                        if (p.hasConfig && p.configGroup != null) {
                            { onOpenConfig(p) }
                        } else {
                            null
                        },
                )
                return@items
            }
            PluginRowItem(
                p,
                // enabled but the engine never started it (after the startup grace) = couldn't start.
                incompatible = p.enabled && !p.active && p.className !in pending,
                onToggle = { checked -> onToggleRow(p, checked) },
                onTogglePin = { onTogglePin(p) },
                onOpenConfig =
                    if (p.hasConfig && p.configGroup != null) {
                        { onOpenConfig(p) }
                    } else {
                        null
                    },
            )
            HorizontalDivider(color = Color(0x22FFFFFF))
        }
    }
}

@Composable
private fun PluginRowItem(
    p: PluginRow,
    incompatible: Boolean,
    onToggle: (Boolean) -> Unit,
    onTogglePin: () -> Unit,
    onOpenConfig: (() -> Unit)?,
) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        // Star toggle: pin a favourite to the top of the list (shared pinnedPlugins CSV).
        Text(
            if (p.pinned) "★" else "☆",
            color = if (p.pinned) Color(0xFFFFC107) else Color(0xFF777777),
            fontSize = 20.sp,
            modifier =
                Modifier
                    .clickable { onTogglePin() }
                    .padding(end = 10.dp)
                    .semantics {
                        contentDescription = if (p.pinned) "Unpin ${p.name}" else "Pin ${p.name}"
                        stateDescription = if (p.pinned) "Pinned" else "Not pinned"
                    },
        )
        val nameMod =
            (if (onOpenConfig != null) Modifier.weight(1f).clickable { onOpenConfig() } else Modifier.weight(1f))
                .semantics { if (onOpenConfig != null) contentDescription = "Configure ${p.name}" }
        Column(nameMod) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(p.name, color = if (incompatible) Color(0xFF9E9E9E) else Color.White)
                if (onOpenConfig != null) Text("  ⚙", color = Color(0xFF9E9E9E)) // tap the name to configure
            }
            // Finding 8: the toggle is on but the engine couldn't start it on this platform (GPU, Discord,
            // Developer Tools, …) — tell the user instead of leaving a dead toggle.
            if (incompatible) Text("✕ couldn't start (incompatible)", color = Color(0xFFE57373), fontSize = 11.sp)
        }
        // Config-only fake-plugins (RuneLite core settings / Chat Color) have no enable state — desktop shows no
        // toggle, only a tap-to-configure row (the ⚙ above). Everything else gets the enable switch.
        if (!p.configOnly) {
            Switch(
                checked = p.enabled,
                onCheckedChange = onToggle,
                modifier =
                    Modifier.semantics {
                        contentDescription = "${p.name}, ${if (p.enabled) "on" else "off"}"
                        stateDescription = if (p.enabled) "On" else "Off"
                    },
            )
        }
    }
}

private fun parsePlugins(json: String): List<PluginRow> =
    try {
        val arr = JSONArray(json)
        (0 until arr.length())
            .map { i ->
                val o = arr.getJSONObject(i)
                PluginRow(
                    className = o.getString("className"),
                    name = o.optString("name", o.getString("className")),
                    description = o.optString("description", ""),
                    tags = o.optString("tags", ""),
                    enabled = o.optBoolean("enabled"),
                    active = o.optBoolean("active"),
                    hasConfig = o.optBoolean("hasConfig"),
                    configGroup = if (o.isNull("configGroup")) null else o.optString("configGroup", null),
                    pinned = o.optBoolean("pinned"),
                    configOnly = o.optBoolean("configOnly"),
                )
            }.sortedWith(compareByDescending<PluginRow> { it.pinned }.thenBy { it.name.lowercase() })
    } catch (t: Throwable) {
        Log.e("MainActivity", "ANDROID_A4_UI_RED parse failed: $t")
        emptyList()
    }
