package dev.audaro.runemobile

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.Log
import androidx.compose.foundation.Image
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import kotlin.coroutines.coroutineContext

/** One side-panel nav entry from MobileUiBridge.listPanels(). */
data class PanelEntry(
    val index: Int,
    val tooltip: String,
    val icon: Bitmap?,
)

// Desktop-like cap for the rendered panel column. The Swing PluginPanel is laid out at ~242 logical px
// (MobileUiBridge.PANEL_W) and supersampled; the bridge's design target is ≈323pt wide (MobileUiBridge:808).
// Stretching the buffer across the whole phone width blew that up ~1.7x (oversize + bilinear "wash"), worst
// on tall panels (Notes/Skill Calc/Screen Markers) that step down to scale 2-3 then upscale hard. Capping the
// display width here restores the intended size and keeps short panels near 1:1 (crisp).
private val PANEL_MAX_DP = 340.dp

private class PanelSnap(
    val w: Int,
    val h: Int,
    val seq: Int,
    val px: IntArray?,
)

// PanelList (the old intermediate "Panels" screen) + its NativeRow were retired in the §4 cutover — the
// launcher grid now surfaces every panel + curated native screen as a first-class tile, so the extra list
// level is gone. PanelEntry/PanelSnap/parsePanels live on (consumed by the grid + the viewer below).

/**
 * A5 Tier-1: the rendered-image panel viewer. Opens the panel (off-screen under CACIO), polls its supersampled
 * ARGB image into a Bitmap (refreshing on frame-seq change for live updates), shows it fit-to-width with
 * vertical scroll, and maps taps back to buffer coords via panelClick. Closes the panel on dispose.
 */
@Composable
fun PanelView(
    index: Int,
    tooltip: String,
    onBack: () -> Unit,
    onPanelTextActive: (Boolean) -> Unit = {},
) {
    var bmp by remember { mutableStateOf<Bitmap?>(null) }
    var pw by remember { mutableStateOf(0) }
    var viewW by remember { mutableStateOf(1) }
    var logged by remember { mutableStateOf(false) }
    val scroll = rememberScrollState()
    // SC-4 panel-text input: a tap that lands in a Swing text field flips isPanelTextActive; we then raise a
    // mirror field whose text is streamed back into the panel via panelText (live-filter search boxes).
    var textActive by remember { mutableStateOf(false) }
    var fieldValue by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    // FIX-11: tell the host whenever a panel text field gains/loses focus, so its per-frame input poll stops
    // raising GameInputView (which would steal focus) / dismissing the IME the mirror field below owns.
    DisposableEffect(textActive) {
        onPanelTextActive(textActive)
        onDispose { onPanelTextActive(false) }
    }

    DisposableEffect(index) {
        onDispose { JvmLauncher.onBridge { JvmLauncher.closePanel() } }
    }
    LaunchedEffect(index) {
        JvmLauncher.onBridge { JvmLauncher.openPanel(index) }
        var lastSeq = -1
        while (coroutineContext.isActive) {
            val s =
                withContext(Dispatchers.IO) {
                    JvmLauncher
                        .onBridge {
                            PanelSnap(
                                JvmLauncher.panelWidth(),
                                JvmLauncher.panelHeight(),
                                JvmLauncher.panelFrameSeq(),
                                JvmLauncher.panelPixels(),
                            )
                        }.get()
                }
            if (s.seq != lastSeq && s.w > 0 && s.h > 0 && s.px != null && s.px.size >= s.w * s.h) {
                bmp = Bitmap.createBitmap(s.px, 0, s.w, s.w, s.h, Bitmap.Config.ARGB_8888)
                pw = s.w
                lastSeq = s.seq
                if (!logged) {
                    Log.i("MainActivity", "ANDROID_A5_UI_GREEN panel='$tooltip' ${s.w}x${s.h}")
                    logged = true
                }
            }
            delay(400)
        }
    }
    Surface(color = Color(0xF2121212), modifier = Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(8.dp)) {
                TextButton(onClick = onBack) { Text("‹ Panels") }
                Text(tooltip, color = Color.White, modifier = Modifier.weight(1f))
            }
            val img = bmp
            if (img == null) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else {
                // Cap the panel to a desktop-like column (≈PANEL_MAX_DP) and centre it, instead of stretching the
                // supersampled buffer across the whole screen. Taps still map through the box width (viewW), so
                // hit-testing is unchanged regardless of the cap.
                BoxWithConstraints(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                    val colW = if (maxWidth < PANEL_MAX_DP) maxWidth else PANEL_MAX_DP
                    Box(
                        Modifier
                            .width(colW)
                            .fillMaxHeight()
                            .verticalScroll(scroll)
                            .onGloballyPositioned { viewW = it.size.width.coerceAtLeast(1) }
                            .pointerInput(pw, viewW) {
                                detectTapGestures(
                                    onTap = { off ->
                                        if (pw > 0 && viewW > 0) {
                                            // fit-width => uniform scale viewW/pw; add the scroll offset for buffer-y.
                                            val bx = (off.x * pw / viewW).toInt()
                                            val by = ((off.y + scroll.value) * pw / viewW).toInt()
                                            JvmLauncher.onBridgeTouch { JvmLauncher.panelClick(bx, by) }
                                            // SC-4: after the click settles, ask the bridge whether it focused a text
                                            // field; if so raise the mirror field pre-filled, else drop the keyboard.
                                            scope.launch {
                                                delay(140)
                                                val active =
                                                    withContext(Dispatchers.IO) {
                                                        JvmLauncher.onBridge { JvmLauncher.isPanelTextActive() }.get()
                                                    }
                                                if (active) {
                                                    fieldValue =
                                                        withContext(Dispatchers.IO) {
                                                            JvmLauncher.onBridge { JvmLauncher.getPanelText() }.get()
                                                        }
                                                    textActive = true
                                                } else {
                                                    textActive = false
                                                }
                                            }
                                        }
                                    },
                                    onLongPress = { off ->
                                        if (pw > 0 && viewW > 0) {
                                            val bx = (off.x * pw / viewW).toInt()
                                            val by = ((off.y + scroll.value) * pw / viewW).toInt()
                                            JvmLauncher.onBridgeTouch { JvmLauncher.panelLongPress(bx, by) } // SC-4 BUTTON3
                                        }
                                    },
                                )
                            },
                    ) {
                        Image(img.asImageBitmap(), tooltip, Modifier.fillMaxWidth(), contentScale = ContentScale.FillWidth)
                    }
                }
                if (textActive) {
                    val fr = remember { FocusRequester() }
                    val keyboard = LocalSoftwareKeyboardController.current
                    // Focus the mirror AND explicitly show the IME — requesting focus alone is unreliable, and the
                    // host poll no longer fights it (onPanelTextActive frees the IME). delay lets layout settle.
                    LaunchedEffect(Unit) {
                        fr.requestFocus()
                        delay(60)
                        keyboard?.show()
                    }
                    OutlinedTextField(
                        value = fieldValue,
                        onValueChange = { v ->
                            fieldValue = v
                            JvmLauncher.onBridgeTouch { JvmLauncher.panelText(v) }
                        },
                        singleLine = true,
                        label = { Text("Search / type into panel") },
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions =
                            KeyboardActions(onDone = {
                                JvmLauncher.onBridgeTouch { JvmLauncher.panelKey(10) } // AWT VK_ENTER -> submit
                            }),
                        modifier = Modifier.fillMaxWidth().padding(8.dp).focusRequester(fr),
                    )
                }
            }
        }
    }
}

// Non-private: reused by the §4 launcher grid (PluginPanel.kt) so it can surface panels as tiles directly.
fun parsePanels(json: String): List<PanelEntry> =
    try {
        val arr = JSONArray(json)
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            val icon =
                o.optString("iconPng", "").takeIf { it.isNotEmpty() }?.let {
                    val bytes = Base64.decode(it, Base64.DEFAULT)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }
            PanelEntry(o.optInt("index", i), o.optString("tooltip", "panel $i"), icon)
        }
    } catch (t: Throwable) {
        Log.e("MainActivity", "ANDROID_A5_UI_RED parse: $t")
        emptyList()
    }
