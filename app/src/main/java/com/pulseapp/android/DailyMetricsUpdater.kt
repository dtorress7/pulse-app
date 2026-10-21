package com.pulseapp.android

import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.data.DailyMetrics
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.sqrt

class DailyMetricsUpdater {

    private data class Reading(val timeMillis: Long, val bpm: Int, val rr: List<Double>)

    companion object {
        private const val REST_THRESHOLD_MULTIPLIER = 1.25
        private const val REST_GRACE_MINUTES = 20
        private const val REST_MIN_DURATION_MINUTES = 90
        private const val DISCONNECT_GAP_MINUTES = 3
    }

    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)
    private val timestampFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)

    suspend fun updateYesterdayIfNeeded(
        db: AppDatabase, csvFile: File, ageYears: Int, weightKg: Float, sex: String
    ) {
        val yesterdayCal = Calendar.getInstance()
        yesterdayCal.add(Calendar.DAY_OF_YEAR, -1)
        val yesterdayKey = dayFormat.format(yesterdayCal.time)

        val existing = db.dailyMetricsDao().getByDate(yesterdayKey)
        if (existing != null) return

        val allReadings = parseCsv(csvFile)
        val dayReadings = allReadings.filter { dayFormat.format(Date(it.timeMillis)) == yesterdayKey }
        if (dayReadings.isEmpty()) return

        val hrMax = Formulas.hrMax(ageYears)

        // La noche que TERMINÓ ese día (se duerme la víspera y se despierta ese día): de las 18:00 de la víspera
        // a las 14:00. Antes se buscaba solo dentro del día natural y la noche quedaba partida en dos.
        val dayStart = Calendar.getInstance().apply {
            time = yesterdayCal.time
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val nightReadings = allReadings.filter { it.timeMillis in (dayStart - 6 * 3_600_000L)..(dayStart + 15 * 3_600_000L) }
        val sleep = SleepDetector.detect(nightReadings.map { it.timeMillis to it.bpm })
        // Con movimiento grabado esa noche, el tiempo despierto sale de SleepStager (más fiable que el pulso solo)
        // y la ventana se recorta a cuando estabas dormido (17/10)
        val staged = sleep?.let {
            SleepStager.stageNight(csvFile, File(csvFile.parentFile, MotionTracker.FILE_NAME), it.startMillis, it.endMillis)
        }
        val window = staged?.let { it.startMillis to it.endMillis - 1 } ?: sleep?.let { it.startMillis to it.endMillis }
        val sleepWindowReadings = if (window != null) {
            nightReadings.filter { it.timeMillis in window.first..window.second }
        } else emptyList()

        val restingHr = if (sleepWindowReadings.isNotEmpty()) findRestingHr(sleepWindowReadings) else null
        // VFC: con fases, la de los tramos de sueño profundo (como WHOOP); ver NightMetrics
        val avgHrv = if (sleepWindowReadings.isNotEmpty()) {
            NightMetrics.hrv(sleepWindowReadings.map { it.timeMillis to it.rr }, staged)
        } else null
        val vo2Max = restingHr?.let { 15.3 * (hrMax / it) }
        val strain = Formulas.strainOf(dayReadings.map { it.timeMillis to it.bpm }, restingHr, hrMax, sex != "F")
        val sleepMinutes = staged?.asleepMinutes ?: sleep?.asleepMinutes

        var sleepStartMinute: Int? = null
        var sleepEndMinute: Int? = null
        val sleepEfficiency: Int? = staged?.efficiencyPct ?: sleep?.efficiencyPct
        if (window != null) {
            val startCal = Calendar.getInstance().apply { timeInMillis = window.first }
            val endCal = Calendar.getInstance().apply { timeInMillis = window.second }
            sleepStartMinute = startCal.get(Calendar.HOUR_OF_DAY) * 60 + startCal.get(Calendar.MINUTE)
            sleepEndMinute = endCal.get(Calendar.HOUR_OF_DAY) * 60 + endCal.get(Calendar.MINUTE)
        }
        val respiratoryRate = if (sleepWindowReadings.isNotEmpty()) {
            RespiratoryRateCalculator().estimate(sleepWindowReadings.flatMap { it.rr })
        } else null

        val avgHr = dayReadings.map { it.bpm }.average()
        val durationMinutes = dayReadings.size / 60.0
        val calories = estimateCalories(avgHr, durationMinutes, ageYears, weightKg, sex)

        db.dailyMetricsDao().save(
            DailyMetrics(
                date = yesterdayKey,
                restingHr = restingHr,
                avgHrv = avgHrv,
                sleepMinutes = sleepMinutes,
                strain = strain,
                vo2Max = vo2Max,
                caloriesKcal = calories,
                sleepStartMinuteOfDay = sleepStartMinute,
                sleepEndMinuteOfDay = sleepEndMinute,
                sleepEfficiencyPct = sleepEfficiency,
                respiratoryRate = respiratoryRate,
                lightMinutes = staged?.lightMinutes,
                deepMinutes = staged?.deepMinutes,
                remMinutes = staged?.remMinutes,
                awakeMinutes = staged?.awakeMinutes ?: sleep?.awakeMinutes,
                wakeEpisodes = staged?.awakenings,
                latencyMinutes = if (staged != null && sleep != null) ((staged.startMillis - sleep.startMillis) / 60_000L).toInt().coerceAtLeast(0) else null
            )
        )
    }

    private fun estimateCalories(avgHr: Double, durationMinutes: Double, age: Int, weightKg: Float, sex: String): Double {
        if (durationMinutes <= 0) return 0.0
        val kcalPerMinute = if (sex == "M") {
            (-55.0969 + (0.6309 * avgHr) + (0.1988 * weightKg) + (0.2017 * age)) / 4.184
        } else {
            (-20.4022 + (0.4472 * avgHr) - (0.1263 * weightKg) + (0.074 * age)) / 4.184
        }
        return kcalPerMinute.coerceAtLeast(0.0) * durationMinutes
    }

    /** FC en reposo = media del 10% de lecturas más bajas del día. */
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

    /** Igual que en MetricsCalculator: agrupa por minuto y tolera picos breves de FC. */
    private fun isNightHour(timeMillis: Long): Boolean {
        val cal = Calendar.getInstance().apply { timeInMillis = timeMillis }
        val hour = cal.get(Calendar.HOUR_OF_DAY)
        return hour >= 20 || hour < 10
    }

    private fun findLongestRestWindowMinutes(readings: List<Reading>): Int? {
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
        var currentStart: Long? = null
        var aboveSince: Long? = null
        var prevKey: Long? = null

        for ((key, avg) in series) {
            val gapMinutes = prevKey?.let { key - it } ?: 0
            if (prevKey != null && gapMinutes > DISCONNECT_GAP_MINUTES) {
                if (currentStart != null && prevKey != null) {
                    val d = prevKey - currentStart!!
                    if (d >= REST_MIN_DURATION_MINUTES) bestDurationMin = d
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
                        if (d >= REST_MIN_DURATION_MINUTES) bestDurationMin = d
                        currentStart = null
                        aboveSince = null
                    }
                }
            }
            prevKey = key
        }
        if (currentStart != null && prevKey != null) {
            val d = prevKey - currentStart!!
            if (d >= REST_MIN_DURATION_MINUTES) bestDurationMin = d
        }

        if (bestDurationMin < REST_MIN_DURATION_MINUTES) return null
        return bestDurationMin.toInt()
    }
/** Igual que findLongestRestWindowMinutes, pero devuelve las lecturas de esa ventana en vez de solo la duración. */
    private fun findLongestRestWindowReadings(readings: List<Reading>): List<Reading> {
        val nightReadings = readings.filter { isNightHour(it.timeMillis) }
        if (nightReadings.size < 2) return emptyList()

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
        var bestStartKey: Long? = null
        var bestEndKey: Long? = null
        var currentStart: Long? = null
        var aboveSince: Long? = null
        var prevKey: Long? = null

        for ((key, avg) in series) {
            val gapMinutes = prevKey?.let { key - it } ?: 0
            if (prevKey != null && gapMinutes > DISCONNECT_GAP_MINUTES) {
                if (currentStart != null && prevKey != null) {
                    val d = prevKey - currentStart!!
                    if (d >= REST_MIN_DURATION_MINUTES) { bestDurationMin = d; bestStartKey = currentStart; bestEndKey = prevKey }
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
                        if (d >= REST_MIN_DURATION_MINUTES) { bestDurationMin = d; bestStartKey = currentStart; bestEndKey = aboveSince }
                        currentStart = null
                        aboveSince = null
                    }
                }
            }
            prevKey = key
        }
       if (currentStart != null && prevKey != null) {
            val d = prevKey - currentStart!!
            if (d >= REST_MIN_DURATION_MINUTES) { bestDurationMin = d; bestStartKey = currentStart; bestEndKey = prevKey }
        }

        if (bestDurationMin < REST_MIN_DURATION_MINUTES || bestStartKey == null || bestEndKey == null) return emptyList()
        val startMillis = bestStartKey * 60000
        val endMillis = bestEndKey * 60000
        return readings.filter { it.timeMillis in startMillis..endMillis }
    }
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
        for (i in 1 until rr.size) { val d = rr[i] - rr[i - 1]; sumSq += d * d }
        return sqrt(sumSq / (rr.size - 1))
    }

    private fun parseCsv(file: File): List<Reading> {
        if (!file.exists()) return emptyList()
        val result = mutableListOf<Reading>()
        file.forEachLine { line ->
            if (line.startsWith("timestamp") || line.isBlank()) return@forEachLine
            val parts = splitCsvLine(line)
            if (parts.size < 2) return@forEachLine
            try {
                val time = timestampFormat.parse(parts[0])?.time ?: return@forEachLine
                val bpm = parts[1].toIntOrNull() ?: return@forEachLine
                if (bpm <= 0 || bpm > 250) return@forEachLine
                val rr = if (parts.size > 2) parts[2].split("|").mapNotNull { it.replace(',', '.').toDoubleOrNull() }.filter { it in 300.0..2000.0 } else emptyList()
                result.add(Reading(time, bpm, rr))
            } catch (e: Exception) { }
        }
        // Ordenado y sin duplicados: el historial de la pulsera puede llegar después de lecturas en directo
        return result.sortedBy { it.timeMillis }.distinctBy { it.timeMillis / 1000 }
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
