package com.pulseapp.android

import java.io.File

/**
 * Pasos que cuenta la PROPIA pulsera (30/10). Cada registro v18 del historial trae en [57..58] (u16) el contador de pasos del ciclo
 * de WHOOP: sube ~2 por segundo andando y se pone a 0 al empezar ciclo. Comprobado con whoop_history_raw_6: el ciclo del 20/10 suma
 * 6029 pasos (WHOOP 6015) aunque faltaban horas de historial, y minuto a minuto sigue al contador de PulseApp (r 0,71).
 * Como el historial llega aunque el móvil esté lejos (p. ej. pádel o fútbol sin el móvil), así no se pierden esos pasos.
 *
 * band_steps.csv: "unix,contador" (segundos). Se escribe cuando el contador cambia o cambia el minuto. Al leer se ordena, se quitan
 * repetidos y los pasos de cada tramo = diferencia entre muestras seguidas (si baja, se reinició: cuenta el valor nuevo).
 */
object BandSteps {
    const val FILE_NAME = "band_steps.csv"
    private const val HEADER = "unix,counter"

    private var lastValue = -1
    private var lastMinute = -1L
    private val pending = StringBuilder()
    private var pendingLines = 0

    /** Contador de pasos de un registro v18 (null si el registro es demasiado corto). */
    fun counterOf(frame: ByteArray): Int? =
        if (frame.size < 59) null else (frame[57].toInt() and 0xFF) or ((frame[58].toInt() and 0xFF) shl 8)

    @Synchronized
    fun record(dir: File?, unix: Long, counter: Int) {
        if (dir == null || unix < 1_600_000_000L) return
        val minute = unix / 60
        if (counter == lastValue && minute == lastMinute) return
        lastValue = counter; lastMinute = minute
        pending.append(unix).append(',').append(counter).append('\n'); pendingLines++
        if (pendingLines >= 50) flush(dir)
    }

    @Synchronized
    fun flush(dir: File?) {
        if (dir == null || pendingLines == 0) return
        try {
            val f = File(dir, FILE_NAME)
            if (!f.exists() || f.length() == 0L) f.writeText(HEADER + "\n")
            f.appendText(pending.toString())
            pending.setLength(0); pendingLines = 0
        } catch (_: Exception) { }
    }

    /** Hueco máximo entre dos muestras seguidas para dar el tramo por cubierto por la pulsera (más = faltó historial). */
    private const val MAX_GAP_S = 1800L

    /**
     * [perMinute] = pasos de la pulsera por minuto (unix/60) en los tramos con historial seguido; [covered] = esos tramos [a, b] en
     * segundos; [gaps] = huecos sin historial (a, b, pasos que contó la pulsera entre medias, si no se reinició).
     */
    class Data(val perMinute: Map<Long, Int>, val covered: List<LongArray>, val gaps: List<LongArray>) {
        fun covers(unix: Long): Boolean {
            var lo = 0; var hi = covered.size - 1
            while (lo <= hi) {
                val mid = (lo + hi) / 2; val c = covered[mid]
                if (unix < c[0]) hi = mid - 1 else if (unix > c[1]) lo = mid + 1 else return true
            }
            return false
        }
    }

    fun read(dir: File?): Data {
        val f = dir?.let { File(it, FILE_NAME) }
        if (f == null || !f.exists()) return Data(emptyMap(), emptyList(), emptyList())
        val samples = java.util.TreeMap<Long, Int>()
        f.forEachLine { line ->
            val c = line.indexOf(',')
            if (c <= 0) return@forEachLine
            val t = line.substring(0, c).toLongOrNull() ?: return@forEachLine
            val v = line.substring(c + 1).trim().toIntOrNull() ?: return@forEachLine
            samples[t] = v
        }
        return fromSamples(samples)
    }

    fun fromSamples(samples: java.util.SortedMap<Long, Int>): Data {
        val per = HashMap<Long, Int>(); val covered = ArrayList<LongArray>(); val gaps = ArrayList<LongArray>()
        var pt = -1L; var pv = 0
        for ((t, v) in samples) {
            if (pt < 0) { covered.add(longArrayOf(t, t)) }
            else {
                val inc = if (v >= pv) v - pv else v   // si baja, la pulsera reinició el contador (ciclo nuevo)
                if (t - pt <= MAX_GAP_S) {
                    if (inc > 0) per[t / 60] = (per[t / 60] ?: 0) + inc
                    covered.last()[1] = t
                } else {
                    gaps.add(longArrayOf(pt, t, inc.toLong()))
                    covered.add(longArrayOf(t, t))
                }
            }
            pt = t; pv = v
        }
        return Data(per, covered, gaps)
    }

    /**
     * Pasos entre [fromMs, toMs): los de la pulsera donde hay historial suyo seguido, los del acelerómetro de PulseApp ([imu]) donde
     * no (antes/después de su historial o en huecos), y en un hueco sin nada de PulseApp, lo que contó la pulsera entre medias.
     */
    fun merged(band: Data, imu: List<MotionMinute>, fromMs: Long, toMs: Long): Int {
        val m0 = fromMs / 60_000L; val m1 = toMs / 60_000L
        var s = 0
        for ((m, v) in band.perMinute) if (m in m0 until m1) s += v
        for (x in imu) {
            val m = x.minuteStartUnix / 60
            if (m in m0 until m1 && !band.covers(x.minuteStartUnix) && !band.covers(x.minuteStartUnix + 59)) s += x.steps
        }
        // Hueco sin historial: la pulsera y PulseApp solo pueden contar de menos ahí (PulseApp si el móvil estuvo lejos, la pulsera si
        // se reinició el contador entre medias) → se queda el mayor de los dos.
        for (g in band.gaps) {
            if (g[1] / 60 !in m0 until m1) continue
            val imuInGap = imu.filter { it.minuteStartUnix in g[0]..g[1] }.sumOf { it.steps }
            s += (g[2].toInt() - imuInGap).coerceAtLeast(0)
        }
        return s
    }

    /** Pasos por día (zona local), con las mismas reglas que [merged]. */
    fun perDay(band: Data, imu: List<MotionMinute>, zone: java.time.ZoneId): Map<java.time.LocalDate, Int> {
        val out = HashMap<java.time.LocalDate, Int>()
        fun day(unix: Long) = java.time.Instant.ofEpochSecond(unix).atZone(zone).toLocalDate()
        for ((m, v) in band.perMinute) { val d = day(m * 60); out[d] = (out[d] ?: 0) + v }
        val imuSorted = imu.sortedBy { it.minuteStartUnix }
        val imuMinutes = imuSorted.map { it.minuteStartUnix }
        for (x in imu) {
            if (band.covers(x.minuteStartUnix) || band.covers(x.minuteStartUnix + 59)) continue
            val d = day(x.minuteStartUnix); out[d] = (out[d] ?: 0) + x.steps
        }
        for (g in band.gaps) {
            var k = java.util.Collections.binarySearch(imuMinutes, g[0]); if (k < 0) k = -k - 1
            var imuInGap = 0
            while (k < imuMinutes.size && imuMinutes[k] <= g[1]) { imuInGap += imuSorted[k].steps; k++ }
            val extra = (g[2].toInt() - imuInGap).coerceAtLeast(0)   // el mayor de los dos (ver merged)
            if (extra > 0) { val d = day(g[1]); out[d] = (out[d] ?: 0) + extra }
        }
        return out
    }

    /** ¿Hay historial de la pulsera dentro de [fromMs, toMs)? */
    fun hasData(band: Data, fromMs: Long, toMs: Long): Boolean =
        band.covered.any { it[0] * 1000 < toMs && it[1] * 1000 >= fromMs }
}
