package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import com.pulseapp.android.R
import com.pulseapp.android.SleepStager
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Hipnograma de la noche: 4 carriles (arriba Despierto, luego REM, Ligero y abajo Profundo),
 * un bloque por tramo de fase y una fina línea que une un tramo con el siguiente.
 * Abajo, la hora de inicio, la del medio y la del final.
 */
class HypnogramView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : View(context, attrs) {

    private var stages: IntArray? = null
    private var startMillis: Long = 0L

    private val dp = resources.displayMetrics.density
    private val timeFormat = SimpleDateFormat("HH:mm", Locale.getDefault())

    private val colors = intArrayOf(
        ContextCompat.getColor(context, R.color.stage_awake),   // 0 Despierto
        ContextCompat.getColor(context, R.color.stage_light),   // 1 Ligero
        ContextCompat.getColor(context, R.color.stage_deep),    // 2 Profundo
        ContextCompat.getColor(context, R.color.stage_rem),     // 3 REM
    )
    /** Carril (0 = arriba) de cada fase: Despierto, REM, Ligero, Profundo. */
    private val laneOf = intArrayOf(0, 2, 3, 1)

    private val guide = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.track_gray)
        alpha = 120
        strokeWidth = 1f * dp
    }
    private val block = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val link = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.2f * dp
        alpha = 130
    }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.text_secondary)
        textSize = 11f * dp
    }

    fun setStages(startMillis: Long, stages: IntArray?) {
        this.startMillis = startMillis
        this.stages = stages
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val h = (150f * dp).toInt()
        setMeasuredDimension(
            resolveSize(suggestedMinimumWidth, widthMeasureSpec),
            resolveSize(h, heightMeasureSpec)
        )
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val st = stages ?: return
        if (st.isEmpty()) return
        val w = width.toFloat()
        val axisH = 20f * dp
        val chartH = height - axisH
        val lanes = 4
        val laneH = chartH / lanes
        val blockH = laneH * 0.62f
        val n = st.size
        fun x(i: Int) = i.toFloat() / n * w
        fun laneTop(stage: Int) = laneOf[stage] * laneH + (laneH - blockH) / 2f

        // Guías de cada carril
        for (l in 0 until lanes) {
            val y = l * laneH + laneH / 2f
            canvas.drawLine(0f, y, w, y, guide)
        }

        var i = 0
        var prevStage = -1
        while (i < n) {
            var j = i
            while (j < n && st[j] == st[i]) j++
            val s = st[i]
            val left = x(i)
            val right = maxOf(x(j), left + 2f * dp)
            val top = laneTop(s)
            // Línea que une con el tramo anterior
            if (prevStage >= 0 && prevStage != s) {
                link.color = colors[s]
                link.alpha = 130
                val y1 = laneTop(prevStage) + blockH / 2f
                val y2 = top + blockH / 2f
                canvas.drawLine(left, y1, left, y2, link)
            }
            block.color = colors[s]
            canvas.drawRoundRect(RectF(left, top, right, top + blockH), 3f * dp, 3f * dp, block)
            prevStage = s
            i = j
        }

        // Eje de horas
        val baseY = height - 5f * dp
        val mid = startMillis + (n / 2) * 60_000L
        val end = startMillis + n * 60_000L
        label.textAlign = Paint.Align.LEFT
        canvas.drawText(timeFormat.format(Date(startMillis)), 0f, baseY, label)
        label.textAlign = Paint.Align.CENTER
        canvas.drawText(timeFormat.format(Date(mid)), w / 2f, baseY, label)
        label.textAlign = Paint.Align.RIGHT
        canvas.drawText(timeFormat.format(Date(end)), w, baseY, label)
    }
}
