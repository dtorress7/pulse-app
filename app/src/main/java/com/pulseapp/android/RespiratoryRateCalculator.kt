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

    /**
     * [readings] = (hora en ms, RR de esa lectura) de la ventana de sueño, en orden.
     * 24/11: si faltan latidos (< 90 % del tiempo cubierto por RR: historial de la pulsera con ~57 % de los latidos, Nico y Pablo) la
     * serie juntaba latidos no seguidos, el tiempo se encogía y salía 0 u 8 rpm (WHOOP 12,8 / 17,3) → [estimateSparse]. Con el pulso
     * en directo (tus noches, ~100 %) el método de siempre, igual que antes.
     */
    fun estimate(readings: List<Pair<Long, List<Double>>>): Double? {
        val items = readings.map { (t, rr) -> t to rr.filter { it in 300.0..2000.0 } }
        if (NightMetrics.coverage(items) < NightMetrics.FULL_COVERAGE) return estimateSparse(items)
        val rr = items.flatMap { it.second }
        if (rr.size < 200) return null
        val estimates = ArrayList<Double>()
        val n = rr.size
        var i = 0
        while (i < n) {
            var j = i
            var acc = 0.0
            while (j < n && acc < SEGMENT_SECONDS) { acc += rr[j] / 1000.0; j++ }
            if (acc < SEGMENT_SECONDS * 0.9) break
            segmentRate(rr.subList(i, j))?.let { estimates.add(it) }
            i = j
        }
        if (estimates.size < 10) return null
        return median(estimates).takeIf { it in 8.0..25.0 }
    }

    /**
     * Con latidos perdidos: cada RR se coloca en su hora (la de la lectura; varios RR de una lectura, hacia atrás) y en cada tramo
     * de 2 min (≥ 30 latidos, sin huecos de > 8 s, artefactos > 20 % fuera, sin tendencia) se busca la respiración con el periodograma
     * de Lomb-Scargle (vale para muestras irregulares), 0,1–0,5 Hz; mediana de ≥ 10 tramos.
     * Comprobado (prototipo en Python = este código): Nico 23/11 11,7 (WHOOP 12,8; antes nada), Pablo 17,4/18,9/17,7 (W 17,3/17,4/17,5;
     * antes 8,1/nada/17,4); tus noches quitando 1 de cada 3 lecturas o el 43 % de los latidos: ±0,6 de lo que da con todos.
     */
    fun estimateSparse(readings: List<Pair<Long, List<Double>>>): Double? {
        val beats = ArrayList<Pair<Double, Double>>()
        for ((t, rr0) in readings) {
            val rr = rr0.filter { it in 300.0..2000.0 }
            var acc = 0.0
            for (k in rr.indices.reversed()) { beats.add((t + 500 - acc) / 1000.0 to rr[k]); acc += rr[k] }
        }
        beats.sortBy { it.first }
        val bt = ArrayList<Double>(); val bv = ArrayList<Double>()
        for ((tt, r) in beats) {
            if (bv.isNotEmpty() && abs(r - bv.last()) > 0.2 * bv.last()) continue
            bt.add(tt); bv.add(r)
        }
        val t = bt.toDoubleArray(); val y = bv.toDoubleArray()
        if (t.size < 200) return null
        val estimates = ArrayList<Double>()
        var w0 = t[0]; var a = 0
        while (w0 < t.last()) {
            while (a < t.size && t[a] < w0) a++
            var b = a
            while (b < t.size && t[b] < w0 + SEGMENT_SECONDS) b++
            w0 += SEGMENT_SECONDS
            if (b - a < SPARSE_MIN_BEATS) continue
            var maxGap = 0.0
            for (k in a + 1 until b) maxGap = maxOf(maxGap, t[k] - t[k - 1])
            if (maxGap > SPARSE_MAX_GAP_S) continue
            lombRate(t.copyOfRange(a, b), y.copyOfRange(a, b))?.let { estimates.add(it) }
        }
        if (estimates.size < 10) return null
        return median(estimates).takeIf { it in 8.0..25.0 }
    }

    private fun lombRate(t: DoubleArray, y0: DoubleArray): Double? {
        val n = t.size
        val tm = t.average(); val ym = y0.average()
        var num = 0.0; var den = 0.0
        for (k in 0 until n) { num += (t[k] - tm) * (y0[k] - ym); den += (t[k] - tm) * (t[k] - tm) }
        val slope = if (den > 0) num / den else 0.0
        val y = DoubleArray(n) { y0[it] - ym - slope * (t[it] - tm) }
        val yMean = y.average()
        for (k in 0 until n) y[k] -= yMean
        var bestF = 0.0; var bestP = -1.0
        var step = 0
        while (true) {
            val f = 0.1 + step * 0.005
            if (f > 0.5 + 1e-9) break
            val w = 2 * PI * f
            var s2 = 0.0; var c2 = 0.0
            for (k in 0 until n) { s2 += sin(2 * w * t[k]); c2 += cos(2 * w * t[k]) }
            val tau = kotlin.math.atan2(s2, c2) / (2 * w)
            var yc = 0.0; var ys = 0.0; var cc = 0.0; var ss = 0.0
            for (k in 0 until n) {
                val c = cos(w * (t[k] - tau)); val s = sin(w * (t[k] - tau))
                yc += y[k] * c; ys += y[k] * s; cc += c * c; ss += s * s
            }
            val pw = yc * yc / cc + ys * ys / ss
            if (pw > bestP) { bestP = pw; bestF = f }
            step++
        }
        return if (bestP > 0) bestF * 60.0 else null
    }

    private fun median(v: List<Double>): Double {
        val e = v.sorted(); val m = e.size
        return if (m % 2 == 1) e[m / 2] else (e[m / 2 - 1] + e[m / 2]) / 2.0
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
        private const val SPARSE_MIN_BEATS = 30
        private const val SPARSE_MAX_GAP_S = 8.0
    }
}
