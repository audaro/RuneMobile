package dev.audaro.runemobile

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets

/**
 * A6 native Jagex-Mobile chrome — the OSRS-mobile tab dock. A full-screen overlay over the live SurfaceView that
 * draws all 14 side-panel tabs as a 2-column × 7-row grid at the BOTTOM-RIGHT (the official mobile arrangement),
 * using the bundled OSRS stone sprites + tab glyphs. The engine's own 14 tab stones are HIDDEN
 * (HudVeneerBridge.setStonesHidden) so these native cells ARE the tabs; a tap opens the tab by replaying the
 * engine stone's op script (HudVeneerBridge.openTab) — no widget is moved or covered, the engine + every plugin
 * stay authoritative. This mirrors the proven iOS layout (ViewController.updateChrome / TAB_GRID_ORDER).
 *
 * The grid is laid out in this view's pixels (the live frame blits full-stretch under it). The host drives the
 * active-tab highlight + enable state from the MobileChromeBridge snapshot each frame ([setActiveTab] /
 * [setGridEnabled]); a tap reports the engine tab index via [onTabTap]. Cells auto-fit the bottom ~56% of the
 * safe height so the grid never collides with the minimap (top-right).
 */
class ChromeOverlayView(
    context: Context,
) : View(context) {
    /** Host callback: the user tapped the tab whose engine stone index is [engineIndex] — replay its op script. */
    var onTabTap: ((engineIndex: Int) -> Unit)? = null

    private var active = -1 // engine tab index of the open tab (red stone), -1 = none
    private var gridEnabled = false // true only in the supported Classic/PRE_EOC layout (toplevel 164), logged in
    private var shown = true // A/B debug toggle (▦ native grid vs ▤ raw engine stones)

    // Composited tab images: stone background + centred glyph, built once. [0] inactive (grey), [1] active (red).
    private val tabInactive = arrayOfNulls<Bitmap>(14)
    private val tabActive = arrayOfNulls<Bitmap>(14)
    private var assetsBuilt = false

    // Last computed layout (view px), so onTouchEvent + the host's side-panel relocation read the same geometry.
    private var lay = Layout(0f, 0f, 0f)

    private class Layout(
        val gx0: Float,
        val gy0: Float,
        val cell: Float,
    )

    // UI-1: when > 0, shrink the 7-row grid to this view-px height so it matches the open side panel's height (the
    // panel is a fixed engine raster we can't grow); cell is floored so tabs stay tappable and capped so it only
    // ever shrinks below today's size.
    private var targetGridHpx = 0f

    private val bmpPaint =
        Paint().apply {
            isAntiAlias = true
            isFilterBitmap = true
            isDither = true
        }
    private val fallbackPaint =
        Paint().apply {
            color = Color.argb(235, 60, 50, 38)
            isAntiAlias = true
        }
    private val fallbackActivePaint =
        Paint().apply {
            color = Color.argb(245, 150, 60, 50)
            isAntiAlias = true
        }
    private val srcRect = Rect()
    private val dstRect = RectF()

    private fun dp(v: Float) = v * resources.displayMetrics.density

    // Tab images are built from runtime cache sprites (setSprites), not bundled assets — so nothing Jagex ships in
    // the repo. Until the first set arrives (one-shot, after login) onDraw uses the stone-toned fallback cells.

    /** TAB_GRID_ORDER[slot] = engine tab (stone) index, row-major (slot 0 = top-left, 1 = top-right, …). The
     *  official OSRS-mobile arrangement; identical to the iOS shell so the bundled icon-N.png glyphs line up. */
    private val order = intArrayOf(3, 1, 4, 2, 5, 13, 6, 7, 0, 12, 8, 9, 10, 11)

    /** Build the 14 active + 14 inactive tab images from a runtime sprite set (the real OSRS cache sprites the
     *  engine loaded after login — stone-active/inactive + icon-0..13), composited stone-then-centred-glyph at the
     *  stone's native size. Idempotent; re-applies if a fresher set arrives. */
    fun setSprites(set: TabSprites.Set) {
        if (!set.usableForGrid()) return
        for (i in 0 until 14) {
            val icon = set.icons.getOrNull(i)
            tabInactive[i] = composite(set.stoneInactive, icon)
            tabActive[i] = composite(set.stoneActive, icon)
        }
        assetsBuilt = true
        Log.i("ChromeOverlay", "a6: tab assets built from runtime cache sprites")
        invalidate()
    }

    /** Composite a stone background with a centred glyph at the stone's native size (no scaling), like the iOS
     *  compositeStone:icon:. Returns the stone alone if there's no icon, or the icon alone if there's no stone. */
    private fun composite(
        stone: Bitmap?,
        icon: Bitmap?,
    ): Bitmap? {
        if (stone == null) return icon
        val out = Bitmap.createBitmap(stone.width, stone.height, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        c.drawBitmap(stone, 0f, 0f, null)
        if (icon != null) {
            val ix = ((stone.width - icon.width) / 2f)
            val iy = ((stone.height - icon.height) / 2f)
            c.drawBitmap(icon, ix, iy, null)
        }
        return out
    }

    /** Host: the engine's currently-open tab (stone index), for the red/grey highlight. -1 = none. */
    fun setActiveTab(activeTab: Int) {
        if (active != activeTab) {
            active = activeTab
            invalidate()
        }
    }

    /** Host: enable the native grid only in the supported layout (logged in + Classic/PRE_EOC toplevel 164).
     *  When disabled the grid draws nothing and consumes no touches (the engine stones are shown instead). */
    fun setGridEnabled(on: Boolean) {
        if (gridEnabled != on) {
            gridEnabled = on
            invalidate()
        }
    }

    fun setShown(on: Boolean) {
        if (shown != on) {
            shown = on
            invalidate()
        }
    }

    val railsShown: Boolean get() = shown
    val isGridActive: Boolean get() = shown && gridEnabled

    // The grid's left/top edge in view px (for the host's side-panel relocation). Valid after a draw/layout pass.
    val gridLeftPx: Float get() = lay.gx0
    val gridTopPx: Float get() = lay.gy0

    /** UI-1: ask the grid to match the open side-panel height (view px; 0 = natural size). Recomputes the layout
     *  immediately so the host can read the new gridLeftPx/gridTopPx in the same pass (no one-frame jitter). */
    fun setTargetGridHeight(viewPx: Float) {
        if (targetGridHpx != viewPx) {
            targetGridHpx = viewPx
            computeLayout()
            invalidate()
        }
    }

    /** [top, right, bottom] safe-area insets (display cutout + system bars), so the grid clears a landscape
     *  notch / nav bar. Defaults to 0 (the full-bleed emulator case). */
    private fun safeInsets(): IntArray {
        val wi = rootWindowInsets ?: return intArrayOf(0, 0, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val i = wi.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            intArrayOf(i.top, i.right, i.bottom)
        } else {
            @Suppress("DEPRECATION")
            intArrayOf(wi.stableInsetTop, wi.stableInsetRight, wi.stableInsetBottom)
        }
    }

    /** Recompute + cache the grid geometry from the current view size + insets (matches iOS updateChrome). */
    private fun computeLayout(): Layout {
        val ins = safeInsets()
        val cap = dp(48f)
        val margin = dp(6f)
        val availH = (height - ins[0] - ins[2]) * 0.56f
        // UI-1: when a target height is set, size the 7 rows to it (floored at dp(24) — TOUCH-1 raised the
        // tappability floor from dp(20) — so the cell can approach the panel height the grid is matching),
        // still capped so the grid only ever shrinks to meet the panel, never grows past today.
        val cell =
            if (targetGridHpx > 0f) {
                minOf(cap, maxOf(targetGridHpx / 7f, dp(24f)))
            } else {
                minOf(cap, if (availH > 0f) availH / 7f else cap)
            }
        val gridW = 2 * cell
        val gridH = 7 * cell
        val gx0 = width - ins[1] - margin - gridW
        val gy0 = height - ins[2] - margin - gridH
        lay = Layout(gx0, gy0, cell)
        return lay
    }

    override fun onDraw(canvas: Canvas) {
        if (!shown || !gridEnabled) return
        val l = computeLayout()
        if (l.cell <= 0f) return
        for (slot in 0 until 14) {
            val i = order[slot]
            val col = slot % 2
            val row = slot / 2
            val left = l.gx0 + col * l.cell
            val top = l.gy0 + row * l.cell
            dstRect.set(left, top, left + l.cell, top + l.cell)
            val bmp = if (i == active) tabActive[i] else tabInactive[i]
            if (bmp != null) {
                srcRect.set(0, 0, bmp.width, bmp.height)
                canvas.drawBitmap(bmp, srcRect, dstRect, bmpPaint)
            } else {
                // Asset missing — draw a stone-toned cell so the tab still reads + stays tappable.
                canvas.drawRoundRect(dstRect, dp(4f), dp(4f), if (i == active) fallbackActivePaint else fallbackPaint)
            }
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!shown || !gridEnabled) return false
        val l = lay
        if (l.cell <= 0f) return false
        when (event.actionMasked) {
            // Consume only if the gesture STARTS inside the grid, so non-grid taps fall through to the game below.
            MotionEvent.ACTION_DOWN -> {
                return slotAt(event.x, event.y) >= 0
            }

            MotionEvent.ACTION_UP -> {
                val i = slotAt(event.x, event.y)
                if (i < 0) return false
                onTabTap?.invoke(i)
                return true
            }
        }
        return false
    }

    /** Engine tab (stone) index under view-px (x,y), or -1 if outside the grid. */
    private fun slotAt(
        x: Float,
        y: Float,
    ): Int {
        val l = lay
        if (l.cell <= 0f) return -1
        // TOUCH-1: 48dp cells can't fit (7 rows must clear the top-right minimap — the 0.56 band IS that
        // clearance), so near-miss taps just OUTSIDE the grid snap to the nearest edge cell instead: clamp
        // the point into the grid when it lands within the outward slop (left into the scene, right/bottom
        // through the screen margin, top into the minimap gap). Interior precision is unchanged.
        val slopL = dp(10f)
        val slopT = dp(4f)
        val gridW = 2 * l.cell
        val gridH = 7 * l.cell
        if (x < l.gx0 - slopL || y < l.gy0 - slopT) return -1
        // No right/bottom bound check beyond the view itself — the grid runs to the screen margin there, so
        // anything past the last cell (still inside this view) snaps back to it.
        val col = (((x - l.gx0).coerceAtMost(gridW - 1f)) / l.cell).toInt()
        val row = (((y - l.gy0).coerceAtMost(gridH - 1f)) / l.cell).toInt()
        if (col < 0 || col > 1 || row < 0 || row > 6) return -1
        val slot = row * 2 + col
        if (slot < 0 || slot >= order.size) return -1
        return order[slot]
    }
}
