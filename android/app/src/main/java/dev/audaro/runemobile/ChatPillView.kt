package dev.audaro.runemobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.util.Log
import android.view.MotionEvent
import android.view.View
import org.json.JSONObject
import kotlin.math.hypot

/**
 * UI-3: the native chat-tab ROW (iOS static-row parity; the old collapsible pill + fan was removed). It draws a
 * full-width row of 7 OPAQUE tabs (All..Trade) over the relocated chat. The engine keeps rendering its OWN chat
 * controls tab row underneath (hiding any tab widget blanks the whole chat raster — see HudVeneerBridge), so the
 * native row's opaque stone-brown backing COVERS it; that's what eliminates the "two tab rows". A tap on the
 * active tab collapses the message area; a tap on another switches the channel; a long-press on a filterable tab
 * opens its engine filter menu (the shared press-and-peek overlay). Taps snap to the nearest tab across the full
 * row, with a generous vertical band, so the buttons are easy to hit. Geometry comes from getChatSnapshot each
 * frame (it keeps reporting the configured chat origin while collapsed, so the row stays put).
 *
 * The class name + the filter/haptic callbacks are kept so the host wiring + MenuOverlay path are unchanged.
 */
class ChatPillView(
    context: Context,
) : View(context) {
    companion object {
        const val TAB_COUNT = 7 // native tabs drawn (All..Trade); the engine keeps the 8th Report tab
        const val CHAT_W = 519 // engine chatbox width (canvas px) — the row spans this
        const val ROW_H_CANVAS = 40 // taller native row (canvas px); pushed into the engine row height
        private val NAMES = arrayOf("All", "Game", "Public", "Private", "Channel", "Clan", "Trade")
        private val FILTERABLE = booleanArrayOf(false, false, true, true, true, true, true)
        private const val NAME_DEFAULT = 0xFFFFF7D9.toInt() // off-white
        private const val FILTER_DEFAULT = 0xFF00E000.toInt() // green ("On")
        private const val OPAQUE_BG = 0xFF423C33.toInt() // iOS stone-brown (66,60,51); fills the FULL tab rect

        private const val LONG_PRESS_MS = 350L

        // UI-3 tighten: ASYMMETRIC tappable band. Generous ABOVE the row (toward the screen top edge, where
        // nothing else lives, so a slightly-high tab tap still lands), but small BELOW — the chat-at-top message
        // area + the scene sit directly under the tabs, and a big below-band was eating those taps.
        private const val EXPAND_UP_DP = 15f
        private const val EXPAND_DOWN_DP = 4f
        private const val SLOP_DP = 12f // travel that turns a tap into a drag (cancels the long-press)
    }

    /** Tap a tab [index]: the host decides collapse (the active tab) vs switch (any other). */
    var onTabTap: ((index: Int) -> Unit)? = null

    /** Long-press a filterable tab: the host opens the engine filter menu at the live button centre (engine canvas
     *  px) anchored at the finger (view px). Returns true once the menu opened (on-canvas gate passed); false =
     *  not yet (e.g. a collapsed chat still expanding) — retried on the next move while held. */
    var onFilterOpen: ((index: Int, engineCx: Int, engineCy: Int, viewX: Float, viewY: Float) -> Boolean)? = null
    var onFilterMove: ((viewX: Float, viewY: Float) -> Unit)? = null
    var onFilterEnd: ((cancelled: Boolean) -> Unit)? = null

    /** Light haptic cue (filter open). */
    var onHaptic: (() -> Unit)? = null

    private class Tab(
        val ex: Int,
        val ey: Int,
        val ew: Int,
        val eh: Int,
        val selected: Boolean,
        val hasNew: Boolean,
        val labelColor: Int,
        val filter: String,
        val filterColor: Int,
    )

    private var shown = true
    private var enabled = false
    private var tabs: List<Tab> = emptyList()
    private var rowX = 0f
    private var rowY = 0f
    private var tabW = 0f
    private var rowH = 0f
    private var effSel = -1
    private var activeTab = -1 // last known selection (kept across a collapse for the collapse/switch test)
    private var optimisticTab = -1 // hold a just-tapped tab selected until the snapshot agrees (no timeout)

    // Gesture: a DOWN in the row band tracks a tap or a filter long-press; nothing else.
    private var tracking = false
    private var downX = 0f
    private var downY = 0f
    private var downTab = -1
    private var moved = false
    private var filterArmed = false // long-press fired on a filterable tab; retry onFilterOpen until it lands
    private var filterTab = -1 // >= 0 while the filter menu is live (host owns the MenuOverlay)
    private val longPressRunnable = Runnable { onLongPress() }

    private val dp = resources.displayMetrics.density
    private var btnNormal: Bitmap? = null
    private var btnSelected: Bitmap? = null
    private var btnNew: Bitmap? = null

    private val bgPaint =
        Paint().apply {
            isAntiAlias = true
            isFilterBitmap = true
            isDither = true
        }
    private val fillPaint = Paint().apply { color = OPAQUE_BG }
    private val namePaint =
        Paint().apply {
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
    private val statePaint =
        Paint().apply {
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
    private val srcRect = Rect()
    private val dstRect = RectF()

    init {
        // The chat-tab button sprites come from the runtime cache (setSprites), not bundled assets. The RuneScape
        // font is a separate bundled asset (not a cache sprite) and is loaded here as before.
        val rsFont =
            try {
                Typeface.createFromAsset(context.assets, "tabassets/runescape.ttf")
            } catch (e: Exception) {
                null
            }
        rsFont?.let {
            namePaint.typeface = it
            statePaint.typeface = it
        }
        Log.i("ChatPill", "ui3: static chat-tab row built (font ${if (rsFont != null) "ok" else "sys"}; sprites pending cache)")
    }

    /** Supply the chat-tab button sprites loaded at runtime from the live cache (3051 / 3053 / 3055). */
    fun setSprites(set: TabSprites.Set) {
        if (!set.usableForChat()) return
        btnNormal = set.chatbtn
        btnSelected = set.chatbtnSelected ?: set.chatbtn
        btnNew = set.chatbtnNew ?: set.chatbtn
        Log.i("ChatPill", "ui3: chat-tab sprites set from runtime cache")
        invalidate()
    }

    fun setShown(on: Boolean) {
        if (shown != on) {
            shown = on
            invalidate()
        }
    }

    /** Optimistically select a just-tapped tab so the highlight is instant (cleared once the snapshot agrees). */
    fun markOptimistic(k: Int) {
        optimisticTab = k
        activeTab = k
        invalidate()
    }

    /** The currently selected channel index (last known); 0 when nothing is reported yet. */
    val currentTab: Int get() = if (activeTab >= 0) activeTab else 0

    /** Feed the latest chat snapshot + canvas→view scale each frame. Returns the tab count parsed. */
    fun update(
        json: String,
        sx: Float,
        sy: Float,
        on: Boolean,
    ): Int {
        val want = on && shown
        if (!want) {
            if (enabled || tabs.isNotEmpty()) {
                reset()
                enabled = false
                tabs = emptyList()
                invalidate()
            }
            return 0
        }
        val o =
            try {
                JSONObject(json)
            } catch (e: Exception) {
                null
            }
        if (o == null || !o.optBoolean("loggedIn")) {
            if (tabs.isNotEmpty()) {
                reset()
                tabs = emptyList()
                invalidate()
            }
            enabled = true
            return 0
        }
        val arr =
            o.optJSONArray("tabs") ?: run {
                reset()
                tabs = emptyList()
                invalidate()
                enabled = true
                return 0
            }
        rowX = o.optInt("chatX", 0) * sx
        rowY = o.optInt("chatY", 0) * sy
        tabW = (CHAT_W * sx) / TAB_COUNT
        rowH = ROW_H_CANVAS * sy
        val list = ArrayList<Tab>(TAB_COUNT)
        var snapSel = -1
        val n = minOf(TAB_COUNT, arr.length())
        for (i in 0 until n) {
            val t = arr.optJSONObject(i) ?: continue
            val sel = t.optBoolean("selected")
            if (sel && snapSel < 0) snapSel = i
            list.add(
                Tab(
                    t.optInt("x", -1),
                    t.optInt("y", -1),
                    t.optInt("w", 0),
                    t.optInt("h", 0),
                    sel,
                    t.optBoolean("new"),
                    t.optInt("labelColor", -1),
                    t.optString("filter", ""),
                    t.optInt("filterColor", -1),
                ),
            )
        }
        effSel = snapSel
        if (optimisticTab >= 0) {
            if (snapSel == optimisticTab) optimisticTab = -1 else effSel = optimisticTab
        }
        if (effSel >= 0) activeTab = effSel
        tabs = list
        enabled = true
        invalidate()
        return list.size
    }

    /** The engine chat-button centre (canvas px) for channel i, or null while it isn't built/on-canvas. */
    fun engineButtonCenter(i: Int): Pair<Int, Int>? {
        val t = tabs.getOrNull(i) ?: return null
        if (t.ew <= 0 || t.eh <= 0 || t.ex < 0 || t.ey < 0) return null
        return (t.ex + t.ew / 2) to (t.ey + t.eh / 2)
    }

    private fun chipRect(i: Int): RectF = RectF(rowX + i * tabW, rowY, rowX + (i + 1) * tabW, rowY + rowH)

    /** Snap a touch to the nearest tab across the full row + an asymmetric vertical band; -1 if outside. */
    private fun tabAt(
        x: Float,
        y: Float,
    ): Int {
        if (y < rowY - EXPAND_UP_DP * dp || y > rowY + rowH + EXPAND_DOWN_DP * dp) return -1
        if (x < rowX || x >= rowX + tabW * TAB_COUNT) return -1
        return ((x - rowX) / tabW).toInt().coerceIn(0, TAB_COUNT - 1)
    }

    private fun reset() {
        removeCallbacks(longPressRunnable)
        tracking = false
        moved = false
        downTab = -1
        filterArmed = false
        filterTab = -1
    }

    // --- drawing ----------------------------------------------------------------------------------------

    private fun colorOf(
        rgb: Int,
        default: Int,
    ) = if (rgb < 0) default else (0xFF000000.toInt() or (rgb and 0xFFFFFF))

    private fun drawChip(
        canvas: Canvas,
        r: RectF,
        i: Int,
        selected: Boolean,
    ) {
        // Opaque fill FIRST so the engine controls row underneath is fully covered — including the sprite's
        // transparent rounded corners (the iOS lesson; without it the engine tabs peek through).
        canvas.drawRect(r, fillPaint)
        val t = tabs.getOrNull(i)
        val bg =
            when {
                selected -> btnSelected
                t?.hasNew == true -> btnNew
                else -> btnNormal
            }
        if (bg != null) {
            srcRect.set(0, 0, bg.width, bg.height)
            bgPaint.alpha = 255
            dstRect.set(r)
            canvas.drawBitmap(bg, srcRect, dstRect, bgPaint)
        }
        val cx = r.centerX()
        namePaint.alpha = 255
        statePaint.alpha = 255
        namePaint.textSize = r.height() * 0.40f
        namePaint.color = colorOf(t?.labelColor ?: -1, NAME_DEFAULT)
        val filter = t?.filter ?: ""
        if (filter.isNotEmpty()) {
            canvas.drawText(NAMES[i], cx, r.top + r.height() * 0.44f, namePaint)
            statePaint.textSize = r.height() * 0.34f
            statePaint.color = colorOf(t?.filterColor ?: -1, FILTER_DEFAULT)
            canvas.drawText(filter, cx, r.top + r.height() * 0.88f, statePaint)
        } else {
            canvas.drawText(NAMES[i], cx, r.top + r.height() * 0.64f, namePaint)
        }
    }

    override fun onDraw(canvas: Canvas) {
        if (!enabled || !shown || tabs.isEmpty() || tabW <= 0f) return
        val n = minOf(TAB_COUNT, tabs.size)
        for (i in 0 until n) {
            drawChip(canvas, chipRect(i), i, selected = i == effSel)
        }
    }

    // --- gesture ----------------------------------------------------------------------------------------

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!enabled || !shown || tabs.isEmpty() || tabW <= 0f) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val k = tabAt(event.x, event.y)
                if (k < 0) return false // outside the row band -> fall through to the game (camera/scroll/etc.)
                tracking = true
                moved = false
                filterArmed = false
                filterTab = -1
                downX = event.x
                downY = event.y
                downTab = k
                if (FILTERABLE[k]) postDelayed(longPressRunnable, LONG_PRESS_MS)
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                if (!tracking) return false
                if (!moved && hypot((event.x - downX).toDouble(), (event.y - downY).toDouble()) > SLOP_DP * dp) {
                    moved = true
                    removeCallbacks(longPressRunnable) // a drag isn't a long-press
                }
                if (filterTab >= 0) {
                    onFilterMove?.invoke(event.x, event.y)
                } else if (filterArmed) {
                    // The chat was collapsed when the long-press fired; the host expanded it. Retry until the
                    // engine button is on-canvas and the menu opens.
                    val centre = engineButtonCenter(downTab)
                    if (onFilterOpen?.invoke(downTab, centre?.first ?: -1, centre?.second ?: -1, event.x, event.y) == true) {
                        filterTab = downTab
                        onHaptic?.invoke()
                    }
                }
                return true
            }

            MotionEvent.ACTION_UP -> {
                if (!tracking) return false
                removeCallbacks(longPressRunnable)
                if (filterTab >= 0) {
                    onFilterEnd?.invoke(false) // release on a menu row commits the filter choice
                    filterTab = -1
                } else if (!moved && !filterArmed) {
                    val k = tabAt(event.x, event.y).let { if (it >= 0) it else downTab }
                    if (k >= 0) onTabTap?.invoke(k)
                }
                tracking = false
                filterArmed = false
                return true
            }

            MotionEvent.ACTION_CANCEL -> {
                if (!tracking) return false
                removeCallbacks(longPressRunnable)
                if (filterTab >= 0) {
                    onFilterEnd?.invoke(true)
                    filterTab = -1
                }
                tracking = false
                filterArmed = false
                return true
            }
        }
        return false
    }

    private fun onLongPress() {
        if (!tracking || moved || downTab < 0 || !FILTERABLE[downTab]) return
        filterArmed = true
        val centre = engineButtonCenter(downTab)
        if (onFilterOpen?.invoke(downTab, centre?.first ?: -1, centre?.second ?: -1, downX, downY) == true) {
            filterTab = downTab
            onHaptic?.invoke()
            Log.i("ChatPill", "ui3: long-press $downTab (${NAMES[downTab]}) -> filter menu")
        }
    }
}
