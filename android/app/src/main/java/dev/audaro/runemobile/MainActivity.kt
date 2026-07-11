package dev.audaro.runemobile

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.MediaStore
import android.util.Log
import android.view.Choreographer
import android.view.GestureDetector
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.webkit.CookieManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.Toast
import androidx.activity.addCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.ui.platform.ComposeView
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * Milestone B host: brings up the embedded HotSpot VM running headless RuneLite (DeviceHeadlessBoot) and
 * blits its composited frames to a SurfaceView, feeding touches back through the JavaBridge facade.
 *
 * HotSpot-in-process is effectively one VM per process, so VM bringup is guarded by a process-wide
 * singleton and uses the application context — the boot survives Activity recreation (rotation etc.).
 */
class MainActivity : AppCompatActivity() {
    private lateinit var surfaceView: SurfaceView
    private lateinit var gestures: GestureDetector
    private lateinit var scaleGestures: ScaleGestureDetector
    private lateinit var keyboardView: GameInputView
    private var cameraGestureActive = false
    private var pinchActive = false
    private var scaleAccum = 1f

    // AP-0 chat scroll-by-drag: a one-finger drag that STARTS inside the live chat box scrolls the chat
    // (finger-scroll, the iOS chatScrollAccum gesture) instead of rotating the camera. The rect is the
    // engine chatbox bounds (canvas px) from the per-frame chrome snapshot, so it tracks the relocate.
    private var chatScrolling = false
    private var chatScrollAccum = 0f
    private var chatRectCanvas: IntArray? = null // [x,y,w,h] canvas px; null = chat not reported

    // Phase-5 world map (floating window): open-state + control rects from the published map snapshot.
    // While open, a one-finger drag that STARTS inside the window pans the MAP (shared panWorldMap — finger
    // deltas in canvas px; synthetic drags don't pan, probe-proven), taps inside are PRECISE clicks (close X,
    // zoom, POIs — no walk ring), and a search-rect tap raises the IME manually (the map search never flips
    // the engine INPUT_TYPE). The engine HUD shoves while open are all shared-side.
    private var mapOpen = false
    private var mapRectCanvas: IntArray? = null // pannable map display [x,y,w,h] (canvas px)
    private var minimapRectCanvas: IntArray? = null // relocated minimap+orb cluster [x,y,w,h] canvas px; null = not relocated
    private var mapSearchCanvas: IntArray? = null // search field rect

    // The window CHROME (close X, zoom, search bar) extends OUTSIDE the pannable display rect — the
    // snapshot publishes each control's rect separately and taps on them must also route precise.
    private var mapCloseCanvas: IntArray? = null
    private var mapZoomInCanvas: IntArray? = null
    private var mapZoomOutCanvas: IntArray? = null

    // Fullscreen map: the outer map-WINDOW rect (canvas px) the SurfaceView is stretched to fill while the map
    // is open, so only the map shows edge-to-edge (the engine caps the window at a structural reserve, leaving
    // scene around it — we scale that gap out of view). null = no transform applied; lastMapWindow detects change.
    private var mapWindowCanvas: IntArray? = null
    private var lastMapWindowApplied: IntArray? = null

    // Scrollable map sub-panels: the KEY (legend) list, and the surface MAPLIST dropdown when open. A swipe that
    // STARTS inside one scrolls it (shared scrollMapPanel) instead of panning the map.
    private var mapKeyCanvas: IntArray? = null
    private var mapMaplistCanvas: IntArray? = null
    private var mapScrolling = false
    private var mapScrollAccum = 0f
    private var mapPanning = false
    private var mapPanAccumX = 0f
    private var mapPanAccumY = 0f

    // FIX-4 inventory item-drag: a one-finger drag that STARTS inside the inventory grid drags the item (touch
    // PRESS->DRAGGED->RELEASE) instead of rotating the camera. invRectCanvas = the live inventory bounds (canvas
    // px) from the chrome snapshot; itemDragLast = the last valid drag point, so a release in the letterbox still
    // closes the engine WidgetDrag (no stuck held item).
    private var invRectCanvas: IntArray? = null
    private var itemDragging = false
    private var itemDragLastX = 0
    private var itemDragLastY = 0

    // DRAG-1b: the engine's other drag-to-reorder panes (Prayer/Spellbook/Bank) as canvas-px rects from the chrome
    // snapshot. A drag that STARTS inside any of these routes through the same engine WidgetDrag stream as the
    // inventory (touch PRESS->DRAGGED->RELEASE) so prayers/spells/bank items reorder instead of rotating the camera.
    private var reorderRectsCanvas: List<IntArray> = emptyList()
    private var mapSearchKeyboard = false // transient ⌨-like latch while the map search is in use
    private var mapWasSearching = false // FIX-14: engine WORLDMAP_SEARCHING edge (drop the latch on commit)
    private var lastMapSnapshot = ""

    // A1 per-frame poll state (driven by Choreographer).
    private var vibrator: Vibrator? = null
    private var lastTapSeq = 0

    // Phase-1 click ring: every world tap spawns a ring whose colour is decided by ENGINE TRUTH, not at touch
    // time — the engine-resolved tap machine settles ~80–160 ms after the tap, so showing instantly would
    // misclassify (the iOS lesson). On tap we snapshot interactTapSeq; the Choreographer poll then resolves:
    // seq advanced within the grace window → red (interaction), grace expired → yellow (walk).
    private lateinit var tapRing: TapRingView
    private var ringPending = false
    private var ringX = 0f
    private var ringY = 0f
    private var ringArmedAtMs = 0L
    private var ringBaseSeq = 0
    private var ringKindBaseSeq = 0 // tapKindSeq at arm time; a bump past it resolves the tap's kind
    private var keyboardShown = false
    private var imeWasShown = false // last frame's ACTUAL ime visibility — to spot a user-driven dismiss
    private var manualKeyboard = false // ⌨ toggle: hold the soft keyboard up with no engine text field open
    private var keyboardToggleBtn: Button? = null // the ⌨ button, so a dismiss can reset its on/off alpha

    // FIX-11: a rendered Swing panel's text field is focused and its OWN Compose mirror field owns the soft
    // keyboard — the per-frame poll must NOT raise GameInputView (steals focus) or dismiss the IME (kills it).
    @Volatile var textActivePanel = false
    private var shiftHeld = false // ⇧ latch: synthetic VK_SHIFT held (AP-2a Finding 12)
    private var ctrlHeld = false // ⌃ latch: synthetic VK_CONTROL held (mirror of shift)
    private var frameCallback: Choreographer.FrameCallback? = null

    // PERF-BATTERY-NETWORK-01: true while backgrounded (onStop..onStart) — the Choreographer UI poll is removed
    // and the render thread idles at 4 Hz. Gates onStart's re-post so the first onStart (right after onCreate's
    // startInputPolling) doesn't double-post the callback.
    private var pollingPaused = false

    // User-defined hotkey buttons: a HUD strip the user populates from the Hotkeys screen (persisted in PREFS_HOTKEYS).
    private var hotkeyRow: LinearLayout? = null // the button container (repopulated on change)
    private var hotkeyStrip: HorizontalScrollView? = null // scroll host (GONE when no hotkeys are active)
    private var hotkeyPrefsListener: android.content.SharedPreferences.OnSharedPreferenceChangeListener? = null

    // UX-XCUT-01: the only release-visible HUD controls. Held as fields so the root window-inset listener can
    // re-apply the safe-area margin (bottom gesture inset + landscape cutout) to them on every inset change /
    // configuration change. Their BASE margins are captured at build so the inset is ADDED, never replaced.
    private var devBar: LinearLayout? = null
    private var launcherHandle: Button? = null
    private var devBarBaseLeft = 0
    private var devBarBaseBottom = 0
    private var hotkeyBaseLeft = 0
    private var hotkeyBaseBottom = 0
    private var handleBaseBottom = 0

    // AP-2a Findings 9/25: a low-frequency daemon that drains the shared notification + link queues (off the UI
    // thread — these calls daemon-attach to HotSpot). nextNotification → system shade; nextLink → browser.
    @Volatile private var drainRun = false
    private var notifId = 1000

    // A6 native chrome (OSRS-mobile 2-col tab grid; the engine stones are hidden and this grid replaces them).
    private lateinit var chromeOverlay: ChromeOverlayView
    private var chromeUiLogged = false

    // Runtime tab/stone/chat sprites pulled from the live cache (HudVeneerBridge.tabSprites) once after login —
    // so the native chrome composites the real OSRS art with nothing bundled. Latched once applied this session.
    private var tabSpritesApplied = false

    // Bug 8: a fail-open login-transition latch. On a FRESH login the engine hasn't finished its first resizable
    // layout for a frame or two, so engaging chrome immediately flashes the half-built grid/chat tabs over the
    // "Welcome to Gielinor" frame. We suppress chrome for a bounded window after the LOGIN_SCREEN→LOGGED_IN edge,
    // then engage REGARDLESS. `sawLoginScreen` arms only off a genuine login (the snapshot's loginScreen flag —
    // an in-game LOADING/teleport blip never passes through the login screen, so chrome keeps engaged there);
    // `loginTransitionUntilMs` is a wall-clock deadline that self-clears, so a stuck/absent signal can never hide
    // chrome for longer than the window. Fail-open by construction.
    private var sawLoginScreen = false
    private var loginTransitionUntilMs = 0L

    // PERF-FRAME-PACING-01: signature of every dynamic input updateChrome() reads; an identical signature (with no
    // timed transition pending) lets the whole per-frame parse + native-veneer cascade short-circuit. "" forces the
    // first frame through.
    private var lastChromeSig = ""
    private var lastStonesHidden: Boolean? = null // desired HudVeneer hide-stones state (send only on change)
    private var lastSideX = Int.MIN_VALUE // last side-panel relocation sent (send only on change)
    private var lastSideY = Int.MIN_VALUE
    private var lastChatX = Int.MIN_VALUE // last chat-at-top relocation sent (send only on change)
    private var lastChatY = Int.MIN_VALUE

    // A3 enlarged native chat-tab veneer (bigger touch targets over the relocated engine chat row).
    private lateinit var chatTabOverlay: ChatPillView

    // UI-4: opaque NPC-dialogue parchment over the (transparent) engine dialogue.
    private lateinit var dialogueOverlay: DialogueView

    // FIX-9: a native "Reconnecting…" scrim shown while the headless auto-reconnect recovers a dropped session.
    private lateinit var reconnectOverlay: ReconnectingOverlayView

    // UX-LOGIN-01: a native "Session expired — sign in again" card shown when the login machine gives up (the
    // chrome snapshot's "sessionExpired" flag); its button re-runs the on-device Jagex login (LoginActivity).
    private lateinit var sessionExpiredOverlay: SessionExpiredOverlayView

    // FATAL-1: a native card for engine-fatal stops (the snapshot's "fatalError"/"fatalCode" — js5connect
    // after a weekly OSRS update, js5io, crash). Terminal; its button relaunches the process.
    private lateinit var fatalErrorOverlay: FatalErrorOverlayView

    // PERF-MEMORY-THERMAL-01: throttles the 117HD scene scale under thermal pressure (armed only on a 117HD boot).
    private var thermalGovernor: ThermalGovernor? = null

    // UX-ONBOARD-01: a branded cold-start splash shown immediately in onCreate over the black SurfaceView, until
    // the engine renders its first real frame (or a real login state lands) / a generous timeout. Bounded so a
    // missed signal can never leave it covering the game.
    private lateinit var splashOverlay: SplashOverlayView
    private var splashDeadlineMs = 0L

    // UX-DISCRETE-01 / ENH-B06: a native "Hopping…" scrim over the relog-based world hop (logout→relogin). Driven
    // purely Android-side: armed from the hop trigger sites, hidden on the next loggedIn edge after the hop or a
    // bounded timeout. `hopWasLoggedIn` tracks the pre-hop loggedIn state so we hide on the rising edge BACK to
    // in-world (the relog logs out first, then back in); `hopDeadlineMs` is the wall-clock failsafe.
    private lateinit var hoppingOverlay: HoppingOverlayView
    private var hopArmed = false
    private var hopDeadlineMs = 0L
    private var hopSawLoggedOut = false

    // DEBUG-only force for the reconnect overlay (real network drops are hard to repro over Wi-Fi adb). null =
    // follow the live snapshot; true/false = force shown/hidden. Driven by the SET_RECONNECT_OVERLAY broadcast.
    @Volatile private var reconnectTestOverride: Boolean? = null

    // UX-LOGIN-01: DEBUG-only force for the session-expired overlay (autologin exhaustion is hard to repro without
    // burning a session). null = follow the live snapshot; driven by the SET_SESSION_EXPIRED_OVERLAY broadcast.
    @Volatile private var sessionExpiredTestOverride: Boolean? = null

    // Phase-4: native-tracked chat collapse state (the shared side shoves the live widget off-canvas; this
    // mirrors what we last asked for — the engine never collapses on its own).
    private var chatCollapsed = false

    // Auto-open: while an engine-rendered dialogue is up we un-collapse the chat (a collapsed chat hides the engine
    // tabs, which suppresses the dialogue raster); these track the edge + whether WE forced it open so we can restore.
    private var dialogueWasActive = false
    private var savedCollapsedForDialogue = false
    private var chatTabsLogged = false
    private var lastChatRowH = Int.MIN_VALUE // last setChatTabRowHeight sent (send only on change)
    private var lastMmX = Int.MIN_VALUE // last minimap relocation sent (send only on change)
    private var lastMmY = Int.MIN_VALUE

    // On-screen overlay-layout editor (drag movable overlays directly on the live game).
    private lateinit var overlayEditView: OverlayEditView

    @Volatile private var overlayEditMode = false
    private var overlayPollThread: Thread? = null

    // A2 press-and-peek menu state.
    private lateinit var menuOverlay: MenuOverlayView
    private var menuActive = false // the long-press has claimed this gesture
    private var menuBuilding = false // waiting for the engine menu to land in the snapshot
    private var menuTouchActive = false // finger still down
    private var menuAnchorX = 0f
    private var menuAnchorY = 0f
    private var menuCurX = 0f
    private var menuCurY = 0f
    private var menuHandRight = false
    private var menuOpenAtNanos = 0L
    private var menuHighlight = -1
    private var emX = 0 // engine menu box (game-canvas coords) from the snapshot
    private var emY = 0
    private var emW = 0
    private var emCount = 0

    // FIX-10b tap-mode (submenu drill-in): a persistent, tap-to-select menu used when an entry has a submenu
    // (Menu Entry Swapper swap lists) or ⇧ is latched. menuDrillParent = the top-level engine index we drilled
    // into (-1 = top level); menuTopEntries = the saved top level for '‹ Back'; menuTapArmed = the opening
    // long-press has been released (so subsequent discrete taps drive selection, not the release itself).
    private var menuTapMode = false
    private var menuTapArmed = false
    private var menuDrillParent = -1
    private var menuTopEntries: List<MenuOverlayView.Entry> = emptyList()

    companion object {
        private const val TAG = "MainActivity"
        private val booted = AtomicBoolean(false)

        // World-map pan speed: multiplier on the grab-the-map finger delta. 1.0 = strict 1:1 (feels slow once the
        // map is magnified to fullscreen); >1 covers more ground per swipe. Tune to taste.
        private const val MAP_PAN_SPEED = 2.5f

        // Engine canvas dimensions (set once at the boot HeadlessResize below; stable in-world). The overlay
        // free-drag UI reads these to map a drag-pad fraction → canvas pixels for OverlayBridge.setOverlayPreferredLocation.
        @Volatile var canvasW = 0

        @Volatile var canvasH = 0

        // ENH-B06: a static hook the native World Switcher Composable (in PluginPanel's Compose tree, with no
        // back-reference to the activity) calls to arm the "Hopping…" scrim from its row-tap / Prev-Next hop. The
        // live activity installs it in onCreate and clears it in onDestroy; null = no scrim (android-only, no
        // shared-contract change). [label] is the card text ("Hopping to world N…" or "Switching worlds…").
        @Volatile var armHopScrimHook: ((label: String) -> Unit)? = null

        private const val NOTIF_CHANNEL = "runelite_game" // audible (IMPORTANCE_DEFAULT)
        private const val NOTIF_CHANNEL_SILENT = "runelite_game_silent" // AP-2: no sound (IMPORTANCE_LOW)
        private const val REQ_POST_NOTIFICATIONS = 7001

        // Bug 8: how long after a fresh login to keep native chrome disengaged so the engine can finish its first
        // resizable layout (the welcome-frame flash window). ~1.2s of LOGGED_IN frames is when the engine's chrome
        // widgets are reliably built (cf. MobileChromeBridge.VERDICT_FRAME=60); 1500ms gives a little headroom.
        private const val LOGIN_TRANSITION_MS = 1500L

        // UX-ONBOARD-01: hard cap on the cold-start splash. Generous — first-install unpack (~30 s) + JVM boot +
        // first frame; the splash normally dismisses on the first frame well before this. Failsafe only.
        private const val SPLASH_TIMEOUT_MS = 60_000L

        // UX-DISCRETE-01 / ENH-B06: hard cap on the "Hopping…" scrim. The relog hop is ~8 s of login chrome; this
        // leaves headroom yet guarantees the scrim never sticks if the loggedIn-edge signal is missed.
        private const val HOP_TIMEOUT_MS = 12_000L

        // AWT virtual-key codes (java.awt.event.KeyEvent) the engine's onKeyStroke expects.
        private const val VK_BACK_SPACE = 8
        private const val VK_ENTER = 10
        private const val VK_ESCAPE = 27
        private const val VK_SPACE = 32
        private const val VK_LEFT = 37
        private const val VK_UP = 38
        private const val VK_RIGHT = 39
        private const val VK_DOWN = 40

        // Minimap-orb touch veneer: the orb keys published by HudVeneerBridge.getOrbSnapshot, and the canvas-px
        // margin each orb's tap zone is inflated by (orbs render ~25px; this enlarges the effective finger target).
        private val ORB_KEYS = arrayOf("hp", "prayer", "run", "spec", "store", "worldmap", "wiki")
        private const val ORB_TAP_PAD = 10

        // User-defined hotkey buttons: the active set the Hotkeys screen writes + the HUD strip reads. Each entry
        // is "groupkeylabel" (SOH-delimited); fire is by (group,key) so a rebind in the plugin reflects.
        const val PREFS_HOTKEYS = "hotkeys"
        const val PREF_HOTKEYS_ACTIVE = "active"

        // Bug 4: the WorldHopper quick-hop keybinds. These mirror RuneLite's WorldHopperConfig @ConfigGroup
        // ("worldhopper") + @ConfigItem keyNames ("nextKey"/"previousKey") — stable config API (renaming them would
        // break every user's saved keybinds). The HUD hotkey strip reroutes these two through the relog hop path
        // (worldHopDirection) instead of firing the plugin keybind, which is the inert in-game hop headless.
        private const val WORLDHOPPER_GROUP = "worldhopper"
        private const val WORLDHOPPER_NEXT_KEY = "nextKey"
        private const val WORLDHOPPER_PREV_KEY = "previousKey"

        // Pinch-to-wheel: geometric step a scale ratio must cross to emit one wheel notch.
        private const val PINCH_STEP = 1.08f

        // Click-ring truth grace: how long after a tap we wait for interactTapSeq before calling it a walk.
        // Matches iOS (250 ms). The old 600 ms was tuned for a slow emulator EDT (interaction at +535 ms), but on
        // real hardware the settle gate stabilises in 3–6 frames and an interaction bumps interactTapSeq at
        // ~65–140 ms (touch-diag measured on a Pixel 7a) — so 600 ms just made every WALK ring appear a visible
        // ~600 ms after the tap, reading as input lag. 250 ms catches real interactions with margin and the walk
        // ring is prompt; a pathologically slow interaction (rare MAX_SETTLE) at worst flashes the wrong colour.
        private const val RING_GRACE_MS = 250L

        // Tap-KIND truth (mirrors JavaBridge.TAP_KIND_*): the engine-resolved tap hit nothing, a walk, a scene
        // entity, or an interface widget. The shell rings only for WALK/SCENE and borders WIDGET.
        @Suppress("UnusedPrivateProperty") // 0=hit-nothing: kept to mirror the engine's full TAP_KIND_* enum
        private const val TAP_KIND_NONE = 0
        private const val TAP_KIND_WALK = 1
        private const val TAP_KIND_SCENE = 2
        private const val TAP_KIND_WIDGET = 3

        // OSRS engine menu geometry: 19px "Choose Option" header, 15px per row. A native row k commits to the
        // engine row centre (menuX + menuW/2, menuY + 19 + k*15 + 7) so plugin onClick/Menu-Entry-Swapper hold.
        private const val MENU_HEADER_PX = 19
        private const val MENU_ROW_PX = 15
    }

    @SuppressLint("ClickableViewAccessibility")
    // FIX-13: debug-only live 117HD config flip, for a thermal-fair fps A/B (apply both presets seconds apart at
    // one thermal/crowd/camera state — no reboot). All three keys apply live via HdPlugin.onConfigChanged.
    //   adb shell am broadcast -a dev.audaro.runemobile.SET_HD_CONFIG --es preset new   (85/8/30)
    //   adb shell am broadcast -a dev.audaro.runemobile.SET_HD_CONFIG --es preset base  (100/16/30, RLHD defaults)
    //   adb shell am broadcast -a dev.audaro.runemobile.SET_HD_CONFIG --es key drawDistance --es value 20
    //   adb shell am broadcast -a dev.audaro.runemobile.SET_HD_CONFIG --ei sceneResolutionScale 90  (generic per-key;
    //     this is the path the MCP android_set_hd_config knob drives — any non-reserved extra is applied as an hd key)
    private var hdConfigReceiver: BroadcastReceiver? = null

    // FIX-9: debug-only force for the "Reconnecting…" overlay (a real in-session drop is hard to repro over
    // Wi-Fi adb, which a network toggle also kills) — lets a screencap verify the scrim renders.
    //   adb shell am broadcast -a dev.audaro.runemobile.SET_RECONNECT_OVERLAY --es show on     (force shown)
    //   adb shell am broadcast -a dev.audaro.runemobile.SET_RECONNECT_OVERLAY --es show off    (force hidden)
    //   adb shell am broadcast -a dev.audaro.runemobile.SET_RECONNECT_OVERLAY --es show clear  (follow live state)
    private var reconnectTestReceiver: BroadcastReceiver? = null
    private var sessionExpiredTestReceiver: BroadcastReceiver? = null
    private var thermalTestReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator

        if (BuildConfig.DEBUG) {
            hdConfigReceiver =
                object : BroadcastReceiver() {
                    override fun onReceive(
                        ctx: Context?,
                        intent: Intent?,
                    ) {
                        intent ?: return
                        val pairs: List<Pair<String, String>> =
                            when (intent.getStringExtra("preset")) {
                                "new" -> {
                                    listOf("sceneResolutionScale" to "85", "anisotropicFilteringLevel" to "8", "drawDistance" to "30")
                                }

                                "base" -> {
                                    listOf("sceneResolutionScale" to "100", "anisotropicFilteringLevel" to "16", "drawDistance" to "30")
                                }

                                else -> {
                                    val k = intent.getStringExtra("key")
                                    val v = intent.getStringExtra("value")
                                    if (k != null && v != null) {
                                        listOf(k to v)
                                    } else {
                                        // Generic per-key path: apply every non-reserved extra as an hd config key. This is
                                        // what the MCP android_set_hd_config knob uses (it sends --ei sceneResolutionScale /
                                        // anisotropicFilteringLevel); --es/--ez per key work too. Previously these extras were
                                        // silently ignored (the receiver only read preset/key/value) — the dead A/B knob.
                                        val reserved = setOf("preset", "key", "value")
                                        intent.extras
                                            ?.keySet()
                                            .orEmpty()
                                            .filter { it !in reserved }
                                            .mapNotNull { key ->
                                                intent.extras
                                                    ?.get(key)
                                                    ?.toString()
                                                    ?.let { key to it }
                                            }
                                    }
                                }
                            }
                        if (pairs.isEmpty()) {
                            Log.w(
                                TAG,
                                "SET_HD_CONFIG: need --es preset new|base, --es key K --es value V, or per-key extras (e.g. --ei sceneResolutionScale 90)",
                            )
                            return
                        }
                        JvmLauncher.onBridgeTouch { pairs.forEach { (k, v) -> JvmLauncher.setConfig("hd", k, v) } }
                        Log.i(TAG, "SET_HD_CONFIG applied live: $pairs")
                    }
                }
            ContextCompat.registerReceiver(
                this,
                hdConfigReceiver,
                IntentFilter("dev.audaro.runemobile.SET_HD_CONFIG"),
                ContextCompat.RECEIVER_EXPORTED,
            )
            reconnectTestReceiver =
                object : BroadcastReceiver() {
                    override fun onReceive(
                        ctx: Context?,
                        intent: Intent?,
                    ) {
                        reconnectTestOverride =
                            when (intent?.getStringExtra("show")) {
                                "on" -> true
                                "off" -> false
                                else -> null // "clear" / anything else -> follow the live snapshot
                            }
                        Log.i(TAG, "SET_RECONNECT_OVERLAY override=$reconnectTestOverride")
                    }
                }
            ContextCompat.registerReceiver(
                this,
                reconnectTestReceiver,
                IntentFilter("dev.audaro.runemobile.SET_RECONNECT_OVERLAY"),
                ContextCompat.RECEIVER_EXPORTED,
            )
            sessionExpiredTestReceiver =
                object : BroadcastReceiver() {
                    override fun onReceive(
                        ctx: Context?,
                        intent: Intent?,
                    ) {
                        sessionExpiredTestOverride =
                            when (intent?.getStringExtra("show")) {
                                "on" -> true
                                "off" -> false
                                else -> null // "clear" / anything else -> follow the live snapshot
                            }
                        Log.i(TAG, "SET_SESSION_EXPIRED_OVERLAY override=$sessionExpiredTestOverride")
                    }
                }
            ContextCompat.registerReceiver(
                this,
                sessionExpiredTestReceiver,
                IntentFilter("dev.audaro.runemobile.SET_SESSION_EXPIRED_OVERLAY"),
                ContextCompat.RECEIVER_EXPORTED,
            )
            // PERF-MEMORY-THERMAL-01: force a thermal status for verification (real thermal pressure is hard to induce
            // on demand). `--ei level N` injects status 0..6 (NONE..SHUTDOWN); level<0 or omitted follows the sensor.
            thermalTestReceiver =
                object : BroadcastReceiver() {
                    override fun onReceive(
                        ctx: Context?,
                        intent: Intent?,
                    ) {
                        val level = intent?.getIntExtra("level", -1) ?: -1
                        Log.i(TAG, "SET_THERMAL_STATUS level=$level")
                        thermalGovernor?.forceStatus(level)
                    }
                }
            ContextCompat.registerReceiver(
                this,
                thermalTestReceiver,
                IntentFilter("dev.audaro.runemobile.SET_THERMAL_STATUS"),
                ContextCompat.RECEIVER_EXPORTED,
            )
        }

        // AP-2a Finding 9: a notification channel for in-game alerts (idle, level-up, etc.) + the runtime
        // POST_NOTIFICATIONS prompt on API 33+ (silently granted below that). The drain loop delivers to it.
        setupNotifications()

        // SurfaceView for the live game frame; a tiny hidden input view to host the soft keyboard's
        // InputConnection (the SurfaceView itself can't be a text editor). FrameLayout stacks them.
        surfaceView = SurfaceView(this)
        keyboardView = GameInputView(this)
        menuOverlay = MenuOverlayView(this)
        tapRing = TapRingView(this)
        // A6 native chrome: the OSRS-mobile 2-col tab grid at the bottom-right. The engine's own 14 tab stones
        // are HIDDEN (HudVeneerBridge.setStonesHidden, driven from updateChrome) so these native cells ARE the
        // tabs; a tap opens the tab by replaying the engine stone's op script (openTab) — works while hidden, so
        // the engine + plugins stay authoritative and no widget is moved or covered (the proven iOS layout).
        overlayEditView =
            OverlayEditView(this).apply {
                visibility = View.GONE
                onDrop = { name, x, y ->
                    Log.i(TAG, "overlay-edit: drop $name -> ($x,$y)")
                    JvmLauncher.onBridgeTouch {
                        JvmLauncher.overlaySetLocation(name, x, y)
                        JvmLauncher.flushConfig()
                    }
                }
                onResetAll = {
                    Log.i(TAG, "overlay-edit: reset all")
                    JvmLauncher.onBridgeTouch {
                        for (b in overlayEditView.currentNames()) JvmLauncher.overlayReset(b)
                        JvmLauncher.flushConfig()
                    }
                }
                onDone = { exitOverlayEditMode() }
            }
        chromeOverlay = ChromeOverlayView(this)
        chromeOverlay.onTabTap = { idx ->
            Log.i(TAG, "a6: native tab $idx tap -> openTab")
            JvmLauncher.onBridgeTouch { JvmLauncher.openTab(idx) } // off the UI thread (daemon-attaches to HotSpot)
        }
        // Phase-4 chat channel PILL (replaces the A3 enlarged tab row as the chat control; iOS parity).
        // Quick tap = collapse/expand (shared shove-off-canvas); hold 0.15s = chips fan out; drag + lift =
        // switch channel (op-script replay, works collapsed); pull DOWN past a filterable chip = its engine
        // filter menu via the shared press-and-peek overlay.
        chatTabOverlay = ChatPillView(this)
        // Apply a cached runtime sprite set immediately (later boots) so the grid/chat show real art before the
        // post-login capture lands; the live capture in updateChrome refreshes + re-caches it.
        TabSprites.parse(TabSprites.cached(filesDir))?.let {
            chromeOverlay.setSprites(it)
            chatTabOverlay.setSprites(it)
        }
        chatTabOverlay.onTabTap = { k ->
            // UI-3 (iOS onChatTabButton): tap the ACTIVE tab to collapse the message area; tap any other to
            // switch the channel (auto-expanding a collapsed chat first).
            if (!chatCollapsed && k == chatTabOverlay.currentTab) {
                chatCollapsed = true
                Log.i(TAG, "ui3: tab $k (active) -> collapse")
                JvmLauncher.onBridgeTouch { JvmLauncher.setChatCollapsed(true) }
            } else {
                chatTabOverlay.markOptimistic(k) // instant highlight
                if (chatCollapsed) {
                    chatCollapsed = false
                    JvmLauncher.onBridgeTouch {
                        JvmLauncher.setChatCollapsed(false)
                        JvmLauncher.switchChatTab(k)
                    }
                } else {
                    JvmLauncher.onBridgeTouch { JvmLauncher.switchChatTab(k) }
                }
                Log.i(TAG, "ui3: tab $k -> switch")
            }
        }
        chatTabOverlay.onFilterOpen = { _, ecx, ecy, vx, vy ->
            if (chatCollapsed) {
                // The collapsed chat's filter button sits off-canvas (y≈3000) — a right-click there opens
                // nothing. Expand first; the engine restores the widget next tick, the snapshot follows, and a
                // later move (finger still below the chip) passes the on-canvas gate below. iOS 69ed4cf9e.
                chatCollapsed = false
                JvmLauncher.onBridgeTouch { JvmLauncher.setChatCollapsed(false) }
                Log.i(TAG, "p4: pull-down on collapsed chat -> expand first")
                false
            } else if (ecx >= 0 && ecy in 0 until JvmLauncher.frameHeight()) {
                beginChatFilterMenu(ecx, ecy, vx, vy)
                true
            } else {
                false // engine button not on-canvas yet (expand still landing) — retried each move
            }
        }
        chatTabOverlay.onFilterMove = { vx, vy ->
            menuCurX = vx
            menuCurY = vy
            if (menuActive && menuOverlay.isActive) updateMenuHighlight(vx, vy)
        }
        chatTabOverlay.onFilterEnd = { cancelled ->
            menuTouchActive = false
            if (cancelled) {
                if (menuActive) cancelMenu()
            } else if (menuOverlay.isActive) {
                commitMenuSelection()
            }
        }
        chatTabOverlay.onHaptic = { vibrateTick() }
        // UI-4: the opaque dialogue parchment. A continue tap precisely clicks the engine CONTINUE widget (robust
        // vs the space-to-continue setting); an option row posts its digit.
        dialogueOverlay = DialogueView(this)
        dialogueOverlay.onContinue = { cx, cy ->
            // Click the engine CONTINUE widget when we have its bounds; otherwise advance with a real SPACE
            // KEY event — a "click here to continue" box listens for the keypress, NOT a typed character
            // (text(" ") never advanced it), so this is the reliable fallback when the widget bounds are absent.
            if (cx >= 0 && cy >= 0) {
                JvmLauncher.onBridgeTouch { JvmLauncher.clickPrecise(cx, cy, 1) }
            } else {
                JvmLauncher.onBridgeTouch { JvmLauncher.keyStroke(VK_SPACE) }
            }
        }
        dialogueOverlay.onOption = { digit -> JvmLauncher.onBridgeTouch { JvmLauncher.text(digit.toString()) } }
        // FIX-9: the "Reconnecting…" scrim (non-interactive; driven from updateChrome's snapshot).
        reconnectOverlay = ReconnectingOverlayView(this)
        // UX-LOGIN-01: the "Session expired" card (interactive; driven from updateChrome's sessionExpired flag).
        sessionExpiredOverlay =
            SessionExpiredOverlayView(this).apply {
                onSignIn = { startActivity(Intent(this@MainActivity, LoginActivity::class.java)) }
            }
        // FATAL-1: the engine-fatal card (interactive; driven from updateChrome's fatalError flag). Restart =
        // the same clean-boot relaunch the renderer restarts use (the embedded VM is one-per-process).
        fatalErrorOverlay =
            FatalErrorOverlayView(this).apply {
                onRestart = {
                    val i = packageManager.getLaunchIntentForPackage(packageName)
                    i?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    startActivity(i)
                    finishAffinity()
                    Runtime.getRuntime().exit(0)
                }
            }
        // UX-DISCRETE-01 / ENH-B06: the "Hopping…" scrim (non-interactive; armed at the hop trigger sites, hidden
        // from updateChrome's loggedIn signal / a timeout).
        hoppingOverlay = HoppingOverlayView(this)
        // UX-ONBOARD-01: the cold-start splash (non-interactive; starts ACTIVE so it covers the black boot screen
        // the moment setContentView runs). Dismissed from updateChrome on the first real frame / a timeout.
        splashOverlay = SplashOverlayView(this)
        splashDeadlineMs = SystemClock.uptimeMillis() + SPLASH_TIMEOUT_MS
        // ENH-B06: let the native World Switcher Composable arm the "Hopping…" scrim from its hop taps.
        armHopScrimHook = { label -> armHopScrim(label) }
        // A4 plugin UI: a full-screen Compose panel (GONE until opened) + a small launcher button. The panel
        // is a data screen (Compose); the live game overlays above stay classic Views (hybrid, §4.2).
        // §4 increment 3: the launcher is a transparent-host PEEK/EXPAND sheet. Material Buttons (the handle +
        // devBar) carry a default elevation that would float them ABOVE a same-Z ComposeView regardless of
        // add-order, so give the panel a large elevation to keep its sheet/scrim on top (no shadow — the host
        // has no opaque outline). GONE until opened.
        val pluginPanel =
            ComposeView(this).apply {
                visibility = View.GONE
                elevation = 200f
            }
        // Compact, low-profile dev affordances (single-glyph): kill the Material 88dp min width + slim padding so
        // the three sit in a small bottom-left cluster instead of three chunky buttons across the HUD.
        val devD = resources.displayMetrics.density

        fun devButton(glyph: String) =
            Button(this).apply {
                text = glyph
                textSize = 16f
                setTextColor(0xFFFFFFFF.toInt())
                minWidth = 0
                minHeight = 0
                // A proper touch target (Material min 40dp) + a rounded translucent chip so the glyphs read as
                // tappable controls rather than tiny text (Finding: the bottom-left tools were too small to hit).
                val touch = (40 * devD).toInt()
                minimumWidth = touch
                minimumHeight = touch
                val px = (12 * devD).toInt()
                setPadding(px, (px * 0.6f).toInt(), px, (px * 0.6f).toInt())
                background =
                    android.graphics.drawable.GradientDrawable().apply {
                        cornerRadius = 12f * devD
                        setColor(0x66000000)
                        setStroke((1 * devD).toInt(), 0x33FFFFFF)
                    }
                alpha = 0.7f
                layoutParams =
                    LinearLayout
                        .LayoutParams(
                            LinearLayout.LayoutParams.WRAP_CONTENT,
                            LinearLayout.LayoutParams.WRAP_CONTENT,
                        ).apply { marginEnd = (6 * devD).toInt() }
            }

        // Swap a sticky modifier between its idle and latched look — a clear filled/accented "active" state.
        // (Finding: the sticky-Shift latch gave no indication it was on; alpha alone was too subtle.)
        fun setModActive(
            b: Button,
            on: Boolean,
        ) {
            b.alpha = if (on) 1f else 0.7f
            b.background =
                android.graphics.drawable.GradientDrawable().apply {
                    cornerRadius = 12f * devD
                    setColor(if (on) 0xCC2AA189.toInt() else 0x66000000)
                    setStroke(((if (on) 2 else 1) * devD).toInt(), if (on) 0xFF3FE0BC.toInt() else 0x33FFFFFF)
                }
            // UX-XCUT-04: the visual latch (filled/accented) is invisible to TalkBack, so mirror it as an a11y
            // stateDescription ("on"/"off") — the spoken counterpart of the Compose chips' "117HD, selected".
            ViewCompat.setStateDescription(b, if (on) "on" else "off")
        }

        // §4 right-bar redesign (increment 1): open the plugin launcher. The dismiss-flush (§4) persists any
        // config edit made in the panel even when it's closed without backgrounding.
        fun openLauncher() {
            pluginPanel.setContent {
                PluginPanel(
                    onClose = {
                        pluginPanel.visibility = View.GONE
                        // Dispose so the sheet's BackHandler unregisters — else BACK in-game would be swallowed.
                        pluginPanel.disposeComposition()
                        JvmLauncher.onBridge { JvmLauncher.flushConfig() }
                    },
                    rendererPref = rendererPref(),
                    onRendererSelect = { setRendererPref(it) },
                    // §4 cutover: the former devBar toolbar glyphs, now fixed launcher tiles (audit §4.3/#9).
                    onScreenshot = { saveScreenshot() },
                    onScreenshotLongPress = { toggleAutoScreenshots() },
                    onAccount = { startActivity(Intent(this@MainActivity, LoginActivity::class.java)) },
                    onLogout = { confirmLogout() },
                    // RuneLite's Discord invite (runelite.properties runelite.discord.invite) — Discord had no
                    // Android home before; publishLink routes it through the shared link path to the browser.
                    onDiscord = { JvmLauncher.onBridge { JvmLauncher.publishLink("https://discord.gg/ArdAhnN") } },
                    // FIX-11: a panel's mirror text field is focused -> the per-frame poll must leave the IME alone.
                    onPanelTextActive = { active -> textActivePanel = active },
                    // Overlay layout is edited ON the live game now: close the panel + enter the on-screen drag mode.
                    onEnterOverlayEdit = { enterOverlayEditMode() },
                )
            }
            pluginPanel.visibility = View.VISIBLE
        }
        // The discoverable bottom-center HANDLE replaces the buried dev-cluster gear as the primary entry into
        // the launcher (audit diagnosis #1: the gear read as a disposable debug control). Tap to open; system
        // BACK closes it (wired below). Drag-up + the PEEK sheet are later increments.
        val launcherHandle =
            Button(this).apply {
                text = "≡ Plugins"
                // UX-XCUT-04: the leading ≡ glyph reads as "identical to" under TalkBack — give it a plain spoken label.
                contentDescription = "Open plugins panel"
                textSize = 12f
                isAllCaps = false
                minWidth = 0
                minimumWidth = 0
                minHeight = 0
                minimumHeight = 0
                val px = (16 * resources.displayMetrics.density).toInt()
                setPadding(px, px / 4, px, px / 4)
                setTextColor(0xFFFFFFFF.toInt())
                background =
                    android.graphics.drawable.GradientDrawable().apply {
                        cornerRadius = 100f
                        setColor(0xCC1E1E1E.toInt())
                        setStroke((1 * resources.displayMetrics.density).toInt(), 0x55FFFFFF)
                    }
                alpha = 0.85f
                setOnClickListener { openLauncher() }
            }
        // A6 A/B: toggle the native grid on/off (▦ = native tab grid + hidden stones; ▤ = raw engine stones).
        // updateChrome re-applies setStonesHidden to match, so flipping this reveals/hides the real stone row.
        val chromeButton = devButton("▦")
        // UX-XCUT-04: spoken label + latch state for the geometric glyphs (▦/▤ are silent/meaningless to TalkBack).
        chromeButton.contentDescription = "Native tab grid"
        ViewCompat.setStateDescription(chromeButton, if (chromeOverlay.railsShown) "on" else "off")
        chromeButton.setOnClickListener {
            chromeOverlay.setShown(!chromeOverlay.railsShown)
            chromeButton.text = if (chromeOverlay.railsShown) "▦" else "▤"
            ViewCompat.setStateDescription(chromeButton, if (chromeOverlay.railsShown) "on" else "off")
        }
        // §4 cutover: sign-in/switch-account (⎆), Log out (⏻) and screenshot (📷) moved out of the devBar into
        // fixed launcher tiles (audit §4.3/#9) — wired in openLauncher to startActivity/confirmLogout/
        // saveScreenshot. Only the in-play input modifiers (⌨ / ⇧) stay on the HUD cluster.
        // AP-0: manual ⌨ keyboard summon — composing public chat / PM has no engine text field for the
        // auto-raise poll to react to, so this forces the soft keyboard up (and keeps the poll from
        // instantly dismissing it). Tapping again returns to pure auto-raise. Mirrors the iOS ⌨ toggle.
        val kbButton = devButton("⌨")
        keyboardToggleBtn = kbButton
        kbButton.contentDescription = "Show keyboard"
        ViewCompat.setStateDescription(kbButton, "off")
        kbButton.setOnClickListener {
            manualKeyboard = !manualKeyboard
            setModActive(kbButton, manualKeyboard)
            Log.i(TAG, "ap0: manual keyboard ${if (manualKeyboard) "ON" else "OFF"}")
        }
        // AP-2a (Finding 12): sticky-Shift latch. The engine's shift-gated surface — "Mark" on objects/NPCs/
        // tiles, Menu Entry Swapper shift-to-customize, overlay "Configure" — only injects while shift is held.
        // Touch has no hardware shift, so this latch posts a synthetic held VK_SHIFT (shared JavaBridge.
        // setShiftHeld, iOS-device-proven): latch ON → long-press shows the shift entries → tap to commit →
        // latch OFF. The hold is multi-second with no per-frame re-assert (proven by ShiftFeedSpike).
        val shiftButton = devButton("⇧")
        shiftButton.contentDescription = "Shift key"
        ViewCompat.setStateDescription(shiftButton, "off")
        shiftButton.setOnClickListener {
            shiftHeld = !shiftHeld
            setModActive(shiftButton, shiftHeld)
            JvmLauncher.setShiftHeld(shiftHeld)
            Log.i(TAG, "ap2a: sticky-Shift ${if (shiftHeld) "HELD" else "released"}")
        }
        // DEBUG: long-press ⇧ publishes a host-origin notification through the shared bridge — a deterministic
        // end-to-end check of the Finding-9 delivery path (queue → drain → NotificationManager) without
        // needing an in-game trigger. Real engine notifications (idle/level) ride the identical path.
        if (BuildConfig.DEBUG) {
            shiftButton.setOnLongClickListener {
                JvmLauncher.onBridge {
                    JvmLauncher.publishNotification("RuneLite", "Notification delivery test")
                    JvmLauncher.publishLink("https://oldschool.runescape.wiki/")
                }
                Log.i(TAG, "ap2a: debug test notification + link published")
                true
            }
        }
        // Ctrl sticky latch — same mechanism as ⇧ (shared JavaBridge.setCtrlHeld), for the Ctrl-gated surface.
        // NOTE: a sticky-Alt latch was removed — RuneLite's drag-hotkey defaults to Alt, so holding Alt engages
        // overlay-managing mode (yellow movable-overlay boxes that swallow taps), trapping the touch user. Mobile
        // repositions overlays via the native overlay-edit flow, so Alt-drag isn't needed here.
        val ctrlButton = devButton("⌃")
        ctrlButton.alpha = 0.7f
        ctrlButton.contentDescription = "Control key"
        ViewCompat.setStateDescription(ctrlButton, "off")
        ctrlButton.setOnClickListener {
            ctrlHeld = !ctrlHeld
            setModActive(ctrlButton, ctrlHeld)
            JvmLauncher.setCtrlHeld(ctrlHeld)
            Log.i(TAG, "mod: sticky-Ctrl ${if (ctrlHeld) "HELD" else "released"}")
        }
        // Track G AG2: restart into GPU Route-C mode (force-enable the base gpu plugin, render the scene on GLES).
        val gpuButton = devButton("◆")
        gpuButton.contentDescription = "Switch to GPU renderer"
        gpuButton.setOnClickListener { restartIntoGpu() }
        // Track G AG3: restart into 117HD (routecrlhd) mode — the sideload-friendly trigger (Quest/SideQuest
        // installs can't easily push an rlhd.mode marker, but anyone can tap a button).
        val hdButton = devButton("HD")
        hdButton.contentDescription = "Switch to 117HD renderer"
        hdButton.setOnClickListener { restartIntoRlhd() }
        // Group the dev affordances into one discreet cluster pinned to the BOTTOM-LEFT — clear of the relocated
        // HUD (chat top-left, minimap top-right, tab grid + side panel bottom-right) so they don't obscure the UI.
        val devBar =
            LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                // In-play input modifiers stay on the HUD: soft keyboard + sticky-shift. (Account/Log out/Screenshot
                // moved to the launcher as fixed tiles — §4 cutover; the settings entry is the bottom-center handle.)
                // Release HUD keeps only the two in-play essentials: keyboard summon (type chat/PMs) + sticky-Shift.
                addView(kbButton)
                addView(shiftButton)
                // Developer-only tooling, hidden in release: the Ctrl/Alt sticky latches (niche modifier surface),
                // the chrome A/B raw-stones toggle, and the GPU/117HD process-restart footguns (renderer selection
                // lives in the native plugin panel — renderer-as-plugins).
                if (BuildConfig.DEBUG) {
                    addView(ctrlButton)
                    addView(chromeButton)
                    addView(gpuButton)
                    addView(hdButton)
                }
            }
        // User-defined hotkey buttons: a HUD strip the user fills from the Hotkeys screen; GONE until populated.
        val hotkeyStripView = buildHotkeyStrip()
        hotkeyStrip = hotkeyStripView
        val root =
            FrameLayout(this).apply {
                val mp = FrameLayout.LayoutParams.MATCH_PARENT
                addView(surfaceView, FrameLayout.LayoutParams(mp, mp))
                addView(tapRing, FrameLayout.LayoutParams(mp, mp)) // tap-feedback ring (over the frame, no touch)
                addView(chromeOverlay, FrameLayout.LayoutParams(mp, mp)) // native 2-col tab grid (stones hidden)
                addView(chatTabOverlay, FrameLayout.LayoutParams(mp, mp)) // enlarged native chat-tab row (top-left)
                addView(dialogueOverlay, FrameLayout.LayoutParams(mp, mp)) // UI-4: opaque NPC-dialogue parchment (above chat, below menus)
                addView(keyboardView, FrameLayout.LayoutParams(1, 1))
                addView(menuOverlay, FrameLayout.LayoutParams(mp, mp)) // drawn on top of the live frame + chrome
                addView(overlayEditView, FrameLayout.LayoutParams(mp, mp)) // on-screen overlay-layout editor (GONE unless editing)
                addView(reconnectOverlay, FrameLayout.LayoutParams(mp, mp)) // FIX-9: "Reconnecting…" scrim (non-interactive)
                addView(hoppingOverlay, FrameLayout.LayoutParams(mp, mp)) // ENH-B06: "Hopping…" scrim (non-interactive)
                addView(sessionExpiredOverlay, FrameLayout.LayoutParams(mp, mp)) // UX-LOGIN-01: "Session expired" card (interactive, top)
                addView(fatalErrorOverlay, FrameLayout.LayoutParams(mp, mp)) // FATAL-1: engine-fatal card (topmost card)
                // §4: the launcher handle sits above the game/chrome (tappable) but below the launcher sheet
                // (covered while it's open) and clears the bottom gesture inset.
                handleBaseBottom = (10 * resources.displayMetrics.density).toInt()
                addView(
                    launcherHandle,
                    FrameLayout
                        .LayoutParams(
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
                        ).apply {
                            bottomMargin = handleBaseBottom
                        },
                )
                // TOUCH-1: the pill is visually ~28dp tall — expand its HIT rect to ≥48dp square via a
                // TouchDelegate on this container (its only delegate), re-installed per layout pass so it
                // tracks the inset-driven bottomMargin moves. Visual size unchanged.
                launcherHandle.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                    val host = v.parent as? android.view.ViewGroup ?: return@addOnLayoutChangeListener
                    val r = android.graphics.Rect()
                    v.getHitRect(r)
                    val min = (48 * resources.displayMetrics.density).toInt()
                    if (r.height() < min) {
                        val add = (min - r.height()) / 2
                        r.top -= add
                        r.bottom += add
                    }
                    if (r.width() < min) {
                        val add = (min - r.width()) / 2
                        r.left -= add
                        r.right += add
                    }
                    host.touchDelegate = android.view.TouchDelegate(r, v)
                }
                devBarBaseLeft = (8 * resources.displayMetrics.density).toInt()
                devBarBaseBottom = devBarBaseLeft
                addView(
                    devBar,
                    FrameLayout
                        .LayoutParams(
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            Gravity.BOTTOM or Gravity.START,
                        ).apply {
                            leftMargin = devBarBaseLeft
                            bottomMargin = devBarBaseBottom
                        },
                )
                // User-defined hotkey buttons: bottom-left, stacked above the devBar; below the launcher sheet.
                hotkeyBaseLeft = (8 * resources.displayMetrics.density).toInt()
                hotkeyBaseBottom = (64 * resources.displayMetrics.density).toInt()
                addView(
                    hotkeyStripView,
                    FrameLayout
                        .LayoutParams(
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            FrameLayout.LayoutParams.WRAP_CONTENT,
                            Gravity.BOTTOM or Gravity.START,
                        ).apply {
                            leftMargin = hotkeyBaseLeft
                            bottomMargin = hotkeyBaseBottom
                        },
                )
                // §4 increment 3: the launcher is now a transparent-host PEEK/EXPAND bottom sheet (SheetScaffold) —
                // added LAST so its sheet/scrim draw OVER the handle + devBar (and the game composites through the
                // transparent top). GONE until opened.
                addView(pluginPanel, FrameLayout.LayoutParams(mp, mp))
                // UX-ONBOARD-01: the cold-start splash is added TOPMOST so it covers every other view (incl. a black
                // SurfaceView and any chrome) during the unpack + JVM boot + first-frame window. It self-dismisses.
                addView(splashOverlay, FrameLayout.LayoutParams(mp, mp))
            }
        setContentView(root)
        // UX-XCUT-01: keep the only release HUD controls (⌨/⇧ devBar, hotkey strip, ≡ Plugins handle) out of the
        // landscape display cutout + the bottom gesture inset. SHORT_EDGES draws the notch UNDER the frame, so
        // these fixed bottom-START / bottom-CENTER views would otherwise sit beneath it in landscape-right. A root
        // inset listener bumps their margins by systemBars∪displayCutout (LEFT for the bottom-START cluster, BOTTOM
        // for all three), recomputed on every inset delivery (incl. configuration / rotation changes). Additive:
        // the inset is added to the captured base margins, never replacing them, and 0 insets (emulator) are a no-op.
        this.devBar = devBar
        this.launcherHandle = launcherHandle
        ViewCompat.setOnApplyWindowInsetsListener(root) { _, insets ->
            applyHudControlInsets(insets)
            insets
        }
        // First pass + re-request after layout so the insets land even if they weren't dispatched before attach.
        root.requestApplyInsets()
        // User-defined hotkey buttons: populate the strip now + rebuild whenever the Hotkeys screen changes the set.
        refreshHotkeyStrip()
        hotkeyPrefsListener =
            android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, k ->
                if (k == PREF_HOTKEYS_ACTIVE) runOnUiThread { refreshHotkeyStrip() }
            }
        getSharedPreferences(PREFS_HOTKEYS, Context.MODE_PRIVATE)
            .registerOnSharedPreferenceChangeListener(hotkeyPrefsListener)
        // §4 dismiss model (d): while the launcher sheet is open the in-sheet BackHandler (PluginPanel) handles
        // BACK — it pops one level (sub-screen -> launcher) or dismisses. This activity callback is the fallback
        // for when no composition is active: dispose+hide if somehow still visible, else passthrough to normal
        // BACK so the app backgrounds.
        onBackPressedDispatcher.addCallback(this) {
            if (overlayEditMode) {
                exitOverlayEditMode() // BACK leaves the on-screen overlay editor
            } else if (mapOpen) {
                // The fullscreen map's close X is a tiny bezel-clipped target at the screen corner — BACK is the
                // reliable close. Click the close button by its CANVAS coordinate (from the snapshot), which the
                // engine resolves regardless of where the stretched view paints it; Escape as a fallback if the
                // close rect isn't published yet.
                val cc = mapCloseCanvas
                if (cc != null) {
                    JvmLauncher.clickPrecise(cc[0] + cc[2] / 2, cc[1] + cc[3] / 2, 1)
                    Log.i(TAG, "p5: BACK -> close world map via close X canvas=(${cc[0]},${cc[1]},${cc[2]},${cc[3]})")
                } else {
                    JvmLauncher.keyStroke(VK_ESCAPE)
                    Log.i(TAG, "p5: BACK -> close world map via Escape (no close rect)")
                }
            } else if (dialogueOverlay.isShowing && dialogueOverlay.dismiss()) {
                // A "click to continue" dialogue is up — BACK advances it (the reliable hardware escape hatch if
                // an empty/stale message box ever traps the tap-to-continue).
                Log.i(TAG, "ui4: BACK -> dismiss dialogue")
            } else if (pluginPanel.visibility == View.VISIBLE) {
                pluginPanel.visibility = View.GONE
                pluginPanel.disposeComposition()
                JvmLauncher.onBridge { JvmLauncher.flushConfig() }
            } else {
                isEnabled = false
                onBackPressedDispatcher.onBackPressed()
            }
        }
        // Edge-to-edge + fullscreen immersive: draw under (and hide) the status + nav bars so the game frame fills
        // the whole screen with no Android time/battery/wifi chrome. Re-asserted in onWindowFocusChanged (a dialog
        // or the soft keyboard can transiently reveal the bars). Cutout = shortEdges so a landscape notch is drawn
        // under (safe-area insets still report it, so the chat/grid placement clears it).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        // The soft keyboard OVERLAYS content — decorFitsSystemWindows(false) (set in enterImmersive) means
        // ADJUST_RESIZE never actually resizes/pans this window, so the game surface and the bottom-anchored
        // plugin sheet stay put exactly as under ADJUST_NOTHING. The difference (UX-KBD-1): RESIZE makes the
        // framework dispatch IME insets, so Compose imePadding() works where we opt in (the config editor's
        // list pads above the keyboard instead of hiding fields under it). The chat-at-top input sits at the
        // TOP of the screen, so the bottom-overlay keyboard never covers it either way.
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        enterImmersive()
        surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    JvmLauncher.setSurface(holder.surface)
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    JvmLauncher.setSurface(holder.surface)
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    JvmLauncher.setSurface(null)
                }
            },
        )

        gestures = GestureDetector(this, GestureListener())
        scaleGestures = ScaleGestureDetector(this, ScaleListener())
        // Drive gestures from the SurfaceView itself so event coords are view-local: the screen->game
        // mapping is then correct wherever the view sits in the window (status-bar inset, display cutout,
        // multi-window), not only the full-bleed emulator case.
        surfaceView.setOnTouchListener { _, event ->
            // Once a long-press has opened the menu, this gesture belongs to menu-peek: track the finger for the
            // row highlight and commit on release — do NOT feed the tap/camera/pinch detectors.
            if (menuActive) {
                menuCurX = event.x
                menuCurY = event.y
                // FIX-10b: tap-mode (submenu drill-in / shift-customize) is a PERSISTENT menu. The opening
                // long-press's release just ARMS it; after that each discrete tap selects a row / drills / Backs,
                // and a tap outside dismisses. Drag-mode (below) is the original slide-select.
                if (menuTapMode) {
                    when (event.actionMasked) {
                        MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                            if (menuTapArmed) updateMenuHighlight(event.x, event.y)
                        }

                        MotionEvent.ACTION_UP -> {
                            menuTouchActive = false
                            if (!menuTapArmed) {
                                menuTapArmed = true
                                menuOverlay.setHighlight(-1)
                            } else {
                                onMenuTap(event.x, event.y)
                            }
                        }
                    }
                    return@setOnTouchListener true
                }
                when (event.actionMasked) {
                    MotionEvent.ACTION_MOVE -> {
                        updateMenuHighlight(event.x, event.y)
                    }

                    MotionEvent.ACTION_UP -> {
                        menuTouchActive = false
                        if (menuOverlay.isActive) commitMenuSelection()
                    }

                    MotionEvent.ACTION_CANCEL -> {
                        menuTouchActive = false
                        cancelMenu()
                    }
                }
                return@setOnTouchListener true
            }
            scaleGestures.onTouchEvent(event) // pinch-zoom first; it sets the isInProgress flag onScroll reads
            gestures.onTouchEvent(event)
            // Pre-hover: move the engine pointer to a fresh single-finger touch so tooltips/menus track it.
            if (event.actionMasked == MotionEvent.ACTION_DOWN && event.pointerCount == 1) {
                JvmLauncher.move(toGameX(event.x), toGameY(event.y))
            }
            if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
                if (itemDragging) {
                    // FIX-4: ALWAYS release so the engine WidgetDrag closes — on a clean UP drop on the lift point
                    // (the destination slot); on a cancel fall back to the last valid drag point.
                    val up = event.actionMasked == MotionEvent.ACTION_UP
                    val fx = if (up) toGameX(event.x) else itemDragLastX
                    val fy = if (up) toGameY(event.y) else itemDragLastY
                    JvmLauncher.touch(2, fx, fy, 1) // MOUSE_RELEASED on the destination slot
                    itemDragging = false
                    Log.i(TAG, "drag-1: item drag end game=($fx,$fy)")
                }
                cameraGestureActive = false
                chatScrolling = false
                mapPanning = false
                mapScrolling = false
            }
            true
        }

        startInputPolling()

        // Boot the VM once per process, off the UI thread and on the application context.
        // `adb ... --ez census true` arms the A-1b runtime gate-flip census (extra gates + the census probe).
        // SLM-PROBE-01(kt)/SLM-MARKER-01: every dev diagnostic below (census + netprobe/gpuSmoke/rlhdprobe) is
        // gated on BuildConfig.DEBUG so a release build cannot be diverted into a probe via a pushed marker or ADB
        // intent extra — they compile in for debug only and are dead in release.
        val censusMode = BuildConfig.DEBUG && (intent?.getBooleanExtra("census", false) ?: false)
        // Track G AG1a: `adb ... --ez gpuSmoke true` boots the facade-only EGL smoke (no engine/tokens/login) to
        // probe GL.createCapabilities().OpenGL33==true through the facade on a live Android EGL context.
        // AG2 login diagnosis: a pushed `netprobe.mode` marker (--other-files) runs the network probe ONLY — does
        // the home-minted Jagex session authenticate from THIS device's IP? — then logs NETPROBE… and stops (no
        // JVM boot). Lets the Firebase device answer "can we mint/login from the datacenter?" before we build for it.
        if (BuildConfig.DEBUG && File(getExternalFilesDir(null), "netprobe.mode").exists()) {
            val app = applicationContext
            thread(name = "netprobe") { NetProbe.run(app) }
            return
        }
        if (BuildConfig.DEBUG && intent?.getBooleanExtra("gpuSmoke", false) == true) {
            if (booted.compareAndSet(false, true)) {
                val app = applicationContext
                thread(name = "jvm-boot") { bootGpuSmoke(app) }
            }
            return
        }
        // Track G AG2.5-b: `adb ... --ez rlhdprobe true` (or a pushed rlhdprobe.mode marker, so Firebase Robo can
        // trigger it without an intent extra) boots the embedded VM on [client-*-gpu.jar + client-*-rlhd.jar],
        // mainClass=RLHDProbe — a headless 117HD class-load + loader-data probe (no engine/bridge/render/login).
        // Proves the OpenCL stub + Zone facade delta resolve at class-load and the loader JSON parses on-device.
        if (BuildConfig.DEBUG && (
                intent?.getBooleanExtra("rlhdprobe", false) == true ||
                    File(getExternalFilesDir(null), "rlhdprobe.mode").exists()
            )
        ) {
            if (booted.compareAndSet(false, true)) {
                val app = applicationContext
                thread(name = "jvm-boot") { bootRlhdProbe(app) }
            }
            return
        }
        // Track G AG2: `adb ... --ez routecgpu true` (or the dev "GPU" button, which restarts the process into
        // this) boots the FULL client on the GPU-variant jar with the gpu plugin force-enabled. Also trigger on a
        // pushed marker file (getExternalFilesDir/gpu.mode): Firebase Test Lab Robo launches the default activity
        // and can't pass an intent extra, but it CAN seed a file via --other-files. Falls through the login gate.
        // Phase-2 renderer-as-plugins: the persisted preference (cpu|gpu|117hd, default cpu — the iOS
        // rendererPref model) joins the dev/CI triggers below as one more way into each mode. Renderers are
        // NOT hot-swappable (jar choice + librlawt registration are fixed at JVM start), so the panel toggle
        // writes this and the change applies on the next process start.
        // Phase 3 auto-GPU: resolve the persisted renderer, running a first-run capability probe to promote capable
        // devices off the CPU default, with a crash-cookie first-boot fallback. The `auto-gpu-armed` marker is
        // written before a pref-driven GPU/117HD boot and cleared by the watchdog once frames actually present; if
        // it's still here at startup the previous promoted boot crashed/blacked/hung before presenting -> revert to
        // CPU (permanently for an AUTO decision; one-shot for a user-explicit one, so they can retry).
        // GUARDED on !booted: onCreate re-runs on any Activity recreation the manifest doesn't absorb (dark-mode
        // flip, locale, split-screen). In that re-entry the JVM is still up and the cookie may legitimately still
        // be armed (the watchdog clears it only after successFrames present) — reading it here would falsely
        // demote a healthy GPU/117HD session to CPU and could latch autoGpuFailed forever. booted is a
        // companion-object AtomicBoolean, so it survives the recreation; the JVM-death paths reset it, so a
        // genuine crashed-boot retry still takes this check.
        if (!booted.get()) {
            val rp = getSharedPreferences("renderer", MODE_PRIVATE)
            val armed = File(filesDir, "auto-gpu-armed")
            if (armed.exists()) {
                // PROD-CRASH-TELEMETRY-01: the cookie body is the mode that failed (gpu|117hd); read it before delete.
                val failedMode = runCatching { armed.readText().trim() }.getOrNull()?.takeIf { it.isNotBlank() } ?: "gpu/117hd"
                armed.delete()
                val wasAuto = rp.getBoolean("autoDecided", false)
                val failCount = rp.getInt("gpuFailCount", 0) + 1
                // commit() (synchronous): the boot path arms a SYNC cookie file next, so the pref must be durably on
                // disk first — else a crash in the apply() flush window could leave an armed cookie with a stale mode.
                val e = rp.edit().putString("mode", "cpu").putInt("gpuFailCount", failCount)
                if (wasAuto) e.putBoolean("autoGpuFailed", true)
                e.commit()
                // Record WHICH renderer + GPU failed so a tail-device fallback is diagnosable post-hoc (the audit's
                // "observable floor") instead of a silent CPU revert. The GPU string was captured by the caps probe.
                val gpu = rp.getString("gpuRenderer", null) ?: "unknown"
                val esTier = rp.getInt("gpuEsTier", -1)
                val detail =
                    "renderer=$failedMode gpu=\"$gpu\" esTier=$esTier " +
                        "wasAuto=$wasAuto failCount=$failCount at=${System.currentTimeMillis()}"
                runCatching { File(filesDir, "gpu-fail.txt").writeText(detail + "\n") } // last-failure record (run-as readable)
                Log.w(TAG, "auto-GPU: prior promoted boot never presented a frame -> CPU fallback ($detail)")
                // Make the silent revert observable (a black-screen crash gives the user no clue why the next
                // boot looks different): one-shot notice; the plugins panel is the re-enable path.
                Toast
                    .makeText(
                        this,
                        "HD renderer didn't start — switched to compatibility mode. Re-enable it under Plugins.",
                        Toast.LENGTH_LONG,
                    ).show()
            }
            if (rp.getString("mode", null) == null && !rp.getBoolean("autoGpuFailed", false)) {
                val probed = probeGpuCaps() // "117hd" | "gpu" | "cpu"
                rp
                    .edit()
                    .putString("mode", probed)
                    .putBoolean("autoDecided", probed != "cpu")
                    .commit() // durable before the cookie arms
                Log.i(TAG, "auto-GPU: first-run caps probe -> default renderer '$probed'")
            }
        }
        val prefRenderer = rendererPref()
        val gpuMode =
            (intent?.getBooleanExtra("routecgpu", false) ?: false) ||
                File(getExternalFilesDir(null), "gpu.mode").exists() || prefRenderer == "gpu"
        // Track G AG3-b: `--ez routecrlhd true` (or a pushed rlhd.mode marker) boots the FULL client on the gpu jar
        // + the rlhd jar with the 117HD (Zone) plugin loaded + started in-world (RLHDStarter). Needs login (tokens).
        // AG3-c: a Firebase Game Loop launch (action TEST_LOOP) also boots routecrlhd — Game Loop runs the app
        // UNINTERRUPTED (no Robo crawl/relaunch), giving the long startUp + Zone shader compile its minute on real Mali.
        val gameLoop = intent?.action == "com.google.intent.action.TEST_LOOP"
        // One-shot marker written by the in-app HD button before it restarts the process. Intent extras don't
        // reliably survive finishAffinity()+relaunch on every launcher (notably Quest's Horizon OS, which
        // relaunches the app from its stored shortcut intent and drops our extra) — a file read at boot does.
        // Consume it on read so HD mode applies to exactly this boot; the next normal launch is the CPU client.
        val rlhdOnce = File(getExternalFilesDir(null), "rlhd.once")
        val rlhdOnceSet = rlhdOnce.exists()
        if (rlhdOnceSet) {
            rlhdOnce.delete()
            Log.i(TAG, "rlhd.once marker consumed -> routecrlhd this boot")
        }
        // A TV (Shield / Android TV) is a GPU-only target here — default its leanback-launcher icon straight into
        // 117HD (the only thing it's used for), so opening the app from the TV home screen is turnkey. A phone
        // still boots the CPU client by default (the HD button / intent opt-in unchanged). Opt out with a
        // cpu.mode marker if the CPU client is ever wanted on the TV.
        val isTv =
            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
                packageManager.hasSystemFeature("android.hardware.type.television")
        val cpuForced = File(getExternalFilesDir(null), "cpu.mode").exists()
        val rlhdMode =
            (intent?.getBooleanExtra("routecrlhd", false) ?: false) ||
                File(getExternalFilesDir(null), "rlhd.mode").exists() || gameLoop || rlhdOnceSet ||
                (isTv && !cpuForced) || prefRenderer == "117hd"
        if (gameLoop) Log.i(TAG, "AG3-c: Game Loop launch -> routecrlhd (uninterrupted run for the Zone shader compile)")
        if (isTv && !cpuForced) Log.i(TAG, "TV/leanback device -> defaulting to routecrlhd (117HD) on launch")
        // PROD-SECURITY-01: the login-first divert below is skipped ONLY for the headless / non-interactive 117HD
        // boots that MUST settle at the engine LOGIN_SCREEN with no human to divert to — the Firebase Game Loop /
        // datacenter shader-compile proof (gameLoop + the rlhd_prelogin.mode marker) and the explicit dev/test
        // triggers (routecrlhd intent extra, rlhd.mode marker), plus a TV (Custom-Tab OAuth is impractical on
        // leanback, so it stays turnkey-117HD). The ordinary user 117HD default (prefRenderer=="117hd", incl. the
        // first-boot auto-GPU promotion) is deliberately NOT in this set: a clean install with no token must still
        // get the native Jagex login first, so login-first is not renderer-dependent for real users.
        val rlhdTestBoot =
            (intent?.getBooleanExtra("routecrlhd", false) ?: false) ||
                File(getExternalFilesDir(null), "rlhd.mode").exists() || gameLoop ||
                File(getExternalFilesDir(null), "rlhd_prelogin.mode").exists() ||
                (isTv && !cpuForced)
        // A3 login-first boot gate: JX_* is snapshotted at JNI_CreateJavaVM, so a valid tokens.json must exist
        // BEFORE boot. With none (and not census, which uses pushed tokens), run the on-device Jagex login first;
        // it writes tokens.json then restarts the process for a clean boot (Review-2: login-first or restart).
        if (!censusMode && !rlhdTestBoot && !JagexTokens.hasTokens(applicationContext) &&
            !LegacyCreds.hasCreds(applicationContext)
        ) {
            // Only the headless test/datacenter 117HD boots (rlhdTestBoot) skip this — they settle at LOGIN_SCREEN
            // for the pre-login Zone shader compile. Every interactive renderer (cpu/gpu AND the 117HD user
            // default) diverts to the on-device Jagex login first.
            Log.i(TAG, "a3: no tokens.json — launching on-device Jagex login before boot")
            startActivity(Intent(this, LoginActivity::class.java))
            finish()
            return
        }
        if (booted.compareAndSet(false, true)) {
            val app = applicationContext
            // Phase 3 auto-GPU: arm the first-boot crash-cookie ONLY for a persisted-pref-driven GPU/117HD boot (the
            // auto-promote or a user panel pick). Dev/CI triggers (intent extras, gpu.mode/rlhd.mode/rlhd.once
            // markers, Game Loop, TV) are deliberate test paths and are NOT cookie-protected.
            if (prefRenderer == "gpu" || prefRenderer == "117hd") {
                runCatching { File(filesDir, "auto-gpu-armed").writeText(prefRenderer) }
                startAutoGpuWatchdog()
                Log.i(TAG, "auto-GPU: armed first-boot fallback cookie for pref '$prefRenderer'")
            }
            thread(name = "jvm-boot") { bootJvm(app, censusMode, gpu = gpuMode && !rlhdMode, rlhd = rlhdMode) }
            // PERF-MEMORY-THERMAL-01: arm the thermal governor for a 117HD boot (no-op for cpu/gpu). It throttles
            // the 117HD sceneResolutionScale under thermal pressure and restores it on cooldown; all config I/O is
            // bridge-threaded so the main-thread listener callback never blocks.
            thermalGovernor =
                ThermalGovernor(
                    getSystemService(POWER_SERVICE) as PowerManager,
                    is117hd = rlhdMode,
                    markerFile = File(filesDir, "thermal-throttle.marker"),
                ).also { it.start() }
        }
        // AP-2a: start draining the notification/link queues. Safe before the VM is up — the externs return ""
        // until the MobileUiBridge facade publishes, then start yielding real items.
        startBridgeDrain()
    }

    /** Phase-2 renderer preference (cpu|gpu|117hd) — the iOS rendererPref model. Persisted; read once at
     *  boot to pick the jar set + routec flags, so a panel toggle applies on the NEXT process start. */
    private fun rendererPref(): String = getSharedPreferences("renderer", MODE_PRIVATE).getString("mode", "cpu") ?: "cpu"

    private fun setRendererPref(mode: String) {
        // A user pick is EXPLICIT: clear the auto-decision flag + any prior auto-fail latch + a stale crash-cookie so
        // the auto-GPU machinery respects the choice (and a user-chosen GPU mode still gets one-shot crash protection).
        getSharedPreferences("renderer", MODE_PRIVATE)
            .edit()
            .putString("mode", mode)
            .putBoolean("autoDecided", false)
            .putBoolean("autoGpuFailed", false)
            .apply()
        runCatching { File(filesDir, "auto-gpu-armed").delete() }
        Log.i(TAG, "p2: rendererPref -> $mode (applies on next launch)")
        val label =
            when (mode) {
                "gpu" -> "GPU"
                "117hd" -> "117 HD"
                else -> "CPU (vanilla)"
            }
        AlertDialog
            .Builder(this)
            .setTitle("Renderer: $label")
            .setMessage("Saved. The renderer is fixed at launch, so it applies on the next start. Restart now?")
            .setPositiveButton("Restart") { _, _ ->
                val i = packageManager.getLaunchIntentForPackage(packageName)
                i?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                startActivity(i)
                finishAffinity()
                Runtime.getRuntime().exit(0)
            }.setNegativeButton("Later", null)
            .show()
    }

    /**
     * Phase 3 auto-GPU capability probe (ported lean from the AG0 ReconActivity). Stands up a throwaway ES3 pbuffer
     * context, reads the real ES tier + MSAA + compute support, tears it down, and maps to a renderer default:
     * `117hd` (ES≥3.1 + compute — the clean Zone path), else `gpu` (ES≥3.0 + MSAA — base GPU), else `cpu`. Any
     * failure returns `cpu` (the safe default). This is the OPTIMISTIC gate; the first-boot watchdog is the recovery.
     */
    private fun probeGpuCaps(): String {
        var dpy = android.opengl.EGL14.EGL_NO_DISPLAY
        var ctx = android.opengl.EGL14.EGL_NO_CONTEXT
        var surf = android.opengl.EGL14.EGL_NO_SURFACE
        try {
            dpy = android.opengl.EGL14.eglGetDisplay(android.opengl.EGL14.EGL_DEFAULT_DISPLAY)
            if (dpy == android.opengl.EGL14.EGL_NO_DISPLAY) return "cpu"
            val ver = IntArray(2)
            if (!android.opengl.EGL14.eglInitialize(dpy, ver, 0, ver, 1)) return "cpu"
            val cfgAttr =
                intArrayOf(
                    android.opengl.EGL14.EGL_RENDERABLE_TYPE,
                    0x0040, // EGL_OPENGL_ES3_BIT_KHR
                    android.opengl.EGL14.EGL_SURFACE_TYPE,
                    android.opengl.EGL14.EGL_PBUFFER_BIT,
                    android.opengl.EGL14.EGL_RED_SIZE,
                    8,
                    android.opengl.EGL14.EGL_GREEN_SIZE,
                    8,
                    android.opengl.EGL14.EGL_BLUE_SIZE,
                    8,
                    android.opengl.EGL14.EGL_ALPHA_SIZE,
                    8,
                    android.opengl.EGL14.EGL_DEPTH_SIZE,
                    24,
                    android.opengl.EGL14.EGL_NONE,
                )
            val cfgs = arrayOfNulls<android.opengl.EGLConfig>(1)
            val nCfg = IntArray(1)
            if (!android.opengl.EGL14.eglChooseConfig(dpy, cfgAttr, 0, cfgs, 0, 1, nCfg, 0) || nCfg[0] < 1) return "cpu"
            // Request the highest ES context the driver supports: 3.2 -> 3.1 -> 3.0.
            val eglContextMinorVersion = 0x30FB
            for (mn in intArrayOf(2, 1, 0)) {
                val ctxAttr =
                    intArrayOf(
                        android.opengl.EGL14.EGL_CONTEXT_CLIENT_VERSION,
                        3,
                        eglContextMinorVersion,
                        mn,
                        android.opengl.EGL14.EGL_NONE,
                    )
                ctx = android.opengl.EGL14.eglCreateContext(dpy, cfgs[0], android.opengl.EGL14.EGL_NO_CONTEXT, ctxAttr, 0)
                if (ctx != android.opengl.EGL14.EGL_NO_CONTEXT) break
            }
            if (ctx == android.opengl.EGL14.EGL_NO_CONTEXT) return "cpu"
            val pbAttr = intArrayOf(android.opengl.EGL14.EGL_WIDTH, 16, android.opengl.EGL14.EGL_HEIGHT, 16, android.opengl.EGL14.EGL_NONE)
            surf = android.opengl.EGL14.eglCreatePbufferSurface(dpy, cfgs[0], pbAttr, 0)
            if (surf == android.opengl.EGL14.EGL_NO_SURFACE) return "cpu"
            if (!android.opengl.EGL14.eglMakeCurrent(dpy, surf, surf, ctx)) return "cpu"

            val glVer = android.opengl.GLES30.glGetString(android.opengl.GLES30.GL_VERSION) ?: ""
            val m = Regex("OpenGL ES (\\d)\\.(\\d)").find(glVer)
            val esTier = (m?.groupValues?.get(1)?.toIntOrNull() ?: 3) * 10 + (m?.groupValues?.get(2)?.toIntOrNull() ?: 0)
            val tmp = IntArray(1)
            while (android.opengl.GLES30.glGetError() != android.opengl.GLES30.GL_NO_ERROR) { /* drain */ }
            android.opengl.GLES30.glGetIntegerv(android.opengl.GLES30.GL_MAX_SAMPLES, tmp, 0)
            val maxSamples = if (android.opengl.GLES30.glGetError() == android.opengl.GLES30.GL_NO_ERROR) tmp[0] else -1
            android.opengl.GLES30.glGetIntegerv(android.opengl.GLES31.GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, tmp, 0)
            val maxCompute = if (android.opengl.GLES30.glGetError() == android.opengl.GLES30.GL_NO_ERROR) tmp[0] else -1
            val renderer = android.opengl.GLES30.glGetString(android.opengl.GLES30.GL_RENDERER) ?: "?"
            val baseGpuOk = esTier >= 30 && maxSamples >= 1
            val hd117Clean = esTier >= 31 && maxCompute > 0
            val pick =
                when {
                    hd117Clean -> "117hd"
                    baseGpuOk -> "gpu"
                    else -> "cpu"
                }
            // PROD-CRASH-TELEMETRY-01: persist the GPU identity now (we hold a live context here) so that if a
            // promoted GPU/117HD boot later fails to present, the crash-cookie fallback can name WHICH GPU died
            // instead of reverting to CPU silently. Cheap one-time write on the first-run probe.
            getSharedPreferences("renderer", MODE_PRIVATE)
                .edit()
                .putString("gpuRenderer", renderer)
                .putInt("gpuEsTier", esTier)
                .apply()
            Log.i(TAG, "auto-GPU caps: esTier=$esTier maxSamples=$maxSamples maxCompute=$maxCompute renderer=\"$renderer\" -> $pick")
            return pick
        } catch (t: Throwable) {
            Log.e(TAG, "auto-GPU caps probe threw -> CPU fallback", t)
            return "cpu"
        } finally {
            if (dpy != android.opengl.EGL14.EGL_NO_DISPLAY) {
                android.opengl.EGL14.eglMakeCurrent(
                    dpy,
                    android.opengl.EGL14.EGL_NO_SURFACE,
                    android.opengl.EGL14.EGL_NO_SURFACE,
                    android.opengl.EGL14.EGL_NO_CONTEXT,
                )
                if (surf != android.opengl.EGL14.EGL_NO_SURFACE) android.opengl.EGL14.eglDestroySurface(dpy, surf)
                if (ctx != android.opengl.EGL14.EGL_NO_CONTEXT) android.opengl.EGL14.eglDestroyContext(dpy, ctx)
                android.opengl.EGL14.eglTerminate(dpy)
            }
        }
    }

    /**
     * Phase 3 auto-GPU first-boot fallback. Polls the native frame-presented counter; the instant the promoted
     * renderer presents a handful of frames (== it activated, not black/crashed), clear the `auto-gpu-armed` cookie
     * to COMMIT the promote. If it never presents within the deadline, leave the cookie armed so the next launch
     * reverts to CPU. A hard crash kills this thread too, leaving the cookie armed -> same revert. Daemon so it
     * never holds the process open.
     */
    private fun startAutoGpuWatchdog() {
        thread(name = "auto-gpu-watchdog", isDaemon = true) {
            val successFrames = 3L // a few real presents prove activation (not a one-frame fluke)
            val deadlineMs = System.currentTimeMillis() + 240_000L // generous: cold JVM boot + cache + Zone shader compile
            while (System.currentTimeMillis() < deadlineMs) {
                try {
                    Thread.sleep(1000)
                } catch (e: InterruptedException) {
                    return@thread
                }
                val frames =
                    try {
                        JvmLauncher.nativeGpuFramesPresented()
                    } catch (t: Throwable) {
                        0L
                    }
                if (frames >= successFrames) {
                    runCatching { File(filesDir, "auto-gpu-armed").delete() }
                    Log.i(TAG, "auto-GPU: renderer presenting ($frames frames) -> committed; crash-cookie cleared")
                    return@thread
                }
            }
            Log.w(TAG, "auto-GPU: renderer presented no frames within 240s -> crash-cookie left armed (CPU next launch)")
        }
    }

    /** Dev "GPU" button: restart the process into GPU Route-C mode (the embedded VM is one-per-process, so
     *  switching from the CPU jar to the GPU jar needs a clean boot — same mechanism as the login restart). */
    private fun restartIntoGpu() {
        val i = packageManager.getLaunchIntentForPackage(packageName)
        i?.putExtra("routecgpu", true)
        i?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        startActivity(i)
        finishAffinity()
        Runtime.getRuntime().exit(0)
    }

    /** Dev "HD" button: restart the process into 117HD (routecrlhd) mode — same clean-boot mechanism as
     *  [restartIntoGpu]; RLHDStarter then loads + starts the Zone plugin at LOGIN_SCREEN/LOGGED_IN. */
    private fun restartIntoRlhd() {
        // Write a one-shot marker BEFORE restarting: some launchers (Quest's Horizon OS) relaunch the app from
        // its stored shortcut intent and drop the routecrlhd extra, so the extra alone isn't reliable on device.
        // The marker is filesystem state read + consumed at boot, so it survives the restart regardless.
        runCatching { File(getExternalFilesDir(null), "rlhd.once").writeText("1") }
        val i = packageManager.getLaunchIntentForPackage(packageName)
        i?.putExtra("routecrlhd", true)
        i?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        startActivity(i)
        finishAffinity()
        Runtime.getRuntime().exit(0)
    }

    /** Log out is destructive (drops the Jagex session + kills the process) — confirm before doing it. */
    private fun confirmLogout() {
        AlertDialog
            .Builder(this)
            .setTitle("Log out")
            .setMessage(
                "Forget this Jagex session? Deletes the saved login (tokens.json) and web cookies, then restarts to the sign-in screen.",
            ).setPositiveButton("Log out") { _, _ -> doLogout() }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /** AP-0 logout: flush pending config (the restart kills the process), delete tokens.json, purge the
     *  WebView cookie store (so the IdP can't silently re-auth the old account), then restart into the
     *  login-first boot gate. Cookie removal is async — chain the restart off its callback. */
    private fun doLogout() {
        val purgeAndRestart = {
            val clean = JagexTokens.deleteAll(applicationContext)
            if (!clean) Log.w(TAG, "logout: a usable tokens.json source remains — session may return on next boot")
            CookieManager.getInstance().removeAllCookies {
                CookieManager.getInstance().flush()
                Log.i(TAG, "logout: tokens deleted + cookies purged — restarting into the login gate")
                val i = packageManager.getLaunchIntentForPackage(packageName)
                i?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                startActivity(i)
                finishAffinity()
                Runtime.getRuntime().exit(0)
            }
        }
        if (booted.get()) {
            JvmLauncher.onBridge {
                // PROD-SECURITY-10: a Jagex logout must also end the runelite.net account session — otherwise the
                // synced RuneLite account (profiles/plugin-hub) stays signed in after the user logs out. Same bridge
                // (client) thread + method the account panel's own logout uses.
                runCatching { JvmLauncher.accountLogout() }.onFailure { Log.w(TAG, "logout: accountLogout failed: ${it.message}") }
                val ack = JvmLauncher.flushConfig()
                Log.i(TAG, "logout: accountLogout + flushConfig -> $ack")
                runOnUiThread(purgeAndRestart)
            }
        } else {
            purgeAndRestart()
        }
    }

    /** AP-2b Finding 5: pull the composited CPU frame (JavaBridge.getFramePixels — the stable 0x00RRGGBB
     *  snapshot) and write a PNG into MediaStore (Pictures/RuneLite) so it lands in the system gallery. The
     *  pixel pull attaches to HotSpot, so it runs on the rl-bridge thread; the encode/insert runs on a plain
     *  background thread; the Toast hops back to the UI thread. No shared-Java change — the getter already exists.
     *  Note: getFramePixels is the CPU path only — under live GPU/117HD present the frame isn't published here. */
    private fun saveScreenshot() {
        if (!booted.get()) {
            Toast.makeText(this, "No frame yet", Toast.LENGTH_SHORT).show()
            return
        }
        JvmLauncher.onBridge {
            val px = JvmLauncher.framePixels()
            val w = JvmLauncher.frameWidth()
            // Width must divide the array exactly; a non-multiple means a torn read across a resize — bail and
            // let the user retap (frames are static at the login screen and rarely resize in-world).
            if (px == null || w <= 0 || px.isEmpty() || px.size % w != 0) {
                runOnUiThread { Toast.makeText(this, "Screenshot unavailable", Toast.LENGTH_SHORT).show() }
                return@onBridge
            }
            val h = px.size / w
            // Source is 0x00RRGGBB (alpha unset). Force opaque; channel order already matches Android's ARGB int
            // (0xAARRGGBB) — NO R<->B swizzle here (unlike the SurfaceView blit, which swizzles for RGBA_8888).
            for (i in px.indices) px[i] = px[i] or 0xFF000000.toInt()
            val savedUri =
                try {
                    val bmp = Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
                    val u = writePngToGallery(bmp)
                    bmp.recycle()
                    u
                } catch (t: Throwable) {
                    Log.w(TAG, "screenshot: encode/save failed", t)
                    null
                }
            runOnUiThread {
                if (savedUri != null) {
                    Toast.makeText(this, "Screenshot saved to Pictures/RuneLite", Toast.LENGTH_SHORT).show()
                    // ENH-A05b: on a phone the dominant post-capture intent is to SHARE (Discord / clan chat), not
                    // hunt the gallery — offer the Android share-sheet with the saved PNG ready to send. The MediaStore
                    // content:// Uri is directly shareable (no FileProvider needed); dismissing the chooser just leaves
                    // the saved gallery copy. (Capture itself is still CPU-path only — the GPU/117HD readback is ENH-A05a.)
                    runCatching {
                        val share =
                            Intent(Intent.ACTION_SEND).apply {
                                type = "image/png"
                                putExtra(Intent.EXTRA_STREAM, savedUri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                        startActivity(Intent.createChooser(share, "Share screenshot"))
                    }
                } else {
                    Toast.makeText(this, "Screenshot save failed", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    /** Insert [bmp] as a PNG into the shared Pictures/RuneLite collection. API 29+ uses scoped storage
     *  (RELATIVE_PATH + IS_PENDING, no permission); API 28 falls back to the legacy top-level insert (covered by
     *  WRITE_EXTERNAL_STORAGE maxSdk=28 in the manifest). Returns the MediaStore content:// Uri on success (so the
     *  caller can offer a share-sheet — ENH-A05b), or null on failure. */
    private fun writePngToGallery(bmp: Bitmap): android.net.Uri? {
        val name = "RuneLite_${System.currentTimeMillis()}.png"
        val resolver = contentResolver
        val values =
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RuneLite")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            }
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return null
        return try {
            resolver.openOutputStream(uri)?.use { out ->
                if (!bmp.compress(Bitmap.CompressFormat.PNG, 100, out)) throw java.io.IOException("PNG compress failed")
            } ?: throw java.io.IOException("null output stream")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
            }
            Log.i(TAG, "screenshot: saved $name -> $uri")
            uri
        } catch (t: Throwable) {
            resolver.delete(uri, null, null) // roll back the half-written/pending row
            Log.w(TAG, "screenshot: write failed", t)
            null
        }
    }

    /** PARITY-ANDROID-SHOT: whether the engine's auto-screenshots (level-ups, drops, clues, kills) are copied to
     *  the gallery as they occur. Off by default (matches iOS); toggled by a long-press on the Screenshot tile. */
    private fun autoSaveScreenshots(): Boolean = getSharedPreferences("screenshots", MODE_PRIVATE).getBoolean("autoSave", false)

    private fun toggleAutoScreenshots() {
        val now = !autoSaveScreenshots()
        getSharedPreferences("screenshots", MODE_PRIVATE).edit().putBoolean("autoSave", now).apply()
        Toast
            .makeText(
                this,
                if (now) {
                    "Auto-save ON: event screenshots (level-ups, drops, clues…) go to Pictures/RuneLite"
                } else {
                    "Auto-save OFF: event screenshots stay on device only"
                },
                Toast.LENGTH_LONG,
            ).show()
        Log.i(TAG, "screenshot: auto-save ${if (now) "ON" else "OFF"}")
    }

    /** PARITY-ANDROID-SHOT: drain the shared-core auto-screenshot queue (MobileUiBridge.nextScreenshot — the
     *  engine writes each event PNG to the sandbox and enqueues its absolute path). When auto-save is enabled we
     *  decode the file and insert it into the gallery; otherwise we still drain (discard) so the queue can't back
     *  up. Runs on the rl-drain thread; caps writes per tick so a burst can't flood the encoder. Mirrors iOS
     *  drainScreenshots. */
    private fun drainScreenshots() {
        val save = autoSaveScreenshots()
        var writes = 0
        var drained = 0
        var path = JvmLauncher.nextScreenshot()
        // The bridge queue is bounded (MAX_SCREENSHOTS) and poll() empties it, so "" arrives quickly; the drain
        // cap is only a backstop against a pathological always-non-empty return so this I/O loop can't spin.
        while (path.isNotEmpty() && drained < 64) {
            drained++
            // decodeFile is a blocking read on the rl-drain thread; capped at 3 encodes/tick so a burst of large
            // PNGs can't stall the notification/link drains sharing this loop (leftovers surface next tick).
            if (save && writes < 3) {
                try {
                    val bmp = BitmapFactory.decodeFile(path)
                    if (bmp != null) {
                        writePngToGallery(bmp)
                        bmp.recycle()
                        writes++
                        Log.i(TAG, "screenshot: auto-saved ${path.substringAfterLast('/')}")
                    }
                } catch (t: Throwable) {
                    Log.w(TAG, "screenshot: auto-save decode/write failed: ${t.message}")
                }
            }
            path = JvmLauncher.nextScreenshot()
        }
        if (drained >= 64) Log.w(TAG, "screenshot: drain backstop hit (queue not emptying?)")
    }

    /** Map a SurfaceView-local coordinate to game-canvas pixels, clamped to the current frame. */
    private fun toGameX(viewX: Float): Int {
        val fw = JvmLauncher.frameWidth()
        val vw = surfaceView.width
        if (fw <= 0 || vw <= 0) return viewX.toInt()
        return (viewX * fw / vw).toInt().coerceIn(0, fw - 1)
    }

    private fun toGameY(viewY: Float): Int {
        val fh = JvmLauncher.frameHeight()
        val vh = surfaceView.height
        if (fh <= 0 || vh <= 0) return viewY.toInt()
        return (viewY * fh / vh).toInt().coerceIn(0, fh - 1)
    }

    private fun scaleX(px: Float): Int {
        val fw = JvmLauncher.frameWidth()
        val vw = surfaceView.width
        return if (fw <= 0 || vw <= 0) px.toInt() else (px * fw / vw).toInt()
    }

    private fun scaleY(px: Float): Int {
        val fh = JvmLauncher.frameHeight()
        val vh = surfaceView.height
        return if (fh <= 0 || vh <= 0) px.toInt() else (px * fh / vh).toInt()
    }

    private class OrbHit(
        val name: String,
        val cx: Int,
        val cy: Int,
    )

    /** Minimap-orb veneer: given a tap in canvas px, return the live orb whose enlarged (ORB_TAP_PAD) bounds
     *  contain it — nearest centre wins when zones overlap — or null when the tap is clear of every orb. The
     *  per-orb bounds come from HudVeneerBridge.getOrbSnapshot, republished each frame + read lock-free. */
    private fun nearestOrb(
        gx: Int,
        gy: Int,
    ): OrbHit? {
        val json = JvmLauncher.orbSnapshotPub()
        if (json.length < 16) return null // "{\"loggedIn\":false}" or empty -> no orbs published
        return try {
            val o = JSONObject(json)
            if (!o.optBoolean("loggedIn", false)) return null
            var best: OrbHit? = null
            var bestD = Long.MAX_VALUE
            for (key in ORB_KEYS) {
                val b = o.optJSONObject(key) ?: continue
                val x = b.optInt("x")
                val y = b.optInt("y")
                val w = b.optInt("w")
                val h = b.optInt("h")
                if (gx < x - ORB_TAP_PAD || gx > x + w + ORB_TAP_PAD ||
                    gy < y - ORB_TAP_PAD || gy > y + h + ORB_TAP_PAD
                ) {
                    continue
                }
                val cx = x + w / 2
                val cy = y + h / 2
                val d = (gx - cx).toLong() * (gx - cx) + (gy - cy).toLong() * (gy - cy)
                if (d < bestD) {
                    bestD = d
                    best = OrbHit(key, cx, cy)
                }
            }
            best
        } catch (t: Throwable) {
            null
        }
    }

    private inner class GestureListener : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true

        override fun onSingleTapUp(e: MotionEvent): Boolean {
            val gx = toGameX(e.x)
            val gy = toGameY(e.y)
            Log.i(
                TAG,
                "tap screen=(${e.x},${e.y}) view=(${surfaceView.width}x${surfaceView.height}) frame=(${JvmLauncher.frameWidth()}x${JvmLauncher.frameHeight()}) -> game=($gx,$gy)",
            )
            // Phase-5: while the world map is open it owns the ENTIRE screen (stretched fullscreen). EVERY tap is
            // a PRECISE engine click — the engine resolves the close X / zoom / search / POI / legend row directly,
            // and the world walk/interact ring stays suppressed. Crucially this also SWALLOWS taps on the map
            // chrome / borders / empty map area: without it those fell through to the world click below, leaking a
            // walk/interact into the live scene behind the map. A search-field tap also raises the IME manually
            // (the map search never flips INPUT_TYPE).
            if (mapOpen) {
                if (inCanvasRect(mapSearchCanvas, gx, gy)) {
                    mapSearchKeyboard = true
                    Log.i(TAG, "p5: map search tap -> raise IME")
                }
                JvmLauncher.clickPrecise(gx, gy, 1)
                return true
            }
            // Minimap-orb touch veneer: the orbs render at ~25px and sit dense next to the minimap walk surface,
            // so a finger easily mis-taps (wrong orb, or a walk). Snap a tap landing in an orb's enlarged zone to
            // the NEAREST orb centre and proxy a PRECISE click there (no walk ring) — adjacency is resolved by
            // nearest-centre. Runs before the minimap-cluster handler so an orb wins over a raw minimap click.
            if (!mapOpen) {
                val orb = nearestOrb(gx, gy)
                if (orb != null) {
                    JvmLauncher.clickPrecise(orb.cx, orb.cy, 1)
                    vibrateTick()
                    Log.i(TAG, "orb-veneer: tap ($gx,$gy) -> ${orb.name} @(${orb.cx},${orb.cy})")
                    return true
                }
            }
            // AP-0: the relocated minimap + orb cluster is HUD/UI. Clicks there still fire (minimap walk / orb
            // ops) but the world-style walk/interact ring is suppressed — a ring drawn on the minimap or an orb
            // is spurious (rings are for in-scene taps), and an orb tap is never a walk so the optimistic-walk
            // grace would always paint a stray yellow ring. Mirrors the open-map precise-click suppression.
            if (!mapOpen && inCanvasRect(minimapRectCanvas, gx, gy)) {
                JvmLauncher.click(gx, gy, 1)
                Log.i(TAG, "ap0: minimap/orb tap ($gx,$gy) -> click without walk-ring")
                return true
            }
            // Arm the tap feedback BEFORE posting the click so the baseline seqs can't race the engine's bump.
            // The kind seq resolves WHAT the tap hit (walk/scene = ring, widget = border, nothing = no feedback);
            // interactTapSeq stays the haptic source.
            ringBaseSeq = JvmLauncher.interactTapSeq()
            ringKindBaseSeq = JvmLauncher.tapKindSeq()
            ringX = e.x
            ringY = e.y
            ringArmedAtMs = SystemClock.uptimeMillis()
            ringPending = true
            JvmLauncher.click(gx, gy, 1)
            return true
        }

        override fun onLongPress(e: MotionEvent) {
            // The map owns the whole screen while open — no right-click menu peek into the scene behind it.
            if (mapOpen) return
            beginMenuPeek(e.x, e.y)
        }

        override fun onScroll(
            e1: MotionEvent?,
            e2: MotionEvent,
            distanceX: Float,
            distanceY: Float,
        ): Boolean {
            // One finger = camera rotate; two fingers / an active pinch = zoom (handled by ScaleListener).
            if (pinchActive || scaleGestures.isInProgress || e2.pointerCount > 1) {
                return false
            }
            // Context routing, decided once at gesture start from the DOWN point (same rule as iOS):
            // inside the open world-map window = pan the MAP; inside the live chat box = scroll the chat;
            // anywhere else = rotate the camera.
            if (!cameraGestureActive && !chatScrolling && !mapPanning && !mapScrolling && !itemDragging) {
                if (mapOpen && e1 != null) {
                    val gx = toGameX(e1.x)
                    val gy = toGameY(e1.y)
                    // A scrollable sub-panel (surface MAPLIST dropdown / KEY legend) takes priority over map pan —
                    // a swipe there scrolls its list, not the map.
                    if (inCanvasRect(mapMaplistCanvas, gx, gy) || inCanvasRect(mapKeyCanvas, gx, gy)) {
                        mapScrolling = true
                        mapScrollAccum = 0f
                        Log.i(TAG, "p5: map panel scroll begin game=($gx,$gy)")
                    } else if (inCanvasRect(mapRectCanvas, gx, gy)) {
                        mapPanning = true
                        mapPanAccumX = 0f
                        mapPanAccumY = 0f
                        Log.i(TAG, "p5: map pan begin")
                    }
                }
                if (!mapPanning && !mapScrolling) {
                    val r = chatRectCanvas
                    if (r != null && e1 != null && !mapOpen) {
                        val gx = toGameX(e1.x)
                        val gy = toGameY(e1.y)
                        if (gx >= r[0] && gx < r[0] + r[2] && gy >= r[1] && gy < r[1] + r[3]) {
                            chatScrolling = true
                            chatScrollAccum = 0f
                            Log.i(TAG, "ap0: chat scroll begin game=($gx,$gy)")
                        }
                    }
                    if (!chatScrolling) {
                        // FIX-4 / DRAG-1b: a drag that STARTS inside the inventory grid OR a reorder pane
                        // (Prayer/Spellbook/Bank) drives the engine WidgetDrag (getDraggedWidget), not the camera.
                        // The true start point (e1, the DOWN event) is the source slot/icon. All these panes use
                        // the identical MOUSE_PRESSED->DRAGGED->RELEASED stream, so one branch covers them.
                        val sx = if (e1 != null) toGameX(e1.x) else -1
                        val sy = if (e1 != null) toGameY(e1.y) else -1
                        val inDraggablePane =
                            !mapOpen && e1 != null &&
                                (inCanvasRect(invRectCanvas, sx, sy) || reorderRectsCanvas.any { inCanvasRect(it, sx, sy) })
                        if (inDraggablePane) {
                            itemDragging = true
                            itemDragLastX = sx
                            itemDragLastY = sy
                            // onTouch(0) primes focus + MOVED + PRESSED on the slot — no clearHover (that would
                            // park the cursor off-canvas; iOS doesn't either).
                            JvmLauncher.touch(0, sx, sy, 1) // MOUSE_PRESSED on the source widget
                            Log.i(TAG, "drag-1: widget drag begin game=($sx,$sy)")
                        } else {
                            cameraGestureActive = true
                            JvmLauncher.clearHover()
                        }
                    }
                }
            }
            if (itemDragging) {
                // Stream the WidgetDrag at the finger's current canvas point (one per frame is fine); cache the
                // last valid point so the release always lands somewhere sensible (no stuck held item).
                val gx = toGameX(e2.x)
                val gy = toGameY(e2.y)
                itemDragLastX = gx
                itemDragLastY = gy
                JvmLauncher.touch(1, gx, gy, 1) // MOUSE_DRAGGED
                return true
            }
            if (mapScrolling) {
                // Scroll the legend / surface-dropdown list (content follows the finger), sub-px accumulated.
                val vh = surfaceView.height
                val ky = if (canvasH > 0 && vh > 0) canvasH.toFloat() / vh else 1f
                mapScrollAccum += distanceY * ky // finger up (distanceY>0) -> reveal lower entries
                val whole = mapScrollAccum.toInt()
                if (whole != 0) {
                    mapScrollAccum -= whole
                    JvmLauncher.onBridgeTouch { JvmLauncher.scrollMapPanel(whole) }
                }
                return true
            }
            if (mapPanning) {
                // "Grab the map": finger deltas -> canvas px, then a speed boost so a swipe covers real ground
                // (plain 1:1 barely moves once the map is magnified to fullscreen). Sub-px accumulated so slow
                // drags don't quantize to zero (the iOS lesson); the shared tick converts to tiles via live zoom.
                // canvasW/H (boot-set) is the reliable canvas size — frameWidth/Height can read 0.
                val vw = surfaceView.width
                val vh = surfaceView.height
                val kx = if (canvasW > 0 && vw > 0) canvasW.toFloat() / vw else 1f
                val ky = if (canvasH > 0 && vh > 0) canvasH.toFloat() / vh else 1f
                mapPanAccumX += -distanceX * kx * MAP_PAN_SPEED
                mapPanAccumY += -distanceY * ky * MAP_PAN_SPEED
                val wx = mapPanAccumX.toInt()
                val wy = mapPanAccumY.toInt()
                if (wx != 0 || wy != 0) {
                    mapPanAccumX -= wx
                    mapPanAccumY -= wy
                    JvmLauncher.onBridgeTouch { JvmLauncher.panWorldMap(wx, wy) }
                }
                return true
            }
            if (chatScrolling) {
                // Content follows the finger: finger dy = -distanceY, scaled to canvas px and accumulated so
                // sub-pixel drags aren't lost; whole px go to the chat's own scroll layer with the same
                // direction mapping as iOS (kChatScrollDir = -1, i.e. send -dy).
                val fh = JvmLauncher.frameHeight()
                val vh = surfaceView.height
                val k = if (fh > 0 && vh > 0) fh.toFloat() / vh else 1f
                chatScrollAccum += -distanceY * k
                val whole = chatScrollAccum.toInt()
                if (whole != 0) {
                    chatScrollAccum -= whole
                    JvmLauncher.onBridgeTouch { JvmLauncher.scrollChat(-whole) }
                }
                return true
            }
            // While the map is open it owns the whole screen — a drag that isn't pan/scroll (handled above) must
            // NOT rotate the world camera behind the map. Swallow it.
            if (mapOpen) {
                return true
            }
            // GestureDetector.onScroll distanceX/Y = old - new, which already equals what iOS sends the bridge
            // (postCameraDx passes -translation, i.e. old - new). Pass it through un-negated so the camera
            // yaws/pitches the same direction as iOS (grab-the-scene feel); negating double-inverts -> reversed.
            JvmLauncher.camera(scaleX(distanceX).toInt(), scaleY(distanceY).toInt())
            return true
        }
    }

    /** Pinch-to-zoom: convert the scale ratio into discrete mouse-wheel notches at the pinch centroid. */
    private inner class ScaleListener : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScaleBegin(d: ScaleGestureDetector): Boolean {
            pinchActive = true
            scaleAccum = 1f
            JvmLauncher.clearHover()
            return true
        }

        override fun onScale(d: ScaleGestureDetector): Boolean {
            scaleAccum *= d.scaleFactor
            val gx = toGameX(d.focusX)
            val gy = toGameY(d.focusY)
            // Fingers spreading (scaleAccum grows) = zoom in = wheel up = negative rotation.
            while (scaleAccum >= PINCH_STEP) {
                JvmLauncher.wheel(gx, gy, -1)
                scaleAccum /= PINCH_STEP
            }
            while (scaleAccum <= 1f / PINCH_STEP) {
                JvmLauncher.wheel(gx, gy, 1)
                scaleAccum *= PINCH_STEP
            }
            return true
        }

        override fun onScaleEnd(d: ScaleGestureDetector) {
            pinchActive = false
            // Re-park the pointer on pinch END too (iOS 469afc4af8): the zoom re-projects the world under
            // the last tracked cursor position, so a begin-only clear leaves a stale hover label behind.
            JvmLauncher.clearHover()
        }
    }

    /**
     * A tiny invisible text editor that hosts the soft keyboard. Its InputConnection forwards committed text
     * to the engine via onText and special keys via onKeyStroke (AWT virtual-key codes). NO_SUGGESTIONS keeps
     * most IMEs on commitText rather than composing, which keeps the mapping 1:1.
     */
    private inner class GameInputView(
        context: Context,
    ) : View(context) {
        init {
            isFocusable = true
            isFocusableInTouchMode = true
        }

        override fun onCheckIsTextEditor(): Boolean = true

        override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
            outAttrs.inputType = EditorInfo.TYPE_CLASS_TEXT or EditorInfo.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or
                EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_DONE
            return object : BaseInputConnection(this, false) {
                override fun commitText(
                    text: CharSequence?,
                    newCursorPosition: Int,
                ): Boolean {
                    val s = text?.toString().orEmpty()
                    if (s.isNotEmpty()) {
                        JvmLauncher.text(s)
                    }
                    return true
                }

                override fun deleteSurroundingText(
                    beforeLength: Int,
                    afterLength: Int,
                ): Boolean {
                    repeat(beforeLength.coerceAtLeast(0)) { JvmLauncher.keyStroke(VK_BACK_SPACE) }
                    return true
                }

                override fun sendKeyEvent(event: KeyEvent): Boolean {
                    if (event.action == KeyEvent.ACTION_DOWN) {
                        when (event.keyCode) {
                            KeyEvent.KEYCODE_DEL -> {
                                JvmLauncher.keyStroke(VK_BACK_SPACE)
                            }

                            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> {
                                JvmLauncher.keyStroke(VK_ENTER)
                            }

                            KeyEvent.KEYCODE_DPAD_LEFT -> {
                                JvmLauncher.keyStroke(VK_LEFT)
                            }

                            KeyEvent.KEYCODE_DPAD_RIGHT -> {
                                JvmLauncher.keyStroke(VK_RIGHT)
                            }

                            KeyEvent.KEYCODE_DPAD_UP -> {
                                JvmLauncher.keyStroke(VK_UP)
                            }

                            KeyEvent.KEYCODE_DPAD_DOWN -> {
                                JvmLauncher.keyStroke(VK_DOWN)
                            }

                            else -> {
                                val u = event.unicodeChar
                                if (u != 0) JvmLauncher.text(u.toChar().toString())
                            }
                        }
                    }
                    return true
                }
            }
        }
    }

    /** User-defined hotkey buttons: build the (empty) HUD strip host. Populated by [refreshHotkeyStrip] from the
     *  PREFS_HOTKEYS active set the native Hotkeys screen writes. GONE until the user activates at least one. */
    private fun buildHotkeyStrip(): HorizontalScrollView {
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        hotkeyRow = row
        return HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFocusable = false
            addView(row)
            visibility = View.GONE
        }
    }

    /** Repopulate the hotkey strip from the persisted active set ("groupkeylabel" entries). Each button fires
     *  its plugin keybind by (group,key) off the LIVE binding (a rebind in the plugin's config is honored). */
    private fun refreshHotkeyStrip() {
        val row = hotkeyRow ?: return
        val strip = hotkeyStrip ?: return
        row.removeAllViews()
        val active =
            getSharedPreferences(PREFS_HOTKEYS, Context.MODE_PRIVATE)
                .getStringSet(PREF_HOTKEYS_ACTIVE, emptySet()) ?: emptySet()
        val pad = (12 * resources.displayMetrics.density).toInt()
        for (entry in active.sorted()) {
            val parts = entry.split('')
            if (parts.size < 2) continue
            val group = parts[0]
            val key = parts[1]
            val label = parts.getOrNull(2).orEmpty().ifEmpty { key }
            val short = label.substringAfter(": ", label) // "<Plugin>: <action>" -> "<action>"
            val btn =
                Button(this).apply {
                    text = short
                    textSize = 12f
                    isAllCaps = false
                    isFocusable = false
                    minWidth = 0
                    minimumWidth = 0
                    minHeight = 0
                    minimumHeight = 0
                    setPadding(pad, pad / 3, pad, pad / 3)
                    setTextColor(0xFFFFFFFF.toInt())
                    background =
                        android.graphics.drawable.GradientDrawable().apply {
                            cornerRadius = 12f
                            setColor(0xCC1E1E1E.toInt())
                            setStroke((1 * resources.displayMetrics.density).toInt(), 0x55FFFFFF)
                        }
                    setOnClickListener {
                        // Bug 4: the WorldHopper quick-hop keybinds (worldhopper/nextKey,previousKey) fire the plugin's
                        // in-game hop, which is inert headless (client.hopToWorld never moves the world). Route them
                        // through the relog path instead — the same fix the World Switcher screen's Next/Prev use — so
                        // the HUD quick-hop hotkey actually hops. Every other hotkey still fires its real keybind.
                        val quickHop =
                            group == WORLDHOPPER_GROUP &&
                                (key == WORLDHOPPER_NEXT_KEY || key == WORLDHOPPER_PREV_KEY)
                        val prev = key == WORLDHOPPER_PREV_KEY
                        // ENH-B06: a quick-hop is a relog under the hood — cover its ~8 s login flash with the
                        // "Hopping…" scrim (the target world isn't known from a direction-hop, so use a generic label).
                        if (quickHop) armHopScrim("Switching worlds…")
                        JvmLauncher.onBridgeTouch {
                            if (quickHop) {
                                JvmLauncher.worldHopDirection(prev)
                            } else {
                                JvmLauncher.fireHotkey(group, key)
                            }
                        }
                        vibrateTick()
                        Log.i(
                            TAG,
                            if (quickHop) {
                                "hotkey: quick-hop ${if (prev) "prev" else "next"} via relog ($short)"
                            } else {
                                "hotkey: fire $group/$key ($short)"
                            },
                        )
                    }
                }
            row.addView(
                btn,
                LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply {
                    rightMargin = (6 * resources.displayMetrics.density).toInt()
                },
            )
        }
        strip.visibility = if (row.childCount > 0) View.VISIBLE else View.GONE
    }

    /** Hide the Android status + navigation bars (sticky immersive) so the game frame is edge-to-edge with no
     *  system chrome. Transient bars come back on a swipe from the edge, then auto-hide. */
    private fun enterImmersive() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive() // re-assert after a dialog / keyboard transiently revealed the bars
    }

    // ---- On-screen overlay-layout editor -----------------------------------------------------------------

    /** Enter the on-screen overlay editor: each movable overlay becomes a draggable box over the live game. */
    private fun enterOverlayEditMode() {
        if (overlayEditMode) return
        overlayEditMode = true
        overlayEditView.setBoxes(emptyList())
        overlayEditView.visibility = View.VISIBLE
        JvmLauncher.onBridge { JvmLauncher.overlaySetUiOpen(true) } // start the bounds snapshot refresh
        startOverlayPoll()
        Log.i(TAG, "overlay-edit: entered")
    }

    private fun exitOverlayEditMode() {
        if (!overlayEditMode) return
        overlayEditMode = false
        overlayPollThread?.interrupt()
        overlayPollThread = null
        overlayEditView.visibility = View.GONE
        JvmLauncher.onBridge {
            JvmLauncher.overlaySetUiOpen(false)
            JvmLauncher.flushConfig()
        }
        Log.i(TAG, "overlay-edit: exited")
    }

    /** Background poll of the published overlay bounds (off the UI thread) feeding the editor view ~2.5 Hz. */
    private fun startOverlayPoll() {
        overlayPollThread?.interrupt()
        overlayPollThread =
            Thread {
                try {
                    while (overlayEditMode && !Thread.currentThread().isInterrupted) {
                        val json =
                            try {
                                JvmLauncher.onBridge { JvmLauncher.overlaysJson() }.get()
                            } catch (t: Throwable) {
                                null
                            }
                        if (json != null) {
                            val boxes = parseOverlayBoxes(json)
                            runOnUiThread { if (overlayEditMode) overlayEditView.setBoxes(boxes) }
                        }
                        Thread.sleep(400)
                    }
                } catch (ie: InterruptedException) {
                    // exit cleanly
                }
            }.also {
                it.isDaemon = true
                it.start()
            }
    }

    private fun parseOverlayBoxes(json: String): List<OverlayEditView.Box> =
        try {
            val o = JSONObject(json)
            if (!o.optBoolean("available", false)) {
                emptyList()
            } else {
                val arr = o.optJSONArray("overlays") ?: return emptyList()
                (0 until arr.length()).mapNotNull { i ->
                    val ov = arr.getJSONObject(i)
                    if (!ov.optBoolean("movable")) return@mapNotNull null
                    val b = ov.optJSONArray("bounds") ?: return@mapNotNull null
                    val w = b.optInt(2)
                    val h = b.optInt(3)
                    if (w <= 0 || h <= 0) return@mapNotNull null
                    OverlayEditView.Box(ov.optString("name", "?"), b.optInt(0), b.optInt(1), w, h)
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "overlay-edit parse: $t")
            emptyList()
        }

    /**
     * Per-frame poll of the engine read-surface: auto-raise/dismiss the soft keyboard when a text field gains/
     * loses focus, and fire a haptic tick when the interact-tap counter advances. Driven by Choreographer so it
     * tracks the display refresh without a dedicated thread.
     */
    private fun startInputPolling() {
        val cb =
            object : Choreographer.FrameCallback {
                override fun doFrame(frameTimeNanos: Long) {
                    // Compare against the ACTUAL IME visibility, not just our last request (the system can dismiss
                    // the keyboard behind our back). API<30 falls back to the cached flag (no ime() inset type).
                    val imeShown =
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            surfaceView.rootWindowInsets?.isVisible(WindowInsets.Type.ime()) ?: keyboardShown
                        } else {
                            keyboardShown
                        }
                    if (textActivePanel) {
                        // FIX-11: a rendered Swing panel's text field is focused; its native Compose mirror field
                        // (PanelView) owns the soft keyboard. Don't touch the IME here — raising GameInputView would
                        // steal focus from the mirror, and dismissing would kill the keyboard the mirror just raised.
                        imeWasShown = imeShown
                    } else {
                        // The keyboard was up and just went down while one of OUR latches still wanted it: that's the
                        // user closing it (the soft-keyboard ▽ / back). Respect it — drop the latches so we don't
                        // immediately re-raise (the old "sticky" behavior fought the close button). Edge-triggered off
                        // the OBSERVED visibility, so the raise animation's transient !imeShown doesn't misfire. An
                        // engine text field (isTextInputOpen) is NOT a latch we clear here — if the engine truly has a
                        // field focused it re-raises next frame, which is correct.
                        if (imeWasShown && !imeShown && (manualKeyboard || mapSearchKeyboard)) {
                            manualKeyboard = false
                            mapSearchKeyboard = false
                            keyboardToggleBtn?.alpha = 0.7f
                            Log.i(TAG, "a1: user dismissed IME -> clear keyboard latches")
                        }
                        imeWasShown = imeShown
                        val want = manualKeyboard || mapSearchKeyboard || JvmLauncher.isTextInputOpen()
                        if (want != imeShown) {
                            if (want != keyboardShown) {
                                keyboardShown = want
                                Log.i(TAG, "a1: textInputOpen/manual=$want -> ${if (want) "raise" else "dismiss"} soft keyboard")
                            }
                            val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                            if (want) {
                                keyboardView.requestFocus()
                                imm.showSoftInput(keyboardView, InputMethodManager.SHOW_IMPLICIT)
                            } else {
                                imm.hideSoftInputFromWindow(keyboardView.windowToken, 0)
                            }
                        } else if (want != keyboardShown) {
                            keyboardShown = want // converged without a request (e.g. user-raised IME matches want)
                        }
                    }
                    val seq = JvmLauncher.interactTapSeq()
                    if (seq != lastTapSeq) {
                        lastTapSeq = seq
                        Log.i(TAG, "a1: interactTapSeq -> $seq (haptic)")
                        vibrateTick()
                    }
                    // Phase-1 tap feedback, resolved from ENGINE TRUTH (tap-kind seq advanced past the tap-time
                    // baseline). Ring ONLY for a real scene tap — SCENE → red, WALK → yellow; a WIDGET op draws a
                    // selection border (no ring); a dead/cancel click shows nothing. So clicks that aren't "in the
                    // game" never paint a ring. The grace covers the settle pipeline (~80–160 ms); a tap that never
                    // resolves (rare — a force-opened menu) just clears with no feedback.
                    if (ringPending) {
                        val kseq = JvmLauncher.tapKindSeq()
                        if (kseq != ringKindBaseSeq) {
                            ringPending = false
                            when (JvmLauncher.lastTapKind()) {
                                TAP_KIND_SCENE -> {
                                    Log.i(TAG, "p1: ring INTERACT (+${SystemClock.uptimeMillis() - ringArmedAtMs}ms)")
                                    tapRing.spawn(ringX, ringY, TapRingView.COLOR_INTERACT)
                                }

                                TAP_KIND_WALK -> {
                                    Log.i(TAG, "p1: ring WALK")
                                    tapRing.spawn(ringX, ringY, TapRingView.COLOR_WALK)
                                }

                                // An interface op: no ring. An item op is outlined by the engine itself (the cyan
                                // item silhouette, armed in JavaBridge) — nothing for the shell to draw.
                                TAP_KIND_WIDGET -> {
                                    Log.i(TAG, "p1: widget op -> no ring (engine outlines items)")
                                }

                                else -> {
                                    Log.i(TAG, "p1: tap hit nothing -> no feedback")
                                }
                            }
                        } else if (SystemClock.uptimeMillis() - ringArmedAtMs > RING_GRACE_MS) {
                            ringPending = false // unresolved (e.g. the click force-opened a menu) — no stray ring
                        }
                    }
                    if (menuBuilding) {
                        tryBuildNativeMenu()
                    }
                    updateChrome()
                    applyOverlayInsets()
                    updateWorldMap()
                    Choreographer.getInstance().postFrameCallback(this)
                }
            }
        frameCallback = cb
        Choreographer.getInstance().postFrameCallback(cb)
    }

    /** AP-2a Finding 9: create the notification channel + request POST_NOTIFICATIONS (API 33+). */
    private fun setupNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch =
                NotificationChannel(NOTIF_CHANNEL, "Game alerts", NotificationManager.IMPORTANCE_DEFAULT)
                    .apply { description = "In-game notifications (idle, level-up, etc.)" }
            mgr.createNotificationChannel(ch)
            // AP-2: a parallel SILENT channel. Android governs notification sound by channel on O+, so a
            // notification whose RuneLite sound is OFF (or volume 0) is routed here — it still shows in the shade
            // but makes no sound. Audible ones use the default channel above (the channel's own sound).
            val chSilent =
                NotificationChannel(NOTIF_CHANNEL_SILENT, "Game alerts (silent)", NotificationManager.IMPORTANCE_LOW)
                    .apply {
                        description = "In-game notifications with sound disabled"
                        setSound(null, null)
                    }
            mgr.createNotificationChannel(chSilent)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_POST_NOTIFICATIONS)
        }
    }

    /**
     * AP-2a Findings 9 + 25: drain the shared notification + link queues on a dedicated daemon (NOT the UI
     * thread — these JNI calls daemon-attach to HotSpot; the UI thread must never attach, ANR risk). A
     * notification → the system shade (NotificationManager); a link → the browser. ~3Hz: notifications/links
     * are human-paced, so a third of a second is imperceptible and costs almost nothing.
     */
    private fun startBridgeDrain() {
        if (drainRun) return
        drainRun = true
        thread(name = "rl-drain", isDaemon = true) {
            while (drainRun) {
                try {
                    var n = JvmLauncher.nextNotification()
                    while (n.isNotEmpty()) {
                        deliverNotification(n)
                        n = JvmLauncher.nextNotification()
                    }
                    var url = JvmLauncher.nextLink()
                    while (url.isNotEmpty()) {
                        openLink(url)
                        url = JvmLauncher.nextLink()
                    }
                    drainScreenshots() // PARITY-ANDROID-SHOT: surface engine auto-screenshots to the gallery
                } catch (t: Throwable) {
                    Log.w(TAG, "rl-drain: ${t.message}")
                }
                try {
                    Thread.sleep(300)
                } catch (e: InterruptedException) {
                    break
                }
            }
        }
    }

    /** Raise a system notification from the shared SOH-delimited payload "titlebodysoundTypevolume"
     *  (NOTIF-1: soundType is the RuneLite NotificationSound name — OFF/NATIVE/CUSTOM — and volume is 0..100, or
     *  ""/-1 for a host-origin default). Android governs notification sound by CHANNEL on O+, so OFF / volume-0
     *  route to the silent channel and everything else to the audible one (.wav CUSTOM maps to the channel sound,
     *  since the desktop file isn't portable to the OS channel). */
    private fun deliverNotification(payload: String) {
        val parts = payload.split('')
        val title: String
        val body: String
        if (parts.size >= 2) {
            title = parts[0].ifEmpty { "RuneLite" }
            body = parts[1]
        } else {
            title = "RuneLite"
            body = payload
        } // legacy/no-separator payload
        val soundType = parts.getOrNull(2).orEmpty()
        val volume = parts.getOrNull(3)?.toIntOrNull() ?: -1
        val silent = soundType.equals("OFF", ignoreCase = true) || volume == 0
        val channel = if (silent) NOTIF_CHANNEL_SILENT else NOTIF_CHANNEL
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.i(TAG, "ap2a: notification suppressed (POST_NOTIFICATIONS not granted): '$title'")
            return
        }
        // Tap reopens the game (single top — don't stack a second activity).
        val openSelf =
            packageManager.getLaunchIntentForPackage(packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
        val pi =
            openSelf?.let {
                android.app.PendingIntent.getActivity(
                    this,
                    0,
                    it,
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
                )
            }
        val n =
            NotificationCompat
                .Builder(this, channel)
                .setSmallIcon(R.drawable.ic_stat_rune)
                .setContentTitle(title.ifEmpty { "RuneMobile" })
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setSilent(silent) // belt-and-suspenders for pre-O (no channels); the channel governs on O+
                .apply { if (pi != null) setContentIntent(pi) }
                .build()
        try {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).notify(notifId++, n)
            Log.i(TAG, "ap2a: notification delivered title='$title' sound='$soundType' vol=$volume silent=$silent")
        } catch (t: Throwable) {
            Log.w(TAG, "ap2a: notify failed: ${t.message}")
        }
    }

    /** AP-0/Finding 25: open an in-game outbound link (Wiki/HiScore/plugin page) in an in-app Chrome Custom Tab
     *  (stays in the task, one back-press returns to the game) instead of cold-switching to the system browser.
     *  Falls back to ACTION_VIEW if no browser supports Custom Tabs. */
    private fun openLink(url: String) {
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            Log.i(TAG, "ap2a: link ignored (non-http): $url")
            return
        }
        val uri = Uri.parse(url)
        try {
            CustomTabsIntent
                .Builder()
                .setShowTitle(true)
                .build()
                .launchUrl(this, uri)
            Log.i(TAG, "ap2a: link opened (custom tab) $url")
        } catch (t: Throwable) {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, uri).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                Log.i(TAG, "ap2a: link opened (browser fallback) $url")
            } catch (t2: Throwable) {
                Log.w(TAG, "ap2a: openLink failed: ${t2.message}")
            }
        }
    }

    /*
     * A6: drive the native 2-col tab grid each frame from the render-thread-published MobileChromeBridge snapshot
     * (lock-free, no HotSpot attach). The grid engages in the supported resizable layouts (logged in + PRE_EOC
     * Classic or OSRS_STRETCH modern); there it hides the engine stones (HudVeneerBridge.setStonesHidden) so the
     * native cells ARE the tabs, highlights the open tab, and relocates the engine side panel flush-left of the
     * grid. In any other layout (FIXED) it disengages — un-hides the engine stones + releases the side panel — so
     * the real HUD renders (the iOS LAYOUT GUARD). All bridge writes go through onBridge (off the UI thread).
     */

    /**
     * UX-DISCRETE-01 / ENH-B06: arm the "Hopping…" scrim. Called from BOTH world-hop trigger sites (the HUD
     * quick-hop hotkey and the World Switcher row/Prev/Next). Sets a bounded deadline; updateChrome shows the
     * scrim while armed and clears it on the next in-world edge after the relog (or at the deadline). [label] is
     * shown on the card — "Hopping to world N…" when the target is known, else a generic "Switching worlds…".
     */
    private fun armHopScrim(label: String) {
        if (!::hoppingOverlay.isInitialized) return
        runOnUiThread {
            hoppingOverlay.setLabel(label)
            hopArmed = true
            hopSawLoggedOut = false
            hopDeadlineMs = SystemClock.uptimeMillis() + HOP_TIMEOUT_MS
            // Show immediately rather than waiting a frame, so the scrim is up before the logout chrome flashes.
            hoppingOverlay.setHopping(true)
            Log.i(TAG, "onboard: hop scrim armed ($label)")
        }
    }

    private fun updateChrome() {
        if (!::chromeOverlay.isInitialized) return
        // One-shot: once the engine has captured the tab/stone/chat sprites from the live cache (after login),
        // hand them to the native chrome + cache them for next boot. Latched, so this is inert after it lands.
        if (!tabSpritesApplied) {
            val sprJson = JvmLauncher.tabSprites()
            if (sprJson.isNotEmpty()) {
                TabSprites.parse(sprJson)?.let { set ->
                    chromeOverlay.setSprites(set)
                    chatTabOverlay.setSprites(set)
                    // Only persist a COMPLETE set — a deadline-partial would otherwise show glyphless tiles on every
                    // later boot. A fresh process re-captures from the cache (usually complete within a few ticks).
                    if (set.complete) TabSprites.cache(filesDir, sprJson)
                    tabSpritesApplied = true
                    Log.i(TAG, "ANDROID_TABSPRITES_GREEN runtime cache sprites applied (${sprJson.length} bytes, complete=${set.complete})")
                }
            }
        }
        val json = JvmLauncher.chromeSnapshotPub()
        // PERF-FRAME-PACING-01: skip the per-frame JSON parse + the whole native-veneer cascade when NOTHING the
        // chrome layer renders has changed. The signature folds in EVERY dynamic input updateChrome (and its
        // helpers) reads:
        //  - the chrome snapshot (loggedIn/loginScreen/reconnecting/rootKind/activeTab + all the canvas rects);
        //  - the LIVE chat + dialogue snapshots (applyChatTabs consumes these directly — omitting them would
        //    freeze the native chat-tab/dialogue veneer while the chrome snapshot sat unchanged);
        //  - the non-snapshot toggles railsShown / mapOpen / reconnectTestOverride;
        //  - the frame + view geometry and safe insets (every relocate scales/positions by these). A pre-layout /
        //    detached 0x0 view is just another captured value: its 0↔nonzero transitions flip the signature (so the
        //    body re-runs and relocates settle), every geometry helper already early-returns while a dimension is 0,
        //    and the non-geometry chrome state (grid/active-tab/reconnect) tracks the snapshot regardless of size.
        // Time-based transitions (splash dismiss, hop scrim, the post-login chrome-suppression window) must still
        // re-evaluate on unchanged input until their deadline passes — `timedPending` forces those through. The
        // sawLoginScreen latch is fully determined by the snapshot, so snapshot equality already covers it.
        val chatSnap = JvmLauncher.chatSnapshotPub()
        val dlgSnap = JvmLauncher.dialogueJsonPub()
        val ins = safeInsetsLTR()
        // Frame-start view of the post-login chrome-suppression window. It self-clears purely by wall clock (no
        // state flag), so it MUST live in the signature: when it flips true→false on the deadline edge the sig
        // changes, which forces one body run to engage chrome — otherwise an idle frame at the exact expiry would
        // short-circuit and chrome would stall until the next input change. (This is the frame-start value; the
        // body recomputes its own `inLoginTransition` after the arming step, since the arming frame is already
        // forced through by the loggedIn snapshot edge.)
        val inLoginTransitionSig = SystemClock.uptimeMillis() < loginTransitionUntilMs
        // Variable-length JSON blobs are length-prefixed (netstring framing) so no field content — including a
        // chat message that happens to contain '|' or ':' — can ever forge a colliding signature.
        val sig =
            StringBuilder(json.length + chatSnap.length + dlgSnap.length + 96)
                .append(json.length)
                .append(':')
                .append(json)
                .append(chatSnap.length)
                .append(':')
                .append(chatSnap)
                .append(dlgSnap.length)
                .append(':')
                .append(dlgSnap)
                .append('|')
                .append(chromeOverlay.railsShown)
                .append('|')
                .append(mapOpen)
                .append('|')
                .append(reconnectTestOverride)
                .append('|')
                .append(sessionExpiredTestOverride)
                .append('|')
                .append(inLoginTransitionSig)
                .append('|')
                .append(surfaceView.width)
                .append('x')
                .append(surfaceView.height)
                .append('|')
                .append(JvmLauncher.frameWidth())
                .append('x')
                .append(JvmLauncher.frameHeight())
                .append('|')
                .append(ins[0])
                .append(',')
                .append(ins[1])
                .append(',')
                .append(ins[2])
                .append(',')
                .append(ins[3])
                .toString()
        // Splash + hop are NOT in the signature: each is a state flag the body itself clears (on first frame /
        // loggedIn edge / its own timeout), so while either is up we must run the body every frame to do that
        // clearing — a stable signature must not be allowed to freeze them.
        val timedPending = (::splashOverlay.isInitialized && splashOverlay.isActive) || hopArmed
        if (!timedPending && sig == lastChromeSig) return
        lastChromeSig = sig
        val o =
            try {
                JSONObject(json)
            } catch (e: Exception) {
                null
            }
        val loggedIn = o?.optBoolean("loggedIn") == true
        // Bug 8: arm the login-transition latch off a genuine LOGIN_SCREEN→LOGGED_IN edge. While logged out we note
        // that we saw the login screen (the snapshot's loginScreen flag); on the next logged-in frame that consumes
        // the flag and opens a bounded suppression window. An in-game LOADING/teleport blip reports loggedIn=false
        // WITHOUT loginScreen, so it never arms the window → chrome stays engaged through region loads (unchanged).
        if (!loggedIn) {
            if (o?.optBoolean("loginScreen") == true) sawLoginScreen = true
        } else if (sawLoginScreen) {
            sawLoginScreen = false
            loginTransitionUntilMs = SystemClock.uptimeMillis() + LOGIN_TRANSITION_MS
        }
        val inLoginTransition = SystemClock.uptimeMillis() < loginTransitionUntilMs
        // FIX-9: show the native "Reconnecting…" scrim while the headless auto-reconnect recovers a dropped
        // session (the snapshot only carries the flag during an active reconnect — a normal login screen or a
        // deliberate logout omits it). The DEBUG override forces it for screencap verification.
        if (::reconnectOverlay.isInitialized) {
            val live = !loggedIn && o?.optBoolean("reconnecting") == true
            val show = reconnectTestOverride ?: live
            if (reconnectOverlay.setReconnecting(show)) {
                Log.i(TAG, "fix9: reconnect overlay -> $show")
            }
        }
        // UX-LOGIN-01: show the interactive "Session expired" card when the login machine has GIVEN UP (autologin/
        // reconnect exhausted) — mutually exclusive with the reconnecting scrim (which the bridge only flags while
        // recovery is still active). Its button re-runs LoginActivity. The DEBUG override forces it for screencap.
        if (::sessionExpiredOverlay.isInitialized) {
            val live = !loggedIn && o?.optBoolean("sessionExpired") == true
            val show = sessionExpiredTestOverride ?: live
            if (sessionExpiredOverlay.setVisible(show)) {
                Log.i(TAG, "uxlogin01: session-expired overlay -> $show")
            }
        }
        // FATAL-1: latch the engine-fatal card on the snapshot's fatal flag. The bridge makes fatal outrank
        // reconnecting/sessionExpired (a fatal is not recoverable), so the overlays never co-fire; the card
        // never hides (terminal for this process — its button relaunches).
        if (::fatalErrorOverlay.isInitialized && o?.optBoolean("fatalError") == true) {
            if (fatalErrorOverlay.showFatal(o.optString("fatalCode", "unknown"))) {
                Log.i(TAG, "fatal1: engine-fatal card shown (code=${o.optString("fatalCode")})")
            }
        }
        // UX-ONBOARD-01: dismiss the cold-start splash only once the engine has actually PAINTED a frame
        // (frameWidth>0, a cheap native counter universal across renderers) — or the wall-clock failsafe fires. A
        // device cold-start trace showed the snapshot's login STATE (loginScreen/loggedIn) flips ~1.1 s BEFORE the
        // first GL blit, so dismissing on state alone briefly uncovered the unpainted (black) SurfaceView. Holding
        // the branded splash until there is real content to show closes that gap; the failsafe still guarantees the
        // splash can never linger over a running game. `realState` now only refines the status text + diagnostics.
        if (::splashOverlay.isInitialized && splashOverlay.isActive) {
            val firstFrame = JvmLauncher.frameWidth() > 0
            val realState = loggedIn || o?.optBoolean("loginScreen") == true
            val timedOut = SystemClock.uptimeMillis() >= splashDeadlineMs
            if (firstFrame || timedOut) {
                splashOverlay.dismiss()
                Log.i(TAG, "onboard: splash dismissed (frame=$firstFrame state=$realState timeout=$timedOut)")
            } else {
                // Past unpack, before the first painted frame: reflect the boot phase rather than a stale
                // "Unpacking…". Once the engine reports a real login state the first blit is imminent, so say so.
                splashOverlay.setStatus(if (realState) "Entering game…" else "Starting up…")
            }
        }
        // UX-DISCRETE-01 / ENH-B06: drive the "Hopping…" scrim purely Android-side off the loggedIn signal. The
        // relog hop logs out then back in; we hold the scrim until we've seen the logout AND the subsequent
        // logged-in edge (or a bounded timeout), so the routine hop stops reading as a kick.
        if (::hoppingOverlay.isInitialized) {
            if (hopArmed) {
                if (!loggedIn) hopSawLoggedOut = true
                val timedOut = SystemClock.uptimeMillis() >= hopDeadlineMs
                val backInWorld = loggedIn && hopSawLoggedOut
                if (timedOut || backInWorld) {
                    hopArmed = false
                    Log.i(TAG, "onboard: hop scrim cleared (backInWorld=$backInWorld timeout=$timedOut)")
                }
            }
            if (hoppingOverlay.setHopping(hopArmed)) {
                Log.i(TAG, "onboard: hop scrim -> $hopArmed")
            }
        }
        val topLevel = o?.optInt("topLevelId", -1) ?: -1
        val rootKind = o?.optString("rootKind", "") ?: ""
        val active = o?.optInt("activeTab", -1) ?: -1
        // The native grid's cells map to real engine stones via openTab op-replay. Engage in BOTH resizable roots:
        // PRE_EOC (Classic, 164) and OSRS_STRETCH (modern, 161) — the shared layer hides/replays the right stones for
        // each (stoneIds/openTabNow branch on the root, STONE0..13 in identical order). FIXED is excluded (the shared
        // tick hard-returns on !isResized + stoneIds has no FIXED branch), so it keeps the raw engine HUD.
        // Bug 8: `inLoginTransition` holds chrome off for the bounded post-login window (then engages regardless),
        // so the grid/chat-tabs don't flash over the half-built welcome frame. Raw engine HUD shows during the window.
        val supported = loggedIn && (rootKind == "PRE_EOC" || rootKind == "OSRS_STRETCH") && !inLoginTransition
        chromeOverlay.setGridEnabled(supported)
        chromeOverlay.setActiveTab(active)

        // AP-0 chat scroll-by-drag: cache the live chatbox bounds (canvas px) for the gesture-start hit test.
        // The snapshot reports the post-relocate bounds, so the scroll region tracks the chat-at-top move.
        chatRectCanvas =
            if (loggedIn) {
                o
                    ?.optJSONArray("chat")
                    ?.takeIf { it.length() >= 4 && it.optInt(2) > 0 && it.optInt(3) > 0 }
                    ?.let { intArrayOf(it.optInt(0), it.optInt(1), it.optInt(2), it.optInt(3)) }
            } else {
                null
            }
        // FIX-4: live inventory grid bounds (null when the inventory tab isn't showing) for the item-drag hit test.
        invRectCanvas =
            if (loggedIn) {
                o
                    ?.optJSONArray("inv")
                    ?.takeIf { it.length() >= 4 && it.optInt(2) > 0 && it.optInt(3) > 0 }
                    ?.let { intArrayOf(it.optInt(0), it.optInt(1), it.optInt(2), it.optInt(3)) }
            } else {
                null
            }
        // DRAG-1b: the Prayer/Spellbook/Bank reorder-pane rects (empty when none on-screen) for the reorder-drag hit test.
        reorderRectsCanvas =
            if (loggedIn) {
                val arr = o?.optJSONArray("reorderPanes")
                if (arr == null || arr.length() == 0) {
                    emptyList()
                } else {
                    val out = ArrayList<IntArray>(arr.length())
                    for (i in 0 until arr.length()) {
                        val r = arr.optJSONArray(i) ?: continue
                        if (r.length() >= 4 && r.optInt(2) > 0 && r.optInt(3) > 0) {
                            out.add(intArrayOf(r.optInt(0), r.optInt(1), r.optInt(2), r.optInt(3)))
                        }
                    }
                    out
                }
            } else {
                emptyList()
            }

        val gridOn = supported && chromeOverlay.railsShown
        applyStonesHidden(gridOn)
        // Phase-5: the pill hides while the world map owns the screen (its engine row-height push resets too,
        // mirroring iOS hideChatTabs); the chat/side/minimap RELOCATES keep being sent — the shared tick gates
        // their application while the map is open and restores them on close, so nothing is released here.
        applyChatTabs(gridOn && !mapOpen)
        if (gridOn) {
            applySidePanel(o)
            applyChatAtTop()
            applyMinimap(o)
            if (!chromeUiLogged && chromeOverlay.gridLeftPx > 0f) {
                chromeUiLogged = true
                Log.i(
                    TAG,
                    "ANDROID_A6_UI_GREEN native 2-col tab grid drawn (engine stones hidden) rootKind=$rootKind topLevel=$topLevel activeTab=$active view=${surfaceView.width}x${surfaceView.height}",
                )
            }
        } else {
            releaseSidePanel()
            releaseChat()
            releaseMinimap()
        }
    }

    /** Drive the enlarged native chat-tab veneer: feed it the published chat snapshot + game→view scale each
     *  frame, and tell the engine to push its message area below the taller native row ([on]) or restore the 23px
     *  default ([!on]). The row-height write is sent only on change (off the UI thread). */
    private fun applyChatTabs(on: Boolean) {
        val fw = JvmLauncher.frameWidth()
        val fh = JvmLauncher.frameHeight()
        val vw = surfaceView.width
        val vh = surfaceView.height
        val sx = if (fw > 0 && vw > 0) vw.toFloat() / fw else 1f
        val sy = if (fh > 0 && vh > 0) vh.toFloat() / fh else 1f
        val chatSnap = if (on) JvmLauncher.chatSnapshotPub() else ""
        val n = chatTabOverlay.update(chatSnap, sx, sy, on)
        // Path B: when the engine renders its own opaque dialogue (engineDialogue), SUPPRESS the native parchment so
        // the engine's dialogue + full 3D head shows through. Otherwise (make-X/reward boxes, or Path-B off) draw the
        // native parchment as before.
        val engineDlg = chatSnap.contains("\"engineDialogue\":true")
        dialogueOverlay.update(chatSnap, if (on && !engineDlg) JvmLauncher.dialogueJsonPub() else "{}", sx, sy, on && !engineDlg)
        // Auto-open/close: a collapsed chat hides the engine tabs -> the dialogue raster is suppressed. So when an
        // engine dialogue opens while collapsed, un-collapse for its duration and restore the collapsed state when it
        // ends (official-mobile behaviour). Native is the single owner of chatCollapsed (no bridge writer / no race).
        if (on) {
            if (engineDlg && !dialogueWasActive && chatCollapsed) {
                savedCollapsedForDialogue = true
                chatCollapsed = false
                JvmLauncher.onBridgeTouch { JvmLauncher.setChatCollapsed(false) }
                Log.i(TAG, "dlg: auto-opened chat for dialogue")
            } else if (!engineDlg && dialogueWasActive && savedCollapsedForDialogue) {
                savedCollapsedForDialogue = false
                chatCollapsed = true
                JvmLauncher.onBridgeTouch { JvmLauncher.setChatCollapsed(true) }
                Log.i(TAG, "dlg: restored collapsed chat after dialogue")
            }
            dialogueWasActive = engineDlg
        }
        if (on && n > 0 && !chatTabsLogged) {
            chatTabsLogged = true
            Log.i(TAG, "ANDROID_A3_CHATTABS_GREEN enlarged native chat-tab row drawn ($n tabs) sx=$sx sy=$sy")
        }
        val wantRowH = if (on) ChatPillView.ROW_H_CANVAS else 0
        if (wantRowH != lastChatRowH) {
            lastChatRowH = wantRowH
            JvmLauncher.onBridge {
                JvmLauncher.setChatTabRowHeight(wantRowH)
                JvmLauncher.setChatAreaWidth(0)
            }
        }
    }

    /** Send the desired engine-stone hide state to HudVeneerBridge, only when it changes (off the UI thread). */
    private fun applyStonesHidden(hide: Boolean) {
        if (lastStonesHidden == hide) return
        lastStonesHidden = hide
        JvmLauncher.onBridge { JvmLauncher.setStonesHidden(hide) }
    }

    /** Relocate the engine side panel flush-left of the native grid (the iOS arrangement). The grid's left/top
     *  edge is in view px; convert to game-canvas px (k = frameW/viewW) and subtract the panel width. Sent only
     *  when it changes. No-op until the grid has laid out (gridLeftPx>0) and a frame size is known. */
    private fun applySidePanel(o: JSONObject?) {
        val fw = JvmLauncher.frameWidth()
        val vw = surfaceView.width
        if (fw <= 0 || vw <= 0) return
        val k = fw.toFloat() / vw.toFloat()
        var sideW = 204 // fallback until the panel is open + reports its width
        var sideHc = 275 // the SIDE_CONTAINER is a fixed 204x275 canvas raster
        val sc = o?.optJSONArray("sideContainer")
        if (sc != null && sc.length() >= 4) {
            if (sc.optInt(2) > 0) sideW = sc.getInt(2)
            if (sc.optInt(3) > 0) sideHc = sc.getInt(3)
        }
        // UI-1: the panel is a fixed engine raster we can't grow, so shrink the native grid to the panel height
        // (constant 275 canvas px) — they then share both the top and bottom edge. Do this BEFORE reading the
        // grid edges below so the relocate uses the post-shrink geometry (setTargetGridHeight recomputes it).
        chromeOverlay.setTargetGridHeight(sideHc / k)
        val gx0 = chromeOverlay.gridLeftPx
        val gy0 = chromeOverlay.gridTopPx
        if (gx0 <= 0f) return
        val sideX = maxOf(0, Math.round(gx0 * k) - sideW) // right edge flush against the grid's left edge
        val sideY = maxOf(0, Math.round(gy0 * k)) // stones hidden, so top-align with the grid
        if (sideX == lastSideX && sideY == lastSideY) return
        lastSideX = sideX
        lastSideY = sideY
        JvmLauncher.onBridge { JvmLauncher.relocateSidePanel(sideX, sideY) }
    }

    /** Stop relocating the engine side panel (let it return to its native position) when the grid disengages. */
    private fun releaseSidePanel() {
        chromeOverlay.setTargetGridHeight(0f) // UI-1: grid back to its natural size when the chrome disengages
        if (lastSideX == -1 && lastSideY == -1) return
        lastSideX = -1
        lastSideY = -1
        JvmLauncher.onBridge { JvmLauncher.relocateSidePanel(-1, -1) }
    }

    /** Move the engine's own chatbox to the top-left (inside the safe area) and flip it to OSRS transparent-chat
     *  mode — the mobile look. It stays the live engine chat (tabs / scrollback / colours / input all work); the
     *  engine tick re-applies it. Insets are in view px → canvas px (k = frameW/viewW); sent only when changed. */
    private fun applyChatAtTop() {
        val fw = JvmLauncher.frameWidth()
        val fh = JvmLauncher.frameHeight()
        val vw = surfaceView.width
        val vh = surfaceView.height
        if (fw <= 0 || fh <= 0 || vw <= 0 || vh <= 0) return
        val kx = fw.toFloat() / vw
        val ky = fh.toFloat() / vh
        val ins = safeInsetsLTR()
        val margin = 8 // canvas-px breathing room from the safe edge
        val chatX = Math.round(ins[0] * kx) + margin
        val chatY = Math.round(ins[1] * ky) + margin
        if (chatX == lastChatX && chatY == lastChatY) return
        lastChatX = chatX
        lastChatY = chatY
        JvmLauncher.onBridge { JvmLauncher.relocateChat(chatX, chatY, true) }
    }

    /** Stop relocating the chat (let it return to its native bottom position) when the chrome disengages.
     *  Also un-collapse: with the pill gone there'd be no way to expand a shoved-off-canvas chat. */
    private fun releaseChat() {
        if (lastChatX == -1 && lastChatY == -1) return
        lastChatX = -1
        lastChatY = -1
        chatCollapsed = false
        JvmLauncher.onBridge {
            JvmLauncher.relocateChat(-1, -1, false)
            JvmLauncher.setChatCollapsed(false)
        }
    }

    // Phase-3: last overlay-insets values sent to the shared OverlayRenderer (send only on change).
    private var lastOverlayInsets: IntArray? = null

    /** Phase-3 overlay safe-insets: convert the full safe-area insets (view px, all four edges) to CANVAS px
     *  and push them to HudVeneerBridge.setOverlaySafeInsets — the shared OverlayRenderer then keeps every
     *  plugin-overlay snap corner clear of the cutout/system bars AND drops TOP_LEFT below the relocated chat
     *  (getOverlayChatAvoid, consumed Java-side). Zero-impact when insets are 0 (emulator, desktop). */
    private fun applyOverlayInsets() {
        val fw = JvmLauncher.frameWidth()
        val fh = JvmLauncher.frameHeight()
        val vw = surfaceView.width
        val vh = surfaceView.height
        if (fw <= 0 || fh <= 0 || vw <= 0 || vh <= 0) return
        val wi = surfaceView.rootWindowInsets ?: return
        val (l, t, r, b) =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val i = wi.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                listOf(i.left, i.top, i.right, i.bottom)
            } else {
                @Suppress("DEPRECATION")
                listOf(wi.stableInsetLeft, wi.stableInsetTop, wi.stableInsetRight, wi.stableInsetBottom)
            }
        val canvas = intArrayOf(l * fw / vw, t * fh / vh, r * fw / vw, b * fh / vh)
        if (lastOverlayInsets?.contentEquals(canvas) == true) return
        lastOverlayInsets = canvas
        Log.i(TAG, "p3: overlay safe-insets -> canvas(${canvas[0]},${canvas[1]},${canvas[2]},${canvas[3]})")
        JvmLauncher.onBridge { JvmLauncher.setOverlayInsets(canvas[0], canvas[1], canvas[2], canvas[3]) }
    }

    /** Phase-5: parse the published world-map snapshot (per frame, cheap — skipped when the string is
     *  unchanged) and gate the native chrome on the open state. The engine-side HUD shoves are shared. */
    private fun updateWorldMap() {
        val snap = JvmLauncher.mapSnapshotPub()
        if (snap == lastMapSnapshot) return
        lastMapSnapshot = snap
        val o =
            try {
                JSONObject(snap)
            } catch (e: Exception) {
                null
            }
        val open = o?.optBoolean("open") == true

        fun rect(key: String): IntArray? =
            o
                ?.optJSONArray(key)
                ?.takeIf { it.length() >= 4 }
                ?.let { intArrayOf(it.optInt(0), it.optInt(1), it.optInt(2), it.optInt(3)) }
        mapRectCanvas = if (open) rect("map") else null
        mapSearchCanvas = if (open) rect("search") else null
        mapCloseCanvas = if (open) rect("close") else null
        mapZoomInCanvas = if (open) rect("zoomIn") else null
        mapZoomOutCanvas = if (open) rect("zoomOut") else null
        mapWindowCanvas = if (open) rect("window") else null
        mapKeyCanvas = if (open) rect("key") else null
        mapMaplistCanvas = if (open) rect("maplist") else null
        // FIX-14: the map search never flips INPUT_TYPE, so the soft keyboard would otherwise linger over the
        // jumped-to map until the map closes. Watch the engine WORLDMAP_SEARCHING flag (published in the
        // snapshot): on its 1->0 edge the search has committed (Enter) or been cancelled (Quit) — drop the latch
        // so the per-frame input poll auto-hides the keyboard.
        val searching = open && o?.optInt("searching", 0) == 1
        if (mapWasSearching && !searching && mapSearchKeyboard) {
            mapSearchKeyboard = false
            Log.i(TAG, "p5: map search committed -> dismiss keyboard")
        }
        mapWasSearching = searching
        if (open != mapOpen) {
            mapOpen = open
            // The native chrome would cover the floating window — hide it while the map owns the screen.
            // View-level visibility only: railsShown (the user's A/B toggle) and all relocates are untouched.
            chromeOverlay.visibility = if (open) View.GONE else View.VISIBLE
            if (!open) {
                mapPanning = false
                mapScrolling = false
                mapSearchKeyboard = false
                resetMapFullscreen()
            }
            Log.i(
                TAG,
                "p5: world map ${if (open) "OPEN" else "closed"} rect=${mapRectCanvas?.joinToString(",")}" +
                    if (open) {
                        " close=${mapCloseCanvas?.joinToString(",")} search=${mapSearchCanvas?.joinToString(",")}" +
                            " zoomIn=${mapZoomInCanvas?.joinToString(",")} zoomOut=${mapZoomOutCanvas?.joinToString(",")}"
                    } else {
                        ""
                    },
            )
        }
        // Stretch the engine map window to fill the whole screen (edge-to-edge, only the map shows). Re-apply
        // when the window rect first settles or changes (e.g. a canvas resize); the close edge resets it above.
        if (open) {
            val win = mapWindowCanvas
            if (win != null && win[2] > 0 && win[3] > 0 && !win.contentEquals(lastMapWindowApplied)) {
                applyMapFullscreen(win)
            }
        }
    }

    /** Non-uniformly scale + translate the SurfaceView so the map-window canvas rect fills the whole view.
     *  Android delivers touches to a transformed view in its UNtransformed local space, so toGameX/Y (hence
     *  pan/tap/zoom/close) keep landing correctly with no touch-pipeline change. UI-thread only. */
    private fun applyMapFullscreen(win: IntArray) {
        // canvasW/canvasH = the engine render canvas (boot-set, stable) — the SAME space the snapshot rects use.
        // (frameWidth()/frameHeight() = the last-blitted GL frame, which can read 0 before a frame composites.)
        val cw = canvasW
        val ch = canvasH
        val vw = surfaceView.width
        val vh = surfaceView.height
        if (cw <= 0 || ch <= 0 || vw <= 0 || vh <= 0 || win[2] <= 0 || win[3] <= 0) return
        // Map the window canvas-rect onto the full view: scale so win[w,h] fills the canvas, pivot (0,0) +
        // translate so win[x,y] lands at the view origin. sx/sy reduce to canvas/win; tx/ty carry the view scale.
        val sx = cw.toFloat() / win[2]
        val sy = ch.toFloat() / win[3]
        surfaceView.pivotX = 0f
        surfaceView.pivotY = 0f
        surfaceView.scaleX = sx
        surfaceView.scaleY = sy
        surfaceView.translationX = -win[0].toFloat() * vw / win[2]
        surfaceView.translationY = -win[1].toFloat() * vh / win[3]
        lastMapWindowApplied = win.copyOf()
        Log.i(TAG, "p5: map fullscreen win=${win.joinToString(",")} canvas=${cw}x$ch scale=($sx,$sy)")
    }

    /** Restore the SurfaceView to its untransformed full-frame state when the map closes. UI-thread only. */
    private fun resetMapFullscreen() {
        lastMapWindowApplied = null
        mapWindowCanvas = null
        if (surfaceView.scaleX == 1f && surfaceView.scaleY == 1f &&
            surfaceView.translationX == 0f && surfaceView.translationY == 0f
        ) {
            return
        }
        surfaceView.scaleX = 1f
        surfaceView.scaleY = 1f
        surfaceView.translationX = 0f
        surfaceView.translationY = 0f
        surfaceView.pivotX = surfaceView.width / 2f
        surfaceView.pivotY = surfaceView.height / 2f
        Log.i(TAG, "p5: map fullscreen reset")
    }

    private fun inCanvasRect(
        r: IntArray?,
        gx: Int,
        gy: Int,
    ): Boolean = r != null && gx >= r[0] && gx < r[0] + r[2] && gy >= r[1] && gy < r[1] + r[3]

    /** [left, top, right, bottom] safe-area insets in VIEW px (display cutout + system bars), so the relocated HUD
     *  clears a landscape notch / nav bar. 0 on the full-bleed emulator. (Existing callers index 0..2 = L/T/R; the
     *  bottom element was added for UX-XCUT-01's HUD-control inset.) */
    private fun safeInsetsLTR(): IntArray {
        val wi = surfaceView.rootWindowInsets ?: return intArrayOf(0, 0, 0, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val i = wi.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            intArrayOf(i.left, i.top, i.right, i.bottom)
        } else {
            @Suppress("DEPRECATION")
            intArrayOf(wi.stableInsetLeft, wi.stableInsetTop, wi.stableInsetRight, wi.stableInsetBottom)
        }
    }

    /** UX-XCUT-01: bump the release HUD controls' margins by the safe-area insets so none sit under the landscape
     *  cutout or the bottom gesture bar. The bottom-START devBar + hotkey strip take the LEFT inset (a landscape
     *  cutout on the left edge) and the BOTTOM inset; the bottom-CENTER ≡ Plugins handle takes the BOTTOM inset.
     *  Additive over the captured base margins; a no-op when insets are 0. Re-runs on every inset delivery
     *  (rotation / configuration change re-dispatches insets). */
    private fun applyHudControlInsets(insets: WindowInsetsCompat) {
        val i = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
        devBar?.let { v ->
            (v.layoutParams as? FrameLayout.LayoutParams)?.let { lp ->
                lp.leftMargin = devBarBaseLeft + i.left
                lp.bottomMargin = devBarBaseBottom + i.bottom
                v.layoutParams = lp
            }
        }
        hotkeyStrip?.let { v ->
            (v.layoutParams as? FrameLayout.LayoutParams)?.let { lp ->
                lp.leftMargin = hotkeyBaseLeft + i.left
                lp.bottomMargin = hotkeyBaseBottom + i.bottom
                v.layoutParams = lp
            }
        }
        launcherHandle?.let { v ->
            (v.layoutParams as? FrameLayout.LayoutParams)?.let { lp ->
                lp.bottomMargin = handleBaseBottom + i.bottom
                v.layoutParams = lp
            }
        }
    }

    /** A7 edge-to-edge: pull the engine minimap+orbs cluster (MAP_CONTAINER) into the top-right safe area — flush
     *  to the right edge, top-aligned, clear of a notch. It stays the live HUD (minimap click-to-walk + orb clicks
     *  keep working — the iOS relocateEngineMinimap move). The cluster width comes from the snapshot. On change. */
    private fun applyMinimap(o: JSONObject?) {
        val fw = JvmLauncher.frameWidth()
        val fh = JvmLauncher.frameHeight()
        val vw = surfaceView.width
        val vh = surfaceView.height
        if (fw <= 0 || fh <= 0 || vw <= 0 || vh <= 0) return
        val kx = fw.toFloat() / vw
        val ky = fh.toFloat() / vh
        val ins = safeInsetsLTR()
        val margin = 8
        var mapW = 211 // fallback cluster width until the snapshot reports it
        var mapH = 340 // fallback cluster height until the snapshot reports it
        val mc = o?.optJSONArray("mapContainer")
        if (mc != null && mc.length() >= 4 && mc.optInt(2) > 0) {
            mapW = mc.getInt(2)
            if (mc.optInt(3) > 0) mapH = mc.getInt(3)
        }
        val mmX = maxOf(0, fw - mapW - Math.round(ins[2] * kx) - margin)
        val mmY = Math.round(ins[1] * ky) + margin
        // AP-0: cache the relocated cluster's canvas rect so a tap on the minimap/orbs suppresses the walk-ring.
        minimapRectCanvas = intArrayOf(mmX, mmY, mapW, mapH)
        if (mmX == lastMmX && mmY == lastMmY) return
        lastMmX = mmX
        lastMmY = mmY
        JvmLauncher.onBridge { JvmLauncher.relocateMinimap(mmX, mmY) }
    }

    /** Stop relocating the minimap (let it return to its native position) when the chrome disengages. */
    private fun releaseMinimap() {
        minimapRectCanvas = null // AP-0: no relocated cluster -> don't suppress rings (raw-stones mode)
        if (lastMmX == -1 && lastMmY == -1) return
        lastMmX = -1
        lastMmY = -1
        JvmLauncher.onBridge { JvmLauncher.relocateMinimap(-1, -1) }
    }

    private fun vibrateTick() {
        val v = vibrator ?: return
        // Guard the vibrate: it needs the VIBRATE permission and some devices restrict the vibrator outright — a
        // SecurityException here must never take down the UI thread (it once did, on the menu-highlight haptic).
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createOneShot(18, VibrationEffect.DEFAULT_AMPLITUDE))
            }
        } catch (e: Exception) {
            // haptics are best-effort; ignore
        }
    }

    // ---- A2 press-and-peek menu state machine -------------------------------------------------------

    /** Long-press: open the engine right-click menu at the finger and start polling for it to land. */
    private fun beginMenuPeek(
        viewX: Float,
        viewY: Float,
    ) {
        if (menuActive) return
        val gx = toGameX(viewX)
        val gy = toGameY(viewY)
        menuAnchorX = viewX
        menuAnchorY = viewY
        menuCurX = viewX
        menuCurY = viewY
        menuHandRight = viewX > surfaceView.width * 0.5f
        menuActive = true
        menuBuilding = true
        menuTouchActive = true
        menuHighlight = -1
        menuTapMode = false
        menuTapArmed = false
        menuDrillParent = -1 // FIX-10b: fresh menu
        menuOpenAtNanos = System.nanoTime()
        JvmLauncher.click(gx, gy, 3) // open the engine right-click menu at the finger
        Log.i(TAG, "a2: long-press -> menu open game=($gx,$gy) hand=${if (menuHandRight) "R" else "L"}")
    }

    /** A3: a native chat-tab long-press opens the engine's filter menu by right-clicking the LIVE engine chat
     *  button (engine canvas px, from the snapshot) and anchoring the native press-and-peek overlay at the finger
     *  (view px). Reuses the A2 menu machinery (tryBuildNativeMenu / updateMenuHighlight / commitMenuSelection),
     *  driven by the chat overlay's long-press callbacks (it owns the gesture). Mirrors the iOS onChatTabLongPress. */
    private fun beginChatFilterMenu(
        engineCx: Int,
        engineCy: Int,
        viewX: Float,
        viewY: Float,
    ) {
        if (menuActive) return
        menuAnchorX = viewX
        menuAnchorY = viewY
        menuCurX = viewX
        menuCurY = viewY
        menuHandRight = viewX > surfaceView.width * 0.5f
        menuActive = true
        menuBuilding = true
        menuTouchActive = true
        menuHighlight = -1
        menuTapMode = false
        menuTapArmed = false
        menuDrillParent = -1 // FIX-10b: fresh menu
        menuOpenAtNanos = System.nanoTime()
        JvmLauncher.click(engineCx, engineCy, 3) // right-click the live engine chat button -> its filter menu
        Log.i(TAG, "a3: chat tab long-press -> filter menu game=($engineCx,$engineCy)")
    }

    /** Poll the snapshot (each frame, while building) until the engine menu the long-press opened is reflected. */
    private fun tryBuildNativeMenu() {
        val d =
            try {
                JSONObject(JvmLauncher.menuSnapshot())
            } catch (e: Exception) {
                null
            }
        val entries = d?.optJSONArray("entries")
        val ready =
            d != null && d.optBoolean("loggedIn", false) && d.optBoolean("menuOpen", false) &&
                d.optInt("count", 0) > 0 && entries != null && entries.length() > 0
        if (ready) {
            menuBuilding = false
            presentNativeMenu(d!!)
            // Drag-mode: a finger lifted before the menu built means cancel. Tap-mode (FIX-10b) is persistent —
            // if the finger is already up, the menu just becomes immediately tap-ready (no auto-cancel).
            if (menuTapMode) {
                if (!menuTouchActive) menuTapArmed = true
            } else if (!menuTouchActive) {
                cancelMenu()
            }
            return
        }
        if (System.nanoTime() - menuOpenAtNanos > 1_000_000_000L) {
            Log.i(TAG, "a2: no engine menu within 1s — aborting")
            teardownMenu()
        }
    }

    /** Build the native overlay from the snapshot (game-space engine box + display-order entries). */
    private fun presentNativeMenu(d: JSONObject) {
        emX = d.optInt("menuX", -1)
        emY = d.optInt("menuY", -1)
        emW = d.optInt("menuW", 0)
        emCount = d.optInt("count", 0)
        val arr = d.optJSONArray("entries") ?: return
        val n = minOf(arr.length(), 14)
        if (n == 0 || emW <= 0) {
            cancelMenu()
            return
        }
        val items = ArrayList<MenuOverlayView.Entry>(n)
        var anySub = false
        for (k in 0 until n) {
            val o = arr.optJSONObject(k) ?: continue
            // FIX-10b: a "sub" array (Menu Entry Swapper swap list) makes this a drill-in parent. engineIndex=k
            // (the top-level display index) so a tap can commit it via invokeMenuEntry / geometry.
            val subArr = o.optJSONArray("sub")
            var sub: List<MenuOverlayView.Entry>? = null
            if (subArr != null && subArr.length() > 0) {
                val cs = ArrayList<MenuOverlayView.Entry>(subArr.length())
                for (c in 0 until subArr.length()) {
                    val co = subArr.optJSONObject(c) ?: continue
                    cs.add(MenuOverlayView.Entry(co.optString("opt", ""), co.optString("tgt", ""), engineIndex = c))
                }
                if (cs.isNotEmpty()) {
                    sub = cs
                    anySub = true
                }
            }
            val role = if (sub != null) MenuOverlayView.Role.PARENT else MenuOverlayView.Role.NORMAL
            items.add(MenuOverlayView.Entry(o.optString("opt", ""), o.optString("tgt", ""), sub = sub, role = role, engineIndex = k))
        }
        menuTopEntries = items
        menuDrillParent = -1
        // FIX-10b: tap-mode when there's a submenu to drill into, or ⇧ is latched (shift-customize). Else the
        // existing slide-select drag menu (tall menus already shrink-to-fit). The ⇧ button is the shift entry.
        menuTapMode = anySub || shiftHeld
        if (menuTapMode) {
            buildTapMenu(items, drilled = false)
            Log.i(TAG, "fix10b: tap menu $emCount entries (anySub=$anySub shift=$shiftHeld) at game=($emX,$emY)")
        } else {
            menuOverlay.show(items, menuAnchorX, menuAnchorY, menuHandRight)
            Log.i(TAG, "a2: native menu $emCount entries at game=($emX,$emY) w=$emW")
            if (menuTouchActive) updateMenuHighlight(menuCurX, menuCurY)
        }
    }

    /** FIX-10b: (re)build the persistent tap-menu — top level, or a submenu (prepend a '‹ Back' row, retitle). */
    private fun buildTapMenu(
        items: List<MenuOverlayView.Entry>,
        drilled: Boolean,
    ) {
        val display =
            if (drilled) {
                ArrayList<MenuOverlayView.Entry>(items.size + 1).apply {
                    add(MenuOverlayView.Entry("‹ Back", "", role = MenuOverlayView.Role.BACK))
                    addAll(items)
                }
            } else {
                items
            }
        menuOverlay.show(
            display,
            menuAnchorX,
            menuAnchorY,
            menuHandRight,
            tap = true,
            header = if (drilled) "Submenu" else "Choose Option",
        )
    }

    /** FIX-10b: a discrete tap in tap-mode — route to a row, or dismiss when it lands outside the box. */
    private fun onMenuTap(
        x: Float,
        y: Float,
    ) {
        when (val r = menuOverlay.hitTest(x, y)) {
            -2 -> {
                cancelMenu()
            }

            // outside the box -> dismiss
            -1 -> { }

            // header -> ignore
            else -> {
                onTapRow(r)
            }
        }
    }

    /** FIX-10b: act on a tapped tap-mode row — Back / drill into a submenu / commit a leaf (top or child). */
    private fun onTapRow(displayRow: Int) {
        val e = menuOverlay.entryAt(displayRow) ?: return
        when (e.role) {
            MenuOverlayView.Role.BACK -> {
                menuDrillParent = -1
                menuOverlay.setHighlight(-1)
                buildTapMenu(menuTopEntries, drilled = false)
            }

            MenuOverlayView.Role.PARENT -> {
                menuDrillParent = e.engineIndex
                menuOverlay.setHighlight(-1)
                vibrateTick()
                buildTapMenu(e.sub ?: emptyList(), drilled = true)
            }

            MenuOverlayView.Role.NORMAL -> {
                if (menuDrillParent >= 0) {
                    // Submenu child — not in the engine menu geometry, so invoke its onClick directly, then
                    // dismiss the still-open engine top-level menu.
                    JvmLauncher.invokeMenuEntry(menuDrillParent, e.engineIndex)
                    closeEngineMenu()
                    Log.i(TAG, "fix10b: tap submenu child parent=$menuDrillParent child=${e.engineIndex}")
                } else {
                    // Top-level leaf — a geometry click invokes + closes the engine menu in one.
                    val gx = emX + emW / 2
                    val gy = emY + MENU_HEADER_PX + e.engineIndex * MENU_ROW_PX + MENU_ROW_PX / 2
                    JvmLauncher.selectMenuPoint(gx, gy)
                    Log.i(TAG, "fix10b: tap top row ${e.engineIndex} -> game=($gx,$gy)")
                }
                teardownMenu()
            }
        }
    }

    /** Lock the highlight onto the row under the finger; haptic tick on change. */
    private fun updateMenuHighlight(
        x: Float,
        y: Float,
    ) {
        if (!menuOverlay.isActive) return
        val row = menuOverlay.rowAt(x, y)
        if (menuOverlay.setHighlight(row)) {
            menuHighlight = row
            vibrateTick()
        }
    }

    /** Release on a row: click through to the engine row centre (19/15 geometry). Off-row -> cancel. */
    private fun commitMenuSelection() {
        val k = menuHighlight
        if (k in 0 until emCount) {
            val gx = emX + emW / 2
            val gy = emY + MENU_HEADER_PX + k * MENU_ROW_PX + MENU_ROW_PX / 2
            JvmLauncher.selectMenuPoint(gx, gy)
            Log.i(TAG, "a2: select row $k -> game=($gx,$gy)")
            teardownMenu()
        } else {
            cancelMenu()
        }
    }

    /** Close the still-open engine right-click menu via its own bottom Cancel row (no stray world click). */
    private fun closeEngineMenu() {
        if (emCount > 0 && emW > 0) {
            val k = emCount - 1
            val gx = emX + emW / 2
            val gy = emY + MENU_HEADER_PX + k * MENU_ROW_PX + MENU_ROW_PX / 2
            JvmLauncher.selectMenuPoint(gx, gy)
        }
    }

    /** Close the engine menu, then tear down. */
    private fun cancelMenu() {
        closeEngineMenu()
        Log.i(TAG, "a2: menu cancelled")
        teardownMenu()
    }

    private fun teardownMenu() {
        menuOverlay.hide()
        menuActive = false
        menuBuilding = false
        menuTouchActive = false
        menuHighlight = -1
        menuTapMode = false // FIX-10b
        menuTapArmed = false
        menuDrillParent = -1
        menuTopEntries = emptyList()
    }

    override fun onStart() {
        super.onStart()
        // PERF-BATTERY-NETWORK-01: returning to the foreground — un-throttle the render thread and re-arm the
        // per-frame UI poll. Guarded by pollingPaused so the FIRST onStart (right after onCreate's
        // startInputPolling already posted the callback) doesn't double-post it.
        if (pollingPaused) {
            pollingPaused = false
            JvmLauncher.setPaused(false)
            frameCallback?.let { Choreographer.getInstance().postFrameCallback(it) }
            Log.i(TAG, "perf: foreground -> render resumed, UI poll re-armed")
        }
    }

    override fun onStop() {
        // A8: the app is backgrounded (and may be killed) — persist any pending plugin-config writes now so a
        // toggle/setting isn't lost. Off the UI thread (it dispatches to the client thread); fire-and-forget.
        if (booted.get()) {
            JvmLauncher.onBridge {
                val ack = JvmLauncher.flushConfig()
                Log.i(TAG, "a8: flushConfig on background -> $ack")
            }
        }
        // PERF-BATTERY-NETWORK-01: not visible — drop the render thread to 4 Hz and stop the per-frame UI poll
        // (updateChrome/applyOverlayInsets/updateWorldMap/IME). Android has no PiP keepalive (iOS-only), so
        // standing the engine work down backgrounded has no on-device consumer to starve.
        pollingPaused = true
        JvmLauncher.setPaused(true)
        frameCallback?.let { Choreographer.getInstance().removeFrameCallback(it) }
        super.onStop()
    }

    override fun onDestroy() {
        frameCallback?.let { Choreographer.getInstance().removeFrameCallback(it) }
        frameCallback = null
        drainRun = false // stop the AP-2a notification/link drain daemon
        hdConfigReceiver?.let { runCatching { unregisterReceiver(it) } }
        hdConfigReceiver = null
        reconnectTestReceiver?.let { runCatching { unregisterReceiver(it) } }
        reconnectTestReceiver = null
        sessionExpiredTestReceiver?.let { runCatching { unregisterReceiver(it) } }
        sessionExpiredTestReceiver = null
        thermalTestReceiver?.let { runCatching { unregisterReceiver(it) } }
        thermalTestReceiver = null
        thermalGovernor?.stop()
        thermalGovernor = null // PERF-MEMORY-THERMAL-01: unregister + restore the baseline scale
        armHopScrimHook = null // ENH-B06: drop the static hook so a dead activity can't be re-armed
        super.onDestroy()
    }

    /**
     * Track G AG1a — boot the embedded VM with the facade-only `gpu-smoke.jar` ALONE on the classpath +
     * mainClass `RouteCSmoke` (`-Drunelite.routec.smoke`). The host (jvm_bootstrap) skips CACIO/engine, dlopen's
     * the librlawt EGL bridge + RegisterNatives the org.lwjgl.opengl/AWTContext facade, then runs the probe →
     * `ANDROID_AG1A` verdict (logcat jvm-stdout in debug). emulator-GREEN != AG1-GREEN (SwiftShader is lenient).
     */
    private fun bootGpuSmoke(app: android.content.Context) {
        val javaHome = AssetInstaller.ensureInstalled(app)
        val libjvm = File(javaHome, "lib/server/libjvm.so")
        val jvmDir = File(app.filesDir, "jvm")
        val smokeJar = File(jvmDir, "gpu-smoke.jar")
        // AssetInstaller only re-unpacks assets/jvm on a runtime.tag change, so a re-install without a tag bump
        // won't refresh the smoke jar. Copy it from assets if absent so the smoke is launchable on any install.
        if (!smokeJar.exists()) {
            runCatching {
                jvmDir.mkdirs()
                app.assets.open("jvm/gpu-smoke.jar").use { i -> smokeJar.outputStream().use { o -> i.copyTo(o) } }
            }.onFailure { Log.w(TAG, "AG1a: copy gpu-smoke.jar from assets failed: ${it.message}") }
        }
        if (!libjvm.exists() || !smokeJar.exists()) {
            Log.e(TAG, "AG1a: missing libjvm ($libjvm) or gpu-smoke.jar ($smokeJar — run android/dev-tools/gpu/build-smoke-jar.sh)")
            booted.set(false)
            return
        }
        val tmpDir = File(app.filesDir, "tmp").apply { mkdirs() }.absolutePath
        JvmLauncher.setStdioRedirect(BuildConfig.DEBUG) // the probe prints ANDROID_AG1A to stdout -> logcat
        val opts = arrayOf("-Djava.io.tmpdir=$tmpDir", "-Drunelite.routec.smoke=true")
        Log.i(TAG, "AG1a: booting RouteCSmoke on the facade-only jar $smokeJar")
        val rc =
            JvmLauncher.startJvm(
                javaHome = javaHome.absolutePath,
                libjvmPath = libjvm.absolutePath,
                libraryPath = File(javaHome, "lib").absolutePath,
                classpath = smokeJar.absolutePath,
                mainClass = "RouteCSmoke",
                extraOpts = opts,
            )
        Log.i(TAG, "AG1a: startJvm rc=$rc (watch logcat: ANDROID_AG1A / librlawt / routec)")
    }

    /**
     * Track G AG2.5-b — boot the embedded VM on [client-*-gpu.jar (the facade-backed client) + client-*-rlhd.jar]
     * with mainClass RLHDProbe (`-Drunelite.rlhdprobe=true`). The host (jvm_bootstrap) does CACIO activation
     * (RLHD touches java.awt at class-init) but SKIPS the bridge/render — this is a headless class-load + loader-
     * data test, no GL context, no tokens, no login. RLHDProbe link/verifies every rs117.* class against the
     * facade, runs the OpenCL class-load graph, and parses the 9 bundled loader JSON files. Watch logcat for
     * ANDROID_RLHD_PROBE / MEGAVERDICT.
     */
    private fun bootRlhdProbe(app: android.content.Context) {
        val javaHome = AssetInstaller.ensureInstalled(app)
        val libjvm = File(javaHome, "lib/server/libjvm.so")
        if (!libjvm.exists()) {
            Log.e(TAG, "rlhdprobe: embedded JRE not installed ($libjvm)")
            booted.set(false)
            return
        }
        val jvmDir = File(app.filesDir, "jvm")
        // The GPU + RLHD jars are added to assets without bumping runtime.tag, so AssetInstaller may not have
        // unpacked them — copy each from assets when absent (a fresh install copies them fine).
        for (suffix in listOf("-gpu.jar", "-rlhd.jar")) {
            val asset =
                runCatching { app.assets.list("jvm") }
                    .getOrNull()
                    ?.firstOrNull { it.startsWith("client-") && it.endsWith(suffix) }
            if (asset != null && !File(jvmDir, asset).exists()) {
                runCatching {
                    jvmDir.mkdirs()
                    app.assets.open("jvm/$asset").use { i -> File(jvmDir, asset).outputStream().use { o -> i.copyTo(o) } }
                }.onFailure { Log.w(TAG, "rlhdprobe: copy $asset from assets failed: ${it.message}") }
            }
        }
        val gpuJar = jvmDir.list { _, n -> n.startsWith("client-") && n.endsWith("-gpu.jar") }?.firstOrNull()
        val rlhdJar = jvmDir.list { _, n -> n.startsWith("client-") && n.endsWith("-rlhd.jar") }?.firstOrNull()
        if (gpuJar == null || rlhdJar == null) {
            Log.e(
                TAG,
                "rlhdprobe: missing jar(s) gpu=$gpuJar rlhd=$rlhdJar in $jvmDir " +
                    "(run android/dev-tools/gpu/stage-android-gpu-jar.sh + stage-rlhd-zone-jar.sh)",
            )
            booted.set(false)
            return
        }
        val classpath = listOf(gpuJar, rlhdJar, "probes.jar").joinToString(":") { File(jvmDir, it).absolutePath }
        val libraryPath = File(javaHome, "lib").absolutePath
        val home = app.filesDir.absolutePath
        val tmpDir = File(app.filesDir, "tmp").apply { mkdirs() }.absolutePath
        val opts =
            arrayOf(
                "-Djava.awt.headless=false",
                "--add-exports=java.desktop/java.awt=ALL-UNNAMED",
                "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED",
                "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED",
                "--add-exports=java.base/sun.security.action=ALL-UNNAMED",
                "--add-opens=java.base/java.util=ALL-UNNAMED",
                "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
                "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED",
                "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
                "-Xmx512m",
                // Fail fast at heap exhaustion instead of limping (seams no-op, GC thrash): a clean exit
                // routes into the existing crash-fallback/relaunch UX and leaves a diagnosable hs_err trail.
                "-XX:+ExitOnOutOfMemoryError",
                "-Duser.home=$home",
                "-Djava.io.tmpdir=$tmpDir",
                "-Drunelite.rlhdprobe=true",
            )
        JvmLauncher.setStdioRedirect(true) // probe prints its verdict to stdout -> logcat
        Log.i(TAG, "rlhdprobe: starting HotSpot RLHDProbe, cp=$classpath")
        val rc =
            JvmLauncher.startJvm(
                javaHome = javaHome.absolutePath,
                libjvmPath = libjvm.absolutePath,
                libraryPath = libraryPath,
                classpath = classpath,
                mainClass = "RLHDProbe",
                extraOpts = opts,
            )
        if (rc != 0) booted.set(false)
        Log.i(TAG, "rlhdprobe: startJvm rc=$rc (watch logcat: ANDROID_RLHD_PROBE / MEGAVERDICT)")
    }

    // BOOT-1: every silent-black-screen guard in bootJvm routes through here so the cold-start splash shows
    // WHY the boot died instead of dismissing over a dead SurfaceView (the splash error mode also disarms its
    // wall-clock failsafe dismiss). Runs on the boot thread; marshals to the UI thread itself.
    private fun postBootError(
        title: String,
        lines: List<String>,
    ) {
        runOnUiThread { if (::splashOverlay.isInitialized) splashOverlay.showBootError(title, lines) }
    }

    private fun bootJvm(
        app: android.content.Context,
        census: Boolean = false,
        gpu: Boolean = false,
        rlhd: Boolean = false,
    ) {
        // UX-ONBOARD-01: on the first-install path, feed a coarse "Unpacking… N%" line into the cold-start splash.
        // The callback runs on this boot thread, so marshal each update to the UI thread. No-op once installed.
        val javaHome =
            try {
                AssetInstaller.ensureInstalled(app) { pct ->
                    runOnUiThread { if (::splashOverlay.isInitialized && splashOverlay.isActive) splashOverlay.setUnpackProgress(pct) }
                }
            } catch (e: AssetInstaller.InsufficientSpaceException) {
                Log.e(TAG, "boot: unpack blocked — ${e.message}")
                booted.set(false)
                postBootError(
                    "Not enough storage",
                    listOf(
                        "This app needs about ${e.neededMb} MB free to",
                        "unpack the game runtime (${e.freeMb} MB available).",
                        "Free up some space, then reopen the app.",
                    ),
                )
                return
            } catch (e: Exception) {
                Log.e(TAG, "boot: runtime unpack failed", e)
                booted.set(false)
                postBootError(
                    "Couldn't unpack the game",
                    listOf(
                        "Unpacking the game runtime failed",
                        "(${e.javaClass.simpleName}). Reopen the app to",
                        "retry; if it keeps failing, reinstall it.",
                    ),
                )
                return
            }
        val libjvm = File(javaHome, "lib/server/libjvm.so")
        if (!libjvm.exists()) {
            Log.e(TAG, "embedded JRE not installed; expected $libjvm")
            booted.set(false) // not booted yet — let a later launch retry the asset unpack
            postBootError(
                "Game runtime missing",
                listOf(
                    "The embedded Java runtime didn't unpack",
                    "completely. Reopen the app to retry; if it",
                    "keeps failing, reinstall it.",
                ),
            )
            return
        }

        val jvmDir = File(app.filesDir, "jvm")
        // GPU + 117HD modes boot the facade-backed jar (client-<ver>-gpu.jar: lwjgl/rlawt/gpu stripped + facade); the
        // CPU boot uses the pristine client-<ver>-shaded.jar. 117HD ALSO needs client-<ver>-rlhd.jar (rs117.* + the
        // shaders/JSON) appended to the classpath. The jars carry the project version, so glob by suffix (a version
        // bump needs no code edit). AssetInstaller only unpacks assets/jvm on a runtime.tag change, so a jar may be
        // absent on an install that didn't bump the tag — copy each from assets if so.
        // Phase-2: EVERY mode boots the facade-backed jar (the iOS single-jar-set model since the gpu merge).
        // The CPU boot is the facade jar with no routec flags + gpuplugin force-disabled — identical client,
        // renderer plugins loadable-but-stopped. This is also the only combination the rlhd jar is compiled
        // against (facade rlawt), so the 117HD panel row class-loads cleanly on any boot. The pristine
        // shaded jar stays staged as the surgery source + desktop-dev artifact, not a boot target.
        val useGpuJar = true
        val jarSuffix = "-gpu.jar"
        run {
            val wanted = mutableListOf<String>()
            if (useGpuJar) wanted.add("-gpu.jar")
            // Phase-2: the rlhd jar rides EVERY classpath (not just rlhd boots) so RendererPanelStarter can
            // load rs117.hd.HdPlugin into the plugin panel as a selectable renderer row on any boot.
            wanted.add("-rlhd.jar")
            for (suffix in wanted) {
                val asset =
                    runCatching { app.assets.list("jvm") }
                        .getOrNull()
                        ?.firstOrNull { it.startsWith("client-") && it.endsWith(suffix) }
                if (asset != null && !File(jvmDir, asset).exists()) {
                    runCatching {
                        jvmDir.mkdirs()
                        app.assets.open("jvm/$asset").use { i -> File(jvmDir, asset).outputStream().use { o -> i.copyTo(o) } }
                    }.onFailure { Log.w(TAG, "boot: copy $asset from assets failed: ${it.message}") }
                }
            }
        }
        val clientJar =
            jvmDir
                .list { _, name -> name.startsWith("client-") && name.endsWith(jarSuffix) }
                ?.firstOrNull()
        if (clientJar == null) {
            Log.e(
                TAG,
                "no client-*$jarSuffix staged in $jvmDir" +
                    if (useGpuJar) " (run android/dev-tools/gpu/stage-android-gpu-jar.sh)" else "",
            )
            booted.set(false)
            postBootError(
                "Game files missing",
                listOf(
                    "The game's client files didn't unpack",
                    "completely. Reopen the app to retry; if it",
                    "keeps failing, reinstall it.",
                ),
            )
            return
        }
        val rlhdJar = jvmDir.list { _, name -> name.startsWith("client-") && name.endsWith("-rlhd.jar") }?.firstOrNull()
        if (rlhd && rlhdJar == null) {
            // Only an rlhd BOOT hard-requires the jar; a CPU/GPU boot just loses the 117HD panel row.
            Log.e(TAG, "no client-*-rlhd.jar staged in $jvmDir (run android/dev-tools/gpu/stage-rlhd-zone-jar.sh)")
            booted.set(false)
            postBootError(
                "HD renderer files missing",
                listOf(
                    "The 117HD renderer's files didn't unpack",
                    "completely. Switch the renderer in the",
                    "plugins panel, or reinstall the app.",
                ),
            )
            return
        }
        val classpath =
            (listOf(clientJar) + listOfNotNull(rlhdJar) + listOf("probes.jar"))
                .joinToString(":") { File(jvmDir, it).absolutePath }
        val libraryPath = File(javaHome, "lib").absolutePath

        // A writable RuneLite home + headless capture dir (the gamepack cache + PNG fallback evidence).
        val home = app.filesDir.absolutePath
        // AG3-c: in rlhd mode put the capture dir on EXTERNAL storage so Firebase --directories-to-pull can fetch the
        // 117HD-rendered frames (the composited output, written by HeadlessCapture once isGpu=true).
        val captureBase = if (rlhd) (app.getExternalFilesDir(null) ?: app.filesDir) else app.filesDir
        val captureDir = File(captureBase, "rl-capture").apply { mkdirs() }.absolutePath
        // Android's default java.io.tmpdir is /tmp (absent in the app sandbox); Font.createFont stages a
        // temp file there and fails with "Problem reading font data", poisoning FontManager.<clinit>. Point
        // it at a writable dir so the gamepack fonts load.
        val tmpDir = File(app.filesDir, "tmp").apply { mkdirs() }.absolutePath

        // A7 resizable (full-screen): force the gamepack into RESIZABLE display mode so HeadlessResize's wider
        // canvas FILLS instead of pillarboxing. The mode is a single byte (byte[3]: 1=fixed, 2=resizable) in the
        // OSRS legacy prefs blob, which the gamepack reads at startup and persists. Patch/seed it before startJvm.
        ensureResizableDisplayMode(File(app.filesDir, ".runelite/jagexcache/oldschool/LIVE/preferences.dat"))

        // JX_* launcher handoff: if a tokens.json is present, set the JX_* env (before startJvm) and arm
        // HeadlessLogin's EULA->Play Now click machine. No tokens.json -> login-screen render only. The setenv
        // must happen here, before JvmLauncher.startJvm creates the VM (HotSpot snapshots env at startup).
        val autologinArmed = JagexTokens.loadAndArm(app)
        // Legacy (non-Jagex) username/password fallback: arms HeadlessLogin's legacy stage instead. A
        // tokens.json session wins when both exist. Same pre-startJvm setenv constraint as JX_*.
        val legacyArmed = !autologinArmed && LegacyCreds.loadAndArm(app)

        // iOS's headless/CACIO opt set, minus the iOS-JIT workarounds (Android grants JIT for free):
        // dropped -XX:+MirrorMappedCodeCache / DisablePrimordialThreadGuardPages / -UseCompressedClassPointers /
        // ReservedCodeCacheSize. Kept: the CACIO JPMS exports/opens, headless render + bridge props.
        val opts =
            mutableListOf(
                "-Djava.awt.headless=false",
                "--add-exports=java.desktop/java.awt=ALL-UNNAMED",
                "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED",
                "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED",
                "--add-exports=java.base/sun.security.action=ALL-UNNAMED",
                "--add-opens=java.base/java.util=ALL-UNNAMED",
                "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
                "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED",
                "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
                "-Xmx512m",
                // Fail fast at heap exhaustion instead of limping (seams no-op, GC thrash): a clean exit
                // routes into the existing crash-fallback/relaunch UX and leaves a diagnosable hs_err trail.
                "-XX:+ExitOnOutOfMemoryError",
                "-Duser.home=$home",
                "-Djava.io.tmpdir=$tmpDir",
                "-Drunelite.bridge=true",
                "-Dheadless.runSeconds=86400", // keep the boot thread alive/logging for the whole session
                "-Dheadless.captureTargetFrames=999999", // never early-exit; ride the window
                "-Drunelite.menupeek=true", // A2: publish the menu-peek snapshot each client tick
                "-Drunelite.menupeek.maxEntries=14",
                "-Drunelite.mobileui=true", // A4: plugin control plane (list/toggle/config from the host)
                "-Drunelite.mobilechrome=true", // A6: publish the read-only chrome snapshot (tab-stone bounds)
                "-Drunelite.hudveneer=true", // A6: the chrome write surface (hide stones / openTab / relocate)
                // Phase-2 renderer-as-plugins (the iOS d2b46053c model): drop safe-mode on every boot (so the
                // renderer plugins CAN load) and let RendererPanelStarter put GPU + 117HD into the panel without
                // starting them. Which one actually STARTS is decided purely by the routec flags below.
                "-Drunelite.nosafemode=true",
                "-Drunelite.rendererpanel=true",
            )
        // Headless frame-capture (PNG snapshots + per-draw bookkeeping) is a dev/CI diagnostic only — release
        // boots don't arm it (SLM-DFLAG-01; HeadlessCapture is inert without the dir). The boot-thread keepalive
        // (runSeconds/captureTargetFrames above) stays unconditional; only the capture writes are DEBUG-gated.
        if (BuildConfig.DEBUG) {
            opts.addAll(
                listOf(
                    "-Drunelite.headless.capture.dir=$captureDir",
                    "-Drunelite.headless.capture.interval=10",
                    "-Drunelite.headless.capture.preLoginMax=40",
                ),
            )
        }
        // Force-disable the renderer plugins that are NOT the chosen renderer — this wins over persisted/SYNCED
        // config (the isPluginEnabled force-off rule), so a RuneLite-account profile that carries the DESKTOP
        // enabled-flag for the other renderer can't start it. Critical for HdPlugin: it declares conflicts="GPU",
        // so a synced profile starting it would STOP the running GPU renderer mid-session, destroy its GL context,
        // and hang the scene-load ("unable to map GL buffer" → "Loading - please wait."). The chosen renderer's key
        // is omitted so it can still start. (CPU = neither renderer runs.)
        // Single source of truth for which renderer plugin is the chosen one (null = CPU, no renderer plugin runs).
        // Force-DISABLE the OTHER renderer plugins (wins over a synced profile's desktop enable — critically
        // HdPlugin's conflicts="GPU" would otherwise stop the GPU renderer mid-session and kill its GL context),
        // and force-ENABLE the chosen one (so a synced profile that DISABLES it can't stop it). The two lists are
        // mutually exclusive by construction.
        val chosenKey =
            if (gpu) {
                "gpuplugin"
            } else if (rlhd) {
                "hdplugin"
            } else {
                null
            }
        val rendererKeys = listOf("gpuplugin", "hdplugin")
        opts.add("-Drunelite.forceDisablePlugins=${rendererKeys.filter { it != chosenKey }.joinToString(",")}")
        if (chosenKey != null) {
            opts.add("-Drunelite.forceEnablePlugins=$chosenKey")
        }
        // A7 resizable: render at the screen's landscape aspect — HeadlessResize grows the gamepack Component on
        // login (stock, inset-aware, the same mechanism iOS device-proved). With the OSRS account in RESIZABLE
        // display mode the gamepack fills it (resizable toplevel 164 → chat-at-top + resizable chrome unblock);
        // a FIXED account harmlessly keeps the 765x503 viewport (gamepack pillarboxes, canvas stays 765x503, so
        // the blit + touch + A6 rails are unchanged — no regression). The account's display mode is the switch.
        run {
            val dm = app.resources.displayMetrics
            val longEdge = maxOf(dm.widthPixels, dm.heightPixels)
            val shortEdge = maxOf(1, minOf(dm.widthPixels, dm.heightPixels))
            // UI-2: match iOS's render height (540). A lower engine canvas blits up to a physically BIGGER HUD
            // (minimap, orbs, chat, side panel, tab grid all scale together) — the only working way to enlarge the
            // minimap (the per-widget MINIMAP-scale path overlaps the orbs / blanks terrain). 540 is iOS-proven
            // safe; below ~480 the minimap column collides with the tab grid.
            val renderH = 540
            val renderW = (renderH.toLong() * longEdge / shortEdge).toInt()
            canvasW = renderW
            canvasH = renderH // for the overlay free-drag pad → canvas-pixel mapping
            opts.add("-Drunelite.headless.resize=${renderW}x$renderH")
            Log.i(
                TAG,
                "A7 resize armed: ${renderW}x$renderH (screen ${longEdge}x$shortEdge; resizable iff account in resizable display mode)",
            )
        }
        // 117HD auto-login: on a real home-network device login works, so autologin straight in-world (RLHDStarter
        // engages at LOGGED_IN too) — the desired turnkey launch. SKIP it only for the Firebase DATACENTER pre-login
        // case (an explicit rlhd_prelogin.mode marker): there the world connect is WAF-blocked and autologin would
        // churn at state=UNKNOWN forever instead of settling at LOGIN_SCREEN, so the Zone shader-compile proof needs
        // the clean login screen. Default (no marker) = autologin, including in routecrlhd.
        val rlhdPreLogin = rlhd && File(app.getExternalFilesDir(null), "rlhd_prelogin.mode").exists()
        if (autologinArmed && !rlhdPreLogin) {
            opts.addAll(JagexTokens.autologinOpts)
            Log.i(
                TAG,
                "autologin ARMED (tokens.json present)${if (rlhd) " [routecrlhd -> RLHDStarter loads 117HD at LOGGED_IN]" else ""}: EULA 302,312 -> Play Now 382,248, world 301",
            )
        } else if (legacyArmed && !rlhdPreLogin) {
            opts.addAll(JagexTokens.autologinOpts)
            opts.add("-Drunelite.headless.autologin.legacy=true")
            Log.i(TAG, "LEGACY autologin ARMED (legacy_login.json present): username/password form, world 301")
        } else if (rlhd) {
            Log.i(TAG, "routecrlhd: autologin SKIPPED (rlhd_prelogin marker -> settle at LOGIN_SCREEN for the datacenter shader compile)")
        }
        if (census) {
            // A-1b runtime gate-flip census: turn on the remaining read-surface gates (menupeek + autologin
            // are already on above) and arm the one-shot GateCensus probe in DeviceHeadlessBoot.
            opts.addAll(
                listOf(
                    "-Drunelite.gatecensus=true",
                    "-Drunelite.huddata=true",
                ),
            )
            Log.i(TAG, "A-1b census mode: +huddata + gatecensus (mobileui/mobilechrome/hudveneer/resize always-on)")
        }
        if (gpu) {
            // Arm RouteCGpuStarter (force-enable + start the gpu plugin once in-world) and the frame-dump
            // diagnostic so the AG2 device gate gets pullable colour/flip evidence. The bridge itself is
            // registered natively (jvm_bootstrap sees -Drunelite.routecgpu and dlopen's librlawt after VM create).
            // Dump to app-private EXTERNAL storage so Firebase Test Lab's --directories-to-pull (and adb pull)
            // can fetch the frames; fall back to internal filesDir if external is unavailable.
            opts.add("-Drunelite.routecgpu=true")
            // The per-frame frame-dump (PNG encode to external storage) is a dev/CI diagnostic only — gate it
            // behind DEBUG so release GPU boots don't pay the per-frame IO (SLM-DFLAG-02 / PERF-FRAME-PACING-03).
            if (BuildConfig.DEBUG) {
                val dumpDir = (app.getExternalFilesDir(null) ?: app.filesDir).absolutePath // +"/routec-frames/"
                opts.addAll(
                    listOf(
                        "-Drunelite.gpuframedump=true",
                        "-Drunelite.gpuframedump.dir=$dumpDir",
                    ),
                )
            }
            Log.i(TAG, "AG2 GPU mode: gpu jar $clientJar, routecgpu armed (frame-dump=${BuildConfig.DEBUG})")
        }
        if (rlhd) {
            // AG3-b: arm RLHDStarter (load + start the 117HD Zone plugin once in-world; it disables the base gpu
            // plugin via its conflicts="GPU"). librlawt is registered natively (jvm_bootstrap sees routecrlhd). Frame
            // dump to app-EXTERNAL storage so the HD frame is pullable (Firebase --directories-to-pull / adb pull).
            opts.add("-Drunelite.routecrlhd=true")
            // PROD-COMPAT-01 bring-up: a pushed `rlhd_overlay_selftest` marker (Firebase --other-files / adb push to
            // the app's external files dir) arms RLHDStarter to force-compile the dev ShaderOverlay shaders on the
            // live driver once 117HD is up, so a strict-GLSL-ES typing regression in an overlay surfaces in the
            // matrix (these overlays are dev-toggle-gated and never compile in a default login run). Inert otherwise.
            if (File(app.getExternalFilesDir(null), "rlhd_overlay_selftest").exists() ||
                File(app.filesDir, "rlhd_overlay_selftest").exists()
            ) {
                opts.add("-Drunelite.rlhdOverlaySelfTest=true")
                Log.i(TAG, "AG3-c: rlhd_overlay_selftest marker -> overlay shader self-test armed")
            }
            // Frame-dump + the once/sec engine-fps logcat probe are dev/CI diagnostics — DEBUG-only so release
            // 117HD boots don't pay the per-frame PNG IO or the fps branch (SLM-DFLAG-02/03 / PERF-FRAME-PACING-03/04).
            if (BuildConfig.DEBUG) {
                val dumpDir = (app.getExternalFilesDir(null) ?: app.filesDir).absolutePath
                opts.addAll(
                    listOf(
                        "-Drunelite.gpuframedump=true",
                        "-Drunelite.gpuframedump.dir=$dumpDir",
                        // FIX-13: arm the once/sec engine-fps logcat probe ([fpsprobe] fps=N gs=...) so a preset A/B can be
                        // measured in-world on real Mali (Hooks.frame, gated by this prop). Only active in 117HD test mode.
                        "-Drunelite.fpsprobe=true",
                    ),
                )
            }
            Log.i(
                TAG,
                "AG3-b 117HD mode: gpu jar $clientJar + rlhd jar $rlhdJar, routecrlhd armed (frame-dump+fpsprobe=${BuildConfig.DEBUG})",
            )
        }

        // A8: only pipe the embedded VM's stdout/err to logcat in DEBUG builds — a release build must not leak
        // the engine's output (account/network chatter). Must be set before startJvm (it redirects fd 1/2 there).
        JvmLauncher.setStdioRedirect(BuildConfig.DEBUG)

        Log.i(TAG, "starting HotSpot: DeviceHeadlessBoot, cp=$classpath")
        val rc =
            JvmLauncher.startJvm(
                javaHome = javaHome.absolutePath,
                libjvmPath = libjvm.absolutePath,
                libraryPath = libraryPath,
                classpath = classpath,
                mainClass = "DeviceHeadlessBoot",
                extraOpts = opts.toTypedArray(),
            )
        if (rc != 0) {
            // VM creation failed (JNI_OK == 0). Clear the boot latch so a later launch into this same process
            // retries instead of being wedged VM-less with booted==true. (A VM that came up but whose main
            // class later threw is still rc==0 and stays booted — that's the engine's own run, not a boot fail.)
            Log.e(TAG, "startJvm rc=$rc — VM bringup FAILED; clearing booted so a relaunch can retry")
            booted.set(false)
            postBootError(
                "Couldn't start the game",
                listOf(
                    "The game's Java runtime failed to start",
                    "(code $rc). Close and reopen the app to",
                    "retry; if it keeps failing, reinstall it.",
                ),
            )
            return
        }
        Log.i(TAG, "startJvm rc=$rc (VM up; watch logcat tags jvm-boot/jvm-stdout)")
        if (census) {
            runA4SeamSelfTest()
            runA6SeamSelfTest()
        }
    }

    /**
     * A7 resizable: force the OSRS gamepack into RESIZABLE display mode by setting the window-mode byte in its
     * legacy prefs blob (preferences.dat byte[3]: 1=fixed, 2=resizable — verified by byte-diffing a fixed vs an
     * iOS-resizable file). The gamepack reads this at startup and keeps it (it normalizes other bytes but honors
     * byte[3]). Patch it if the file exists; seed a minimal resizable one if not (fresh install). Idempotent;
     * runs before startJvm. With this + HeadlessResize's wider canvas, the scene fills the screen (PRE_EOC modern)
     * instead of pillarboxing 765x503 — no per-account/server setting needed (the mode is client-side per install).
     */
    private fun ensureResizableDisplayMode(f: File) {
        try {
            if (f.exists() && f.length() >= 4) {
                val b = f.readBytes()
                if (b[3] != 0x02.toByte()) {
                    b[3] = 0x02
                    f.writeBytes(b)
                    Log.i(TAG, "a7: preferences.dat patched fixed->resizable (byte3=2)")
                } else {
                    Log.i(TAG, "a7: preferences.dat already resizable")
                }
            } else {
                f.parentFile?.mkdirs()
                // Minimal valid OSRS preferences.dat with window mode = resizable (byte[3]=02).
                f.writeBytes(
                    byteArrayOf(
                        0x0c,
                        0x00,
                        0x00,
                        0x02,
                        0x00,
                        0x00,
                        0x00,
                        0x32,
                        0x00,
                        0x00,
                        0x00,
                        0x00,
                        0x00,
                        0x00,
                        0x00,
                        0x00,
                        0x00,
                        0x19,
                        0x00,
                    ),
                )
                Log.i(TAG, "a7: seeded resizable preferences.dat (fresh)")
            }
        } catch (e: Exception) {
            Log.w(TAG, "a7: ensureResizableDisplayMode failed: ${e.message}")
        }
    }

    /**
     * A6 chrome-seam probe (census mode): does the FIXED-mode MobileChromeBridge read surface resolve real
     * geometry once the world fully loads? The bridge's own one-shot CHROME_READ verdict fires ~60 LOGGED_IN
     * frames in — possibly before the scene builds — so this polls the LIVE getSnapshot() for ~40s after login
     * and reports the most-resolved snapshot. GREEN = the read surface ever resolved a viewport OR a tab stone
     * (=> A6 cover-and-proxy is viable in FIXED mode; the resizable look is a separate, deferrable concern).
     * RED = logged in but the surface stayed empty (=> the resizable-canvas resize is a hard prerequisite).
     * Runs on the rl-bridge thread (queued after the A4 test), by which point the world is fully loaded.
     */
    private fun runA6SeamSelfTest() {
        JvmLauncher.onBridge {
            var loggedIn = false
            var everResolved = false // viewport OR any tab stone resolved => cover-and-proxy viable in fixed mode
            var best = "(no loggedIn snapshot)"
            for (i in 0 until 40) { // ~40s @ 1s — chrome only ticks once mobilechrome gate + LOGGED_IN
                val snap =
                    try {
                        JvmLauncher.chromeSnapshot()
                    } catch (t: Throwable) {
                        ""
                    }
                if (snap.length > 2) {
                    try {
                        val o = org.json.JSONObject(snap)
                        if (o.optBoolean("loggedIn")) {
                            loggedIn = true
                            val vp = !o.isNull("viewport")
                            val tabs = o.optJSONArray("tabs")
                            var tabsNonNull = 0
                            if (tabs != null) for (j in 0 until tabs.length()) if (!tabs.isNull(j)) tabsNonNull++
                            val resolved = vp || tabsNonNull > 0
                            if (resolved) everResolved = true
                            best = "rootKind=${o.optString("rootKind", "?")} resized=${o.optBoolean("resized")} " +
                                "topLevel=${o.optInt("topLevelId", -1)} activeTab=${o.optInt("activeTab", -1)} " +
                                "viewport=$vp tabsNonNull=$tabsNonNull/14 sidePanel=${!o.isNull("sidePanel")} " +
                                "minimap=${!o.isNull("minimap")} orbs=${!o.isNull("orbs")} chat=${!o.isNull("chat")}"
                            if (resolved) break
                        }
                    } catch (t: Throwable) {
                        // transient parse — retry
                    }
                }
                Thread.sleep(1000)
            }
            when {
                everResolved -> Log.i(TAG, "ANDROID_A6_SEAM_GREEN fixed-mode chrome read resolved: $best")
                loggedIn -> Log.e(TAG, "ANDROID_A6_SEAM_RED loggedIn but read surface empty: $best — resizable-canvas fix required")
                else -> Log.e(TAG, "ANDROID_A6_SEAM_RED chrome snapshot never reached loggedIn (gate/login/boot?)")
            }
        }
    }

    /**
     * A4 host-seam self-test (census mode): prove the Android host can reach the plugin control plane
     * (MobileUiBridge) ACROSS the VM boundary on the rl-bridge thread — the path A4's UI will use (A-1b proved
     * the same call in-VM). Read-only: poll listPlugins() until the engine has booted and the -Drunelite.mobileui
     * gate has wired it, then log the received length + the event seq. (Write/toggle + the Compose UI are next.)
     */
    private fun runA4SeamSelfTest() {
        JvmLauncher.onBridge {
            var plugins = ""
            for (i in 0 until 90) {
                plugins =
                    try {
                        JvmLauncher.listPlugins()
                    } catch (t: Throwable) {
                        ""
                    }
                if (plugins.length > 2) break
                Thread.sleep(1000)
            }
            val seq =
                try {
                    JvmLauncher.mobileUiSeq()
                } catch (t: Throwable) {
                    -1L
                }
            if (plugins.length <= 2) {
                Log.e(TAG, "ANDROID_A4_SEAM_RED listPlugins empty after 90s (mobileui gate / boot?)")
                return@onBridge
            }
            Log.i(TAG, "ANDROID_A4_SEAM_GREEN listPluginsLen=${plugins.length} mobileUiSeq=$seq")

            // A4 write path: toggle a currently-enabled plugin off->on (restoring it) and confirm the
            // round-trip. setPluginEnabled queues the start/stop on the EDT, so poll until the flag flips.
            try {
                val arr = org.json.JSONArray(plugins)
                var className: String? = null
                var was = true
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    if (o.optBoolean("enabled")) {
                        className = o.getString("className")
                        was = true
                        break
                    }
                }
                if (className == null && arr.length() > 0) { // fallback: none enabled -> first plugin
                    className = arr.getJSONObject(0).getString("className")
                    was = arr.getJSONObject(0).optBoolean("enabled")
                }
                if (className == null) {
                    Log.e(TAG, "ANDROID_A4_TOGGLE_RED no plugins to toggle")
                    return@onBridge
                }
                val seq0 = JvmLauncher.mobileUiSeq()
                val ack = JvmLauncher.setPluginEnabled(className, !was)
                val flipped = pollEnabled(className, !was, 8)
                val seq1 = JvmLauncher.mobileUiSeq()
                JvmLauncher.setPluginEnabled(className, was) // restore original state
                val restored = pollEnabled(className, was, 8)
                if (flipped && restored) {
                    Log.i(TAG, "ANDROID_A4_TOGGLE_GREEN plugin=$className $was->${!was}->$was seq=$seq0->$seq1 ack=$ack")
                } else {
                    Log.e(TAG, "ANDROID_A4_TOGGLE_RED plugin=$className flipped=$flipped restored=$restored ack=$ack")
                }
            } catch (t: Throwable) {
                Log.e(TAG, "ANDROID_A4_TOGGLE_RED parse/toggle threw: $t")
            }

            // A4 config READ surface: pull one plugin's typed config schema across the boundary — this is what
            // the config UI renders. (setConfig is wired and follows the same EDT write path as the toggle.)
            try {
                val arr2 = org.json.JSONArray(JvmLauncher.listPlugins())
                var group: String? = null
                for (i in 0 until arr2.length()) {
                    val o = arr2.getJSONObject(i)
                    if (o.optBoolean("hasConfig") && !o.isNull("configGroup")) {
                        group = o.getString("configGroup")
                        break
                    }
                }
                if (group != null) {
                    val cfg = JvmLauncher.getPluginConfig(group)
                    val wid = JvmLauncher.processedWriteId()
                    if (cfg.length > 2) {
                        Log.i(TAG, "ANDROID_A4_CONFIG_GREEN group=$group configLen=${cfg.length} writeId=$wid")
                    } else {
                        Log.e(TAG, "ANDROID_A4_CONFIG_RED group=$group empty schema")
                    }
                } else {
                    Log.e(TAG, "ANDROID_A4_CONFIG_RED no plugin advertises a config group")
                }
            } catch (t: Throwable) {
                Log.e(TAG, "ANDROID_A4_CONFIG_RED getPluginConfig threw: $t")
            }

            // A5 Tier-1 panel seam: open a plugin's Swing side-panel off-screen (CACIO) and pull its rendered
            // ARGB image across the VM boundary — the rendered-image fallback that works for any plugin panel.
            try {
                val parr = org.json.JSONArray(JvmLauncher.listPanels())
                if (parr.length() == 0) {
                    Log.e(TAG, "ANDROID_A5_SEAM_RED no panels listed (mobileui gate / safe-mode?)")
                } else {
                    val p0 = parr.getJSONObject(0)
                    val idx = p0.optInt("index", 0)
                    val tip = p0.optString("tooltip", "?")
                    JvmLauncher.openPanel(idx)
                    var px: IntArray? = null
                    var w = 0
                    var h = 0
                    for (i in 0 until 30) {
                        Thread.sleep(500)
                        w = JvmLauncher.panelWidth()
                        h = JvmLauncher.panelHeight()
                        px = JvmLauncher.panelPixels()
                        if (w > 0 && h > 0 && (px?.size ?: 0) >= w * h) break
                    }
                    val n = px?.size ?: 0
                    if (n > 0 && w > 0 && h > 0) {
                        Log.i(
                            TAG,
                            "ANDROID_A5_SEAM_GREEN panels=${parr.length()} panel='$tip' ${w}x$h px=$n seq=${JvmLauncher.panelFrameSeq()}",
                        )
                    } else {
                        Log.e(TAG, "ANDROID_A5_SEAM_RED panels=${parr.length()} panel='$tip' ${w}x$h px=$n")
                    }
                    JvmLauncher.closePanel()
                }
            } catch (t: Throwable) {
                Log.e(TAG, "ANDROID_A5_SEAM_RED panel seam threw: $t")
            }

            // A5 Tier-2 Quest Helper seam (QuestHelperBridge). isAvailable() is false unless the Quest Helper
            // hub plugin is installed — BOTH outcomes prove the seam (the native screen falls back to Tier-1
            // when false). GREEN = the host reached the bridge and got parseable JSON across the boundary.
            try {
                val qAvail = JvmLauncher.questAvailable()
                JvmLauncher.questSetUiOpen(true)
                var qlist = "{}"
                for (i in 0 until 20) {
                    qlist = JvmLauncher.questListJson()
                    if (qlist.length > 2 && (!qAvail || qlist.contains("\"quests\""))) break
                    Thread.sleep(500)
                }
                val qobj = org.json.JSONObject(qlist)
                val qListAvail = qobj.optBoolean("available")
                val qn = qobj.optJSONArray("quests")?.length() ?: 0
                org.json.JSONObject(JvmLauncher.questActiveJson()) // parse-check the active surface too
                JvmLauncher.questSetUiOpen(false)
                Log.i(TAG, "ANDROID_A5_TIER2_QUEST_GREEN available=$qListAvail quests=$qn isAvailable=$qAvail")
            } catch (t: Throwable) {
                Log.e(TAG, "ANDROID_A5_TIER2_QUEST_RED quest seam threw: $t")
            }

            // A5 Tier-2 World Switcher seam (WorldSwitcherBridge). World Switcher is BUILT-IN and we're
            // LOGGED_IN, so expect available=true with a populated world list (setUiOpen triggers an async
            // WorldService refresh — poll until it lands). GREEN requires available=true && worlds>0.
            try {
                val wFlag = JvmLauncher.worldAvailable()
                JvmLauncher.worldSetUiOpen(true)
                var wAvail = false
                var wn = 0
                var wcur = -1
                for (i in 0 until 30) {
                    Thread.sleep(500)
                    val o = org.json.JSONObject(JvmLauncher.worldListJson())
                    wAvail = o.optBoolean("available")
                    wn = o.optJSONArray("worlds")?.length() ?: 0
                    wcur = o.optInt("current", -1)
                    if (wAvail && wn > 0) break
                }
                JvmLauncher.worldSetUiOpen(false)
                if (wAvail && wn > 0) {
                    Log.i(TAG, "ANDROID_A5_TIER2_WORLD_GREEN available=true worlds=$wn current=$wcur")
                } else {
                    Log.e(TAG, "ANDROID_A5_TIER2_WORLD_RED available=$wAvail worlds=$wn isAvailable=$wFlag")
                }
            } catch (t: Throwable) {
                Log.e(TAG, "ANDROID_A5_TIER2_WORLD_RED world seam threw: $t")
            }
        }
    }

    /** Poll listPlugins() until [className]'s enabled flag == [want] (the toggle applies async on the EDT). */
    private fun pollEnabled(
        className: String,
        want: Boolean,
        secs: Int,
    ): Boolean {
        for (i in 0 until secs * 2) {
            try {
                val list = org.json.JSONArray(JvmLauncher.listPlugins())
                for (j in 0 until list.length()) {
                    val o = list.getJSONObject(j)
                    if (o.getString("className") == className) {
                        if (o.optBoolean("enabled") == want) return true
                        break
                    }
                }
            } catch (t: Throwable) {
                // transient parse/read — retry
            }
            Thread.sleep(500)
        }
        return false
    }
}
