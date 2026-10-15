package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import com.pulseapp.android.R
import com.pulseapp.android.StressPoint
import java.util.Calendar

data class ActivityPeriod(val startMinute: Int, val endMinute: Int)

/**
 * Gráfica de estrés del rediseño: escala fija 0–3, eje X = últimas 24 h (ahora a la derecha).
 * Línea fina con degradado azul eléctrico → azul acero → verde, relleno verde que se desvanece,
 * guías tenues en 0/1/2/3, franja de sueño (10 % + línea superior), marcas de actividad
 * y marcador discontinuo de "ahora".
 */
class StressChartView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null
) : View(context, attrs) {

    private var points: List<StressPoint> = emptyList()
    private var sleepStartMinute: Int? = null
    private var sleepEndMinute: Int? = null
    private var activities: List<ActivityPeriod> = emptyList()

    /** Si es true (por defecto) dibuja la línea de "ahora" en la hora actual. */
    var showNowMarker: Boolean = true

    private val dp = resources.displayMetrics.density

    private val strainBlue = ContextCompat.getColor(context, R.color.strain_blue)
    private val sleepBlue = ContextCompat.getColor(context, R.color.sleep_blue)
    private val green = ContextCompat.getColor(context, R.color.recovery_green)
    private val track = ContextCompat.getColor(context, R.color.track_gray)
    private val textPrimary = ContextCompat.getColor(context, R.color.text_primary)

    private val guidePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = track
        alpha = 150
        strokeWidth = 1f * dp
    }
    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.6f * dp
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val sleepFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.argb(26, Color.red(sleepBlue), Color.green(sleepBlue), Color.blue(sleepBlue))
    }
    private val sleepLinePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 2f * dp
        color = sleepBlue
    }
    private val activityPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = strainBlue
    }
    private val nowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1f * dp
        color = textPrimary
        pathEffect = DashPathEffect(floatArrayOf(3f * dp, 3f * dp), 0f)
    }
    private val nowDotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = textPrimary }

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

        val top = 4f * dp
        val bottom = h - 4f * dp
        // Eje X = últimas 24 h hasta ahora (como WHOOP): "ahora" queda en el borde derecho
        val now = System.currentTimeMillis()
        val from = now - 24 * 3_600_000L
        fun xForTime(t: Long) = (w * (t - from) / (now - from).toFloat()).coerceIn(0f, w)
        /** Un minuto del día → su aparición más reciente que no sea futura. */
        fun timeOfMinute(minute: Int): Long {
            val c = Calendar.getInstance().apply {
                set(Calendar.HOUR_OF_DAY, minute / 60); set(Calendar.MINUTE, minute % 60)
                set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
            }
            if (c.timeInMillis > now) c.add(Calendar.DAY_OF_YEAR, -1)
            return c.timeInMillis
        }
        fun yFor(score: Float) = bottom - (score.coerceIn(0f, 3f) / 3f) * (bottom - top)

        // Franja de sueño
        val start = sleepStartMinute
        val end = sleepEndMinute
        if (start != null && end != null) {
            val te = timeOfMinute(end)
            var ts = timeOfMinute(start)
            if (ts > te) ts -= 24 * 3_600_000L
            drawSleep(canvas, xForTime(ts), xForTime(te), top, bottom)
        }

        // Guías 0/1/2/3
        for (i in 0..3) {
            val y = yFor(i.toFloat())
            canvas.drawLine(0f, y, w, y, guidePaint)
        }

        // Actividades: barra fina en la parte inferior
        activities.forEach { a ->
            val te = timeOfMinute(a.endMinute)
            var ts = timeOfMinute(a.startMinute)
            if (ts > te) ts -= 24 * 3_600_000L
            val x1 = xForTime(ts)
            val x2 = xForTime(te).coerceAtLeast(x1 + 4f * dp)
            canvas.drawRoundRect(x1, bottom - 3f * dp, x2, bottom + 1f * dp, 2f * dp, 2f * dp, activityPaint)
        }

        val pts = points.map { p -> (if (p.timeMillis > 0) p.timeMillis else timeOfMinute(p.minuteOfDay)) to p.score }
            .filter { it.first >= from }.sortedBy { it.first }
        if (pts.isNotEmpty()) {
            linePaint.shader = LinearGradient(
                0f, 0f, w, 0f, intArrayOf(strainBlue, sleepBlue, green), null, Shader.TileMode.CLAMP
            )
            fillPaint.shader = LinearGradient(
                0f, top, 0f, bottom,
                Color.argb(56, Color.red(green), Color.green(green), Color.blue(green)),
                Color.argb(0, Color.red(green), Color.green(green), Color.blue(green)),
                Shader.TileMode.CLAMP
            )
            // Tramos separados: si faltan datos más de 15 min, la línea se corta (antes unía los huecos en recta)
            val segments = mutableListOf<MutableList<Pair<Long, Float>>>()
            pts.forEach { p ->
                val last = segments.lastOrNull()?.lastOrNull()
                if (last == null || p.first - last.first > 15 * 60_000L) segments.add(mutableListOf(p)) else segments.last().add(p)
            }
            segments.forEach { seg ->
                val linePath = Path()
                val fillPath = Path()
                seg.forEachIndexed { i, (t, sc) ->
                    val x = xForTime(t); val y = yFor(sc)
                    if (i == 0) { linePath.moveTo(x, y); fillPath.moveTo(x, bottom); fillPath.lineTo(x, y) }
                    else { linePath.lineTo(x, y); fillPath.lineTo(x, y) }
                }
                if (seg.size == 1) linePath.lineTo(xForTime(seg[0].first) + 2f * dp, yFor(seg[0].second))
                fillPath.lineTo(xForTime(seg.last().first), bottom)
                fillPath.close()
                canvas.drawPath(fillPath, fillPaint)
                canvas.drawPath(linePath, linePaint)
            }
        }

        if (showNowMarker) {
            val x = w - 1.5f * dp
            canvas.drawLine(x, top, x, bottom, nowPaint)
            canvas.drawCircle(x - 1.5f * dp, bottom, 3f * dp, nowDotPaint)
        }
    }

    private fun drawSleep(canvas: Canvas, x1: Float, x2: Float, top: Float, bottom: Float) {
        canvas.drawRect(x1, top, x2, bottom, sleepFillPaint)
        canvas.drawLine(x1, top + sleepLinePaint.strokeWidth / 2, x2, top + sleepLinePaint.strokeWidth / 2, sleepLinePaint)
    }
}
