package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import android.view.View
import android.view.WindowInsets

/**
 * The A2 press-and-peek native menu: a full-screen, non-interactive overlay drawn over the live SurfaceView
 * (selection is driven by the host's long-press drag, not by this view's own touch). It renders an OSRS-styled
 * "Choose Option" box at the finger — header at the press point, body extending down and toward the side AWAY
 * from the holding hand — and hit-tests the finger to a display-row index.
 *
 * This view owns only the on-screen *presentation* (view-space geometry, touch-friendly row heights). The host
 * (MainActivity) maps the chosen row back to the engine's 19px-header/15px-row geometry to commit the click via
 * JavaBridge.selectMenuPoint, so plugin onClick consumers + Menu Entry Swapper ordering are honoured.
 */
class MenuOverlayView(
    context: Context,
) : View(context) {
    /** FIX-10b: a row's role in tap-mode. NORMAL = leaf (commit); PARENT = has a submenu (drill in); BACK = the
     *  synthetic "‹ Back" row the host prepends inside a submenu. Drag-mode menus are all NORMAL. */
    enum class Role { NORMAL, PARENT, BACK }

    /**
     * One menu row in display order (index 0 = top = the engine's left-click default). FIX-10b adds: [sub] (a
     * parent's child entries, from the snapshot's "sub" array), [role], and [engineIndex] — the entry's index in
     * the engine top-level list (for a top row) OR the child index within its parent's submenu (for a drilled
     * child); -1 for synthetic rows. Defaults keep drag-mode callers unchanged.
     */
    data class Entry(
        val opt: String,
        val tgt: String,
        val sub: List<Entry>? = null,
        val role: Role = Role.NORMAL,
        val engineIndex: Int = -1,
    )

    private var entries: List<Entry> = emptyList()
    private var active = false
    private var tapMode = false // FIX-10b: persistent tap-to-select (submenus / shift) vs slide-select
    private var headerText = "Choose Option"
    private var boxX = 0f
    private var boxY = 0f
    private var highlight = -1

    // View-space geometry matching the iOS native menu (kMenuHeaderViewH 22 / kMenuRowViewH 44 / kMenuWidth 210),
    // independent of the engine's fixed 19/15 px menu.
    private val headerH = dp(22f)
    private val baseRowH = dp(44f) // TOUCH-1: minimum touch-target height (was 32; FIX-10 still shrinks to fit)

    // FIX-10: a slide-select peek menu can't scroll, so a row past the screen edge is unreachable. rowH shrinks
    // (down to a legible floor) in show() when a tall menu wouldn't otherwise fit fully on-screen.
    private var rowH = baseRowH

    // UI-5: the box width is the iOS kMenuWidth (210) floor, grown per-show to fit the widest entry's text so
    // long rows (e.g. the Grand Exchange) don't spill outside the border (iOS: boxW = MAX(kMenuWidth, er+16)).
    private val minMenuW = dp(210f)
    private var boxW = minMenuW
    private val pad = dp(6f)
    private val xTol = dp(44f) // horizontal slack so a straight slide down still tracks the rows

    private val bgPaint = Paint().apply { color = Color.argb(238, 33, 28, 23) }
    private val borderPaint =
        Paint().apply {
            color = Color.argb(255, 140, 128, 102)
            style = Paint.Style.STROKE
            strokeWidth = dp(1f)
            isAntiAlias = true
        }
    private val hlPaint = Paint().apply { color = Color.argb(56, 255, 255, 255) }
    private val headerPaint =
        Paint().apply {
            color = Color.WHITE
            textSize = sp(14f)
            isFakeBoldText = true
            isAntiAlias = true
        }
    private val optPaint =
        Paint().apply {
            color = Color.WHITE
            textSize = sp(16f)
            isFakeBoldText = true
            isAntiAlias = true
        }
    private val tgtPaint =
        Paint().apply {
            color = Color.argb(255, 140, 217, 255)
            textSize = sp(16f)
            isFakeBoldText = true
            isAntiAlias = true
        }

    init {
        // Always laid out to full screen (so geometry/draw are valid the instant show() flips `active`); it is
        // non-interactive, so touches fall through to the SurfaceView below. Content is gated on `active`.
        isClickable = false
        isFocusable = false
    }

    private fun dp(v: Float) = v * resources.displayMetrics.density

    private fun sp(v: Float) = v * resources.displayMetrics.scaledDensity

    /** UX-XCUT-02: [left, top, right, bottom] safe-area insets (display cutout + system bars) so the "Choose
     *  Option" box clamps to the safe rect — never under a landscape cutout / rounded corner. Mirrors the helper
     *  ChromeOverlayView already uses. Defaults to 0 (the full-bleed emulator case). */
    private fun safeInsets(): IntArray {
        val wi = rootWindowInsets ?: return intArrayOf(0, 0, 0, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val i = wi.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            intArrayOf(i.left, i.top, i.right, i.bottom)
        } else {
            @Suppress("DEPRECATION")
            intArrayOf(wi.stableInsetLeft, wi.stableInsetTop, wi.stableInsetRight, wi.stableInsetBottom)
        }
    }

    /** Show the menu (display-order entries) anchored at the finger; body biased away from the holding hand.
     *  FIX-10b: [tap] = persistent tap-to-select (submenu drill-in / shift-customize); [header] overrides the
     *  title (e.g. "Submenu" when drilled). Drag-mode callers omit both and behave exactly as before. */
    fun show(
        items: List<Entry>,
        anchorX: Float,
        anchorY: Float,
        handRight: Boolean,
        tap: Boolean = false,
        header: String = "Choose Option",
    ) {
        entries = items
        tapMode = tap
        headerText = header
        highlight = -1
        val vw = if (width > 0) width.toFloat() else resources.displayMetrics.widthPixels.toFloat()
        val vh = if (height > 0) height.toFloat() else resources.displayMetrics.heightPixels.toFloat()
        // FIX-10: shrink the rows so even a tall menu fits fully on-screen (rowAt + onDraw use this same rowH,
        // and the host maps by row INDEX, so the shrink is self-consistent and doesn't shift the selection).
        val avail = vh - pad * 2 - headerH
        rowH =
            if (items.isNotEmpty() && items.size * baseRowH > avail) {
                (avail / items.size).coerceAtLeast(dp(22f))
            } else {
                baseRowH
            }
        // UI-5: grow the box to the widest row (opt + gap + cyan target) so long entries stay inside the border;
        // dp(20f) = the dp(10f) text left margin (onDraw) + dp(10f) right padding.
        var widest = 0f
        for (e in items) {
            var w = optPaint.measureText(e.opt)
            if (e.tgt.isNotEmpty()) w += sp(5f) + tgtPaint.measureText(e.tgt)
            if (w > widest) widest = w
        }
        boxW = maxOf(minMenuW, widest + dp(20f))
        val totalH = headerH + items.size * rowH
        // Finger sits near the near top corner; body opens away from the hand.
        var ox = if (handRight) anchorX - (boxW - dp(26f)) else anchorX - dp(26f)
        var oy = anchorY - headerH * 0.5f
        // UX-XCUT-02: clamp the box origin to the SAFE rect (system bars + display cutout), not the raw view size,
        // so neither the header nor row 0 (the default-action row) can draw under a landscape cutout / rounded
        // corner. Folds the insets into the same min/max coerce the desktop window-clamp used; 0 insets are a no-op.
        val ins = safeInsets()
        val minX = ins[0].toFloat() + pad
        val maxX = (vw - ins[2] - boxW - pad).coerceAtLeast(minX)
        val minY = ins[1].toFloat() + pad
        val maxY = (vh - ins[3] - totalH - pad).coerceAtLeast(minY)
        ox = ox.coerceIn(minX, maxX)
        oy = oy.coerceIn(minY, maxY)
        boxX = ox
        boxY = oy
        active = true
        invalidate()
    }

    fun hide() {
        active = false
        entries = emptyList()
        highlight = -1
        invalidate()
    }

    val isActive: Boolean get() = active

    /** Display-row index under a finger point (view px), or -1 for the header/cancel zone. Y-driven. */
    fun rowAt(
        x: Float,
        y: Float,
    ): Int {
        if (!active || entries.isEmpty()) return -1
        if (x < boxX - xTol || x > boxX + boxW + xTol) return -1
        val ry = y - (boxY + headerH)
        if (ry < 0) return -1
        val r = (ry / rowH).toInt()
        return r.coerceAtMost(entries.size - 1)
    }

    val isTapMode: Boolean get() = tapMode

    /** FIX-10b tap hit-test: row index (>=0), -1 for the header strip, or -2 for a tap OUTSIDE the box (dismiss).
     *  Unlike rowAt (slide-select, generous xTol), this respects the real box bounds so an outside tap cancels. */
    fun hitTest(
        x: Float,
        y: Float,
    ): Int {
        if (!active || entries.isEmpty()) return -2
        val totalH = headerH + entries.size * rowH
        if (x < boxX || x > boxX + boxW || y < boxY || y > boxY + totalH) return -2
        if (y < boxY + headerH) return -1
        val r = ((y - (boxY + headerH)) / rowH).toInt()
        return r.coerceIn(0, entries.size - 1)
    }

    /** The entry at a display-row index, or null if out of range. */
    fun entryAt(i: Int): Entry? = entries.getOrNull(i)

    /** Set the locked-on row; returns true if it changed (so the host can fire a haptic). */
    fun setHighlight(row: Int): Boolean {
        if (row == highlight) return false
        highlight = row
        invalidate()
        return true
    }

    override fun onDraw(canvas: Canvas) {
        if (!active || entries.isEmpty()) return
        val totalH = headerH + entries.size * rowH
        canvas.drawRect(boxX, boxY, boxX + boxW, boxY + totalH, bgPaint)
        canvas.drawRect(boxX, boxY, boxX + boxW, boxY + totalH, borderPaint)

        // Header ("Choose Option", or "Submenu" when drilled in — FIX-10b).
        val hdrBaseline = boxY + headerH / 2f - (headerPaint.ascent() + headerPaint.descent()) / 2f
        canvas.drawText(headerText, boxX + dp(10f), hdrBaseline, headerPaint)

        var ry = boxY + headerH
        for (i in entries.indices) {
            if (i == highlight) {
                canvas.drawRect(boxX, ry, boxX + boxW, ry + rowH, hlPaint)
            }
            val e = entries[i]
            val baseline = ry + rowH / 2f - (optPaint.ascent() + optPaint.descent()) / 2f
            var x = boxX + dp(10f)
            canvas.drawText(e.opt, x, baseline, optPaint)
            if (e.tgt.isNotEmpty()) {
                x += optPaint.measureText(e.opt) + sp(5f)
                canvas.drawText(e.tgt, x, baseline, tgtPaint)
            }
            // FIX-10b: a right-aligned ▸ marks a row that drills into a submenu.
            if (e.role == Role.PARENT) {
                canvas.drawText("▸", boxX + boxW - dp(16f), baseline, optPaint)
            }
            ry += rowH
        }
    }
}
