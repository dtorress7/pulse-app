package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import com.pulseapp.android.R
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * Medidor semicircular (180°) del Monitor de Estrés, escala fija 0–3.
 * Arco con degradado azul → verde → ámbar y extremos redondeados; aguja blanca corta
 * que va del interior del arco hasta su borde exterior, en angle = π·(1 − valor/3).
 */
class SemicircularGaugeView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : View(context, attrs) {

    private var value: Float = 0f // 0..3

    private val dp = resources.displayMetrics.density
    private val strainBlue = ContextCompat.getColor(context, R.color.strain_blue)
    private val green = ContextCompat.getColor(context, R.color.recovery_green)
    private val amber = ContextCompat.getColor(context, R.color.alert_amber)

    private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val needlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.text_primary)
        strokeCap = Paint.Cap.ROUND
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        color = ContextCompat.getColor(context, R.color.text_secondary)
        typeface = ResourcesCompat.getFont(context, R.font.barlow_condensed_semibold)
        textSize = 13f * resources.displayMetrics.scaledDensity
    }
    private val rect = RectF()

    fun setValue(newValue: Float) {
        value = newValue.coerceIn(0f, 3f)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0f || h <= 0f) return

        val stroke = 12f * dp
        val labelSpace = labelPaint.textSize * 1.6f
        // El arco cabe a lo ancho y en alto (radio + medio trazo + etiquetas)
        val radius = min(w / 2f - stroke, h - stroke / 2f - labelSpace)
        val cx = w / 2f
        val cy = h - labelSpace

        rect.set(cx - radius, cy - radius, cx + radius, cy + radius)
        arcPaint.strokeWidth = stroke
        arcPaint.shader = LinearGradient(
            rect.left, 0f, rect.right, 0f,
            intArrayOf(strainBlue, green, amber), null, Shader.TileMode.CLAMP
        )
        canvas.drawArc(rect, 180f, 180f, false, arcPaint)

        val angle = Math.PI * (1 - value / 3.0)
        val inner = radius - stroke * 1.6f
        val outer = radius + stroke / 2f
        needlePaint.strokeWidth = 5f * dp
        canvas.drawLine(
            cx + (inner * cos(angle)).toFloat(), cy - (inner * sin(angle)).toFloat(),
            cx + (outer * cos(angle)).toFloat(), cy - (outer * sin(angle)).toFloat(),
            needlePaint
        )

        canvas.drawText("0,0", cx - radius, cy + labelSpace * 0.85f, labelPaint)
        canvas.drawText("3,0", cx + radius, cy + labelSpace * 0.85f, labelPaint)
    }
}
