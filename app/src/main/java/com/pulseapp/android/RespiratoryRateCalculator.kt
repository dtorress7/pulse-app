package com.pulseapp.android

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * Frecuencia respiratoria (respiraciones por minuto) a partir de los intervalos RR del sueño, por la arritmia
 * sinusal respiratoria: el pulso se acelera al inhalar y se frena al exhalar.
 *
 * 17/10: método espectral. Antes se suavizaba con una media de 5 latidos, que es casi lo que dura una
 * respiración (unos 4–5 latidos), así que borraba la señal: salían 8 rpm frente a 13,1 de WHOOP.
 * Ahora: tramos de 2 min de latidos seguidos (sin artefactos) → serie RR remuestreada a 4 Hz, sin media ni
 * tendencia y con ventana de Hann → frecuencia con más energía entre 0,1 y 0,5 Hz (6–30 rpm). Se da la mediana
 * de todos los tramos (≥10). Con tus dos noches: 13,8 y 12,6 rpm (WHOOP: ~13,6 y 13,1).
 */
class RespiratoryRateCalculator {

    fun estimate(rrIntervalsMs: List<Double>): Double? {
        val rr = rrIntervalsMs.filter { it in 300.0..2000.0 }
        if (rr.size < 200) return null
        val estimates = ArrayList<Double>()
        var i = 0
        val n = rr.size
        while (i < n) {
            var j = i
            var acc = 0.0
            while (j < n && acc < SEGMENT_SECONDS) { acc += rr[j] / 1000.0; j++ }
            if (acc < SEGMENT_SECONDS * 0.9) break
            segmentRate(rr.subList(i, j))?.let { estimates.add(it) }
            i = j
        }
        if (estimates.size < 10) return null
        estimates.sort()
        val m = estimates.size
        val median = if (m % 2 == 1) estimates[m / 2] else (estimates[m / 2 - 1] + estimates[m / 2]) / 2.0
        return median.takeIf { it in 8.0..25.0 }
    }

    private fun segmentRate(seg: List<Double>): Double? {
        val ok = ArrayList<Double>(seg.size)
        ok.add(seg[0])
        var bad = 0
        for (k in 1 until seg.size) {
            if (abs(seg[k] - ok.last()) <= 0.2 * ok.last()) ok.add(seg[k]) else bad++
        }
        if (bad > seg.size * 0.1 || ok.size < 4) return null
        // Tiempo de cada latido
        val t = DoubleArray(ok.size)
        var acc = 0.0
        for (k in ok.indices) { acc += ok[k] / 1000.0; t[k] = acc }
        val m = ((t.last() - t[0]) * FS).toInt()
        if (m < 64) return null
        val y = DoubleArray(m)
        var p = 0
        for (q in 0 until m) {
            val tt = t[0] + q / FS
            while (p < t.size - 2 && t[p + 1] < tt) p++
            val f = ((tt - t[p]) / (t[p + 1] - t[p])).coerceIn(0.0, 1.0)
            y[q] = ok[p] + (ok[p + 1] - ok[p]) * f
        }
        // Sin media ni tendencia lineal, con ventana de Hann
        val mean = y.average()
        val mx = (m - 1) / 2.0
        var num = 0.0; var den = 0.0
        for (q in 0 until m) { num += (q - mx) * (y[q] - mean); den += (q - mx) * (q - mx) }
        val slope = num / den
        for (q in 0 until m) {
            y[q] = (y[q] - mean - slope * (q - mx)) * (0.5 - 0.5 * cos(2 * PI * q / (m - 1)))
        }
        var bestF = 0.0; var bestP = -1.0; var total = 0.0
        var step = 0
        while (true) {
            val f = 0.1 + step * 0.005
            if (f > 0.5 + 1e-9) break
            val w = 2 * PI * f / FS
            var re = 0.0; var im = 0.0
            for (q in 0 until m) { re += y[q] * cos(w * q); im += y[q] * sin(w * q) }
            val pw = re * re + im * im
            total += pw
            if (pw > bestP) { bestP = pw; bestF = f }
            step++
        }
        return if (total > 0 && bestP / total > 0.05) bestF * 60.0 else null
    }

    companion object {
        private const val SEGMENT_SECONDS = 120.0
        private const val FS = 4.0
    }
}
