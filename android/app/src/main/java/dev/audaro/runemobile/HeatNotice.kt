package dev.audaro.runemobile

import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import kotlin.math.abs

/** Game settings > Lower resolution when hot, and the hot-phone notice's Don't show again. Both default off. */
object HeatSettings {
    const val KEY_LOWER_RESOLUTION = "heat_lower_resolution"
    private const val KEY_NOTICE_OFF = "heat_notice_off"

    /** Lower 117 HD's resolution while the phone is hot. Off, the heat response leaves 117 HD alone. */
    fun lowerResolution(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_LOWER_RESOLUTION, false)

    fun setLowerResolution(
        ctx: Context,
        on: Boolean,
    ) = prefs(ctx).edit().putBoolean(KEY_LOWER_RESOLUTION, on).apply()

    /** The player tapped "Don't show again" on the hot-phone notice. */
    fun noticeOff(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_NOTICE_OFF, false)

    fun setNoticeOff(
        ctx: Context,
        off: Boolean,
    ) = prefs(ctx).edit().putBoolean(KEY_NOTICE_OFF, off).apply()
}

/** Game settings' 117 HD section. */
@Composable
internal fun GsHeatSection() {
    val ctx = LocalContext.current
    GsSectionHeader("117 HD")
    var on by remember { mutableStateOf(HeatSettings.lowerResolution(ctx)) }
    GsSwitchRow(
        "Lower resolution when hot",
        "While your phone is hot, 117 HD draws at no more than 65% (50% when it's very hot), then goes back to your " +
            "setting when it cools. Off, a hot phone leaves your resolution alone.",
        on,
    ) {
        on = it
        HeatSettings.setLowerResolution(ctx, it)
    }
}

/**
 * The hot-phone notice: a small card that offers Lower resolution when hot without getting in the way of play. Only
 * its two buttons are clickable. The card and its text aren't, so a touch anywhere else on it isn't consumed and the
 * frame it sits in hands it on to the game beneath: the card can't swallow a tap meant for the game. It never takes
 * focus and never pauses anything. MainActivity decides when it shows.
 */
internal object HeatNotice {
    private const val ACCENT = 0xFFF29E1C.toInt()
    private const val MUTED = 0x99FFFFFF.toInt()

    /**
     * Where the card goes: the lowest spot for a [w] x [h] box inside [area] that stays [gap] clear of every box in
     * [blockers], and as near the middle across as the room there allows. It starts at the bottom of [area]; where
     * something is in the way it moves up to just above it and looks again. Boxes are [left, top, right, bottom] in the
     * frame's px. Gives the card's [left, top], or null when nothing fits anywhere. iOS's RMHeatNoticeSpot is the same
     * walk.
     */
    fun spot(
        area: IntArray,
        w: Int,
        h: Int,
        blockers: List<IntArray>,
        gap: Int,
    ): IntArray? {
        var bottom = area[3]
        var found: IntArray? = null
        while (found == null && bottom - h >= area[1]) {
            val top = bottom - h
            val inBand = blockers.filter { it[1] - gap < bottom && it[3] + gap > top }
            found = across(area, w, inBand, gap)?.let { intArrayOf(it, top) }
            // Up to just clear of the lowest thing in the way. With nothing in the way and still no room, the area is
            // narrower than the card, so that's the end of it.
            bottom = if (inBand.isEmpty()) area[1] - 1 else inBand.maxOf { it[1] - gap }
        }
        return found
    }

    /** The left edge for a [w]-wide card in a gap between [inBand]'s boxes across [area], nearest the middle, or null. */
    private fun across(
        area: IntArray,
        w: Int,
        inBand: List<IntArray>,
        gap: Int,
    ): Int? {
        val mid = (area[0] + area[2]) / 2
        val ranges = inBand.map { (it[0] - gap) to (it[2] + gap) }.sortedBy { it.first } + (area[2] to area[2])
        var from = area[0]
        var best: Int? = null
        for ((start, end) in ranges) {
            val to = minOf(start, area[2])
            if (to - from >= w) {
                val x = (mid - w / 2).coerceIn(from, to - w)
                if (best == null || abs(x + w / 2 - mid) < abs(best + w / 2 - mid)) best = x
            }
            from = maxOf(from, end)
        }
        return best
    }

    /** The card. [compact] puts the buttons under the line, for a narrow screen. [takesTouch] is asked as a touch lands
     *  on it: false lets the touch through to whatever is under the card instead. Kept discreet: one short line and
     *  two text buttons on a see-through strip, no border, no filled button, so it reads as a passing hint over the
     *  game rather than something that wants attention. */
    fun card(
        ctx: Context,
        compact: Boolean,
        onTurnOn: () -> Unit,
        onNeverAgain: () -> Unit,
        takesTouch: () -> Boolean,
    ): View {
        val d = ctx.resources.displayMetrics.density
        val wrap = LinearLayout.LayoutParams.WRAP_CONTENT
        val buttons =
            LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(button(ctx, "Don't show again", MUTED, bold = false, onNeverAgain))
                addView(button(ctx, "Turn on", ACCENT, bold = true, onTurnOn))
            }
        return object : LinearLayout(ctx) {
            // A child that turns down the first touch of a gesture leaves the frame to offer it to the next view
            // under the finger, so false here hands the whole gesture on.
            override fun dispatchTouchEvent(ev: MotionEvent): Boolean =
                if (ev.actionMasked == MotionEvent.ACTION_DOWN && !takesTouch()) false else super.dispatchTouchEvent(ev)
        }.apply {
            orientation = if (compact) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            if (!compact) gravity = Gravity.CENTER_VERTICAL
            // The buttons' own height pads a single line; a line above them needs its own.
            setPadding((10 * d).toInt(), if (compact) (7 * d).toInt() else 0, (2 * d).toInt(), 0)
            background =
                GradientDrawable().apply {
                    cornerRadius = 10 * d
                    setColor(0x8C000000.toInt())
                }
            if (compact) {
                // Both wrap. A MATCH_PARENT header in this WRAP_CONTENT column would be narrowed to the buttons' width
                // after it was measured, keeping the height of its wider pass and cutting the text off.
                addView(header(ctx), LinearLayout.LayoutParams(wrap, wrap).apply { gravity = Gravity.START })
                addView(buttons, LinearLayout.LayoutParams(wrap, wrap).apply { gravity = Gravity.END })
            } else {
                addView(header(ctx), LinearLayout.LayoutParams(0, wrap, 1f))
                addView(buttons, LinearLayout.LayoutParams(wrap, wrap).apply { leftMargin = (2 * d).toInt() })
            }
        }
    }

    /** The thermometer and the line. The line gives way to the buttons, never the other way. */
    private fun header(ctx: Context): View {
        val d = ctx.resources.displayMetrics.density
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(
                TextView(ctx).apply {
                    text = "🌡" // thermometer
                    textSize = 13f
                    setPadding(0, 0, (6 * d).toInt(), 0)
                },
            )
            addView(
                TextView(ctx).apply {
                    text = "Phone's hot. Lower 117 HD's resolution?"
                    textSize = 12f
                    setTextColor(0xD9FFFFFF.toInt())
                },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
            )
        }
    }

    /** A text button, no fill: still a finger's height to tap, though the strip shows only its words. */
    private fun button(
        ctx: Context,
        label: String,
        color: Int,
        bold: Boolean,
        onTap: () -> Unit,
    ) = Button(ctx).apply {
        val d = ctx.resources.displayMetrics.density
        text = label
        textSize = 12f
        isAllCaps = false
        if (bold) setTypeface(typeface, Typeface.BOLD)
        minWidth = 0
        minimumWidth = 0
        minHeight = 0
        minimumHeight = (32 * d).toInt()
        setPadding((8 * d).toInt(), 0, (8 * d).toInt(), 0)
        setTextColor(color)
        background = null
        stateListAnimator = null
        setOnClickListener { onTap() }
    }
}
