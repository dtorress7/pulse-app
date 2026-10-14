package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import com.pulseapp.android.R

/**
 * Anillo de progreso: trazo grueso, pista gris, arco de color, valor grande centrado.
 * Uso en XML:
 * <com.pulseapp.android.ui.CircularRingView
 *     app:ringColor="@color/recovery_green" ... /> (color se fija por código, ver setRingColor)
 */
class CircularRingView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : View(context, attrs) {

    private var progress: Float = 0f // 0..1
    private var ringColorInt: Int = Color.GREEN
    private var valueText: String = "--"
    private var labelText: String = ""

    private val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 18f
        strokeCap = Paint.Cap.ROUND
        color = ContextCompatColor(context, R.color.track_gray)
    }
    private val progressPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 18f
        strokeCap = Paint.Cap.ROUND
    }
    private val valuePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompatColor(context, R.color.text_primary)
        textAlign = Paint.Align.CENTER
        textSize = 44f
        isFakeBoldText = true
    }
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompatColor(context, R.color.text_secondary)
        textAlign = Paint.Align.CENTER
        textSize = 22f
    }

    private val rect = RectF()

    fun setValue(progress0to1: Float, valueText: String, labelText: String, ringColor: Int) {
        this.progress = progress0to1.coerceIn(0f, 1f)
        this.valueText = valueText
        this.labelText = labelText
        this.ringColorInt = ringColor
        progressPaint.color = ringColor
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val strokeHalf = trackPaint.strokeWidth / 2
        rect.set(strokeHalf, strokeHalf, width - strokeHalf, height - strokeHalf)

        canvas.drawArc(rect, 0f, 360f, false, trackPaint)
        canvas.drawArc(rect, -90f, 360f * progress, false, progressPaint)

        val centerX = width / 2f
        val centerY = height / 2f
        canvas.drawText(valueText, centerX, centerY - 4f, valuePaint)
        canvas.drawText(labelText, centerX, centerY + 26f, labelPaint)
    }

    private fun ContextCompatColor(context: Context, resId: Int): Int =
        androidx.core.content.ContextCompat.getColor(context, resId)
}
