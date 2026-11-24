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
    /** [bpm] = pulso de cada lectura (mismo orden que [readings]); si falta, no se quitan tramos por pulso alto. */
    fun hrv(readings: List<Pair<Long, List<Double>>>, staged: SleepStager.Result?, bpm: List<Int>? = null): Double? {
        staged?.let { stageHrv(readings, it, bpm) }?.let { return it }
        return hrvOld(readings, staged)
    }

    /**
     * 1/11: VFC = e^0,0819 · P^0,3808 · L^0,6030, con P y L = media del RMSSD de los tramos de 2 min dentro del PROFUNDO y del LIGERO
     * (filtro de artefactos 30 % en vez de 20 %: el 20 % tiraba latidos buenos en las noches de VFC alta). 16 noches de WHOOP, dejando
     * cada noche fuera: error medio 1,9 → 1,42 ms, máx 5,3 → 3,4 (31/10→1/11: 83,5 → 80,5, WHOOP 78,2); ajustando con las 10 primeras y
     * probando las 6 últimas 2,28 → 1,62; con las fases EXACTAS de WHOOP 1,40 (no depende de acertar cada minuto de fase).
     * Sin fases o con < 10 tramos de alguna de las dos → el método anterior.
     */
    // 4/11: fuera los tramos de 2 min con el pulso medio > FC en reposo de la noche (mediana) + 12. Tras el fútbol de las 21–22 h el
    // primer profundo iba a 72–77 lpm (FCR 61) con RMSSD 40–55 y hundía la VFC (74,6 vs WHOOP 80,1). 19 noches dejando cada una fuera:
    // 1,76 → 1,45 ms (máx 5,7 → 3,8); ajustando con 16–25/10 y probando 26/10–4/11: 2,08 → 1,67. Coeficientes reajustados con las 19.
    fun stageHrv(readings: List<Pair<Long, List<Double>>>, staged: SleepStager.Result, bpm: List<Int>? = null): Double? {
        val st = staged.stages
        val deep = LinkedHashMap<Long, ArrayList<Pair<Long, List<Double>>>>(); val light = LinkedHashMap<Long, ArrayList<Pair<Long, List<Double>>>>()
        val hrSum = HashMap<Long, Double>(); val hrN = HashMap<Long, Int>()
        val useHr = bpm != null && bpm.size == readings.size && bpm.isNotEmpty()
        val ref = if (useHr) bpm!!.sorted().let { s -> if (s.size % 2 == 0) (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0 else s[s.size / 2].toDouble() } else 0.0
        for ((n, r) in readings.withIndex()) {
            val (t, rr) = r
            if (rr.isEmpty()) continue
            val i = (t / 60_000L - staged.startMinute).toInt()
            if (i !in st.indices) continue
            val stage = st[i]
            val map = when (stage) { SleepStager.DEEP -> deep; SleepStager.LIGHT -> light; else -> continue }
            val w = t / WINDOW_MS
            map.getOrPut(w) { ArrayList() }.add(t to rr.filter { it in 300.0..2000.0 })
            if (useHr) { val k = w * 8 + stage; hrSum[k] = (hrSum[k] ?: 0.0) + bpm!![n]; hrN[k] = (hrN[k] ?: 0) + 1 }
        }
        fun mean(m: Map<Long, List<Pair<Long, List<Double>>>>, stage: Int): Double? {
            val v = m.entries.filter { (w, items) ->
                if (items.sumOf { it.second.size } < MIN_RR_PER_WINDOW) return@filter false
                if (!useHr) return@filter true
                val k = w * 8 + stage; val n = hrN[k] ?: return@filter true
                hrSum.getValue(k) / n <= ref + STAGE_HIGH_HR
            }.mapNotNull { rmssdAdjacent(it.value, STAGE_ARTIFACT) }
            return if (v.size < STAGE_MIN_WINDOWS) null else v.average()
        }
        val p = mean(deep, SleepStager.DEEP) ?: return null
        val l = mean(light, SleepStager.LIGHT) ?: return null
        return Math.exp(STAGE_C + STAGE_DEEP_EXP * Math.log(p) + STAGE_LIGHT_EXP * Math.log(l))
    }

    /**
     * 24/11: RMSSD solo con diferencias entre latidos SEGUIDOS. [items] = (hora en ms de cada lectura, RR de esa lectura), en orden.
     * Con la pulsera de Nico (y la de Pablo) el historial solo trae RR en ~57 % de los latidos (uno por segundo como mucho): al juntar
     * los RR de un tramo, cada hueco hacía restar dos intervalos que NO son seguidos y la VFC salía alta (Nico 23/11 63,6 vs WHOOP 54).
     * Una lectura sigue a la anterior si el tiempo entre las dos ≤ sus RR + 0,5 s (un latido perdido deja ~2 RR de hueco).
     * Comprobado: tus noches (pulso en directo, sin huecos) salen igual (±1 ms; 18–23/11 MAE 1,45 → 1,33); quitando de tus datos una
     * lectura de cada 3 la VFC subía +15 % y ahora ±1 %; Nico 63,6 → 51,2 (W 54), con las ventanas de WHOOP 54,9/60,3 → 42,9/48,6
     * (W 45/54); Pablo 3 noches 3,2 → 2,6.
     */
    fun rmssdAdjacent(items: List<Pair<Long, List<Double>>>, maxJump: Double): Double? {
        if (coverage(items) >= FULL_COVERAGE) return rmssd(items.flatMap { it.second }, maxJump)
        var prev: Double? = null; var prevT = Long.MIN_VALUE
        var sumSq = 0.0; var n = 0
        for ((t, rr) in items) {
            if (rr.isEmpty()) continue
            val joins = prev != null && t - prevT <= rr.sum() + GAP_TOL_MS
            for ((k, r) in rr.withIndex()) {
                val p = prev
                if ((k == 0 && !joins) || p == null) { prev = r; continue }
                if (kotlin.math.abs(r - p) / p <= maxJump) { val d = r - p; sumSq += d * d; n++; prev = r }
            }
            prevT = t
        }
        if (n < 1) return null
        return sqrt(sumSq / n)
    }

    const val GAP_TOL_MS = 500.0
    /** Con ≥ 90 % de los latidos (pulso en directo) todo se queda como antes; las reglas de latidos seguidos son para el historial con huecos. */
    const val FULL_COVERAGE = 0.9

    /** Parte del tiempo cubierta por latidos con RR: suma de los RR / tiempo entre la primera y la última lectura (1 = ninguno perdido). */
    fun coverage(items: List<Pair<Long, List<Double>>>): Double {
        val withRr = items.filter { it.second.isNotEmpty() }
        if (withRr.size < 2) return 0.0
        val first = withRr.first(); val last = withRr.last()
        val span = (last.first - first.first) + first.second.sum()
        val beats = withRr.sumOf { it.second.sum() }
        return if (span > 0) beats / span else 0.0
    }

    private const val STAGE_ARTIFACT = 0.30
    private const val STAGE_MIN_WINDOWS = 10
    const val STAGE_HIGH_HR = 12.0
    const val STAGE_C = 0.03828059
    const val STAGE_DEEP_EXP = 0.38089473
    const val STAGE_LIGHT_EXP = 0.61171261

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
        val windows = LinkedHashMap<Long, ArrayList<Pair<Long, List<Double>>>>()
        for ((t, rr) in readings) {
            if (rr.isEmpty()) continue
            windows.getOrPut(t / WINDOW_MS) { ArrayList() }.add(t to rr.filter { it in 300.0..2000.0 })
        }
        val values = windows.values.filter { w -> w.sumOf { it.second.size } >= MIN_RR_PER_WINDOW }.mapNotNull { rmssdAdjacent(it, 0.20) }
        if (values.size < MIN_WINDOWS) return null
        return HRV_K * Math.pow(values.average(), HRV_EXP)
    }
}
