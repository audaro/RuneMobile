package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View

/**
 * UX-DISCRETE-01 / ENH-B06: a full-screen, non-interactive "Hopping…" scrim shown over the live SurfaceView
 * while a world hop runs. Because the in-engine hop is inert headless, a world hop is implemented as a
 * logout→changeWorld→relogin relog (~8 s of raw engine login/welcome chrome), so a routine hop otherwise reads
 * as a kick/disconnect with no status. This scrim covers that flash with a calm native card so the moment reads
 * as "switching worlds".
 *
 * A sibling of [ReconnectingOverlayView]: MATCH_PARENT, isClickable=false, draws nothing when idle (touches
 * fall through to the game), self-invalidating per frame only while visible. Driven entirely Android-side by
 * MainActivity — armed from the world-hop trigger sites (HUD quick-hop hotkey + World Switcher row/Prev/Next),
 * hidden on the next logged-in edge after the hop or after a bounded timeout, so it can never stick over the game.
 */
class HoppingOverlayView(
    context: Context,
) : View(context) {
    // Thread contract: setHopping/setLabel are called only from the UI thread (the HUD-hotkey onClick, the
    // World-Switcher Compose onClick, and the Choreographer-driven updateChrome hide), and onDraw runs on the UI
    // thread too — so these need no locking. Both are @Volatile anyway as a belt-and-suspenders guard against a
    // future off-thread caller (a stale read could only ever cause a one-frame visual blip, never a crash).
    @Volatile private var active = false

    @Volatile private var label = "Hopping to world…"

    private val scrimPaint = Paint().apply { color = Color.argb(150, 0, 0, 0) }
    private val cardPaint =
        Paint().apply {
            color = Color.argb(238, 33, 28, 23)
            isAntiAlias = true
        }
    private val borderPaint =
        Paint().apply {
            color = Color.argb(255, 140, 128, 102)
            style = Paint.Style.STROKE
            strokeWidth = dp(1.5f)
            isAntiAlias = true
        }
    private val textPaint =
        Paint().apply {
            color = Color.WHITE
            textSize = sp(17f)
            isFakeBoldText = true
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
    private val spinnerTrackPaint =
        Paint().apply {
            color = Color.argb(60, 255, 255, 255)
            style = Paint.Style.STROKE
            strokeWidth = dp(3f)
            isAntiAlias = true
        }
    private val spinnerPaint =
        Paint().apply {
            color = Color.argb(255, 255, 200, 90)
            style = Paint.Style.STROKE
            strokeWidth = dp(3f)
            strokeCap = Paint.Cap.ROUND
            isAntiAlias = true
        }

    private val spinnerRect = RectF()

    init {
        isClickable = false
        isFocusable = false
    }

    private fun dp(v: Float) = v * resources.displayMetrics.density

    private fun sp(v: Float) = v * resources.displayMetrics.scaledDensity

    val isActive: Boolean get() = active

    /** Set the label (e.g. "Hopping to world 308…" when the target is known, else a generic "Switching worlds…"). */
    fun setLabel(text: String) {
        label = text
        if (active) postInvalidateOnAnimation()
    }

    /** Show/hide the overlay; returns true if the state changed (the per-frame poll calls this every frame, so
     *  it must be cheap when nothing changed — and the host logs only on a transition). */
    fun setHopping(on: Boolean): Boolean {
        if (on == active) return false
        active = on
        invalidate()
        return true
    }

    override fun onDraw(canvas: Canvas) {
        if (!active) return
        val vw = width.toFloat()
        val vh = height.toFloat()

        // Dim the whole screen so the engine's raw logout/login/welcome chrome doesn't read through.
        canvas.drawRect(0f, 0f, vw, vh, scrimPaint)

        // Centered status card.
        val cardW = minOf(dp(260f), vw - dp(48f))
        val cardH = dp(140f)
        val cx = vw / 2f
        val top = (vh - cardH) / 2f
        val left = cx - cardW / 2f
        val r = dp(10f)
        canvas.drawRoundRect(left, top, left + cardW, top + cardH, r, r, cardPaint)
        canvas.drawRoundRect(left, top, left + cardW, top + cardH, r, r, borderPaint)

        // Rotating spinner (track ring + a 90° sweep advancing once/sec).
        val rad = dp(18f)
        val scy = top + dp(52f)
        spinnerRect.set(cx - rad, scy - rad, cx + rad, scy + rad)
        canvas.drawArc(spinnerRect, 0f, 360f, false, spinnerTrackPaint)
        val sweepStart = (System.currentTimeMillis() % 1000L) / 1000f * 360f
        canvas.drawArc(spinnerRect, sweepStart, 90f, false, spinnerPaint)

        // Label.
        val baseline = top + dp(106f) - (textPaint.ascent() + textPaint.descent()) / 2f
        canvas.drawText(label, cx, baseline, textPaint)

        // Keep the spinner turning while visible; stops as soon as active flips false.
        postInvalidateOnAnimation()
    }
}
