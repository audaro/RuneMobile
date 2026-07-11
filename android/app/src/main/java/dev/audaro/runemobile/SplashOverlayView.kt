package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.View

/**
 * UX-ONBOARD-01: a full-screen, non-interactive branded cold-start overlay. Cold start unpacks a ~198 MB asset
 * tree, boots the on-device JVM and renders the first frame — until then the Z0 SurfaceView is black, which
 * reads as a hang/ANR. This scrim is added topmost and shown IMMEDIATELY in onCreate (before any frame paints),
 * drawing an OSRS-styled dark card with a rotating spinner + a "Loading…" line so the launch reads as "starting
 * up", not "frozen". On the first-install path it can also show a coarse "Unpacking… N%" progress line.
 *
 * Modeled on [ReconnectingOverlayView]: laid out MATCH_PARENT, isClickable=false, self-invalidating per frame
 * only while visible. Driven entirely Android-side by MainActivity — armed in onCreate, dismissed by
 * [dismiss] when the engine produces its first real frame (or a real login state is observed), and bounded by
 * a generous wall-clock timeout failsafe so a missed signal can never leave it stuck over the game.
 */
class SplashOverlayView(
    context: Context,
) : View(context) {
    // Start ACTIVE: the splash must be up the instant the activity content is set, before the boot thread runs.
    private var active = true

    @Volatile private var statusLine = "Loading…"

    // Coarse unpack progress 0..100; <0 means "no progress line" (boot/first-frame phase, just the spinner).
    @Volatile private var progressPct = -1

    // BOOT-1: terminal boot-failure state — spinner stops, an error title + body lines render, and dismiss()
    // becomes a no-op so the wall-clock failsafe can't drop the card and expose a dead black SurfaceView.
    @Volatile private var errorMode = false
    private var errorTitle = ""
    private var errorLines: List<String> = emptyList()

    private val scrimPaint = Paint().apply { color = Color.argb(255, 22, 18, 14) }
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
    private val titlePaint =
        Paint().apply {
            color = Color.argb(255, 255, 200, 90)
            textSize = sp(22f)
            isFakeBoldText = true
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
    private val textPaint =
        Paint().apply {
            color = Color.WHITE
            textSize = sp(16f)
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

    /** Coarse unpack progress (first-install path only). pct 0..100; sets the status to "Unpacking… N%". */
    fun setUnpackProgress(pct: Int) {
        progressPct = pct.coerceIn(0, 100)
        statusLine = "Unpacking… $progressPct%"
        postInvalidateOnAnimation()
    }

    /** Switch the status line to a free-form message (e.g. "Starting up…") with no percent. */
    fun setStatus(msg: String) {
        progressPct = -1
        statusLine = msg
        postInvalidateOnAnimation()
    }

    /**
     * BOOT-1: latch a terminal boot failure onto the splash. The card stays up (dismiss() no-ops) because a
     * failed boot leaves nothing behind it but a black SurfaceView — the copy is the only signal the user gets.
     */
    fun showBootError(
        title: String,
        lines: List<String>,
    ) {
        errorMode = true
        errorTitle = title
        errorLines = lines
        active = true
        visibility = VISIBLE
        postInvalidateOnAnimation()
    }

    /** Dismiss the splash. Idempotent; returns true the first time it actually hides (so the host logs once). */
    fun dismiss(): Boolean {
        if (!active || errorMode) return false
        active = false
        visibility = GONE
        invalidate()
        return true
    }

    override fun onDraw(canvas: Canvas) {
        if (!active) return
        val vw = width.toFloat()
        val vh = height.toFloat()

        // Opaque background so the black SurfaceView never reads through during the cold boot.
        canvas.drawRect(0f, 0f, vw, vh, scrimPaint)

        // Centered status card (taller in error mode to fit the body lines).
        val lineH = dp(20f)
        val cardW = minOf(if (errorMode) dp(340f) else dp(280f), vw - dp(48f))
        val cardH = if (errorMode) dp(96f) + errorLines.size * lineH else dp(180f)
        val cx = vw / 2f
        val top = (vh - cardH) / 2f
        val left = cx - cardW / 2f
        val r = dp(10f)
        canvas.drawRoundRect(left, top, left + cardW, top + cardH, r, r, cardPaint)
        canvas.drawRoundRect(left, top, left + cardW, top + cardH, r, r, borderPaint)

        // BOOT-1 error mode: static title + body, no spinner (nothing is in progress any more).
        if (errorMode) {
            val titleBaseline = top + dp(40f) - (titlePaint.ascent() + titlePaint.descent()) / 2f
            canvas.drawText(errorTitle, cx, titleBaseline, titlePaint)
            var y = top + dp(72f)
            for (line in errorLines) {
                canvas.drawText(line, cx, y, textPaint)
                y += lineH
            }
            return
        }

        // Brand title.
        val titleBaseline = top + dp(40f) - (titlePaint.ascent() + titlePaint.descent()) / 2f
        canvas.drawText("Old School", cx, titleBaseline, titlePaint)

        // Rotating spinner (track ring + a 90° sweep advancing once/sec).
        val rad = dp(18f)
        val scy = top + dp(96f)
        spinnerRect.set(cx - rad, scy - rad, cx + rad, scy + rad)
        canvas.drawArc(spinnerRect, 0f, 360f, false, spinnerTrackPaint)
        val sweepStart = (System.currentTimeMillis() % 1000L) / 1000f * 360f
        canvas.drawArc(spinnerRect, sweepStart, 90f, false, spinnerPaint)

        // Status line.
        val baseline = top + dp(150f) - (textPaint.ascent() + textPaint.descent()) / 2f
        canvas.drawText(statusLine, cx, baseline, textPaint)

        // Keep the spinner turning while visible; stops as soon as active flips false.
        postInvalidateOnAnimation()
    }
}
