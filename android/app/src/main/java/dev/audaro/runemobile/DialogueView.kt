package dev.audaro.runemobile

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.util.Log
import android.view.MotionEvent
import android.view.View
import org.json.JSONObject

/**
 * UI-4: the native NPC-dialogue parchment (Android analogue of the iOS dialogueView). The shared bridge forces the
 * engine chat/dialogue into transparent-colour mode while the chat is relocated, so the engine's dialogue box has
 * no opaque background and the chat lines behind it bleed through. This view draws an OPAQUE OSRS parchment over
 * the chat region from HudVeneerBridge.getDialogueJson + the chat snapshot's dialogueActive flag, and renders the
 * name / body / continue / options natively on top (the engine dialogue underneath is simply occluded). A tap
 * advances a "click here to continue" dialogue (precise click on the engine CONTINUE widget); an option row posts
 * its digit. No shared-bridge change, so the chat-at-top look + iOS parity are untouched.
 */
class DialogueView(
    context: Context,
) : View(context) {
    companion object {
        private const val CHAT_W = 519 // engine chatbox width (canvas px)
        private const val BOX_H_CANVAS = 40 + 142 // native tab row (ChatPillView.ROW_H_CANVAS) + content height
        private const val PARCH = 0xFFD6C79E.toInt() // OSRS parchment tan (opaque) — iOS RGB(0.84,0.78,0.62)
        private const val BORDER = 0xFF5C4521.toInt() // iOS RGB(0.36,0.27,0.13)
        private const val NAME_COLOR = 0xFF800000.toInt() // dark red NPC/player name
        private const val TEXT_COLOR = 0xFF1A1206.toInt() // near-black body on parchment
        private const val CONT_COLOR = 0xFF00008C.toInt() // blue "Click here to continue"
        private const val OPT_COLOR = 0xFF1A1206.toInt()
    }

    /** Tap-to-continue: precise-click the engine CONTINUE widget centre (canvas px); (-1,-1) → fall back to space. */
    var onContinue: ((engineCx: Int, engineCy: Int) -> Unit)? = null

    /** An option row tapped: post its 1-based digit to the engine. */
    var onOption: ((digit: Int) -> Unit)? = null

    private var active = false
    private var boxX = 0f
    private var boxY = 0f
    private var boxW = 0f
    private var boxH = 0f
    private var name: String? = null
    private var body: String = ""
    private var hasContinue = false
    private var options: List<Pair<String, Int>> = emptyList() // (text, digit)
    private val optionRects = ArrayList<RectF>()
    private var contCx = -1
    private var contCy = -1
    private var headRect: RectF? = null // engine 3D-chathead bounds (view px) — cut out of the parchment
    private var lastJson = ""
    private var bodyLayout: StaticLayout? = null

    private val fillPaint = Paint().apply { color = PARCH }
    private val borderPaint =
        Paint().apply {
            style = Paint.Style.STROKE
            color = BORDER
            isAntiAlias = true
        }
    private val namePaint =
        Paint().apply {
            color = NAME_COLOR
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
    private val contPaint =
        Paint().apply {
            color = CONT_COLOR
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
    private val bodyPaint =
        TextPaint().apply {
            color = TEXT_COLOR
            isAntiAlias = true
        }
    private val optPaint =
        Paint().apply {
            color = OPT_COLOR
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
    private val dp = resources.displayMetrics.density

    private fun hide() {
        if (active) {
            active = false
            lastJson = ""
            invalidate()
        }
    }

    /** True while a dialogue parchment is being shown (so the shell can route BACK to dismiss it). */
    val isShowing: Boolean get() = active

    /** Programmatic dismiss (e.g. hardware BACK): advance a "click to continue" dialogue. No-op for an options
     *  dialogue (there's no neutral choice) and when nothing is showing. Returns true if it acted. */
    fun dismiss(): Boolean {
        if (!active || options.isNotEmpty()) return false
        onContinue?.invoke(contCx, contCy)
        return true
    }

    /** Drive each frame: [chatSnap] (for the dialogueActive/topLevel gate) + [dlgJson] + canvas→view scale. */
    fun update(
        chatSnap: String,
        dlgJson: String,
        sx: Float,
        sy: Float,
        show: Boolean,
    ) {
        if (!show) {
            hide()
            return
        }
        val cd =
            try {
                JSONObject(chatSnap)
            } catch (e: Exception) {
                null
            }
        if (cd == null || !cd.optBoolean("loggedIn") || cd.optInt("topLevelId") != 164 || !cd.optBoolean("dialogueActive")) {
            hide()
            return
        }
        val d =
            try {
                JSONObject(dlgJson)
            } catch (e: Exception) {
                null
            }
        if (d == null || !d.has("type")) {
            hide()
            return
        }

        boxX = cd.optInt("chatX", 0) * sx
        boxY = cd.optInt("chatY", 0) * sy
        boxW = CHAT_W * sx
        boxH = BOX_H_CANVAS * sy
        active = true

        val cont = d.optJSONObject("cont")
        if (cont != null) {
            contCx = cont.optInt("x") + cont.optInt("w") / 2
            contCy = cont.optInt("y") + cont.optInt("h") / 2
        } else {
            contCx = -1
            contCy = -1
        }

        // The engine's 3D chathead bounds (canvas px → view px). Drawn as a transparent cutout in the parchment so
        // the real head (still rendered underneath on the game surface) shows through, like desktop OSRS.
        val head = d.optJSONObject("head")
        headRect =
            if (head != null && head.optInt("w") > 0 && head.optInt("h") > 0) {
                val hx = head.optInt("x") * sx
                val hy = head.optInt("y") * sy
                RectF(hx, hy, hx + head.optInt("w") * sx, hy + head.optInt("h") * sy)
            } else {
                null
            }
        // Ignore a head rect that doesn't fall inside the dialogue box (stale/bad engine coords) so the cutout
        // can't punch outside the parchment and the text-column math can't degenerate. intersect() clamps the
        // rect to the overlap (returns false + leaves it untouched when there is none).
        headRect?.let { if (!it.intersect(boxX, boxY, boxX + boxW, boxY + boxH)) headRect = null }

        if (dlgJson != lastJson) {
            lastJson = dlgJson
            rebuild(d)
            Log.i(
                "DialogueView",
                "ui4: dialogue type=${d.optString("type")} name=${name ?: "-"} opts=${options.size} cont=($contCx,$contCy)",
            )
        }
        invalidate()
    }

    private fun rebuild(d: JSONObject) {
        name = d.optString("name", "").takeIf { it.isNotBlank() }
        body = d.optString("text", "")
        hasContinue = d.optBoolean("continue", false)
        val optArr = d.optJSONArray("options")
        options =
            if (optArr != null) {
                (0 until optArr.length()).mapNotNull { i ->
                    val o = optArr.optJSONObject(i) ?: return@mapNotNull null
                    val t = o.optString("text", "")
                    if (t.isBlank()) null else t to o.optInt("digit", i + 1)
                }
            } else {
                emptyList()
            }
        bodyLayout = null // re-laid out in onDraw against the live box width
        requestLayout()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        if (!active || boxW <= 0f || boxH <= 0f) return
        val r = RectF(boxX, boxY, boxX + boxW, boxY + boxH)
        // Fill the parchment, cutting out the head rect so the engine's real 3D chathead (still rendered
        // underneath on the game surface) shows through — the "real head" mode the bridge's head bounds exist for.
        val hole = headRect
        canvas.save()
        if (hole != null) canvas.clipOutRect(hole)
        canvas.drawRoundRect(r, 5f * dp, 5f * dp, fillPaint)
        canvas.restore()
        borderPaint.strokeWidth = 2f * dp
        canvas.drawRoundRect(r, 5f * dp, 5f * dp, borderPaint)

        val padX = 12f * dp
        // Text column = the box minus the head's column (head on the left -> text to the right, and vice-versa);
        // fall back to the full inset width if the head math degenerates (mirrors iOS dialogueContentFrameForHead).
        var textLeft = r.left + padX
        var textRight = r.right - padX
        if (hole != null) {
            if (hole.centerX() < r.centerX()) textLeft = hole.right + padX else textRight = hole.left - padX
            if (textRight - textLeft < 60f * dp) {
                textLeft = r.left + padX
                textRight = r.right - padX
            }
        }
        val cx = (textLeft + textRight) / 2f
        val colW = (textRight - textLeft).coerceAtLeast(1f)
        var y = r.top + 10f * dp
        val baseSize = (boxH * 0.11f).coerceIn(11f * dp, 20f * dp)

        // Name (NPC/player), bold dark-red, centred over the text column.
        name?.let {
            namePaint.textSize = baseSize * 1.05f
            y += namePaint.textSize
            canvas.drawText(it, cx, y, namePaint)
            y += 6f * dp
        }

        if (options.isNotEmpty()) {
            // Option rows (centred, tappable). The body, if any, is the prompt above them.
            if (body.isNotBlank()) {
                bodyPaint.textSize = baseSize
                drawBody(canvas, textLeft, colW, y).also { y = it }
                y += 4f * dp
            }
            optionRects.clear()
            optPaint.textSize = baseSize * 1.02f
            val rowH = optPaint.textSize + 10f * dp
            for ((text, _) in options) {
                val rowTop = y
                val baseline = y + optPaint.textSize + 3f * dp
                canvas.drawText(text, cx, baseline, optPaint)
                optionRects.add(RectF(r.left, rowTop, r.right, rowTop + rowH))
                y += rowH
            }
        } else {
            // Statement dialogue: body text + "Click here to continue".
            bodyPaint.textSize = baseSize
            drawBody(canvas, textLeft, colW, y)
            if (hasContinue) {
                contPaint.textSize = baseSize * 0.95f
                canvas.drawText("Click here to continue", cx, r.bottom - 9f * dp, contPaint)
            }
        }
    }

    /** Draw the wrapped body text in the column [textLeft]..[textLeft]+[colW] starting at [top]; returns the y below it. */
    private fun drawBody(
        canvas: Canvas,
        textLeft: Float,
        colW: Float,
        top: Float,
    ): Float {
        if (body.isBlank()) return top
        val w = colW.toInt().coerceAtLeast(1)
        val layout =
            StaticLayout.Builder
                .obtain(body, 0, body.length, bodyPaint, w)
                .setAlignment(Layout.Alignment.ALIGN_CENTER)
                .build()
        canvas.save()
        canvas.translate(textLeft, top)
        layout.draw(canvas)
        canvas.restore()
        return top + layout.height
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!active) return false
        val r = RectF(boxX, boxY, boxX + boxW, boxY + boxH)
        if (!r.contains(event.x, event.y)) return false // outside the parchment -> fall through
        if (event.actionMasked == MotionEvent.ACTION_UP) {
            if (options.isNotEmpty()) {
                val idx = optionRects.indexOfFirst { it.contains(event.x, event.y) }
                if (idx >= 0) {
                    val digit = options[idx].second
                    onOption?.invoke(digit)
                    Log.i("DialogueView", "ui4: option $idx -> digit $digit")
                }
            } else {
                onContinue?.invoke(contCx, contCy)
                Log.i("DialogueView", "ui4: continue -> ($contCx,$contCy)")
            }
        }
        return true // consume taps over the parchment while a dialogue is open
    }
}
