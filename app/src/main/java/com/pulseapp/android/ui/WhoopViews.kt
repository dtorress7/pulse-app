package com.pulseapp.android.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import android.util.AttributeSet
import android.view.View
import androidx.core.content.ContextCompat
import androidx.core.content.res.ResourcesCompat
import com.pulseapp.android.R
import com.pulseapp.android.StressPoint
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/* Vistas dibujadas a mano con el aspecto de la app de WHOOP (17/10). */

private fun View.dp(v: Float) = v * resources.displayMetrics.density
private fun View.col(id: Int) = ContextCompat.getColor(context, id)
private fun withAlpha(c: Int, a: Int) = Color.argb(a, Color.red(c), Color.green(c), Color.blue(c))

/**
 * Gráfica del Monitor de estrés de Inicio: escala 0–3 con etiquetas a la izquierda, el día desde las 00:00 hasta
 * ahora, franja de sueño con la luna encima, línea que pasa de turquesa (bajo) a verde (alto) y marca de "ahora".
 */
class StressDayChartView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {

    private var points: List<StressPoint> = emptyList()
    private var from = 0L
    private var to = 1L
    private var sleepFrom: Long? = null
    private var sleepTo: Long? = null
    private var showNow = true

    private val labelFont = ResourcesCompat.getFont(context, R.font.barlow_condensed_semibold)
    private val boldFont = ResourcesCompat.getFont(context, R.font.barlow_condensed_bold)
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(Color.WHITE, 28); strokeWidth = dp(1f) }
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_secondary); textSize = dp(13f); typeface = labelFont }
    private val nowLabel = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_primary); textSize = dp(14f); typeface = boldFont }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = dp(2.2f); strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND
    }
    private val sleepFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(Color.WHITE, 16) }
    private val sleepLine = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.w_ring_sleep); strokeWidth = dp(2.5f) }
    private val nowDash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = col(R.color.text_primary); strokeWidth = dp(1.2f); style = Paint.Style.STROKE
        pathEffect = DashPathEffect(floatArrayOf(dp(4f), dp(4f)), 0f)
    }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_primary) }
    private val moon = ContextCompat.getDrawable(context, R.drawable.ic_moon_filled)?.mutate()

    fun setData(points: List<StressPoint>, fromMillis: Long, toMillis: Long, sleepFromMillis: Long?, sleepToMillis: Long?, isNow: Boolean) {
        this.points = points; from = fromMillis; to = max(toMillis, fromMillis + 60_000L)
        sleepFrom = sleepFromMillis; sleepTo = sleepToMillis; showNow = isNow
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        if (w <= 0f || h <= 0f) return
        val left = dp(34f); val right = w - dp(8f)
        val top = dp(30f); val bottom = h - dp(28f)
        fun x(t: Long) = left + (right - left) * ((t - from).toFloat() / (to - from)).coerceIn(0f, 1f)
        fun y(v: Float) = bottom - (bottom - top) * (v.coerceIn(0f, 3f) / 3f)

        // Sueño: franja + línea arriba + luna
        val sf = sleepFrom; val st = sleepTo
        if (sf != null && st != null && st > from && sf < to) {
            val x1 = x(max(sf, from)); val x2 = x(min(st, to))
            canvas.drawRect(x1, y(3f), x2, bottom, sleepFill)
            canvas.drawLine(x1, y(3f), x2, y(3f), sleepLine)
            moon?.let {
                val s = dp(18f).toInt(); val cx = ((x1 + x2) / 2).toInt()
                it.setTint(col(R.color.text_primary))
                it.setBounds(cx - s / 2, (y(3f) - dp(26f)).toInt(), cx + s / 2, (y(3f) - dp(26f)).toInt() + s)
                it.draw(canvas)
            }
        }
        // Guías horizontales y etiquetas 0,0..3,0
        for (i in 0..3) {
            val yy = y(i.toFloat())
            canvas.drawLine(left, yy, right, yy, grid)
            canvas.drawText("%d,0".format(i), 0f, yy + dp(4.5f), label)
        }
        // Guías verticales cada 4 h y etiquetas de hora
        val fmt = SimpleDateFormat("HH:mm", Locale("es", "ES"))
        canvas.drawText(fmt.format(Date(from + 60_000L)), left - dp(4f), h - dp(6f), label)
        val c = Calendar.getInstance().apply { timeInMillis = from; set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }
        while (true) {
            c.add(Calendar.HOUR_OF_DAY, 1)
            if (c.timeInMillis >= to) break
            if (c.get(Calendar.HOUR_OF_DAY) % 4 != 0) continue
            val xx = x(c.timeInMillis)
            if (xx - left < dp(40f) || right - xx < dp(46f)) continue
            canvas.drawLine(xx, top, xx, bottom, grid)
            val t = fmt.format(c.time)
            canvas.drawText(t, xx - label.measureText(t) / 2, h - dp(6f), label)
        }
        // Línea: degradado vertical según el nivel (turquesa → verde)
        line.shader = LinearGradient(0f, y(0f), 0f, y(3f),
            intArrayOf(col(R.color.w_stress_line_low), col(R.color.w_stress_line_low), col(R.color.w_stress_line_high)),
            floatArrayOf(0f, 0.25f, 0.75f), Shader.TileMode.CLAMP)
        val pts = points.filter { it.timeMillis in from..to }.sortedBy { it.timeMillis }
        var path = Path(); var started = false; var last = 0L
        for (p in pts) {
            val xx = x(p.timeMillis); val yy = y(p.score)
            if (!started || p.timeMillis - last > 15 * 60_000L) {
                if (started) canvas.drawPath(path, line)
                path = Path(); path.moveTo(xx, yy); started = true
            } else path.lineTo(xx, yy)
            last = p.timeMillis
        }
        if (started) canvas.drawPath(path, line)
        // Ahora
        if (showNow) {
            val xx = right - dp(2f)
            val dash = Path().apply { moveTo(xx, top - dp(14f)); lineTo(xx, bottom) }
            canvas.drawPath(dash, nowDash)
            canvas.drawCircle(xx, bottom, dp(3.5f), dot)
            val t = fmt.format(Date(to))
            canvas.drawText(t, right - nowLabel.measureText(t), h - dp(6f), nowLabel)
        }
    }
}

/**
 * "Esfuerzo y recuperación" de WHOOP: 7 días, esfuerzo (azul, escala 0–21 a la izquierda) y recuperación
 * (círculos del color de su zona, escala 0–100 % a la derecha), con el día elegido resaltado.
 */
class StrainRecoveryChartView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {

    data class Day(val weekday: String, val dayOfMonth: String, val strain: Double?, val recovery: Int?)

    private var days: List<Day> = emptyList()
    private val f = ResourcesCompat.getFont(context, R.font.barlow_condensed_bold)
    private val fs = ResourcesCompat.getFont(context, R.font.barlow_condensed_semibold)
    private val blue = col(R.color.strain_blue)
    private val green = col(R.color.w_recovery_high)
    private val amber = col(R.color.alert_amber)
    private val red = col(R.color.alert_red)
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(Color.WHITE, 24); strokeWidth = dp(1f) }
    private val axis = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = dp(13f); typeface = fs }
    private val value = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = dp(17f); typeface = f }
    private val dayLabel = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = dp(13.5f); typeface = fs; textAlign = Paint.Align.CENTER }
    private val strainLine = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = blue; style = Paint.Style.STROKE; strokeWidth = dp(2.4f); strokeJoin = Paint.Join.ROUND }
    private val recLine = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.parseColor("#8A9096"); style = Paint.Style.STROKE; strokeWidth = dp(2.4f); strokeJoin = Paint.Join.ROUND }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = dp(2.6f) }
    private val ringFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.w_card) }
    private val highlight = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(Color.WHITE, 22) }

    fun setDays(d: List<Day>) { days = d; invalidate() }

    private fun recColor(r: Int) = when { r >= 67 -> green; r >= 34 -> amber; else -> red }

    override fun onDraw(canvas: Canvas) {
        if (days.isEmpty()) return
        val w = width.toFloat(); val h = height.toFloat()
        val left = dp(30f); val right = w - dp(46f)
        val top = dp(22f); val bottom = h - dp(58f)
        val n = days.size
        val step = (right - left) / n
        fun cx(i: Int) = left + step * (i + 0.5f)
        fun yStrain(s: Double) = bottom - (bottom - top) * (s / 21.0).toFloat().coerceIn(0f, 1f)
        fun yRec(r: Int) = bottom - (bottom - top) * (r / 100f).coerceIn(0f, 1f)

        // Columna del día elegido (el último)
        canvas.drawRoundRect(RectF(cx(n - 1) - step * 0.42f, top - dp(16f), cx(n - 1) + step * 0.42f, h - dp(4f)), dp(6f), dp(6f), highlight)

        // Guías: 0/7/14/21 ↔ 0/33/66/100 %
        val leftLabels = listOf("0", "7", "14", "21")
        val rightLabels = listOf("0%" to red, "33%" to red, "66%" to amber, "100%" to green)
        for (i in 0..3) {
            val yy = bottom - (bottom - top) * i / 3f
            canvas.drawLine(left, yy, right, yy, grid)
            axis.color = blue; axis.textAlign = Paint.Align.LEFT
            canvas.drawText(leftLabels[i], 0f, yy + dp(4.5f), axis)
            axis.color = rightLabels[i].second; axis.textAlign = Paint.Align.RIGHT
            canvas.drawText(rightLabels[i].first, w, yy + dp(4.5f), axis)
        }

        // Líneas
        fun poly(values: List<Pair<Int, Float>>, p: Paint) {
            if (values.size < 2) return
            val path = Path()
            values.forEachIndexed { k, (i, yy) -> if (k == 0) path.moveTo(cx(i), yy) else path.lineTo(cx(i), yy) }
            canvas.drawPath(path, p)
        }
        val recPts = days.mapIndexedNotNull { i, d -> d.recovery?.let { i to yRec(it) } }
        val strPts = days.mapIndexedNotNull { i, d -> d.strain?.let { i to yStrain(it) } }
        poly(recPts, recLine)
        poly(strPts, strainLine)

        val r = dp(6.5f)
        days.forEachIndexed { i, d ->
            val x = cx(i)
            val ys = d.strain?.let { yStrain(it) }
            val yr = d.recovery?.let { yRec(it) }
            if (yr != null) {
                ring.color = recColor(d.recovery!!)
                canvas.drawCircle(x, yr, r, ringFill); canvas.drawCircle(x, yr, r, ring)
            }
            if (ys != null) {
                ring.color = blue
                canvas.drawCircle(x, ys, r, ringFill); canvas.drawCircle(x, ys, r, ring)
            }
            // Etiquetas: la recuperación arriba y el esfuerzo debajo (si están muy juntas, se separan)
            value.textAlign = Paint.Align.CENTER
            if (yr != null) {
                val above = ys == null || yr <= ys
                value.color = recColor(d.recovery!!)
                canvas.drawText("${d.recovery} %", x, if (above) yr - r - dp(5f) else yr + r + dp(17f), value)
            }
            if (ys != null) {
                // Debajo si está por debajo de la recuperación, salvo que choque con los días (entonces encima, como WHOOP)
                val below = (yr == null || ys >= yr) && ys + r + dp(17f) <= bottom + dp(4f)
                value.color = blue
                val txt = "%.1f".format(Locale.US, d.strain).replace('.', ',')
                canvas.drawText(txt, x, if (below) ys + r + dp(17f) else ys - r - dp(5f), value)
            }
            val last = i == n - 1
            dayLabel.color = if (last) col(R.color.text_primary) else col(R.color.text_secondary)
            canvas.drawText(d.weekday, x, h - dp(30f), dayLabel)
            canvas.drawText(d.dayOfMonth, x, h - dp(11f), dayLabel)
        }
    }
}

/** Línea de pulso en directo del Monitor de salud: últimos minutos sobre cuadrícula, punto en el último valor. */
class LiveHrLineView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private var pts: List<Pair<Long, Int>> = emptyList()
    private var windowMs = 10 * 60_000L
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(Color.WHITE, 14); strokeWidth = dp(1f) }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = dp(3f); strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
    private val dash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = withAlpha(Color.WHITE, 170); strokeWidth = dp(1.2f); style = Paint.Style.STROKE
        pathEffect = DashPathEffect(floatArrayOf(dp(4f), dp(4f)), 0f)
    }
    private val dotOuter = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val dotInner = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.strain_blue) }

    fun setPoints(p: List<Pair<Long, Int>>) { pts = p; invalidate() }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        if (w <= 0f) return
        val cell = dp(14f)
        var gx = 0f; while (gx <= w) { canvas.drawLine(gx, 0f, gx, h, grid); gx += cell }
        var gy = 0f; while (gy <= h) { canvas.drawLine(0f, gy, w, gy, grid); gy += cell }
        val endX = w - dp(16f)
        canvas.drawLine(endX, dp(4f), endX, h - dp(4f), dash)
        if (pts.isEmpty()) return
        val now = pts.last().first
        val from = now - windowMs
        // Medias de 5 s: el pulso segundo a segundo hace una línea demasiado nerviosa
        val vis = pts.filter { it.first >= from }.groupBy { it.first / 5000 }.entries.sortedBy { it.key }
            .map { (k, v) -> (if (k == now / 5000) now else k * 5000 + 2500) to Math.round(v.map { it.second }.average()).toInt() }
        val minB = (vis.minOf { it.second } - 10).toFloat()
        val maxB = (vis.maxOf { it.second } + 10).toFloat()
        fun x(t: Long) = endX * ((t - from).toFloat() / windowMs)
        fun y(b: Int) = h - dp(10f) - (h - dp(20f)) * ((b - minB) / max(1f, maxB - minB))
        line.shader = LinearGradient(0f, 0f, endX, 0f, withAlpha(col(R.color.strain_blue), 0), col(R.color.strain_blue), Shader.TileMode.CLAMP)
        val path = Path()
        vis.forEachIndexed { i, (t, b) -> if (i == 0) path.moveTo(x(t), y(b)) else path.lineTo(x(t), y(b)) }
        canvas.drawPath(path, line)
        val ly = y(vis.last().second)
        canvas.drawCircle(endX, ly, dp(7f), dotOuter)
        canvas.drawCircle(endX, ly, dp(3.5f), dotInner)
    }
}

/** Pulso de una actividad: área azul, escala a la izquierda, líneas discontinuas en el inicio y el final. */
class ActivityHrChartView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private var pts: List<Pair<Long, Int>> = emptyList()
    private var start = 0L
    private var end = 1L
    private val fs = ResourcesCompat.getFont(context, R.font.barlow_condensed_semibold)
    private val fb = ResourcesCompat.getFont(context, R.font.barlow_condensed_bold)
    private val grid = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(Color.WHITE, 22); strokeWidth = dp(1f) }
    private val axis = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_secondary); textSize = dp(13f); typeface = fs }
    private val timeLabel = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.text_primary); textSize = dp(14f); typeface = fb }
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = col(R.color.strain_blue); style = Paint.Style.STROKE; strokeWidth = dp(1.8f); strokeJoin = Paint.Join.ROUND }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val dash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = withAlpha(Color.WHITE, 200); strokeWidth = dp(1.2f); style = Paint.Style.STROKE
        pathEffect = DashPathEffect(floatArrayOf(dp(4f), dp(4f)), 0f)
    }
    private val dot = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }

    /** [points] incluye unos minutos antes y después de la actividad (como WHOOP). */
    fun setData(points: List<Pair<Long, Int>>, startMillis: Long, endMillis: Long) {
        pts = points; start = startMillis; end = endMillis; invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        if (w <= 0f || pts.size < 2) return
        val left = 0f; val right = w
        val top = dp(10f); val bottom = h - dp(30f)
        val t0 = pts.first().first; val t1 = pts.last().first
        val lo = floor((pts.minOf { it.second } - 5) / 25.0) * 25
        val hi = ceil((pts.maxOf { it.second } + 5) / 25.0) * 25
        fun x(t: Long) = left + (right - left) * ((t - t0).toFloat() / max(1L, t1 - t0))
        fun y(b: Double) = bottom - (bottom - top) * ((b - lo) / (hi - lo)).toFloat()
        var v = lo
        while (v <= hi + 0.1) {
            val yy = y(v)
            canvas.drawLine(dp(28f), yy, right, yy, grid)
            canvas.drawText("%.0f".format(v), dp(2f), yy + dp(4.5f), axis)
            v += 25
        }
        fill.shader = LinearGradient(0f, top, 0f, bottom, withAlpha(col(R.color.strain_blue), 110), withAlpha(col(R.color.strain_blue), 8), Shader.TileMode.CLAMP)
        val p = Path(); val f = Path()
        pts.forEachIndexed { i, (t, b) ->
            val xx = x(t); val yy = y(b.toDouble())
            if (i == 0) { p.moveTo(xx, yy); f.moveTo(xx, bottom); f.lineTo(xx, yy) } else { p.lineTo(xx, yy); f.lineTo(xx, yy) }
        }
        f.lineTo(x(t1), bottom); f.close()
        canvas.drawPath(f, fill)
        canvas.drawPath(p, line)
        val fmt = SimpleDateFormat("HH:mm", Locale("es", "ES"))
        for ((t, alignLeft) in listOf(start to true, end to false)) {
            val xx = x(t)
            canvas.drawPath(Path().apply { moveTo(xx, top - dp(6f)); lineTo(xx, bottom) }, dash)
            canvas.drawCircle(xx, bottom, dp(3.5f), dot)
            val s = fmt.format(Date(t))
            val tx = if (alignLeft) xx + dp(4f) else xx - timeLabel.measureText(s) - dp(4f)
            canvas.drawText(s, tx, h - dp(8f), timeLabel)
        }
    }
}

/** Barra de zona de WHOOP: fondo rayado, relleno del color de la zona y el rango típico en un recuadro discontinuo. */
class ZoneBarView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {
    private var fraction = 0f
    private var typicalLo: Float? = null
    private var typicalHi: Float? = null
    private val stripe = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = withAlpha(Color.WHITE, 30); strokeWidth = dp(2f) }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val typicalFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(46, 0, 0, 0) }
    private val typicalDash = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = withAlpha(Color.WHITE, 200); strokeWidth = dp(1.2f); style = Paint.Style.STROKE
        pathEffect = DashPathEffect(floatArrayOf(dp(3f), dp(3f)), 0f)
    }

    fun setData(fraction0to1: Float, color: Int, typicalLo: Float?, typicalHi: Float?) {
        fraction = fraction0to1.coerceIn(0f, 1f); fill.color = color
        this.typicalLo = typicalLo; this.typicalHi = typicalHi
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        if (w <= 0f) return
        val barTop = h * 0.2f; val barBottom = h * 0.8f
        canvas.save()
        canvas.clipRect(0f, barTop, w, barBottom)
        var x = -h
        while (x < w + h) { canvas.drawLine(x, barBottom, x + (barBottom - barTop), barTop, stripe); x += dp(7f) }
        canvas.restore()
        if (fraction > 0f) {
            val fw = max(w * fraction, barBottom - barTop)
            canvas.drawRoundRect(RectF(0f, barTop, fw, barBottom), (barBottom - barTop) / 2, (barBottom - barTop) / 2, fill)
        }
        // Rango típico encima de la barra: recuadro oscurecido con bordes discontinuos
        val lo = typicalLo; val hi = typicalHi
        if (lo != null && hi != null) {
            val x1 = w * lo; val x2 = max(w * hi, x1 + dp(4f))
            canvas.drawRect(x1, 0f, x2, h, typicalFill)
            canvas.drawLine(x1, 0f, x1, h, typicalDash); canvas.drawLine(x2, 0f, x2, h, typicalDash)
        }
    }
}
