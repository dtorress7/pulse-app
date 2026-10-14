package com.pulseapp.android

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.sqrt

data class DailySummary(
    val restingHr: Int?,
    val avgHr: Int?,
    val avgHrv: Double?,
    val vo2Max: Double?,
    val strain: Double,
    val sleepMinutes: Int?, // tiempo REALMENTE dormido (sin los minutos "despierto" detectados)
    val timeInBedMinutes: Int?, // duración total de la ventana, como el "Total" de Whoop
    val awakeMinutes: Int?,
    val sleepStart: String?,
    val sleepEnd: String?,
    val sleepStartMinuteOfDay: Int?,
    val sleepEndMinuteOfDay: Int?,
    val sleepEfficiencyPct: Int?,
    val respiratoryRate: Double?,
    val totalReadings: Int
)

private data class Reading(val timeMillis: Long, val bpm: Int, val rr: List<Double>)

class MetricsCalculator(ageYears: Int, private val male: Boolean = true) {

    private val hrMax: Double = Formulas.hrMax(ageYears)
    private val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)

    companion object {
        private const val REST_THRESHOLD_MULTIPLIER = 1.25
        private const val REST_GRACE_MINUTES = 20
        private const val REST_MIN_DURATION_MINUTES = 90
        private const val DISCONNECT_GAP_MINUTES = 3
    }

    fun analyze(file: File): DailySummary {
        val readings = parseCsv(file)
        if (readings.isEmpty()) {
            return DailySummary(null, null, null, null, 0.0, null, null, null, null, null, null, null, null, null, 0)
        }

        val avgHr = readings.map { it.bpm }.average().toInt()
        val restWindow = findLongestRestWindow(readings)

        // FC en reposo y HRV se calculan SOLO con la ventana de sueño detectada
        // (igual que Whoop) — usar el día entero dispara ambos valores artificialmente.
        val sleepReadings = if (restWindow != null) {
            readings.filter { it.timeMillis in restWindow.first..restWindow.second }
        } else {
            emptyList()
        }
        val restingHr = if (sleepReadings.isNotEmpty()) findRestingHr(sleepReadings) else findRestingHr(readings)
        val avgHrv = if (sleepReadings.isNotEmpty()) {
            computeRMSSD(sleepReadings.flatMap { it.rr })
        } else {
            computeRMSSD(readings.flatMap { it.rr })
        }
        val vo2Max = restingHr?.let { 15.3 * (hrMax / it) }
        val strain = computeStrain(readings, restingHr)

        val calStart = restWindow?.first?.let { java.util.Calendar.getInstance().apply { timeInMillis = it } }
        val calEnd = restWindow?.second?.let { java.util.Calendar.getInstance().apply { timeInMillis = it } }
        val sleepEfficiency = restWindow?.let { computeSleepEfficiency(readings, it.first, it.second) }
        val respiratoryRate = if (sleepReadings.isNotEmpty()) {
            RespiratoryRateCalculator().estimate(sleepReadings.flatMap { it.rr })
        } else null

        val timeInBedMinutes = restWindow?.let { ((it.second - it.first) / 60000).toInt() }
        val awakeMinutes = restWindow?.let { computeAwakeMinutes(readings, it.first, it.second) }
        val actualSleepMinutes = if (timeInBedMinutes != null && awakeMinutes != null) {
            (timeInBedMinutes - awakeMinutes).coerceAtLeast(0)
        } else timeInBedMinutes

        return DailySummary(
            restingHr = restingHr,
            avgHr = avgHr,
            avgHrv = avgHrv,
            vo2Max = vo2Max,
            strain = strain,
            sleepMinutes = actualSleepMinutes,
            timeInBedMinutes = timeInBedMinutes,
            awakeMinutes = awakeMinutes,
            sleepStart = restWindow?.first?.let { sdf.format(Date(it)) },
            sleepEnd = restWindow?.second?.let { sdf.format(Date(it)) },
            sleepStartMinuteOfDay = calStart?.let { it.get(java.util.Calendar.HOUR_OF_DAY) * 60 + it.get(java.util.Calendar.MINUTE) },
            sleepEndMinuteOfDay = calEnd?.let { it.get(java.util.Calendar.HOUR_OF_DAY) * 60 + it.get(java.util.Calendar.MINUTE) },
            sleepEfficiencyPct = sleepEfficiency,
            respiratoryRate = respiratoryRate,
            totalReadings = readings.size
        )
    }

    private fun parseCsv(file: File): List<Reading> {
        if (!file.exists()) return emptyList()
        val result = mutableListOf<Reading>()
        file.forEachLine { line ->
            if (line.startsWith("timestamp") || line.isBlank()) return@forEachLine
            val parts = splitCsvLine(line)
            if (parts.size < 2) return@forEachLine
            try {
                val time = sdf.parse(parts[0])?.time ?: return@forEachLine
                val bpm = parts[1].toIntOrNull() ?: return@forEachLine
                if (bpm <= 0 || bpm > 250) return@forEachLine
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
                c == ',' && !inQuotes -> {
                    result.add(current.toString())
                    current.setLength(0)
                }
                else -> current.append(c)
            }
        }
        result.add(current.toString())
        return result
    }

    /** Descarta intervalos RR que difieren >20% del anterior (artefactos de movimiento, no HRV real). */
    private fun filterRRArtifacts(rr: List<Double>): List<Double> {
        if (rr.size < 2) return rr
        val filtered = mutableListOf(rr[0])
        for (i in 1 until rr.size) {
            val prev = filtered.last()
            val diffPct = kotlin.math.abs(rr[i] - prev) / prev
            if (diffPct <= 0.20) filtered.add(rr[i])
        }
        return filtered
    }

    private fun computeRMSSD(rrRaw: List<Double>): Double? {
        val rr = filterRRArtifacts(rrRaw)
        if (rr.size < 2) return null
        var sumSq = 0.0
        for (i in 1 until rr.size) {
            val diff = rr[i] - rr[i - 1]
            sumSq += diff * diff
        }
        return sqrt(sumSq / (rr.size - 1))
    }

    /**
     * FC en reposo = mediana de toda la ventana (más fiel a Whoop que el mínimo,
     * que puede ser un instante puntual poco representativo).
     */
    private fun findRestingHr(readings: List<Reading>): Int? {
        if (readings.isEmpty()) return null
        val sortedBpm = readings.map { it.bpm }.sorted()
        val mid = sortedBpm.size / 2
        return if (sortedBpm.size % 2 == 0) {
            (sortedBpm[mid - 1] + sortedBpm[mid]) / 2
        } else {
            sortedBpm[mid]
        }
    }

    /** Esfuerzo del día con TRIMP de Banister + escala logarítmica (ver Formulas). */
    private fun computeStrain(readings: List<Reading>, restingHr: Int?): Double =
        Formulas.strainOf(readings.map { it.timeMillis to it.bpm }, restingHr, hrMax, male)

    /** Solo se considera "posible sueño" lo que ocurre entre las 20:00 y las 12:00 del día siguiente. */
    private fun isNightHour(timeMillis: Long): Boolean {
        val cal = java.util.Calendar.getInstance().apply { timeInMillis = timeMillis }
        val hour = cal.get(java.util.Calendar.HOUR_OF_DAY)
        return hour >= 20 || hour < 10
    }

    private fun findLongestRestWindow(readings: List<Reading>): Pair<Long, Long>? {
        val nightReadings = readings.filter { isNightHour(it.timeMillis) }
        if (nightReadings.size < 2) return null

        val buckets = LinkedHashMap<Long, MutableList<Int>>()
        for (r in nightReadings) {
            val minuteKey = r.timeMillis / 60000
            buckets.getOrPut(minuteKey) { mutableListOf() }.add(r.bpm)
        }
        val series = buckets.entries.sortedBy { it.key }
            .map { (key, values) -> key to (values.sum().toDouble() / values.size) }

        val sortedBpm = nightReadings.map { it.bpm }.sorted()
        val tenPercentCount = (sortedBpm.size * 0.10).toInt().coerceAtLeast(1)
        val restingHr = sortedBpm.take(tenPercentCount).average()
        val threshold = restingHr * REST_THRESHOLD_MULTIPLIER

        var bestDurationMin = 0L
        var bestStart: Long? = null
        var bestEnd: Long? = null

        var currentStart: Long? = null
        var aboveSince: Long? = null
        var prevKey: Long? = null

        for ((key, avg) in series) {
            val gapMinutes = prevKey?.let { key - it } ?: 0
            if (prevKey != null && gapMinutes > DISCONNECT_GAP_MINUTES) {
                if (currentStart != null && prevKey != null) {
                    val d = prevKey - currentStart
                    if (d >= REST_MIN_DURATION_MINUTES) { bestDurationMin = d; bestStart = currentStart; bestEnd = prevKey }
                }
                currentStart = key
                aboveSince = null
            } else {
                if (avg <= threshold) {
                    aboveSince = null
                    if (currentStart == null) currentStart = key
                } else if (currentStart != null) {
                    if (aboveSince == null) {
                        aboveSince = key
                    } else if (key - aboveSince!! > REST_GRACE_MINUTES) {
                        val d = aboveSince!! - currentStart!!
                        if (d >= REST_MIN_DURATION_MINUTES) { bestDurationMin = d; bestStart = currentStart; bestEnd = aboveSince }
                        currentStart = null
                        aboveSince = null
                    }
                }
            }
            prevKey = key
        }
        if (currentStart != null && prevKey != null) {
            val d = prevKey - currentStart!!
            if (d >= REST_MIN_DURATION_MINUTES) { bestDurationMin = d; bestStart = currentStart; bestEnd = prevKey }
        }

        if (bestDurationMin < REST_MIN_DURATION_MINUTES) return null
        return Pair(bestStart!! * 60000, bestEnd!! * 60000)
    }
    /**
     * % de minutos dentro de la ventana de sueño que estuvieron realmente por debajo
     * del umbral de reposo (sin contar los picos breves tolerados) — es nuestra
     * aproximación a "Sleep Efficiency": cuánto de ese tiempo fue descanso real
     * frente a movimiento/activación.
     */
    private fun computeSleepEfficiency(readings: List<Reading>, windowStart: Long, windowEnd: Long): Int {
        val windowReadings = readings.filter { it.timeMillis in windowStart..windowEnd }
        if (windowReadings.isEmpty()) return 0

        val buckets = LinkedHashMap<Long, MutableList<Int>>()
        for (r in windowReadings) {
            val minuteKey = r.timeMillis / 60000
            buckets.getOrPut(minuteKey) { mutableListOf() }.add(r.bpm)
        }
        val minuteAverages = buckets.values.map { it.sum().toDouble() / it.size }

        val sortedBpm = windowReadings.map { it.bpm }.sorted()
        val tenPercentCount = (sortedBpm.size * 0.10).toInt().coerceAtLeast(1)
        val restingHr = sortedBpm.take(tenPercentCount).average()
        val threshold = restingHr * REST_THRESHOLD_MULTIPLIER

        val belowCount = minuteAverages.count { it <= threshold }
        return ((belowCount.toDouble() / minuteAverages.size) * 100).toInt().coerceIn(0, 100)
    }
    /** Minutos dentro de la ventana con FC por encima del umbral de reposo (aprox. "despierto"). */
    private fun computeAwakeMinutes(readings: List<Reading>, windowStart: Long, windowEnd: Long): Int {
        val windowReadings = readings.filter { it.timeMillis in windowStart..windowEnd }
        if (windowReadings.isEmpty()) return 0

        val buckets = LinkedHashMap<Long, MutableList<Int>>()
        for (r in windowReadings) {
            val minuteKey = r.timeMillis / 60000
            buckets.getOrPut(minuteKey) { mutableListOf() }.add(r.bpm)
        }
        val minuteAverages = buckets.values.map { it.sum().toDouble() / it.size }

        val sortedBpm = windowReadings.map { it.bpm }.sorted()
        val tenPercentCount = (sortedBpm.size * 0.10).toInt().coerceAtLeast(1)
        val threshold = sortedBpm.take(tenPercentCount).average() * REST_THRESHOLD_MULTIPLIER

        return minuteAverages.count { it > threshold }
    }
}
