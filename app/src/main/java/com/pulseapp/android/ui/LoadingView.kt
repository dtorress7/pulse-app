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
import androidx.core.content.res.ResourcesCompat
import com.pulseapp.android.R
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Pantalla de carga animada (fondo negro) con el logo de PulseApp:
 * el anillo gira con su degradado azul → verde, el latido recorre la línea como en un monitor y, al pasar por el pico,
 * el anillo "late" y suelta una onda. Debajo, las letras de CARGANDO saltan una detrás de otra.
 */
class LoadingView @JvmOverloads constructor(context: Context, attrs: AttributeSet? = null) : View(context, attrs) {

    /** Solo para pruebas: si no es null se dibuja ese instante (ms) en vez del reloj. */
    var fixedTimeMs: Long? = null
    var text: String = "CARGANDO"

    private val startNs = System.nanoTime()
    private val d = resources.displayMetrics.density
    private val blue = Color.parseColor("#02A9F7")
    private val green = Color.parseColor("#16EC06")

    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; color = Color.parseColor("#1E262B")
    }
    private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val wave = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val ghost = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND; color = Color.argb(46, 255, 255, 255)
    }
    private val knockout = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND; color = Color.BLACK
    }
    private val trace = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private val head = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val letters = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        typeface = ResourcesCompat.getFont(context, R.font.barlow_condensed_bold)
        textSize = 17f * d
    }
    private val rect = RectF()

    // Latido del logo (coordenadas del logo de 120 × 120 con el anillo de radio 44 centrado en 60,60)
    private val pulse = floatArrayOf(8f, 62f, 38f, 62f, 45f, 48f, 54f, 82f, 64f, 30f, 72f, 70f, 77f, 62f, 112f, 62f)
    private val samples: List<FloatArray>   // puntos cada poco a lo largo del latido: x, y, distancia acumulada (0..1)
    private val spikeAt: Float              // posición (0..1) del pico más alto

    init {
        val pts = ArrayList<FloatArray>()
        var total = 0f
        val segLen = FloatArray(pulse.size / 2 - 1) { i ->
            hypot(pulse[2 * i + 2] - pulse[2 * i], pulse[2 * i + 3] - pulse[2 * i + 1])
        }
        segLen.forEach { total += it }
        var acc = 0f
        for (i in segLen.indices) {
            val steps = max(2, (segLen[i] / 1.2f).toInt())
            for (s in 0 until steps) {
                val f = s / steps.toFloat()
                pts.add(floatArrayOf(pulse[2 * i] + (pulse[2 * i + 2] - pulse[2 * i]) * f,
                    pulse[2 * i + 1] + (pulse[2 * i + 3] - pulse[2 * i + 1]) * f, (acc + segLen[i] * f) / total))
            }
            acc += segLen[i]
        }
        pts.add(floatArrayOf(pulse[pulse.size - 2], pulse[pulse.size - 1], 1f))
        samples = pts
        spikeAt = pts.minByOrNull { it[1] }!![2]
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        if (w <= 0f || h <= 0f) return
        val t = fixedTimeMs ?: ((System.nanoTime() - startNs) / 1_000_000L)
        val cx = w / 2f
        val cy = h / 2f - 34f * d
        val r = min(58f * d, w * 0.17f)
        val unit = r / 44f                       // 1 unidad del logo en píxeles
        fun lx(x: Float) = cx + (x - 60f) * unit
        fun ly(y: Float) = cy + (y - 60f) * unit

        // Ritmo: un latido cada 1,1 s; la cabeza recorre el trazo en 0,8 s
        val beat = 1100L
        val phase = (t % beat) / beat.toFloat()
        val headPos = (phase / 0.8f).coerceAtMost(1.15f)
        val sinceSpike = ((phase - spikeAt * 0.8f + 1f) % 1f) * beat   // ms desde que pasó por el pico
        val bump = 1f + 0.055f * exp(-(sinceSpike / 90f) * (sinceSpike / 90f))
        val rr = r * bump

        // Onda que sale del anillo en cada latido
        if (sinceSpike < 700f) {
            val k = sinceSpike / 700f
            wave.strokeWidth = 3f * d * (1f - k)
            wave.color = Color.argb((120 * (1f - k)).toInt(), Color.red(green), Color.green(green), Color.blue(green))
            canvas.drawCircle(cx, cy, rr + 26f * d * k, wave)
        }

        // Anillo: pista + arco de 270° que gira (como el del logo)
        val stroke = 10f * unit
        track.strokeWidth = stroke
        canvas.drawCircle(cx, cy, rr, track)
        arc.strokeWidth = stroke
        arc.shader = LinearGradient(cx - rr, cy + rr, cx + rr, cy - rr, blue, green, Shader.TileMode.CLAMP)
        rect.set(cx - rr, cy - rr, cx + rr, cy + rr)
        val rot = (t % 1600L) / 1600f * 360f
        canvas.drawArc(rect, -90f + rot, 300f, false, arc)

        // Latido: hueco negro sobre el anillo (como en el logo) + silueta tenue + trazo que se va dibujando con estela
        val line = android.graphics.Path()
        for (k in 0 until pulse.size / 2) {
            if (k == 0) line.moveTo(lx(pulse[0]), ly(pulse[1])) else line.lineTo(lx(pulse[2 * k]), ly(pulse[2 * k + 1]))
        }
        knockout.strokeWidth = 11f * unit
        canvas.drawPath(line, knockout)
        ghost.strokeWidth = 5.5f * unit
        canvas.drawPath(line, ghost)
        trace.strokeWidth = 5.5f * unit
        val tail = 0.45f
        for (i in 1 until samples.size) {
            val p = samples[i][2]
            if (p > headPos || p < headPos - tail) continue
            val a = ((p - (headPos - tail)) / tail).coerceIn(0f, 1f)
            trace.color = Color.argb((255 * a).toInt(), 255, 255, 255)
            canvas.drawLine(lx(samples[i - 1][0]), ly(samples[i - 1][1]), lx(samples[i][0]), ly(samples[i][1]), trace)
        }
        if (headPos <= 1f) {
            val hp = samples.minByOrNull { kotlin.math.abs(it[2] - headPos) }!!
            canvas.drawCircle(lx(hp[0]), ly(hp[1]), 4.2f * unit, head)
        }

        // CARGANDO: cada letra salta por turnos (ola), como en el vídeo de referencia
        val spacing = 5f * d
        val widths = text.map { letters.measureText(it.toString()) }
        val totalW = widths.sum() + spacing * (text.length - 1)
        var x = cx - totalW / 2f
        val baseY = cy + r + 70f * d
        val cycle = 1500L
        text.forEachIndexed { i, ch ->
            val lt = ((t - i * 85L) % cycle + cycle) % cycle
            val jump = if (lt < 320L) sin(Math.PI * lt / 320.0).toFloat() else 0f
            letters.color = Color.argb((150 + 105 * jump).toInt(), 255, 255, 255)
            canvas.drawText(ch.toString(), x, baseY - jump * 9f * d, letters)
            x += widths[i] + spacing
        }

        if (fixedTimeMs == null) postInvalidateOnAnimation()
    }
}
