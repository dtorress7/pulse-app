package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SweepGradient
import android.graphics.Matrix
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import com.pulseapp.android.R
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * Medidor del Monitor de estrés como WHOOP (5/11): arco de 0,0 a 3,0 (azul → verde → ámbar), marca blanca en el valor,
 * número grande, nivel (BAJO / MEDIO / ALTO) en su color y la hora debajo.
 */
class StressGaugeView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private var value: Float? = null
    private var level = ""
    private var time = ""
    private val dp = resources.displayMetrics.density
    private fun col(id: Int) = ContextCompat.getColor(context, id)
    private val bold = ResourcesCompat.getFont(context, R.font.barlow_condensed_bold)
    private val semi = ResourcesCompat.getFont(context, R.font.barlow_condensed_semibold)
    private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; color = Color.argb(40, 255, 255, 255) }
    private val tick = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; strokeCap = Paint.Cap.ROUND }
    private val big = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_primary); typeface = bold; textAlign = Paint.Align.CENTER }
    private val lvl = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = bold; textAlign = Paint.Align.CENTER; letterSpacing = 0.12f }
    private val small = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_secondary); typeface = semi; textAlign = Paint.Align.CENTER }

    // Arco de 150° a 390° (240°), abierto por abajo
    private val startDeg = 150f
    private val sweepDeg = 240f

    fun setData(value: Float?, level: String, time: String) {
        this.value = value; this.level = level; this.time = time; invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        if (w <= 0 || h <= 0) return
        val stroke = 7f * dp
        val r = min(w * 0.36f, h * 0.48f)
        val cx = w / 2; val cy = r + 16f * dp
        val oval = RectF(cx - r, cy - r, cx + r, cy + r)
        track.strokeWidth = stroke
        canvas.drawArc(oval, startDeg, sweepDeg, false, track)
        // Degradado a lo largo del arco: 0 → azul, 1,5 → verde, 3 → ámbar
        val blue = col(R.color.w_low_blue); val mint = col(R.color.w_mint); val amber = col(R.color.alert_amber)
        // SweepGradient empieza en 0° (derecha); rotamos para que el color siga el arco desde 150°
        val m = Matrix(); m.setRotate(startDeg - 1f, cx, cy)
        val sg2 = SweepGradient(cx, cy, intArrayOf(blue, mint, amber, amber), floatArrayOf(0f, sweepDeg / 2 / 360f, sweepDeg / 360f, 1f))
        sg2.setLocalMatrix(m)
        arc.shader = sg2
        arc.strokeWidth = stroke
        canvas.drawArc(oval, startDeg, sweepDeg, false, arc)
        // Marca del valor
        val v = value
        if (v != null) {
            val a = Math.toRadians((startDeg + sweepDeg * (v.coerceIn(0f, 3f) / 3f)).toDouble())
            val r1 = r - stroke * 1.4f; val r2 = r + stroke * 1.4f
            tick.strokeWidth = 4f * dp
            tick.setShadowLayer(4f * dp, 0f, 0f, Color.argb(160, 0, 0, 0))
            canvas.drawLine(cx + (r1 * cos(a)).toFloat(), cy + (r1 * sin(a)).toFloat(), cx + (r2 * cos(a)).toFloat(), cy + (r2 * sin(a)).toFloat(), tick)
        }
        big.textSize = r * 0.62f
        canvas.drawText(if (v == null) "--" else String.format(java.util.Locale("es", "ES"), "%.1f", v), cx, cy + r * 0.12f, big)
        lvl.textSize = 17f * dp
        lvl.color = when (level) { "ALTO" -> amber; "MEDIO" -> mint; else -> blue }
        canvas.drawText(level, cx, cy + r * 0.42f, lvl)
        small.textSize = 13f * dp
        canvas.drawText(time, cx, cy + r * 0.62f, small)
        // 0,0 y 3,0 en los extremos
        val endY = cy + (r * sin(Math.toRadians(startDeg.toDouble()))).toFloat() + 24f * dp
        canvas.drawText("0,0", cx + (r * cos(Math.toRadians(startDeg.toDouble()))).toFloat(), endY, small)
        canvas.drawText("3,0", cx + (r * cos(Math.toRadians((startDeg + sweepDeg).toDouble()))).toFloat(), endY, small)
    }
}
