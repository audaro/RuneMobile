package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.os.SystemClock
import android.view.View

/**
 * Tap-feedback ring (parity with the iOS click ring): every world tap spawns an expanding/fading ring at the
 * touch point — RED when the engine consumed an interaction (interactTapSeq advanced), YELLOW for a plain
 * walk. The colour decision is the caller's (MainActivity defers it until the engine-resolved tap state
 * machine reports truth, ~80–160 ms after the tap); this view only animates. Non-interactive: it sits over
 * the game frame but swallows no touches. The engine's own click-cross sprites are blanked by the shared
 * runtime (runelite.touch.hideClickCross), so this is the only tap feedback the user sees.
 */
class TapRingView(
    context: Context,
) : View(context) {
    private data class Ring(
        val x: Float,
        val y: Float,
        val color: Int,
        val startMs: Long,
    )

    private val rings = ArrayList<Ring>(4)
    private val paint =
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = 3f * resources.displayMetrics.density
        }
    private val baseRadius = 16f * resources.displayMetrics.density

    init {
        // Never intercept the gesture stream the SurfaceView owns.
        isClickable = false
        isFocusable = false
    }

    companion object {
        const val COLOR_INTERACT = 0xFFE53935.toInt() // red: the engine consumed an interaction
        const val COLOR_WALK = 0xFFFFD54F.toInt() // yellow: plain walk
        private const val LIFE_MS = 450L // matches the iOS 0.45 s scale-and-fade
        private const val SCALE_FROM = 0.5f
        private const val SCALE_TO = 2.2f
    }

    /** Spawn a ring at view-local (x, y). Call from the UI thread. */
    fun spawn(
        x: Float,
        y: Float,
        color: Int,
    ) {
        rings.add(Ring(x, y, color, SystemClock.uptimeMillis()))
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (rings.isEmpty()) return
        val now = SystemClock.uptimeMillis()
        val it = rings.iterator()
        while (it.hasNext()) {
            val r = it.next()
            val t = (now - r.startMs).toFloat() / LIFE_MS
            if (t >= 1f) {
                it.remove()
                continue
            }
            paint.color = r.color
            paint.alpha = ((1f - t) * 255f).toInt()
            canvas.drawCircle(r.x, r.y, baseRadius * (SCALE_FROM + (SCALE_TO - SCALE_FROM) * t), paint)
        }
        if (rings.isNotEmpty()) postInvalidateOnAnimation()
    }
}
