package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View

/**
 * FIX-9: a full-screen, non-interactive "Reconnecting…" overlay shown over the live SurfaceView while the
 * headless auto-reconnect machine recovers an in-session network drop. During recovery the engine briefly
 * flashes its raw "Failed to login. Please try again." / welcome login screens; this scrim covers them with a
 * calm, native status card so the moment reads as "reconnecting", not "you've been kicked".
 *
 * Driven entirely by [setReconnecting] from MainActivity.updateChrome (off the published chrome snapshot's
 * "reconnecting" flag). Like MenuOverlayView it is laid out MATCH_PARENT but isClickable=false, so when idle
 * it draws nothing and touches fall through to the game; while active it dims the screen and draws a centered
 * OSRS-styled card with a rotating spinner, self-invalidating per frame only while visible.
 */
class ReconnectingOverlayView(
    context: Context,
) : View(context) {
    private var active = false

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

    /** Show/hide the overlay; returns true if the state changed (the per-frame poll calls this every frame, so
     *  it must be cheap when nothing changed — and the host logs only on a transition). */
    fun setReconnecting(on: Boolean): Boolean {
        if (on == active) return false
        active = on
        invalidate()
        return true
    }

    val isActive: Boolean get() = active

    override fun onDraw(canvas: Canvas) {
        if (!active) return
        val vw = width.toFloat()
        val vh = height.toFloat()

        // Dim the whole screen so the engine's raw login screens don't read through.
        canvas.drawRect(0f, 0f, vw, vh, scrimPaint)

        // Centered status card.
        val cardW = minOf(dp(240f), vw - dp(48f))
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
        canvas.drawText("Reconnecting\u2026", cx, baseline, textPaint)

        // Keep the spinner turning while visible; stops as soon as active flips false.
        postInvalidateOnAnimation()
    }
}
