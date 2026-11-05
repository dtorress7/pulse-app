package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import com.pulseapp.android.R

/**
 * Barras apiladas al 100 % de la "Vista de tendencias" del Monitor de estrés (5/11, como WHOOP): bajo (azul) abajo, medio (verde)
 * y alto (ámbar) arriba, escala 0–100 % a la izquierda y etiquetas de fecha (dos líneas) debajo. Barra null = sin datos.
 */
class StressTrendChartView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    class Bar(val low: Int, val mid: Int, val high: Int)

    private var bars: List<Bar?> = emptyList()
    private var labels: List<Pair<String, String>?> = emptyList()
    private val dp = resources.displayMetrics.density
    private fun col(id: Int) = ContextCompat.getColor(context, id)
    private val semi = ResourcesCompat.getFont(context, R.font.barlow_condensed_semibold)
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(30, 255, 255, 255); strokeWidth = dp }
    private val axis = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_secondary); textSize = 12 * dp; typeface = semi }
    private val center = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_secondary); textSize = 12 * dp; typeface = semi; textAlign = Paint.Align.CENTER }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)

    fun setData(bars: List<Bar?>, labels: List<Pair<String, String>?>) { this.bars = bars; this.labels = labels; invalidate() }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        if (w <= 0 || bars.isEmpty()) return
        val left = 44 * dp; val right = w - 4 * dp; val top = 8 * dp; val bottom = h - 36 * dp
        for (i in 0..4) {
            val y = bottom - (bottom - top) * i / 4f
            canvas.drawLine(left, y, right, y, grid)
            canvas.drawText("${i * 25} %", 0f, y + 4 * dp, axis)
        }
        val n = bars.size
        val slot = (right - left) / n
        val bw = (slot * 0.72f).coerceAtMost(26 * dp)
        val blue = col(R.color.w_low_blue); val mint = col(R.color.w_mint); val amber = col(R.color.alert_amber)
        for ((i, b) in bars.withIndex()) {
            val cx = left + slot * (i + 0.5f)
            labels.getOrNull(i)?.let { (a, c) ->
                canvas.drawText(a, cx, bottom + 16 * dp, center)
                canvas.drawText(c, cx, bottom + 31 * dp, center)
            }
            if (b == null) continue
            val tot = (b.low + b.mid + b.high).toFloat()
            if (tot <= 0) continue
            var y = bottom
            for ((v, c) in listOf(b.low to blue, b.mid to mint, b.high to amber)) {
                if (v <= 0) continue
                val hh = (bottom - top) * v / tot
                fill.color = c
                canvas.drawRect(RectF(cx - bw / 2, y - hh, cx + bw / 2, y), fill)
                y -= hh
            }
        }
    }
}
