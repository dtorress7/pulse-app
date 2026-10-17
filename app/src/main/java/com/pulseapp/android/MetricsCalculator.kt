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
    val totalReadings: Int,
    val sleepStartMillis: Long? = null,
    val sleepEndMillis: Long? = null,
    /** Fases minuto a minuto de la noche (solo si esa noche hay movimiento grabado). */
    val stages: SleepStager.Result? = null
)

private data class Reading(val timeMillis: Long, val bpm: Int, val rr: List<Double>)

class MetricsCalculator(ageYears: Int, private val male: Boolean = true) {

    private val hrMax: Double = Formulas.hrMax(ageYears)
    private val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)

    companion object {
        private const val DISCONNECT_GAP_MINUTES = 3
    }

    fun analyze(file: File, motionFile: File = File(file.parentFile, MotionTracker.FILE_NAME)): DailySummary {
        val readings = parseCsv(file)
        if (readings.isEmpty()) {
            return DailySummary(null, null, null, null, 0.0, null, null, null, null, null, null, null, null, null, 0)
        }

        // Noche más reciente (últimas 30 h), detectada con SleepDetector (ajustado con tu noche del 14→15/10)
        val now = System.currentTimeMillis()
        val recent = readings.filter { it.timeMillis >= now - 30 * 3_600_000L }
        val sleep = SleepDetector.detect(recent.map { it.timeMillis to it.bpm })
        val restWindow = sleep?.let { it.startMillis to it.endMillis }

        // Ciclo del día como WHOOP: empieza al dormirte (si la noche acabó hace menos de 20 h); si no, a las 00:00.
        // Antes se usaba TODO el archivo y el esfuerzo de hoy arrastraba el de días anteriores.
        val midnight = java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
            set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
        }.timeInMillis
        val cycleStart = if (sleep != null && now - sleep.endMillis < 20 * 3_600_000L) sleep.startMillis else midnight
        val cycleReadings = readings.filter { it.timeMillis >= cycleStart }
        val avgHr = cycleReadings.takeIf { it.isNotEmpty() }?.map { it.bpm }?.average()?.toInt()

        // Con movimiento grabado esa noche, las fases (y el tiempo despierto) salen de SleepStager.
        // La ventana de las fases ya viene recortada: empieza al dormirse y acaba al despertar (17/10).
        val staged = sleep?.let { SleepStager.stageNight(file, motionFile, it.startMillis, it.endMillis) }
        val window = staged?.let { it.startMillis to it.endMillis - 1 } ?: restWindow

        // FC en reposo y VFC SOLO con la ventana de sueño (igual que WHOOP)
        val sleepReadings = if (window != null) {
            readings.filter { it.timeMillis in window.first..window.second }
        } else emptyList()
        // Sin noche registrada no hay FC en reposo real (de día sale ~15 lpm más alta y hunde el esfuerzo): se deja vacía
        val restingHr = if (sleepReadings.isNotEmpty()) findRestingHr(sleepReadings) else null
        // VFC: con fases, la de los tramos de sueño profundo (como WHOOP); ver NightMetrics
        val avgHrv = if (sleepReadings.isNotEmpty()) NightMetrics.hrv(sleepReadings.map { it.timeMillis to it.rr }, staged) else null
        val vo2Max = restingHr?.let { 15.3 * (hrMax / it) }
        val strain = computeStrain(cycleReadings, restingHr)

        val calStart = window?.first?.let { java.util.Calendar.getInstance().apply { timeInMillis = it } }
        val calEnd = window?.second?.let { java.util.Calendar.getInstance().apply { timeInMillis = it } }
        val sleepEfficiency = sleep?.efficiencyPct
        val respiratoryRate = if (sleepReadings.isNotEmpty()) {
            RespiratoryRateCalculator().estimate(sleepReadings.flatMap { it.rr })
        } else null

        val timeInBedMinutes = staged?.minutes ?: sleep?.inBedMinutes
        val awakeMinutes = staged?.awakeMinutes ?: sleep?.awakeMinutes
        val actualSleepMinutes = staged?.asleepMinutes ?: sleep?.asleepMinutes

        return DailySummary(
            restingHr = restingHr,
            avgHr = avgHr,
            avgHrv = avgHrv,
            vo2Max = vo2Max,
            strain = strain,
            sleepMinutes = actualSleepMinutes,
            timeInBedMinutes = timeInBedMinutes,
            awakeMinutes = awakeMinutes,
            sleepStart = window?.first?.let { sdf.format(Date(it)) },
            sleepEnd = window?.second?.let { sdf.format(Date(it)) },
            sleepStartMinuteOfDay = calStart?.let { it.get(java.util.Calendar.HOUR_OF_DAY) * 60 + it.get(java.util.Calendar.MINUTE) },
            sleepEndMinuteOfDay = calEnd?.let { it.get(java.util.Calendar.HOUR_OF_DAY) * 60 + it.get(java.util.Calendar.MINUTE) },
            sleepEfficiencyPct = staged?.efficiencyPct ?: sleepEfficiency,
            respiratoryRate = respiratoryRate,
            totalReadings = readings.size,
            sleepStartMillis = window?.first,
            sleepEndMillis = window?.second,
            stages = staged
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
}
