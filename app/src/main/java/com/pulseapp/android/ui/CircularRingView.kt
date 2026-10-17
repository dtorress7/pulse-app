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
import kotlin.math.min

/**
 * Anillo de progreso del rediseño: trazo grueso (≈10 % del tamaño) con extremos redondeados,
 * pista gris, número grande condensado en el centro y, opcionalmente, una etiqueta debajo del número.
 *
 * El número admite un sufijo pequeño: "72%" se dibuja como "72" grande + "%" pequeño.
 * Si labelText está vacío, no se dibuja etiqueta (en Inicio la etiqueta va fuera del anillo).
 */
class CircularRingView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : View(context, attrs) {

    private var progress: Float = 0f // 0..1
    private var valueText: String = "--"
    private var labelText: String = ""

    private val numberFont = ResourcesCompat.getFont(context, R.font.barlow_condensed_bold)
    private val labelFont = ResourcesCompat.getFont(context, R.font.barlow_condensed_semibold)

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        color = ContextCompat.getColor(context, R.color.track_gray)
    }
    private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        color = Color.GREEN
    }
    private val valuePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.text_primary)
        textAlign = Paint.Align.LEFT
        typeface = numberFont
        fontFeatureSettings = "tnum"
    }
    private val suffixPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.text_secondary)
        textAlign = Paint.Align.LEFT
        typeface = numberFont
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.text_secondary)
        textAlign = Paint.Align.CENTER
        typeface = labelFont
        letterSpacing = 0.14f
    }

    private val rect = RectF()

    /** Grosor del trazo respecto al tamaño (WHOOP usa un anillo más fino que el rediseño anterior). */
    var strokeRatio: Float = 0.105f
        set(v) { field = v; invalidate() }

    /** Si es true el sufijo (%) va del mismo color que el número, como en WHOOP. */
    var suffixSameColor: Boolean = false
        set(v) { field = v; suffixPaint.color = if (v) valuePaint.color else ContextCompat.getColor(context, R.color.text_secondary); invalidate() }

    /** Tamaño del número respecto al anillo (0 = el de siempre). */
    var numberRatio: Float = 0f
        set(v) { field = v; invalidate() }

    /** Tamaño de la etiqueta de debajo respecto al anillo (0 = el de siempre). */
    var labelRatio: Float = 0f
        set(v) { field = v; invalidate() }

    fun setLabelColor(color: Int) { labelPaint.color = color; invalidate() }

    /** Tamaño del sufijo (%) respecto al número. */
    var suffixRatio: Float = 0.46f
        set(v) { field = v; invalidate() }

    fun setTrackColor(color: Int) { trackPaint.color = color; invalidate() }

    /** Texto pequeño encima del número (la marca "PULSE" de las pantallas de Sueño y Esfuerzo). */
    var topText: String = ""
        set(v) { field = v; invalidate() }

    /** Marca blanca sobre el anillo (0..1), p. ej. el esfuerzo recomendado. null = sin marca. */
    var markerFraction: Float? = null
        set(v) { field = v; invalidate() }

    private val topPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.text_secondary)
        textAlign = Paint.Align.CENTER
        typeface = ResourcesCompat.getFont(context, R.font.barlow_condensed_medium)
        letterSpacing = 0.3f
    }
    private val markerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; strokeCap = Paint.Cap.BUTT }

    fun setValue(progress0to1: Float, valueText: String, labelText: String, ringColor: Int) {
        this.progress = progress0to1.coerceIn(0f, 1f)
        this.valueText = valueText
        this.labelText = labelText
        progressPaint.color = ringColor
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val size = min(width, height).toFloat()
        if (size <= 0f) return
        val stroke = size * strokeRatio
        trackPaint.strokeWidth = stroke
        progressPaint.strokeWidth = stroke

        val cx = width / 2f
        val cy = height / 2f
        val r = (size - stroke) / 2f
        rect.set(cx - r, cy - r, cx + r, cy + r)

        canvas.drawArc(rect, 0f, 360f, false, trackPaint)
        if (progress > 0f) canvas.drawArc(rect, -90f, 360f * progress, false, progressPaint)
        markerFraction?.let { f ->
            val a = Math.toRadians((-90.0 + 360.0 * f.coerceIn(0f, 1f)))
            val r1 = r - stroke * 0.55f; val r2 = r + stroke * 0.55f
            markerPaint.strokeWidth = stroke * 0.32f
            canvas.drawLine(cx + (r1 * Math.cos(a)).toFloat(), cy + (r1 * Math.sin(a)).toFloat(),
                cx + (r2 * Math.cos(a)).toFloat(), cy + (r2 * Math.sin(a)).toFloat(), markerPaint)
        }
        if (valueText.isEmpty()) return // anillo pequeño sin número (cabecera fija de Inicio)

        // Separa el número del sufijo (% o similar) para dibujarlo más pequeño
        val number = valueText.trimEnd('%')
        val suffix = if (valueText.endsWith("%")) "%" else ""
        val hasLabel = labelText.isNotBlank()

        valuePaint.textSize = size * (if (numberRatio > 0f) numberRatio else if (hasLabel) 0.27f else 0.31f)
        suffixPaint.textSize = valuePaint.textSize * suffixRatio
        labelPaint.textSize = size * (if (labelRatio > 0f) labelRatio else 0.095f)

        val numberWidth = valuePaint.measureText(number)
        val suffixWidth = if (suffix.isEmpty()) 0f else suffixPaint.measureText(suffix) + size * 0.01f
        val startX = cx - (numberWidth + suffixWidth) / 2f
        val fm = valuePaint.fontMetrics
        val baseline = if (hasLabel) cy + (-fm.ascent) * 0.30f else cy - (fm.ascent + fm.descent) / 2f

        canvas.drawText(number, startX, baseline, valuePaint)
        if (suffix.isNotEmpty()) {
            canvas.drawText(suffix, startX + numberWidth + size * 0.01f, baseline, suffixPaint)
        }
        if (hasLabel) {
            labelText.uppercase().split("\n").forEachIndexed { i, line ->
                canvas.drawText(line, cx, baseline + labelPaint.textSize * (1.7f + 1.35f * i), labelPaint)
            }
        }
        if (topText.isNotEmpty()) {
            topPaint.textSize = size * 0.075f
            canvas.drawText(topText, cx, baseline + fm.ascent * 0.95f - topPaint.textSize * 0.6f, topPaint)
        }
    }
}
