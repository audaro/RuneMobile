package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

/**
 * FATAL-1: a full-screen, INTERACTIVE card for engine-fatal stops (the chrome snapshot's
 * "fatalError"/"fatalCode", noted from RSAppletStub.onError via MobileChromeBridge). Desktop RuneLite routes
 * these to a Swing FatalErrorDialog the headless boot can't render — without this card, every weekly OSRS
 * update ends in a silent black screen (stale client rev -> error_game_js5connect). This is a TERMINAL
 * state: the applet is dead and nothing recovers, so the card latches on and its single "Restart app" button
 * relaunches the process (the same clean-boot mechanism as the renderer restarts; for a stale-rev js5connect
 * the copy tells the user a rebuilt app is needed). Consumes touches while visible, like
 * [SessionExpiredOverlayView].
 */
class FatalErrorOverlayView(
    context: Context,
) : View(context) {
    /** Invoked when the user taps "Restart app". */
    var onRestart: (() -> Unit)? = null

    private var active = false
    private var title = ""
    private var bodyLines: List<String> = emptyList()

    private val scrimPaint = Paint().apply { color = Color.argb(205, 0, 0, 0) }
    private val cardPaint =
        Paint().apply {
            color = Color.argb(245, 33, 28, 23)
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
            color = Color.WHITE
            textSize = sp(18f)
            isFakeBoldText = true
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
    private val bodyPaint =
        Paint().apply {
            color = Color.argb(255, 210, 198, 170)
            textSize = sp(14f)
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
    private val buttonPaint =
        Paint().apply {
            color = Color.argb(255, 92, 72, 38)
            isAntiAlias = true
        }
    private val buttonBorderPaint =
        Paint().apply {
            color = Color.argb(255, 180, 150, 96)
            style = Paint.Style.STROKE
            strokeWidth = dp(1.5f)
            isAntiAlias = true
        }
    private val buttonTextPaint =
        Paint().apply {
            color = Color.argb(255, 255, 230, 170)
            textSize = sp(16f)
            isFakeBoldText = true
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }

    private val cardRect = RectF()
    private val buttonRect = RectF()

    init {
        isClickable = false
        isFocusable = false
    }

    private fun dp(v: Float) = v * resources.displayMetrics.density

    private fun sp(v: Float) = v * resources.displayMetrics.scaledDensity

    /**
     * Latch the card on with per-code copy; returns true on the first (state-changing) call. Never hides —
     * a fatal is terminal for this process. The per-frame poll calls this every frame once flagged.
     */
    fun showFatal(code: String): Boolean {
        if (active) return false
        active = true
        isClickable = true
        val copy = copyFor(code)
        title = copy.first
        bodyLines = copy.second
        invalidate()
        return true
    }

    val isActive: Boolean get() = active

    // Per-code copy. js5connect after the weekly OSRS update = stale client rev — the honest headline case
    // (the fix is a rebuilt app, or you're offline); js5io = blocked/flaky connection; crash = engine died.
    private fun copyFor(code: String): Pair<String, List<String>> =
        when (code) {
            "error_game_js5connect" -> {
                "Can't reach the game servers" to
                    listOf(
                        "Old School RuneScape may have just updated —",
                        "after a weekly game update this app needs a",
                        "rebuilt release before it can connect.",
                        "Install the newest build of the app, or if",
                        "you're offline, check your connection.",
                    )
            }

            "error_game_js5io" -> {
                "Connection to the update server failed" to
                    listOf(
                        "The connection to the game's update server",
                        "was interrupted or blocked. Check your network",
                        "(a firewall or captive portal can block it),",
                        "then reopen the app.",
                    )
            }

            "error_game_crash" -> {
                "The game crashed" to
                    listOf(
                        "Close and reopen the app to get back in.",
                        "If this keeps happening, disable recently",
                        "added plugins before reconnecting.",
                    )
            }

            else -> {
                "The game stopped" to
                    listOf(
                        "Close and reopen the app to get back in.",
                        "(code: $code)",
                    )
            }
        }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!active) return false
        // Consume everything while visible; fire the callback on an up inside the button.
        if (event.action == MotionEvent.ACTION_UP && buttonRect.contains(event.x, event.y)) {
            onRestart?.invoke()
        }
        return true
    }

    override fun onDraw(canvas: Canvas) {
        if (!active) return
        val vw = width.toFloat()
        val vh = height.toFloat()
        canvas.drawRect(0f, 0f, vw, vh, scrimPaint)

        val lineH = dp(20f)
        val cardW = minOf(dp(340f), vw - dp(48f))
        val cardH = dp(150f) + bodyLines.size * lineH
        val cx = vw / 2f
        val top = (vh - cardH) / 2f
        val left = cx - cardW / 2f
        val r = dp(10f)
        cardRect.set(left, top, left + cardW, top + cardH)
        canvas.drawRoundRect(cardRect, r, r, cardPaint)
        canvas.drawRoundRect(cardRect, r, r, borderPaint)

        canvas.drawText(title, cx, top + dp(40f), titlePaint)
        var y = top + dp(70f)
        for (line in bodyLines) {
            canvas.drawText(line, cx, y, bodyPaint)
            y += lineH
        }

        // "Restart app" button.
        val btnW = cardW - dp(48f)
        val btnH = dp(46f)
        val btnLeft = cx - btnW / 2f
        val btnTop = top + cardH - btnH - dp(22f)
        buttonRect.set(btnLeft, btnTop, btnLeft + btnW, btnTop + btnH)
        val br = dp(8f)
        canvas.drawRoundRect(buttonRect, br, br, buttonPaint)
        canvas.drawRoundRect(buttonRect, br, br, buttonBorderPaint)
        val tBaseline = buttonRect.centerY() - (buttonTextPaint.ascent() + buttonTextPaint.descent()) / 2f
        canvas.drawText("Restart app", cx, tBaseline, buttonTextPaint)
    }
}
