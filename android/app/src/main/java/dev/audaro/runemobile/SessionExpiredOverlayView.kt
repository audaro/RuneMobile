package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

/**
 * UX-LOGIN-01: a full-screen, INTERACTIVE "Session expired" overlay shown when the headless login machine has
 * given up (autologin / reconnect exhausted — [HeadlessLogin.hasGivenUp], surfaced as the chrome snapshot's
 * "sessionExpired" flag). Unlike the transient [ReconnectingOverlayView] scrim (which recovers on its own), this
 * is a hard stop: the client is parked on the raw desktop login screen with no automated recovery, so the shell
 * presents a calm native card with a single "Sign in again" button that re-runs the on-device Jagex login
 * (LoginActivity). It consumes touches while visible so the dead engine login screen underneath can't be poked.
 *
 * Driven by [setVisible] from MainActivity.updateChrome; [onSignIn] is invoked when the button is tapped.
 */
class SessionExpiredOverlayView(
    context: Context,
) : View(context) {
    /** Invoked when the user taps "Sign in again". */
    var onSignIn: (() -> Unit)? = null

    private var active = false

    private val scrimPaint = Paint().apply { color = Color.argb(190, 0, 0, 0) }
    private val cardPaint =
        Paint().apply {
            color = Color.argb(240, 33, 28, 23)
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
        isClickable = true // consume touches while visible (the engine login screen underneath is dead)
        isFocusable = false
    }

    private fun dp(v: Float) = v * resources.displayMetrics.density

    private fun sp(v: Float) = v * resources.displayMetrics.scaledDensity

    /** Show/hide; returns true if the state changed (the per-frame poll calls this every frame). */
    fun setVisible(on: Boolean): Boolean {
        if (on == active) return false
        active = on
        isClickable = on
        invalidate()
        return true
    }

    val isActive: Boolean get() = active

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!active) return false
        // Consume everything while visible; fire the callback on an up inside the button.
        if (event.action == MotionEvent.ACTION_UP && buttonRect.contains(event.x, event.y)) {
            onSignIn?.invoke()
        }
        return true
    }

    override fun onDraw(canvas: Canvas) {
        if (!active) return
        val vw = width.toFloat()
        val vh = height.toFloat()
        canvas.drawRect(0f, 0f, vw, vh, scrimPaint)

        val cardW = minOf(dp(300f), vw - dp(48f))
        val cardH = dp(196f)
        val cx = vw / 2f
        val top = (vh - cardH) / 2f
        val left = cx - cardW / 2f
        val r = dp(10f)
        cardRect.set(left, top, left + cardW, top + cardH)
        canvas.drawRoundRect(cardRect, r, r, cardPaint)
        canvas.drawRoundRect(cardRect, r, r, borderPaint)

        canvas.drawText("Session expired", cx, top + dp(44f), titlePaint)
        canvas.drawText("Your session has ended.", cx, top + dp(78f), bodyPaint)
        canvas.drawText("Sign in again to keep playing.", cx, top + dp(98f), bodyPaint)

        // "Sign in again" button.
        val btnW = cardW - dp(48f)
        val btnH = dp(46f)
        val btnLeft = cx - btnW / 2f
        val btnTop = top + cardH - btnH - dp(22f)
        buttonRect.set(btnLeft, btnTop, btnLeft + btnW, btnTop + btnH)
        val br = dp(8f)
        canvas.drawRoundRect(buttonRect, br, br, buttonPaint)
        canvas.drawRoundRect(buttonRect, br, br, buttonBorderPaint)
        val tBaseline = buttonRect.centerY() - (buttonTextPaint.ascent() + buttonTextPaint.descent()) / 2f
        canvas.drawText("Sign in again", cx, tBaseline, buttonTextPaint)
    }
}
