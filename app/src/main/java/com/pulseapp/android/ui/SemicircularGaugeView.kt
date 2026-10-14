package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import com.pulseapp.android.R
import kotlin.math.cos
import kotlin.math.sin

/**
 * Medidor semicircular (arco de 180°) con aguja, para el detalle del Monitor de Estrés.
 * Escala fija 0-3. angle = π·(1 - valor/3), igual que pide el spec.
 */
class SemicircularGaugeView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : View(context, attrs) {

    private var value: Float = 0f // 0..3

    private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 36f
        strokeCap = Paint.Cap.ROUND
    }
    private val needlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        strokeWidth = 15f
        strokeCap = Paint.Cap.ROUND
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.CENTER
        textSize = 26f
    }

    fun setValue(newValue: Float) {
        value = newValue.coerceIn(0f, 3f)
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val strainBlue = ContextCompat.getColor(context, R.color.strain_blue)
        val recoveryGreen = ContextCompat.getColor(context, R.color.recovery_green)
        val alertAmber = ContextCompat.getColor(context, R.color.alert_amber)
        val textSecondary = ContextCompat.getColor(context, R.color.text_secondary)
        labelPaint.color = textSecondary

        val w = width.toFloat()
        val radius = 100f * (w / 320f) // escala relativa al ancho disponible
        val strokeWidth = 36f * (w / 320f)
        arcPaint.strokeWidth = strokeWidth
        needlePaint.strokeWidth = 15f * (w / 320f)

        val centerX = w / 2f
        val centerY = height * 0.75f

        val rect = RectF(
            centerX - radius, centerY - radius,
            centerX + radius, centerY + radius
        )

        arcPaint.shader = LinearGradient(
            rect.left, 0f, rect.right, 0f,
            intArrayOf(strainBlue, recoveryGreen, alertAmber),
            null, Shader.TileMode.CLAMP
        )
        // Arco de 180°, de izquierda (180°) a derecha (0°)
        canvas.drawArc(rect, 180f, 180f, false, arcPaint)

        // Aguja: angle = π·(1 - valor/3), medido desde la derecha (0 rad) en sentido antihorario
        val angleRad = Math.PI * (1 - value / 3.0)
        val needleLength = radius - strokeWidth / 2
        val needleX = centerX + (needleLength * cos(angleRad)).toFloat()
        val needleY = centerY - (needleLength * sin(angleRad)).toFloat()
        canvas.drawLine(centerX, centerY, needleX, needleY, needlePaint)

        // Etiquetas en los extremos
        canvas.drawText("0,0", centerX - radius, centerY + 40f, labelPaint)
        canvas.drawText("3,0", centerX + radius, centerY + 40f, labelPaint)
    }
}
