package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import com.pulseapp.android.R
import kotlin.math.max
import kotlin.math.min

/**
 * Gráfica de "Tendencias semanales" de WHOOP (7 días, el último resaltado): barras (apiladas o no), barras flotantes
 * (tiempo en cama / regularidad, con horas a la izquierda y líneas discontinuas de la hora óptima) o líneas con puntos.
 */
class WeekChartView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {

    data class Day(val weekday: String, val dayOfMonth: String)
    data class Label(val text: String, val color: Int)
    /** Barra flotante en minutos (para la noche: minutos desde las 12:00 del día anterior, así la noche es continua). */
    data class Range(val start: Float, val end: Float, val startLabel: String?, val endLabel: String?)
    data class Series(val values: List<Float?>, val color: Int, val labels: List<String?>, val labelsBelow: Boolean)

    private enum class Mode { BARS, RANGES, LINES }

    private var mode = Mode.BARS
    private var days: List<Day> = emptyList()
    private var bars: List<List<Pair<Float, Int>>?> = emptyList()
    private var barLabels: List<Label?> = emptyList()
    private var maxValue: Float? = null
    private var ranges: List<Range?> = emptyList()
    private var rangeColor = 0
    private var dimPrevious = false
    private var yLabels: List<Pair<Float, String>> = emptyList()
    private var optimal: List<Pair<Float, Float>?> = emptyList()
    private var series: List<Series> = emptyList()

    private val d = resources.displayMetrics.density
    private val fb = ResourcesCompat.getFont(context, R.font.barlow_condensed_bold)
    private val fs = ResourcesCompat.getFont(context, R.font.barlow_condensed_semibold)
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(24, 255, 255, 255); strokeWidth = d }
    private val highlight = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(22, 255, 255, 255) }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val value = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = fb; textSize = 14.5f * d; textAlign = Paint.Align.CENTER }
    private val dayP = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = fs; textSize = 12.5f * d; textAlign = Paint.Align.CENTER }
    private val axis = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = fs; textSize = 12f * d; color = ContextCompat.getColor(context, R.color.text_secondary) }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2.2f * d; strokeJoin = Paint.Join.ROUND }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2.2f * d }
    private val ringFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ContextCompat.getColor(context, R.color.w_card) }
    private val dash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 1.3f * d; color = Color.argb(200, 255, 255, 255)
        pathEffect = DashPathEffect(floatArrayOf(4f * d, 4f * d), 0f)
    }
    private val textPrimary = ContextCompat.getColor(context, R.color.text_primary)
    private val textSecondary = ContextCompat.getColor(context, R.color.text_secondary)
    private val dimBar = Color.parseColor("#6E757A")

    fun setBars(days: List<Day>, values: List<List<Pair<Float, Int>>?>, labels: List<Label?>, max: Float? = null) {
        mode = Mode.BARS; this.days = days; bars = values; barLabels = labels; maxValue = max; invalidate()
    }

    fun setRanges(days: List<Day>, ranges: List<Range?>, color: Int, dimPrevious: Boolean = false,
                  yLabels: List<Pair<Float, String>> = emptyList(), optimal: List<Pair<Float, Float>?> = emptyList()) {
        mode = Mode.RANGES; this.days = days; this.ranges = ranges; rangeColor = color
        this.dimPrevious = dimPrevious; this.yLabels = yLabels; this.optimal = optimal; invalidate()
    }

    fun setLines(days: List<Day>, series: List<Series>) {
        mode = Mode.LINES; this.days = days; this.series = series; invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val n = days.size
        if (n == 0) return
        val w = width.toFloat(); val h = height.toFloat()
        val left = if (yLabels.isNotEmpty() && mode == Mode.RANGES) 40f * d else 0f
        val right = w
        val top = 26f * d
        val bottom = h - 46f * d
        val step = (right - left) / n
        fun cx(i: Int) = left + step * (i + 0.5f)

        canvas.drawRoundRect(RectF(cx(n - 1) - step * 0.42f, 4f * d, cx(n - 1) + step * 0.42f, h - 2f * d), 5f * d, 5f * d, highlight)
        if (mode != Mode.RANGES || yLabels.isEmpty()) {
            for (k in 0..4) { val y = bottom - (bottom - top) * k / 4f; canvas.drawLine(left, y, right, y, grid) }
        }
        days.forEachIndexed { i, day ->
            dayP.color = if (i == n - 1) textPrimary else textSecondary
            canvas.drawText(day.weekday, cx(i), h - 25f * d, dayP)
            canvas.drawText(day.dayOfMonth, cx(i), h - 8f * d, dayP)
        }
        when (mode) {
            Mode.BARS -> drawBars(canvas, n, top, bottom, step, ::cx)
            Mode.RANGES -> drawRanges(canvas, n, left, right, top, bottom, step, ::cx)
            Mode.LINES -> drawLines(canvas, top, bottom, ::cx)
        }
    }

    private fun drawBars(canvas: Canvas, n: Int, top: Float, bottom: Float, step: Float, cx: (Int) -> Float) {
        val totals = bars.map { b -> b?.sumOf { it.first.toDouble() }?.toFloat() ?: 0f }
        val mx = max(maxValue ?: 0f, totals.maxOrNull() ?: 0f).takeIf { it > 0f } ?: 1f
        val bw = step * 0.38f
        for (i in 0 until n) {
            val b = bars.getOrNull(i)
            var y = bottom
            b?.forEach { (v, c) ->
                if (v <= 0f) return@forEach
                val hgt = (bottom - top - 18f * d) * (v / mx)
                fill.color = c
                canvas.drawRect(cx(i) - bw / 2, y - hgt, cx(i) + bw / 2, y, fill)
                y -= hgt
            }
            if (b != null && totals[i] <= 0f) { fill.color = Color.argb(60, 255, 255, 255); canvas.drawRect(cx(i) - bw / 2, bottom - 2f * d, cx(i) + bw / 2, bottom, fill) }
            barLabels.getOrNull(i)?.let { l ->
                value.color = l.color
                canvas.drawText(l.text, cx(i), y - 6f * d, value)
            }
        }
    }

    private fun drawRanges(canvas: Canvas, n: Int, left: Float, right: Float, top: Float, bottom: Float, step: Float, cx: (Int) -> Float) {
        val all = ranges.filterNotNull().flatMap { listOf(it.start, it.end) } + optimal.filterNotNull().flatMap { listOf(it.first, it.second) } +
            yLabels.map { it.first }
        if (all.isEmpty()) return
        val lo = (all.minOrNull() ?: 0f) - 25f
        val hi = (all.maxOrNull() ?: 1f) + 25f
        fun y(m: Float) = top + 14f * d + (bottom - top - 28f * d) * ((m - lo) / max(1f, hi - lo))
        yLabels.forEach { (m, s) ->
            val yy = y(m)
            canvas.drawLine(left, yy, right, yy, grid)
            canvas.drawText(s, 0f, yy + 4f * d, axis)
        }
        // Hora óptima de acostarse / despertar (líneas discontinuas)
        for (which in 0..1) {
            val p = Path(); var started = false
            optimal.forEachIndexed { i, o ->
                if (o == null) return@forEachIndexed
                val yy = y(if (which == 0) o.first else o.second)
                val x1 = cx(i) - step * 0.42f; val x2 = cx(i) + step * 0.42f
                if (!started) { p.moveTo(x1, yy); started = true } else p.lineTo(x1, yy)
                p.lineTo(x2, yy)
            }
            if (started) canvas.drawPath(p, dash)
        }
        val bw = step * 0.3f
        ranges.forEachIndexed { i, r ->
            if (r == null) return@forEachIndexed
            val last = i == n - 1
            fill.color = if (dimPrevious && !last) dimBar else rangeColor
            canvas.drawRoundRect(RectF(cx(i) - bw / 2, y(r.start), cx(i) + bw / 2, y(r.end)), 3f * d, 3f * d, fill)
            value.color = if (dimPrevious && !last) textSecondary else rangeColor
            value.textSize = 13.5f * d
            r.startLabel?.let { canvas.drawText(it, cx(i), y(r.start) - 6f * d, value) }
            r.endLabel?.let { canvas.drawText(it, cx(i), y(r.end) + 17f * d, value) }
            value.textSize = 14.5f * d
        }
    }

    private fun drawLines(canvas: Canvas, top: Float, bottom: Float, cx: (Int) -> Float) {
        val vals = series.flatMap { s -> s.values.filterNotNull() }
        if (vals.isEmpty()) return
        val lo = vals.minOrNull()!!; val hi = vals.maxOrNull()!!
        val pad = max(1f, (hi - lo) * 0.25f)
        fun y(v: Float) = bottom - 20f * d - (bottom - top - 50f * d) * ((v - (lo - pad)) / max(1f, (hi + pad) - (lo - pad)))
        series.forEach { s ->
            line.color = s.color
            val p = Path(); var started = false
            s.values.forEachIndexed { i, v -> if (v != null) { if (!started) { p.moveTo(cx(i), y(v)); started = true } else p.lineTo(cx(i), y(v)) } }
            canvas.drawPath(p, line)
        }
        series.forEach { s ->
            ring.color = s.color
            s.values.forEachIndexed { i, v ->
                if (v == null) return@forEachIndexed
                canvas.drawCircle(cx(i), y(v), 5f * d, ringFill); canvas.drawCircle(cx(i), y(v), 5f * d, ring)
                s.labels.getOrNull(i)?.let { t ->
                    value.color = s.color
                    canvas.drawText(t, cx(i), if (s.labelsBelow) y(v) + 20f * d else y(v) - 10f * d, value)
                }
            }
        }
    }
}

/**
 * Barra de la noche minuto a minuto (tarjeta "Eficiencia del sueño"): [awakeRow] = false dibuja lo dormido (barra azul
 * con huecos donde estuviste despierto); true dibuja la pista rayada con una marca blanca en cada despertar.
 */
class SleepTimelineBar @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private var stages: IntArray = IntArray(0)
    var awakeRow = false
    private val d = resources.displayMetrics.density
    private val blue = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ContextCompat.getColor(context, R.color.w_ring_sleep) }
    private val stripe = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(34, 255, 255, 255); strokeWidth = 2f * d }
    private val tick = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }

    /** [stages] con 0 = despierto (como SleepStager). */
    fun setStages(stages: IntArray, awakeRow: Boolean) { this.stages = stages; this.awakeRow = awakeRow; invalidate() }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        val n = stages.size
        if (w <= 0f || n == 0) return
        fun x(i: Int) = w * i / n
        if (!awakeRow) {
            var i = 0
            while (i < n) {
                if (stages[i] == 0) { i++; continue }
                var j = i
                while (j < n && stages[j] != 0) j++
                canvas.drawRoundRect(RectF(x(i) + d, 0f, max(x(j) - d, x(i) + 2 * d), h), 3f * d, 3f * d, blue)
                i = j
            }
        } else {
            canvas.save(); canvas.clipRect(0f, 0f, w, h)
            var xx = -h; while (xx < w + h) { canvas.drawLine(xx, h, xx + h, 0f, stripe); xx += 7f * d }
            canvas.restore()
            var i = 0
            while (i < n) {
                if (stages[i] != 0) { i++; continue }
                var j = i
                while (j < n && stages[j] == 0) j++
                canvas.drawRect(x(i), 0f, max(x(j), x(i) + 2.5f * d), h, tick)
                i = j
            }
        }
    }
}

/** Indicador de 3 tramos (deficiente / suficiente / óptimo) de la tarjeta de la calificación del sueño. */
class TriSegmentView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    /** 0 = deficiente (naranja), 1 = suficiente (gris), 2 = óptimo (verde); -1 = sin dato. */
    var level: Int = -1
        set(v) { field = v; invalidate() }
    private val d = resources.displayMetrics.density
    private val off = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#3A4247") }
    private val on = Paint(Paint.ANTI_ALIAS_FLAG)
    private val colors = intArrayOf(Color.parseColor("#F5A524"), Color.parseColor("#B9BEC2"), Color.parseColor("#2CE5A3"))

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        val gap = 3f * d
        val seg = (w - 2 * gap) / 3f
        for (i in 0..2) {
            val x = i * (seg + gap)
            val p = if (i == level) on.apply { color = colors[i] } else off
            canvas.drawRoundRect(RectF(x, 0f, x + seg, h), h / 2, h / 2, p)
        }
    }
}
