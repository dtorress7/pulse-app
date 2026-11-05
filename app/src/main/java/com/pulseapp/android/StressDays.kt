package com.pulseapp.android

import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.DailyMetrics
import java.io.File
import java.time.LocalDate
import java.time.ZoneId

/**
 * Reparto del estrés de cada día (bajo / medio / alto en minutos, para Día total, Sin actividad y Sueño), para la "Vista de
 * tendencias" del Monitor de estrés (5/11). Los días cerrados se guardan en stress_days.csv (no se recalculan cada vez);
 * hoy se calcula siempre. Días sin pulso = null.
 */
object StressDays {
    private const val FILE = "stress_days.csv"
    private const val HEADER = "#pulseapp_stress_days v1"

    private fun readCache(dir: File): MutableMap<String, StressBreakdown.Day?> {
        val f = File(dir, FILE)
        val out = HashMap<String, StressBreakdown.Day?>()
        if (!f.exists()) return out
        val lines = f.readLines()
        if (lines.firstOrNull() != HEADER) return out
        for (l in lines.drop(1)) {
            val p = l.split(',')
            if (p.size == 2 && p[1] == "-") { out[p[0]] = null; continue }
            if (p.size < 10) continue
            val v = p.drop(1).map { it.toIntOrNull() ?: 0 }
            out[p[0]] = StressBreakdown.Day(StressBreakdown.Mins(v[0], v[1], v[2]), StressBreakdown.Mins(v[3], v[4], v[5]),
                StressBreakdown.Mins(v[6], v[7], v[8]))
        }
        return out
    }

    private fun writeCache(dir: File, m: Map<String, StressBreakdown.Day?>) {
        val sb = StringBuilder(HEADER).append('\n')
        for ((k, d) in m.toSortedMap()) {
            if (d == null) { sb.append(k).append(",-\n"); continue }
            sb.append(k)
            for (x in listOf(d.total, d.noActivity, d.sleep)) sb.append(',').append(x.low).append(',').append(x.mid).append(',').append(x.high)
            sb.append('\n')
        }
        runCatching { File(dir, FILE).writeText(sb.toString()) }
    }

    /** Ventana de sueño de un día guardado (la noche que acaba ese día). */
    fun sleepOf(row: DailyMetrics?, dayStart: Long): LongRange? {
        val ss = row?.sleepStartMinuteOfDay ?: return null
        val se = row.sleepEndMinuteOfDay ?: return null
        val end = dayStart + se * 60_000L
        val start = if (ss > se) dayStart - (1440 - ss) * 60_000L else dayStart + ss * 60_000L
        return if (end > start) start..end else null
    }

    /** Reparto de cada día de [days] (hoy incluido, hasta ahora). */
    fun load(dir: File, days: List<LocalDate>, stored: Map<String, DailyMetrics>, sessions: List<ActivitySession>,
             baseline: PersonalBaseline?, zone: ZoneId = ZoneId.systemDefault()): Map<LocalDate, StressBreakdown.Day?> {
        val today = LocalDate.now(zone)
        val cache = readCache(dir)
        val firstData = stored.keys.minOrNull()
        val missing = days.filter { it <= today && (it == today || !cache.containsKey(it.toString())) }
        // Antes de tu primer día guardado no hay pulso: no hace falta leer el archivo
        val toCompute = missing.filter { firstData == null || it.toString() >= LocalDate.parse(firstData).minusDays(1).toString() || it == today }
        val res = HashMap<LocalDate, StressBreakdown.Day?>()
        val now = System.currentTimeMillis()
        val calc = StressCalculator()
        val acts = sessions.filter { it.type != Formulas.NAP_TYPE }.map { it.startMillis..it.endMillis }
        val naps = sessions.filter { it.type == Formulas.NAP_TYPE }.map { it.startMillis..it.endMillis }
        // De 7 en 7 días para no llenar la memoria (cada día son ~86 400 lecturas con sus RR)
        for (chunk in toCompute.chunked(7)) {
            val ranges = chunk.map { d -> d.atStartOfDay(zone).toInstant().toEpochMilli()..minOf(now, d.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()) }
            val samples = calc.loadSamplesIn(File(dir, "hr_log.csv"), ranges)
            for ((i, d) in chunk.withIndex()) {
                val r = ranges[i]
                val series = calc.seriesBetween(samples, r.first, r.last, null, baseline)
                val day = if (series.size < 12) null else {
                    val next = stored[d.plusDays(1).toString()]
                    val sleep = listOfNotNull(sleepOf(stored[d.toString()], r.first),
                        sleepOf(next, d.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli())) + naps
                    StressBreakdown.of(series, sleep, acts)
                }
                res[d] = day
                if (d != today) cache[d.toString()] = day
            }
        }
        if (toCompute.isNotEmpty()) {
            // Solo se guardan los días cerrados hace ≥ 2 días (al de ayer aún le puede llegar historial de la pulsera)
            writeCache(dir, cache.filterKeys { it <= today.minusDays(2).toString() })
        }
        for (d in days) if (!res.containsKey(d)) res[d] = cache[d.toString()]
        return res
    }
}
