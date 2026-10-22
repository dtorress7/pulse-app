package com.pulseapp.android

import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * Fases del sueño (Despierto / Ligero / Profundo / REM) con movimiento + pulso + VFC, minuto a minuto.
 *
 * Se ejecuta SOLO sobre la ventana que ya detectó [SleepDetector] y SOLO si esa noche hay movimiento
 * (motion_minutes.csv, "Movimiento y pasos" activado). Sin movimiento no se inventan fases.
 *
 * Calibrado con WHOOP (15→16 y 16→17/10, las dos noches con movimiento). 17/10: REM más fácil al final de la
 * noche (umbral −0,4 → 0,0 según avanza; antes −0,3 fijo daba 76 min de REM frente a 131 de WHOOP) y la noche
 * empieza en el primer tramo de ≥15 min dormido y acaba en el último minuto dormido (antes contaba como
 * "despierto" el rato en la cama antes de dormirse: 1:05 frente a 0:15 de WHOOP).
 *
 * 1) DESPIERTO. Un minuto es "agitado" si hay movimiento (≥10 s moviéndose o pasos) y el pulso sube ≥6 lpm sobre su
 *    base local (percentil 33 de ±20 min), o hay movimiento fuerte (≥30 s), o el pulso sube ≥15 lpm con giro/cambio
 *    de postura. Cada grupo de minutos agitados (huecos ≤2 min) se amplía 1 min antes y hasta 2 min después
 *    mientras el pulso siga ≥6 lpm alto. Solo cuenta como despertar si dura ≥3 min o el pulso sube ≥12 lpm.
 * 2) Del resto de minutos (lejos de un despertar, ±2 min) se miran dos señales respecto a la mediana de los 90 min
 *    de alrededor (así se quita la subida natural de VFC y la bajada de pulso a lo largo de la noche):
 *      - PROFUNDO: VFC (RMSSD de 7 min, en logaritmo) por encima de la mediana local y pulso ≥0,5 lpm por debajo
 *        de la local. El umbral de VFC sube un poco hacia el final de la noche (más profundo al principio).
 *      - REM: VFC por debajo de la local (≥0,4 al principio, ≥0,2 a mitad, ≥0 al final: el REM se alarga al
 *        final de la noche) y pulso igual o por encima de la local. No hay REM en los primeros 45 min ni
 *        profundo en los últimos 45 min.
 *      - LIGERO: todo lo demás. Los tramos de profundo/REM de menos de 4 min pasan a ligero.
 */
object SleepStager {

    const val AWAKE = 0
    const val LIGHT = 1
    const val DEEP = 2
    const val REM = 3

    // Despierto
    private const val WAKE_MOVE_SECS = 10
    private const val WAKE_SPIKE = 6.0
    private const val WAKE_BIG_MOVE_SECS = 30
    private const val WAKE_SPIKE_HIGH = 15.0
    private const val WAKE_GAP = 2
    private const val WAKE_TAIL = 2
    private const val WAKE_MIN_MINUTES = 3
    private const val WAKE_MIN_SPIKE = 12.0

    // Profundo / REM — RONDA GRANDE 22/10: ajustados a la vez con las 7 noches con movimiento y WHOOP (16→22/10).
    // Error medio por noche: ligero 34→14 min, profundo 21→16, REM 28→13, VFC 4,3→4,3 ms (antes: ventana 91, profundo 0/0,3/−0,5,
    // REM −0,2/0,4/0). Arnés: /home/claude/check/tune (TStager.kt + Tune.kt).
    private const val LOCAL_WINDOW = 61
    private const val DEEP_HRV = -0.05
    private const val DEEP_HRV_SLOPE = 0.0
    private const val DEEP_HR = -0.5
    private const val REM_HRV = -0.1
    private const val REM_HRV_SLOPE = 0.3
    private const val REM_HR = -1.0
    private const val REM_NO_FIRST_MIN = 45
    private const val DEEP_NO_LAST_MIN = 45
    private const val MIN_RUN = 4

    private const val MIN_WINDOW_MINUTES = 90
    /** La noche empieza en el primer tramo de al menos estos minutos sin despertar. */
    private const val ONSET_RUN = 15
    private const val MIN_MOTION_COVERAGE = 0.6

    class Result(val startMinute: Long, val stages: IntArray) {
        val minutes get() = stages.size
        fun count(stage: Int) = stages.count { it == stage }
        val awakeMinutes get() = count(AWAKE)
        val lightMinutes get() = count(LIGHT)
        val deepMinutes get() = count(DEEP)
        val remMinutes get() = count(REM)
        val asleepMinutes get() = minutes - awakeMinutes
        val efficiencyPct get() = if (minutes > 0) (asleepMinutes * 100 / minutes).coerceIn(0, 100) else 0
        /** Número de despertares (tramos "despierto" seguidos). */
        val awakenings: Int
            get() {
                var n = 0
                for (i in stages.indices) if (stages[i] == AWAKE && (i == 0 || stages[i - 1] != AWAKE)) n++
                return n
            }
        val startMillis get() = startMinute * 60_000L
        val endMillis get() = (startMinute + minutes) * 60_000L
    }

    data class HrReading(val timeMillis: Long, val bpm: Int, val rr: List<Double>)

    private val tsFormat = ThreadLocal.withInitial { SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US) }

    /** Lee hr_log.csv (solo las lecturas entre [fromMillis] y [toMillis]). */
    fun parseHr(file: File, fromMillis: Long, toMillis: Long): List<HrReading> {
        if (!file.exists()) return emptyList()
        val fmt = tsFormat.get()!!
        val fromStr = fmt.format(java.util.Date(fromMillis))
        val toStr = fmt.format(java.util.Date(toMillis))
        val out = ArrayList<HrReading>()
        file.forEachLine { line ->
            if (line.length < 21 || line[0] != '2') return@forEachLine
            val ts = line.substring(0, 19)
            if (ts < fromStr || ts > toStr) return@forEachLine
            val c1 = line.indexOf(',', 19)
            if (c1 < 0) return@forEachLine
            val c2 = line.indexOf(',', c1 + 1)
            val bpmStr = if (c2 < 0) line.substring(c1 + 1) else line.substring(c1 + 1, c2)
            val bpm = bpmStr.trim().toIntOrNull() ?: return@forEachLine
            if (bpm <= 0 || bpm > 250) return@forEachLine
            val rr = if (c2 >= 0) {
                line.substring(c2 + 1).replace("\"", "").split('|')
                    .mapNotNull { it.replace(',', '.').toDoubleOrNull() }.filter { it in 300.0..2000.0 }
            } else emptyList()
            val t = try { fmt.parse(ts)?.time ?: return@forEachLine } catch (e: Exception) { return@forEachLine }
            out.add(HrReading(t, bpm, rr))
        }
        return out.sortedBy { it.timeMillis }.distinctBy { it.timeMillis / 1000 }
    }

    /** Todo el proceso: lee los archivos, y clasifica la ventana. null si no hay movimiento o datos suficientes. */
    private var cacheKey: String? = null
    private var cacheValue: Result? = null

    fun stageNight(hrFile: File, motionFile: File, startMillis: Long, endMillis: Long): Result? {
        if (!motionFile.exists()) return null
        // Inicio solo se llama una vez por minuto desde Inicio: se reaprovecha si no cambió la ventana ni el movimiento
        val key = "$startMillis-$endMillis-${motionFile.length()}-${hrFile.length() / 200_000L}"
        synchronized(this) { if (key == cacheKey) return cacheValue }
        val computed = computeNight(hrFile, motionFile, startMillis, endMillis)
        synchronized(this) { cacheKey = key; cacheValue = computed }
        return computed
    }

    private fun computeNight(hrFile: File, motionFile: File, startMillis0: Long, endMillis0: Long): Result? {
        val allMotion = MotionTracker.readMinutes(motionFile)
        val (startMillis, endMillis) = motionBounds(startMillis0, endMillis0, allMotion)
        val motion = allMotion.filter { it.minuteStartUnix / 60 in (startMillis / 60_000L)..(endMillis / 60_000L) }
        if (motion.isEmpty()) return null
        val readings = parseHr(hrFile, startMillis, endMillis)
        return stage(startMillis, endMillis, readings, motion)
    }

    /**
     * Inicio y fin de la noche por QUIETUD (21/10). Minuto quieto = ≥50 s sin moverse, giro < 2,5 °/s y 0 pasos
     * (dormido el giro está en su suelo, 1,3–1,7; en el sofá viendo la tele va de 3 a 10 aunque el pulso esté tan bajo como dormido).
     *  - Ancla = el primer tramo quieto de ≥15 min que llega a la ventana del pulso.
     *  - Inicio = desde el ancla hacia atrás, saltando cambios de postura (≤5 min moviéndose, ≤12 pasos), hasta el primer tramo
     *    quieto de ≥15 min (20/10: el sofá de 22:14 ya no cuenta → 23:11; 19→20 tras entrenar sigue en 23:11).
     *  - Fin = final del último tramo quieto de ≥15 min que empieza antes del fin del pulso, si después hay movimiento grabado
     *    (21/10: sentado desayunando 08:04–08:11 ya no alarga la noche), alargado por ratos quietos separados por ≤2 min de giros.
     */
    fun motionBounds(startMillis: Long, endMillis: Long, motion: List<MotionMinute>): Pair<Long, Long> {
        val byMin = HashMap<Long, MotionMinute>(motion.size * 2)
        for (mm in motion) byMin[mm.minuteStartUnix / 60] = mm
        fun still(m: MotionMinute?) = m != null && m.stillSecs >= 50 && m.gyroDps < 2.5f && m.steps == 0
        val m0 = startMillis / 60_000L; val m1 = endMillis / 60_000L
        // Tramos quietos (se tolera 1 minuto suelto que no lo sea)
        val runs = ArrayList<LongArray>()
        var k = m0 - 180
        while (k <= m1 + 120) {
            if (!still(byMin[k])) { k++; continue }
            val a = k; var b = k
            var j = k + 1
            while (j <= m1 + 120) {
                if (still(byMin[j])) { b = j; j++ }
                else if (still(byMin[j + 1])) j++
                else break
            }
            runs.add(longArrayOf(a, b)); k = b + 1
        }
        val long = runs.filter { it[1] - it[0] + 1 >= 15 }
        val anchor = long.firstOrNull { it[1] >= m0 && it[0] <= m1 } ?: return startMillis to endMillis
        // Inicio: hacia atrás desde el ancla
        var onset = anchor[0]
        var m = anchor[0] - 1
        while (true) {
            var b = m; var steps = 0
            while (byMin[b] != null && !still(byMin[b]) && m - b < 6) { steps += byMin[b]!!.steps; b-- }
            if (byMin[b] == null || m - b > 5 || steps > 12) break
            var q = b
            while (still(byMin[q])) q--
            if (b - q >= 15) onset = q + 1
            if (b == q) break
            m = q
        }
        // Fin: último tramo largo que empieza antes del fin del pulso
        var end = m1
        val last = long.filter { it[0] in onset..m1 }.maxByOrNull { it[0] }
        if (last != null && last[1] < m1) {
            val after = (last[1] + 1..m1).count { byMin[it] != null }
            if (after * 2 >= (m1 - last[1]).toInt()) {
                end = last[1]
                // Al despertar suele haber ratos quietos cortos entre giros (≤2 min, ≤15 pasos): siguen siendo noche
                while (true) {
                    var b = end + 1; var steps = 0
                    while (byMin[b] != null && !still(byMin[b]) && b - end <= 3) { steps += byMin[b]!!.steps; b++ }
                    if (b - end - 1 > 2 || steps > 15 || !still(byMin[b])) break
                    while (still(byMin[b + 1])) b++
                    end = b
                }
                end = minOf(end, m1)
            }
        }
        return onset * 60_000L to end * 60_000L
    }

    /**
     * Inicio del sueño por QUIETUD (20/10). Tras entrenar, el pulso sigue alto la primera hora de sueño y el detector
     * (solo pulso) empezaba tarde (00:00 en vez de 23:11). Hacia atrás desde el inicio: se aceptan ráfagas de movimiento
     * de ≤5 min con ≤12 pasos (cambios de postura) y, antes de cada una, un tramo de quietud total (≥50 s quieto, giro <3 °/s,
     * sin pasos) de ≥15 min. El inicio pasa al principio del tramo quieto más antiguo. Comprobado con las 5 noches con
     * movimiento: solo cambia la 19→20 (23:12; WHOOP 23:11); las demás quedan igual.
     */
    fun extendOnsetByStillness(startMillis: Long, motion: List<MotionMinute>): Long {
        val byMin = HashMap<Long, MotionMinute>(motion.size * 2)
        for (mm in motion) byMin[mm.minuteStartUnix / 60] = mm
        fun still(m: MotionMinute?) = m != null && m.stillSecs >= 50 && m.gyroDps < 3f && m.steps == 0
        var m = startMillis / 60_000L - 1
        var best = startMillis / 60_000L
        var first = true
        while (true) {
            var b = m; var stepsB = 0
            while (byMin[b] != null && !still(byMin[b]) && m - b < 6) { stepsB += byMin[b]!!.steps; b-- }
            if (byMin[b] == null || m - b > 5 || stepsB > 12) break
            var k = b
            while (still(byMin[k])) k--
            if (b - k < (if (first) 1 else 15)) break
            if (b - k >= 15) best = k + 1
            first = false
            m = k
        }
        return best * 60_000L
    }

    fun stage(startMillis: Long, endMillis: Long, readings: List<HrReading>, motion: List<MotionMinute>): Result? {
        val m0 = startMillis / 60_000L
        val m1 = endMillis / 60_000L
        val n = (m1 - m0 + 1).toInt()
        if (n < MIN_WINDOW_MINUTES) return null

        // ---- Pulso y RR por minuto ----
        val hrSum = DoubleArray(n); val hrCnt = IntArray(n)
        val rrLists = Array(n) { ArrayList<Double>() }
        for (r in readings) {
            val i = (r.timeMillis / 60_000L - m0).toInt()
            if (i < 0 || i >= n) continue
            hrSum[i] = hrSum[i] + r.bpm.toDouble()
            hrCnt[i] = hrCnt[i] + 1
            rrLists[i].addAll(r.rr)
        }
        val hrRaw = DoubleArray(n) { if (hrCnt[it] >= 20) hrSum[it] / hrCnt[it] else Double.NaN }
        if (hrRaw.count { !it.isNaN() } < n * 0.6) return null
        val hrm = interp(hrRaw)

        // ---- Movimiento por minuto ----
        val moveSecs = IntArray(n); val steps = IntArray(n); val hasMotion = BooleanArray(n)
        val gx = DoubleArray(n); val gy = DoubleArray(n); val gz = DoubleArray(n)
        for (mm in motion) {
            val i = (mm.minuteStartUnix / 60 - m0).toInt()
            if (i < 0 || i >= n) continue
            hasMotion[i] = true
            moveSecs[i] = (mm.seconds - mm.stillSecs).coerceAtLeast(0)
            steps[i] = mm.steps
            gx[i] = mm.gravX.toDouble(); gy[i] = mm.gravY.toDouble(); gz[i] = mm.gravZ.toDouble()
        }
        if (hasMotion.count { it } < n * MIN_MOTION_COVERAGE) return null
        val dg = DoubleArray(n)
        var prev = -1
        for (i in 0 until n) {
            if (!hasMotion[i]) continue
            if (prev >= 0) {
                val dx = gx[i] - gx[prev]; val dy = gy[i] - gy[prev]; val dz = gz[i] - gz[prev]
                dg[i] = sqrt(dx * dx + dy * dy + dz * dz)
            }
            prev = i
        }

        // ---- 1) Despertares ----
        val base = DoubleArray(n) { i ->
            val w = ArrayList<Double>()
            for (j in maxOf(0, i - 20)..minOf(n - 1, i + 20)) w.add(hrm[j])
            w.sort(); w[w.size / 3]
        }
        val sp = DoubleArray(n) { hrm[it] - base[it] }
        val ar = BooleanArray(n) { i ->
            val mv = moveSecs[i]
            ((mv >= WAKE_MOVE_SECS || steps[i] > 0) && sp[i] >= WAKE_SPIKE) ||
                mv >= WAKE_BIG_MOVE_SECS ||
                (sp[i] >= WAKE_SPIKE_HIGH && (mv >= 3 || dg[i] >= 0.8))
        }
        val eps = ArrayList<IntArray>()
        run {
            var i = 0
            while (i < n) {
                if (ar[i]) {
                    var j = i; var last = i
                    while (j < n && j - last <= WAKE_GAP) { if (ar[j]) last = j; j++ }
                    val s = maxOf(0, i - 1)
                    var e = last
                    var k = e + 1; var t = 0
                    while (k < n && t < WAKE_TAIL && sp[k] >= WAKE_SPIKE) { e = k; k++; t++ }
                    eps.add(intArrayOf(s, e))
                    i = last + 1
                } else i++
            }
        }
        val merged = ArrayList<IntArray>()
        for (ep in eps) {
            if (merged.isNotEmpty() && ep[0] <= merged.last()[1] + 1) merged.last()[1] = maxOf(merged.last()[1], ep[1])
            else merged.add(ep)
        }
        val aw = BooleanArray(n)
        for (ep in merged) {
            val len = ep[1] - ep[0] + 1
            var peak = 0.0
            for (k in ep[0]..ep[1]) if (sp[k] > peak) peak = sp[k]
            if (len >= WAKE_MIN_MINUTES || peak >= WAKE_MIN_SPIKE) for (k in ep[0]..ep[1]) aw[k] = true
        }

        // ---- 2) Señales de pulso y VFC ----
        val hrs = rollMedian(hrm, 5)
        val sumSq = DoubleArray(n); val cnt = IntArray(n)
        for (i in 0 until n) {
            val x = rrLists[i]
            for (k in 0 until x.size - 1) {
                val a = x[k]; val b = x[k + 1]
                if (abs(b - a) < 0.2 * a && a > 300 && a < 2000) { sumSq[i] += (b - a) * (b - a); cnt[i]++ }
            }
        }
        val lrmRaw = DoubleArray(n) { i ->
            var s = 0.0; var c = 0
            for (j in maxOf(0, i - 3)..minOf(n - 1, i + 3)) { s += sumSq[j]; c += cnt[j] }
            if (c >= 40) ln(sqrt(s / c)) else Double.NaN
        }
        if (lrmRaw.count { !it.isNaN() } < n * 0.4) return null
        val lrm = interp(lrmRaw)

        val awakeIdx = (0 until n).filter { !aw[it] }
        if (awakeIdx.isEmpty()) return Result(m0, IntArray(n) { AWAKE })
        val globalHr = median(awakeIdx.map { hrs[it] })
        val globalLr = median(awakeIdx.map { lrm[it] })
        val xh = DoubleArray(n); val xl = DoubleArray(n)
        val half = LOCAL_WINDOW / 2
        for (i in 0 until n) {
            val idx = (maxOf(0, i - half) until minOf(n, i + half + 1)).filter { !aw[it] }
            val hl = if (idx.isNotEmpty()) median(idx.map { hrs[it] }) else globalHr
            val ll = if (idx.isNotEmpty()) median(idx.map { lrm[it] }) else globalLr
            xh[i] = hrs[i] - hl
            xl[i] = lrm[i] - ll
        }

        // ---- Clasificación ----
        val st = IntArray(n) { if (aw[it]) AWAKE else LIGHT }
        for (i in 0 until n) {
            if (aw[i]) continue
            var near = false
            for (j in maxOf(0, i - 2)..minOf(n - 1, i + 2)) if (aw[j]) { near = true; break }
            if (near) continue
            val prog = i.toDouble() / maxOf(1, n - 1)
            val deepThr = DEEP_HRV + DEEP_HRV_SLOPE * (prog - 0.5)
            if (xl[i] >= deepThr && xh[i] <= DEEP_HR && i <= n - DEEP_NO_LAST_MIN) st[i] = DEEP
            else if (xl[i] <= REM_HRV + REM_HRV_SLOPE * (prog - 0.5) && xh[i] >= REM_HR && i >= REM_NO_FIRST_MIN) st[i] = REM
        }
        // Tramos cortos de profundo/REM → ligero
        var i = 0
        while (i < n) {
            var j = i
            while (j < n && st[j] == st[i]) j++
            if ((st[i] == DEEP || st[i] == REM) && j - i < MIN_RUN) for (k in i until j) st[k] = LIGHT
            i = j
        }
        // Recorte: fuera el rato en la cama antes de dormirse y después de despertarse
        val (a, b) = trimBounds(st)
        return Result(m0 + a, st.copyOfRange(a, b))
    }

    /** [inicio, fin) de la noche: del primer tramo de ≥[ONSET_RUN] min sin despertar al último minuto dormido. */
    fun trimBounds(st: IntArray): Pair<Int, Int> {
        val n = st.size
        var start = -1
        var i = 0
        while (i < n) {
            if (st[i] == AWAKE) { i++; continue }
            var j = i
            while (j < n && st[j] != AWAKE) j++
            if (j - i >= ONSET_RUN) { start = i; break }
            i = j
        }
        if (start < 0) return 0 to n
        var end = n
        while (end > start && st[end - 1] == AWAKE) end--
        return start to end
    }

    private fun median(v: List<Double>): Double {
        val s = v.sorted(); val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    private fun interp(v: DoubleArray): DoubleArray {
        val n = v.size; val out = v.copyOf()
        val idx = (0 until n).filter { !v[it].isNaN() }
        if (idx.isEmpty()) return out
        var lo = -1; var p = 0
        for (i in 0 until n) {
            if (!v[i].isNaN()) { lo = i; continue }
            while (p < idx.size && idx[p] < i) p++
            val hi = if (p < idx.size) idx[p] else -1
            out[i] = when {
                lo < 0 -> v[hi]
                hi < 0 -> v[lo]
                else -> v[lo] + (v[hi] - v[lo]) * (i - lo) / (hi - lo)
            }
        }
        return out
    }

    private fun rollMedian(v: DoubleArray, w: Int): DoubleArray {
        val h = w / 2
        return DoubleArray(v.size) { i ->
            val x = ArrayList<Double>()
            for (j in maxOf(0, i - h)..minOf(v.size - 1, i + h)) if (!v[j].isNaN()) x.add(v[j])
            if (x.isEmpty()) Double.NaN else median(x)
        }
    }
}
