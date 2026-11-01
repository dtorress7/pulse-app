package com.pulseapp.android

import kotlin.math.sqrt

/**
 * VFC de la noche como WHOOP.
 *
 * 24/10 (10 noches, 9 con el hipnograma de WHOOP leído de las capturas): WHOOP calcula la VFC sobre los tramos de SUEÑO PROFUNDO
 * (lo confirmó su IA). Con las fases nuevas (SleepModel, que ya coloca el profundo donde WHOOP) se hace igual:
 *   1. RMSSD de cada tramo de profundo de ≥5 min (saltos >20 % fuera), media ponderada por la duración → p.
 *   2. VFC = 7,9966 · p^0,55945 (WHOOP estrecha la escala: los valores extremos los acerca a la media).
 * Validación justa (fases y calibración sin la noche probada): error medio 1,5 ms; la noche 23→24 (11 h, despertar a las 11) da 92 (WHOOP 92).
 * Sin fases o con <10 min de profundo: el método del 23/10 (toda la noche en tramos de 2 min, error medio 3,3 ms con 9 noches;
 * esa noche larga daba 101).
 */
object NightMetrics {

    private const val WINDOW_MS = 120_000L
    private const val MIN_RR_PER_WINDOW = 60
    private const val MIN_WINDOWS = 10
    const val HRV_K = 0.0766391
    const val HRV_EXP = 1.6237416
    const val DEEP_K = 7.9965785
    const val DEEP_EXP = 0.5594471
    private const val DEEP_MIN_SEGMENT = 5
    private const val DEEP_MIN_TOTAL = 10

    /** RMSSD descartando intervalos que cambian >20 % respecto al anterior (artefactos). */
    fun rmssd(rrRaw: List<Double>, maxJump: Double = 0.20): Double? {
        if (rrRaw.size < 2) return null
        val rr = ArrayList<Double>(rrRaw.size)
        rr.add(rrRaw[0])
        for (i in 1 until rrRaw.size) {
            val prev = rr.last()
            if (kotlin.math.abs(rrRaw[i] - prev) / prev <= maxJump) rr.add(rrRaw[i])
        }
        if (rr.size < 2) return null
        var sumSq = 0.0
        for (i in 1 until rr.size) { val d = rr[i] - rr[i - 1]; sumSq += d * d }
        return sqrt(sumSq / (rr.size - 1))
    }

    /** [readings] = (hora en ms, intervalos RR) de la ventana de sueño, en orden; [staged] = fases de esa noche (o null). */
    // 25/10: media de los dos métodos (profundo y toda la noche). 10 noches con el pipeline de la app: error medio 2,6 → 1,8 ms,
    // máx 11 → 5 (noche tras el partido del 24/10: profundo 82, toda la noche 66, WHOOP 71; noche larga del 24: 94 / 100, WHOOP 92).
    fun hrv(readings: List<Pair<Long, List<Double>>>, staged: SleepStager.Result?): Double? {
        staged?.let { stageHrv(readings, it) }?.let { return it }
        return hrvOld(readings, staged)
    }

    /**
     * 1/11: VFC = e^0,0819 · P^0,3808 · L^0,6030, con P y L = media del RMSSD de los tramos de 2 min dentro del PROFUNDO y del LIGERO
     * (filtro de artefactos 30 % en vez de 20 %: el 20 % tiraba latidos buenos en las noches de VFC alta). 16 noches de WHOOP, dejando
     * cada noche fuera: error medio 1,9 → 1,42 ms, máx 5,3 → 3,4 (31/10→1/11: 83,5 → 80,5, WHOOP 78,2); ajustando con las 10 primeras y
     * probando las 6 últimas 2,28 → 1,62; con las fases EXACTAS de WHOOP 1,40 (no depende de acertar cada minuto de fase).
     * Sin fases o con < 10 tramos de alguna de las dos → el método anterior.
     */
    fun stageHrv(readings: List<Pair<Long, List<Double>>>, staged: SleepStager.Result): Double? {
        val st = staged.stages
        val deep = LinkedHashMap<Long, ArrayList<Double>>(); val light = LinkedHashMap<Long, ArrayList<Double>>()
        for ((t, rr) in readings) {
            if (rr.isEmpty()) continue
            val i = (t / 60_000L - staged.startMinute).toInt()
            if (i !in st.indices) continue
            val map = when (st[i]) { SleepStager.DEEP -> deep; SleepStager.LIGHT -> light; else -> continue }
            map.getOrPut(t / WINDOW_MS) { ArrayList() }.addAll(rr.filter { it in 300.0..2000.0 })
        }
        fun mean(m: Map<Long, List<Double>>): Double? {
            val v = m.values.filter { it.size >= MIN_RR_PER_WINDOW }.mapNotNull { rmssd(it, STAGE_ARTIFACT) }
            return if (v.size < STAGE_MIN_WINDOWS) null else v.average()
        }
        val p = mean(deep) ?: return null
        val l = mean(light) ?: return null
        return Math.exp(STAGE_C + STAGE_DEEP_EXP * Math.log(p) + STAGE_LIGHT_EXP * Math.log(l))
    }

    private const val STAGE_ARTIFACT = 0.30
    private const val STAGE_MIN_WINDOWS = 10
    const val STAGE_C = 0.0819
    const val STAGE_DEEP_EXP = 0.3808
    const val STAGE_LIGHT_EXP = 0.6030

    /** Método del 25/10 (media de profundo calibrado y toda la noche): solo si no hay fases suficientes. */
    fun hrvOld(readings: List<Pair<Long, List<Double>>>, staged: SleepStager.Result?): Double? {
        val whole = wholeNightHrv(readings)
        val deep = staged?.let { deepHrv(readings, it) } ?: return whole
        return if (whole != null) (deep + whole) / 2 else deep
    }

    /** Media ponderada del RMSSD de los tramos de profundo (≥5 min), calibrada a WHOOP. */
    fun deepHrv(readings: List<Pair<Long, List<Double>>>, staged: SleepStager.Result): Double? {
        val st = staged.stages
        val n = st.size
        val perMinute = Array(n) { ArrayList<Double>() }
        for ((t, rr) in readings) {
            val i = (t / 60_000L - staged.startMinute).toInt()
            if (i in 0 until n) perMinute[i].addAll(rr.filter { it in 300.0..2000.0 })
        }
        var weighted = 0.0
        var weight = 0
        var i = 0
        while (i < n) {
            var j = i
            while (j < n && st[j] == st[i]) j++
            if (st[i] == SleepStager.DEEP && j - i >= DEEP_MIN_SEGMENT) {
                val rr = ArrayList<Double>()
                for (k in i until j) rr.addAll(perMinute[k])
                val v = rmssd(rr)
                if (v != null && rr.size > 2) { weighted += v * (j - i); weight += j - i }
            }
            i = j
        }
        if (weight < DEEP_MIN_TOTAL) return null
        return DEEP_K * Math.pow(weighted / weight, DEEP_EXP)
    }

    /** Método del 23/10: media del RMSSD de tramos de 2 min de toda la noche. */
    fun wholeNightHrv(readings: List<Pair<Long, List<Double>>>): Double? {
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
