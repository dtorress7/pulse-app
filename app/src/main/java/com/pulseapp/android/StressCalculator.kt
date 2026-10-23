package com.pulseapp.android

import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.sqrt

data class StressPoint(val minuteOfDay: Int, val score: Float, val timeMillis: Long = 0L) // score 0..3

data class StressSummary(
    val currentScore: Float?,      // score de la última ventana (0..3)
    val level: String,             // "BAJO" / "MEDIO" / "ALTO"
    val lastUpdateMinute: Int?,    // minuto del día (0-1439) de la última lectura
    val series: List<StressPoint>  // un punto cada 5 min de las ÚLTIMAS 24 h
)

/**
 * Estrés 0–3 por ventanas de 5 minutos: pulso y VFC de la ventana frente a tu línea base.
 *
 * 23/10, ajustado con la curva de WHOOP del 22/10 21:38 → 23/10 09:32 (fútbol, noche y mañana; 135 ventanas) y validado
 * con el estrés del sueño de 4 noches de WHOOP (medio 25/10/104/~200 min → 25/10/115/190):
 *   z = 3,4 · (FC − FCR base) / (FCmáx − FCR base) + 0,2 · ln(VFC base / VFC de la ventana)
 *   estrés = 0,3 + 2,7 · (1 − e^(−z))   (z < 0 → 0,3)
 * WHOOP nunca baja de ~0,3 dormido y se satura poco a poco: antes (4,8·(0,7·subida de pulso + 0,3·caída de VFC))
 * dormido salía 0 y cualquier pulso >100 daba 3,0. Error medio frente a la curva de WHOOP: 0,34 → 0,15.
 * Solo se usan las últimas 24 h.
 */
class StressCalculator {

    private data class Reading(val timeMillis: Long, val bpm: Int, val rr: List<Double>)

    companion object {
        const val FLOOR = 0.3
        const val K_HR = 3.4
        const val K_HRV = 0.2
    }

    fun analyze(file: File, restingHr: Int?, baseline: PersonalBaseline? = null): StressSummary {
        val now = System.currentTimeMillis()
        val readings = parseCsv(file).filter { it.timeMillis >= now - 24 * 3_600_000L }
        if (readings.isEmpty()) return StressSummary(null, "BAJO", null, emptyList())

        val baselineRhr = baseline?.avgRestingHr ?: Formulas.FALLBACK_RHR
        val baselineHrv = baseline?.avgHrv ?: Formulas.FALLBACK_HRV

        val windowMillis = 5 * 60 * 1000L
        val series = readings.groupBy { it.timeMillis / windowMillis }.entries.sortedBy { it.key }
            .filter { it.value.size >= 30 }   // ventanas con al menos ~30 s de datos
            .map { (windowKey, w) ->
                val score = computeScore(w.map { it.bpm }.average(), computeRMSSD(w.flatMap { it.rr }), baselineRhr, baselineHrv)
                val t = windowKey * windowMillis
                val cal = Calendar.getInstance().apply { timeInMillis = t }
                StressPoint(cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE), score, t)
            }

        val current = series.lastOrNull()
        val level = when {
            current == null || current.score < 1f -> "BAJO"
            current.score < 2f -> "MEDIO"
            else -> "ALTO"
        }
        return StressSummary(current?.score, level, current?.minuteOfDay, series)
    }

    /** Lecturas del archivo desde [sinceMillis] (para calcular el estrés de días anteriores con una sola lectura). */
    class Sample(val timeMillis: Long, val bpm: Int, val rr: List<Double>)

    fun loadSamples(file: File, sinceMillis: Long): List<Sample> = loadSamples(file, sinceMillis, null)

    private fun loadSamples(file: File, sinceMillis: Long, keep: ((Long) -> Boolean)?): List<Sample> {
        if (!file.exists()) return emptyList()
        // Las líneas empiezan por la fecha local "yyyy-MM-dd": las de días anteriores se saltan sin convertir la hora (rápido)
        val minKey = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(sinceMillis - 86_400_000L))
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        val out = ArrayList<Sample>()
        file.forEachLine { line ->
            if (line.length < 20 || line[10] != 'T') return@forEachLine
            if (line < minKey) return@forEachLine   // "2026-10-14T…" < "2026-10-15"; "2026-10-15T…" no
            val parts = splitCsvLine(line)
            if (parts.size < 2) return@forEachLine
            try {
                val time = sdf.parse(parts[0])?.time ?: return@forEachLine
                if (time < sinceMillis || (keep != null && !keep(time))) return@forEachLine
                val bpm = parts[1].toIntOrNull() ?: return@forEachLine
                if (bpm <= 0 || bpm > 250) return@forEachLine
                val rr = if (parts.size > 2) parts[2].split("|").mapNotNull { it.replace(',', '.').toDoubleOrNull() }.filter { it in 300.0..2000.0 }
                else emptyList()
                out.add(Sample(time, bpm, rr))
            } catch (e: Exception) { }
        }
        return out.sortedBy { it.timeMillis }.distinctBy { it.timeMillis / 1000 }
    }

    /** Como [loadSamples] pero guardando solo lo que cae dentro de [ranges] (p. ej. 7 noches) para no llenar la memoria. */
    fun loadSamplesIn(file: File, ranges: List<LongRange>): List<Sample> {
        if (ranges.isEmpty()) return emptyList()
        return loadSamples(file, ranges.minOf { it.first }) { t -> ranges.any { t in it } }
    }

    /** Serie de estrés (un punto cada 5 min) entre [from] y [to] con la misma fórmula que [analyze]. */
    fun seriesBetween(samples: List<Sample>, from: Long, to: Long, restingHr: Int?, baseline: PersonalBaseline?): List<StressPoint> {
        val baselineRhr = baseline?.avgRestingHr ?: Formulas.FALLBACK_RHR
        val baselineHrv = baseline?.avgHrv ?: Formulas.FALLBACK_HRV
        val windowMillis = 5 * 60 * 1000L
        return samples.filter { it.timeMillis in from until to }
            .groupBy { it.timeMillis / windowMillis }.entries.sortedBy { it.key }
            .filter { it.value.size >= 30 }
            .map { (windowKey, w) ->
                val score = computeScore(w.map { it.bpm }.average(), computeRMSSD(w.flatMap { it.rr }), baselineRhr, baselineHrv)
                val t = windowKey * windowMillis
                val cal = Calendar.getInstance().apply { timeInMillis = t }
                StressPoint(cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE), score, t)
            }
    }

    private fun computeScore(avgHr: Double, windowHrv: Double?, baselineRhr: Double, baselineHrv: Double): Float {
        val reserve = (Formulas.hrMaxOrDefault() - baselineRhr).coerceAtLeast(60.0)
        var z = K_HR * (avgHr - baselineRhr) / reserve
        if (windowHrv != null && windowHrv > 0) z += K_HRV * ln(baselineHrv / windowHrv)
        return (FLOOR + (3.0 - FLOOR) * (1.0 - exp(-z.coerceAtLeast(0.0)))).toFloat().coerceIn(0f, 3f)
    }

    /** RMSSD descartando saltos > 20 % (artefactos), mínimo 10 diferencias válidas. */
    private fun computeRMSSD(rr: List<Double>): Double? {
        var sum = 0.0; var n = 0
        for (i in 1 until rr.size) {
            val d = rr[i] - rr[i - 1]
            if (kotlin.math.abs(d) <= 0.2 * rr[i - 1]) { sum += d * d; n++ }
        }
        return if (n >= 10) sqrt(sum / n) else null
    }

    private fun parseCsv(file: File): List<Reading> {
        if (!file.exists()) return emptyList()
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        val result = mutableListOf<Reading>()
        file.forEachLine { line ->
            if (line.startsWith("timestamp") || line.isBlank()) return@forEachLine
            val parts = splitCsvLine(line)
            if (parts.size < 2) return@forEachLine
            try {
                val time = sdf.parse(parts[0])?.time ?: return@forEachLine
                val bpm = parts[1].toIntOrNull() ?: return@forEachLine
                val rr = if (parts.size > 2) {
                    parts[2].split("|").mapNotNull { it.replace(',', '.').toDoubleOrNull() }
                        .filter { it in 300.0..2000.0 }
                } else emptyList()
                result.add(Reading(time, bpm, rr))
            } catch (e: Exception) { }
        }
        return result.sortedBy { it.timeMillis }
    }

    private fun splitCsvLine(line: String): List<String> {
        val result = mutableListOf<String>()
        val current = StringBuilder()
        var inQuotes = false
        for (c in line) {
            when {
                c == '"' -> inQuotes = !inQuotes
                c == ',' && !inQuotes -> { result.add(current.toString()); current.setLength(0) }
                else -> current.append(c)
            }
        }
        result.add(current.toString())
        return result
    }
}
