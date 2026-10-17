package com.pulseapp.android

import kotlin.math.sqrt

/**
 * VFC de la noche como WHOOP (17/10). WHOOP no usa toda la noche: da más peso al sueño profundo.
 * Comprobado con 2 noches: RMSSD de toda la noche 70 / 87 ms frente a WHOOP 80 / 108; RMSSD medio de los
 * tramos de PROFUNDO 87 / 104 ms. Con fases (≥20 min de profundo) se usa la media de los tramos de profundo,
 * ponderada por su duración; sin fases, toda la ventana de sueño.
 */
object NightMetrics {

    private const val MIN_DEEP_MINUTES = 20

    /** RMSSD descartando intervalos que cambian >20 % respecto al anterior (artefactos). */
    fun rmssd(rrRaw: List<Double>): Double? {
        if (rrRaw.size < 2) return null
        val rr = ArrayList<Double>(rrRaw.size)
        rr.add(rrRaw[0])
        for (i in 1 until rrRaw.size) {
            val prev = rr.last()
            if (kotlin.math.abs(rrRaw[i] - prev) / prev <= 0.20) rr.add(rrRaw[i])
        }
        if (rr.size < 2) return null
        var sumSq = 0.0
        for (i in 1 until rr.size) { val d = rr[i] - rr[i - 1]; sumSq += d * d }
        return sqrt(sumSq / (rr.size - 1))
    }

    /** [readings] = (hora en ms, intervalos RR) de la ventana de sueño, en orden. */
    fun hrv(readings: List<Pair<Long, List<Double>>>, staged: SleepStager.Result?): Double? {
        val whole = rmssd(readings.flatMap { it.second })
        if (staged == null || staged.deepMinutes < MIN_DEEP_MINUTES) return whole
        val st = staged.stages
        val n = st.size
        // RR de cada minuto de la noche
        val perMinute = Array(n) { ArrayList<Double>() }
        for ((t, rr) in readings) {
            val i = (t / 60_000L - staged.startMinute).toInt()
            if (i in 0 until n) perMinute[i].addAll(rr)
        }
        var weighted = 0.0
        var weight = 0
        var i = 0
        while (i < n) {
            var j = i
            while (j < n && st[j] == st[i]) j++
            if (st[i] == SleepStager.DEEP) {
                val rr = ArrayList<Double>()
                for (k in i until j) rr.addAll(perMinute[k])
                val v = rmssd(rr)
                if (v != null) { weighted += v * (j - i); weight += j - i }
            }
            i = j
        }
        return if (weight >= MIN_DEEP_MINUTES) weighted / weight else whole
    }
}
