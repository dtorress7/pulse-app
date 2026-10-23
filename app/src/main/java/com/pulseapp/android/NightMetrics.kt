package com.pulseapp.android

import kotlin.math.sqrt

/**
 * VFC de la noche como WHOOP (23/10, validado con 9 noches 14→23/10 frente a la API de WHOOP).
 * Antes (17/10) se usaba la media de los tramos de sueño PROFUNDO: dependía de acertar las fases y fallaba
 * hasta 10 ms (22→23: 87 vs 97). Ahora no depende de las fases:
 *   1. RMSSD de cada tramo de 2 min de la ventana de sueño (≥60 latidos válidos, saltos >20 % fuera).
 *   2. media de esos RMSSD → m.
 *   3. VFC = 0,07664 · m^1,6237 (WHOOP limpia más los artefactos y su escala crece más deprisa que la nuestra).
 * Error medio 1,7 ms (dejando cada noche fuera del ajuste, 2,2 ms); el método anterior, 5,3 ms.
 */
object NightMetrics {

    private const val WINDOW_MS = 120_000L
    private const val MIN_RR_PER_WINDOW = 60
    private const val MIN_WINDOWS = 10
    const val HRV_K = 0.0766391
    const val HRV_EXP = 1.6237416

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

    /** [readings] = (hora en ms, intervalos RR) de la ventana de sueño, en orden. [staged] ya no se usa (se deja la firma). */
    @Suppress("UNUSED_PARAMETER")
    fun hrv(readings: List<Pair<Long, List<Double>>>, staged: SleepStager.Result?): Double? {
        val windows = LinkedHashMap<Long, ArrayList<Double>>()
        for ((t, rr) in readings) {
            if (rr.isEmpty()) continue
            windows.getOrPut(t / WINDOW_MS) { ArrayList() }.addAll(rr.filter { it in 300.0..2000.0 })
        }
        val values = windows.values.filter { it.size >= MIN_RR_PER_WINDOW }.mapNotNull { rmssd(it) }
        if (values.size < MIN_WINDOWS) return null
        return HRV_K * Math.pow(values.average(), HRV_EXP)
    }
}
