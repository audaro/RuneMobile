package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.view.MotionEvent
import android.view.View
import kotlin.math.roundToInt

// Strip a trailing "Overlay" and space out the camel-cased class name for a readable box label.
private fun prettyOverlayName(n: String): String {
    val base = n.removeSuffix("Overlay").ifEmpty { n }
    return base.replace(Regex("([a-z])([A-Z])"), "$1 $2").trim().ifEmpty { n }
}

/**
 * On-screen overlay-layout editor: draws each movable RuneLite overlay as a translucent, labelled box at its live
 * game-canvas bounds (scaled to view px) directly over the running game, and lets the user DRAG it to a new spot —
 * the mobile analogue of the desktop "overlay management" mode. The box being dragged follows the finger; on
 * release its new top-left (canvas px) is committed via {@code onDrop} (the host writes it through
 * OverlayBridge.setOverlayPreferredLocation). A floating toolbar offers Done + Reset-all. Non-dragged boxes track
 * the host-fed live bounds ({@link #setBoxes}); the dragged one is left alone until release.
 */
class OverlayEditView(
    context: Context,
) : View(context) {
    data class Box(
        val name: String,
        val cx: Int,
        val cy: Int,
        val cw: Int,
        val ch: Int,
    )

    /** New top-left in CANVAS px for [name] (clamped on-canvas). Host commits it on the bridge thread. */
    var onDrop: ((name: String, canvasX: Int, canvasY: Int) -> Unit)? = null
    var onDone: (() -> Unit)? = null
    var onResetAll: (() -> Unit)? = null

    private var boxes: List<Box> = emptyList()

    // Drag state. dragW/dragH (view px) drive the on-screen box; dragCw/dragCh are the box's ORIGINAL canvas-px
    // size, cached on grab so the commit clamp uses the exact integer footprint (no view-px round-trip drift).
    private var dragName: String? = null
    private var dragW = 0f
    private var dragH = 0f
    private var dragCw = 0
    private var dragCh = 0
    private var grabDX = 0f
    private var grabDY = 0f
    private var dragLeft = 0f
    private var dragTop = 0f

    private val dp = resources.displayMetrics.density
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x33FFD54F } // translucent amber
    private val fillActive = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x66FFD54F }
    private val border =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 1.5f * dp
            color = 0xFFFFD54F.toInt()
        }
    private val label =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 11f * dp
            typeface = Typeface.DEFAULT_BOLD
        }
    private val labelBg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xAA000000.toInt() }
    private val btnBg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xEE2A2A2A.toInt() }
    private val btnTxt =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 14f * dp
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
    private val hintTxt =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xCCFFFFFF.toInt()
            textSize = 12f * dp
            textAlign =
                Paint.Align.CENTER
        }
    private val rrf = RectF()

    // Toolbar button rects (view px), computed in onDraw, hit-tested in onTouch.
    private val doneRect = RectF()
    private val resetRect = RectF()

    private fun sx() = if (MainActivity.canvasW > 0) width.toFloat() / MainActivity.canvasW else 1f

    private fun sy() = if (MainActivity.canvasH > 0) height.toFloat() / MainActivity.canvasH else 1f

    /** Feed live overlay bounds (host poll). The box currently being dragged is preserved. */
    fun setBoxes(list: List<Box>) {
        boxes = list
        invalidate()
    }

    /** Names of the overlays currently shown (for Reset-all). */
    fun currentNames(): List<String> = boxes.map { it.name }

    private fun layoutToolbar() {
        val w = 96f * dp
        val h = 40f * dp
        val m = 10f * dp
        val top = m
        doneRect.set(width - m - w, top, width - m, top + h)
        resetRect.set(width - m - w - m - w, top, width - m - m - w, top + h)
    }

    override fun onDraw(canvas: Canvas) {
        if (visibility != VISIBLE) return
        val sx = sx()
        val sy = sy()
        // Movable-overlay boxes (the dragged one is drawn from its live drag rect, others from fed bounds).
        for (b in boxes) {
            val dragging = b.name == dragName
            val l: Float
            val t: Float
            val r: Float
            val bot: Float
            if (dragging) {
                l = dragLeft
                t = dragTop
                r = dragLeft + dragW
                bot = dragTop + dragH
            } else {
                l = b.cx * sx
                t = b.cy * sy
                r = (b.cx + b.cw) * sx
                bot = (b.cy + b.ch) * sy
            }
            rrf.set(l, t, r, bot)
            canvas.drawRect(rrf, if (dragging) fillActive else fill)
            canvas.drawRect(rrf, border)
            val name = prettyOverlayName(b.name)
            val tw = label.measureText(name)
            val lx = l + 3f * dp
            val ly = t + 13f * dp
            canvas.drawRect(lx - 2f * dp, t + 1f * dp, lx + tw + 2f * dp, t + 17f * dp, labelBg)
            canvas.drawText(name, lx, ly, label)
        }
        // Floating toolbar (Done / Reset all) + a one-line hint, drawn last so they sit above the boxes.
        layoutToolbar()
        drawButton(canvas, doneRect, "Done")
        drawButton(canvas, resetRect, "Reset all")
        canvas.drawText("Drag an overlay to move it", width / 2f, 26f * dp, hintTxt)
    }

    private fun drawButton(
        canvas: Canvas,
        r: RectF,
        text: String,
    ) {
        canvas.drawRoundRect(r, 10f * dp, 10f * dp, btnBg)
        canvas.drawText(text, r.centerX(), r.centerY() + 5f * dp, btnTxt)
    }

    private fun boxAt(
        x: Float,
        y: Float,
    ): Box? {
        val sx = sx()
        val sy = sy()
        // Topmost (last-drawn) box under the point wins.
        for (i in boxes.indices.reversed()) {
            val b = boxes[i]
            val l = b.cx * sx
            val t = b.cy * sy
            val r = (b.cx + b.cw) * sx
            val bot = (b.cy + b.ch) * sy
            if (x >= l && x <= r && y >= t && y <= bot) return b
        }
        return null
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (visibility != VISIBLE) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (doneRect.contains(event.x, event.y)) {
                    onDone?.invoke()
                    return true
                }
                if (resetRect.contains(event.x, event.y)) {
                    onResetAll?.invoke()
                    return true
                }
                val b = boxAt(event.x, event.y) ?: return true // consume taps in edit mode (no game interaction)
                val sx = sx()
                val sy = sy()
                dragName = b.name
                dragCw = b.cw
                dragCh = b.ch
                dragW = b.cw * sx
                dragH = b.ch * sy
                dragLeft = b.cx * sx
                dragTop = b.cy * sy
                grabDX = event.x - dragLeft
                grabDY = event.y - dragTop
                invalidate()
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                if (dragName == null) return true
                dragLeft = (event.x - grabDX).coerceIn(0f, (width - dragW).coerceAtLeast(0f))
                dragTop = (event.y - grabDY).coerceIn(0f, (height - dragH).coerceAtLeast(0f))
                invalidate()
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val name = dragName
                if (name != null && event.actionMasked == MotionEvent.ACTION_UP) {
                    val sx = sx()
                    val sy = sy()
                    val cw = MainActivity.canvasW
                    val ch = MainActivity.canvasH
                    val cx = (dragLeft / sx).roundToInt().coerceIn(0, (cw - dragCw).coerceAtLeast(0))
                    val cy = (dragTop / sy).roundToInt().coerceIn(0, (ch - dragCh).coerceAtLeast(0))
                    onDrop?.invoke(name, cx, cy)
                }
                dragName = null
                invalidate()
                return true
            }
        }
        return false
    }
}
