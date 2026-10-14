package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import com.pulseapp.android.R
import com.pulseapp.android.StressPoint

data class ActivityPeriod(val startMinute: Int, val endMinute: Int)

/**
 * Mini-gráfica de estrés: línea con gradiente azul->menta, relleno degradado bajo la curva,
 * líneas guía tenues en 0/1/2/3, franja de sueño y marcadores de actividad.
 */
class StressChartView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : View(context, attrs) {

    private var points: List<StressPoint> = emptyList()
    private var sleepStartMinute: Int? = null
    private var sleepEndMinute: Int? = null
    private var activities: List<ActivityPeriod> = emptyList()

    private val guidePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = ContextCompat.getColor(context, R.color.track_gray)
        strokeWidth = 1.5f
    }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 4.8f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val sleepFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val sleepLinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 5f
    }
    private val activityPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    fun setSeries(newPoints: List<StressPoint>) {
        points = newPoints
        invalidate()
    }

    /** Ventana de sueño detectada, en minutos del día (0-1439). Pasa null si no hay. */
    fun setSleepWindow(startMinute: Int?, endMinute: Int?) {
        sleepStartMinute = startMinute
        sleepEndMinute = endMinute
        invalidate()
    }

    /** Periodos de actividad guardados, en minutos del día. */
    fun setActivities(newActivities: List<ActivityPeriod>) {
        activities = newActivities
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        if (w <= 0 || h <= 0) return

        val minMinute = 0
        val maxMinute = 1439
        fun xFor(minute: Int) = w * (minute - minMinute) / (maxMinute - minMinute).toFloat()

        // Franja de sueño: rectángulo translúcido + línea sólida arriba
       val start = sleepStartMinute
        val end = sleepEndMinute
        if (start != null && end != null) {
            val sleepBlue = ContextCompat.getColor(context, R.color.sleep_blue)
            sleepFillPaint.color = Color.argb(26, Color.red(sleepBlue), Color.green(sleepBlue), Color.blue(sleepBlue))
            sleepLinePaint.color = sleepBlue

            if (start <= end) {
                val x1 = xFor(start)
                val x2 = xFor(end)
                canvas.drawRect(x1, 0f, x2, h, sleepFillPaint)
                canvas.drawLine(x1, 4f, x2, 4f, sleepLinePaint)
            } else {
                // La ventana cruza la medianoche: se dibuja en dos tramos
                val x1a = xFor(start)
                canvas.drawRect(x1a, 0f, w, h, sleepFillPaint)
                canvas.drawLine(x1a, 4f, w, 4f, sleepLinePaint)
                val x2b = xFor(end)
                canvas.drawRect(0f, 0f, x2b, h, sleepFillPaint)
                canvas.drawLine(0f, 4f, x2b, 4f, sleepLinePaint)
            }
        }

        // Marcadores de actividad: barra superior de color en la franja de cada sesión
        val strainBlue = ContextCompat.getColor(context, R.color.strain_blue)
        activityPaint.color = strainBlue
        activities.forEach { activity ->
            val x1 = xFor(activity.startMinute)
            val x2 = xFor(activity.endMinute).coerceAtLeast(x1 + 6f) // ancho mínimo visible
            canvas.drawRect(x1, 0f, x2, 10f, activityPaint)
        }

        // Líneas guía 0/1/2/3
        for (i in 0..3) {
            val y = h - (i / 3f) * h
            canvas.drawLine(0f, y, w, y, guidePaint)
        }

        if (points.size < 2) return

        val sleepBlueColor = ContextCompat.getColor(context, R.color.sleep_blue)
        val recoveryGreen = ContextCompat.getColor(context, R.color.recovery_green)

        linePaint.shader = LinearGradient(
            0f, 0f, w, 0f,
            intArrayOf(strainBlue, sleepBlueColor, recoveryGreen),
            null, Shader.TileMode.CLAMP
        )
        fillPaint.shader = LinearGradient(
            0f, 0f, 0f, h,
            Color.argb(56, 61, 255, 160),
            Color.argb(0, 61, 255, 160),
            Shader.TileMode.CLAMP
        )

        fun yFor(score: Float) = h - (score.coerceIn(0f, 3f) / 3f) * h

        val linePath = Path()
        val fillPath = Path()
        points.forEachIndexed { index, point ->
            val x = xFor(point.minuteOfDay)
            val y = yFor(point.score)
            if (index == 0) {
                linePath.moveTo(x, y)
                fillPath.moveTo(x, h)
                fillPath.lineTo(x, y)
            } else {
                linePath.lineTo(x, y)
                fillPath.lineTo(x, y)
            }
        }
        val lastX = xFor(points.last().minuteOfDay)
        fillPath.lineTo(lastX, h)
        fillPath.close()

        canvas.drawPath(fillPath, fillPaint)
        canvas.drawPath(linePath, linePaint)
    }
}
