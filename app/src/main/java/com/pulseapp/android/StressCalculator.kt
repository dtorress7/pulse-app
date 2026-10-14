package com.pulseapp.android

import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.sqrt

data class StressPoint(val minuteOfDay: Int, val score: Float) // score 0..3

data class StressSummary(
    val currentScore: Float?,      // score de la última ventana (0..3)
    val level: String,             // "BAJO" / "MEDIO" / "ALTO"
    val lastUpdateMinute: Int?,    // minuto del día (0-1439) de la última lectura
    val series: List<StressPoint>  // un punto cada 5 min, para la mini-gráfica
)

/**
 * Calcula un "Stress Score" 0-3 por ventanas de 5 minutos, comparando la FC y el HRV
 * de cada ventana con una línea base.
 *
 * IMPORTANTE — esto es una aproximación, no el algoritmo real de ninguna marca comercial:
 * - La "línea base" debería ser HRV media de los últimos 14 días. Por ahora se calcula
 *   con todo el histórico disponible en el CSV (no hay aún almacenamiento diario persistente).
 * - Umbrales: <1 bajo, 1-2 medio, >=2 alto (igual que el spec pedido).
 */
class StressCalculator {

    private data class Reading(val timeMillis: Long, val bpm: Int, val rr: List<Double>)

    fun analyze(file: File, restingHr: Int?, baseline: PersonalBaseline? = null): StressSummary {
        val readings = parseCsv(file)
        if (readings.isEmpty() || restingHr == null) {
            return StressSummary(null, "BAJO", null, emptyList())
        }

        // Usa la línea base personal de 14 días si ya existe; si no, respaldo con la sesión actual
        val baselineHrv = baseline?.avgHrv ?: (computeRMSSD(readings.flatMap { it.rr }) ?: 40.0)
        val baselineRhr = baseline?.avgRestingHr ?: restingHr.toDouble()

        val windowMillis = 5 * 60 * 1000L
        val windows = readings.groupBy { it.timeMillis / windowMillis }

        val series = windows.entries.sortedBy { it.key }.mapNotNull { (windowKey, windowReadings) ->
            val avgHr = windowReadings.map { it.bpm }.average()
            val windowRR = windowReadings.flatMap { it.rr }
            val windowHrv = computeRMSSD(windowRR)

            val score = computeScore(avgHr, windowHrv, baselineRhr, baselineHrv)

            val cal = Calendar.getInstance()
            cal.timeInMillis = windowKey * windowMillis
            val minuteOfDay = cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)

            StressPoint(minuteOfDay, score)
        }

        val current = series.lastOrNull()
        val level = when {
            current == null -> "BAJO"
            current.score < 1f -> "BAJO"
            current.score < 2f -> "MEDIO"
            else -> "ALTO"
        }

        return StressSummary(current?.score, level, current?.minuteOfDay, series)
    }

    private fun computeScore(avgHr: Double, windowHrv: Double?, baselineRhr: Double, baselineHrv: Double): Float {
        val hrElevation = ((avgHr - baselineRhr) / baselineRhr).coerceIn(0.0, 1.0)
        val hrvDrop = if (windowHrv != null) {
            ((baselineHrv - windowHrv) / baselineHrv).coerceIn(0.0, 1.0)
        } else {
            hrElevation
        }
        val combined = (hrElevation * 0.5 + hrvDrop * 0.5) * 3.0
        return combined.toFloat().coerceIn(0f, 3f)
    }

    private fun computeRMSSD(rr: List<Double>): Double? {
        if (rr.size < 2) return null
        var sumSq = 0.0
        for (i in 1 until rr.size) {
            val diff = rr[i] - rr[i - 1]
            sumSq += diff * diff
        }
        return sqrt(sumSq / (rr.size - 1))
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
