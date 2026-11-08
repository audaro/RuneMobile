package dev.audaro.runemobile

import android.content.Context
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
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

    /** The card. [compact] stacks the buttons under the text, for a narrow screen. */
    fun card(
        ctx: Context,
        compact: Boolean,
        onTurnOn: () -> Unit,
        onNeverAgain: () -> Unit,
    ): View {
        val d = ctx.resources.displayMetrics.density
        val wrap = LinearLayout.LayoutParams.WRAP_CONTENT
        val buttons =
            LinearLayout(ctx).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(button(ctx, "Don't show again", filled = false, onNeverAgain))
                addView(
                    button(ctx, "Turn on", filled = true, onTurnOn),
                    LinearLayout.LayoutParams(wrap, wrap).apply { leftMargin = (8 * d).toInt() },
                )
            }
        return LinearLayout(ctx).apply {
            orientation = if (compact) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            if (!compact) gravity = Gravity.CENTER_VERTICAL
            setPadding((12 * d).toInt(), (8 * d).toInt(), (10 * d).toInt(), (8 * d).toInt())
            background =
                GradientDrawable().apply {
                    cornerRadius = 14 * d
                    setColor(0xE0141414.toInt())
                    setStroke((1 * d).toInt(), 0xB3F29E1C.toInt())
                }
            if (compact) {
                // Both wrap. A MATCH_PARENT header in this WRAP_CONTENT column would be narrowed to the buttons' width
                // after it was measured, keeping the height of its wider pass and cutting the text off.
                addView(header(ctx, wide = false), LinearLayout.LayoutParams(wrap, wrap).apply { gravity = Gravity.START })
                addView(
                    buttons,
                    LinearLayout.LayoutParams(wrap, wrap).apply {
                        gravity = Gravity.END
                        topMargin = (8 * d).toInt()
                    },
                )
            } else {
                addView(header(ctx, wide = true), LinearLayout.LayoutParams(0, wrap, 1f))
                addView(buttons, LinearLayout.LayoutParams(wrap, wrap).apply { leftMargin = (10 * d).toInt() })
            }
        }
    }

    /** The thermometer, the title and the line under it. The text gives way to the buttons, never the other way. */
    private fun header(
        ctx: Context,
        wide: Boolean,
    ): View {
        val d = ctx.resources.displayMetrics.density
        val texts =
            LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                addView(
                    TextView(ctx).apply {
                        text = "Your phone is getting hot"
                        textSize = 14f
                        setTypeface(typeface, Typeface.BOLD)
                        setTextColor(0xFFFFFFFF.toInt())
                    },
                )
                addView(
                    TextView(ctx).apply {
                        text = "Lowering 117 HD's resolution while it's hot helps it cool."
                        textSize = 12f
                        setTextColor(0xFFBFBFBF.toInt())
                        if (wide) maxWidth = (240 * d).toInt() // two short lines beside the buttons
                    },
                )
            }
        return LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(
                TextView(ctx).apply {
                    text = "🌡" // thermometer
                    textSize = 20f
                    setPadding(0, 0, (10 * d).toInt(), 0)
                },
            )
            addView(texts, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        }
    }

    private fun button(
        ctx: Context,
        label: String,
        filled: Boolean,
        onTap: () -> Unit,
    ) = Button(ctx).apply {
        val d = ctx.resources.displayMetrics.density
        text = label
        textSize = 13f
        isAllCaps = false
        minWidth = 0
        minimumWidth = 0
        minHeight = 0
        minimumHeight = (36 * d).toInt()
        setPadding((12 * d).toInt(), (6 * d).toInt(), (12 * d).toInt(), (6 * d).toInt())
        setTextColor(if (filled) 0xFF000000.toInt() else 0xFFFFFFFF.toInt())
        background =
            GradientDrawable().apply {
                cornerRadius = 8 * d
                setColor(if (filled) ACCENT else 0x1FFFFFFF)
            }
        stateListAnimator = null
        setOnClickListener { onTap() }
    }
}
