package com.pulseapp.android

import com.pulseapp.android.data.ActivitySession
import java.io.File
import kotlin.math.roundToInt
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Calcula el resumen de una sesión de actividad a partir del CSV, filtrando
 * solo las lecturas entre startMillis y endMillis.
 */
class ActivityRecorder {

    private data class Reading(val timeMillis: Long, val bpm: Int)

    fun summarize(
        file: File,
        startMillis: Long,
        endMillis: Long,
        ageYears: Int,
        weightKg: Float,
        sex: String,
        type: String = "Sin clasificar",
        autoDetected: Boolean = false,
        restingHr: Int? = null
    ): ActivitySession? {
        val readings = parseCsv(file).filter { it.timeMillis in startMillis..endMillis }
        if (readings.isEmpty()) return null

        val hrMax = Formulas.hrMax(ageYears)
        val avgHr = readings.map { it.bpm }.average()
        val maxHr = readings.maxOf { it.bpm }

        // Minutos por zona en decimales: con lecturas cada segundo, truncar cada tramo a entero daba siempre 0
        var z0 = 0.0; var z1 = 0.0; var z2 = 0.0; var z3 = 0.0; var z4 = 0.0; var z5 = 0.0
        var trimpTotal = 0.0
        val rhr = restingHr ?: Formulas.DEFAULT_RESTING_HR

        val bounds = Formulas.zoneBounds(hrMax)
        for (i in 1 until readings.size) {
            val deltaMin = (readings[i].timeMillis - readings[i - 1].timeMillis) / 60000.0
            if (deltaMin <= 0 || deltaMin > 8) continue
            when (Formulas.zoneOf(readings[i].bpm, bounds)) {
                0 -> z0 += deltaMin
                1 -> z1 += deltaMin
                2 -> z2 += deltaMin
                3 -> z3 += deltaMin
                4 -> z4 += deltaMin
                else -> z5 += deltaMin
            }
            trimpTotal += Formulas.trimp(deltaMin, readings[i].bpm, rhr, hrMax, sex != "F")
        }
        // Esfuerzo de la actividad: misma escala que el del día (WHOOP: fútbol 2 h ≈ 10,7)
        val strain = Formulas.strainFromTrimp(trimpTotal,
            if (Formulas.isStrength(type)) (endMillis - startMillis) / 60000.0 else 0.0)

        val durationMinutes = (endMillis - startMillis) / 60000.0
        // Calorías por tiempo en cada zona (ajustadas con el export de WHOOP); antes Keytel daba ~1,8× más
        val bmr = Formulas.bmr().takeIf { it > 0 }
            ?: CalorieCalculator().basalMetabolicRate(ageYears, weightKg, 175f, sex)
        val calories = if (durationMinutes > 0) Formulas.activityKcal(doubleArrayOf(z0, z1, z2, z3, z4, z5), bmr) else 0.0

        return ActivitySession(
            startMillis = startMillis,
            endMillis = endMillis,
            avgHr = avgHr.toInt(),
            maxHr = maxHr,
            strain = strain,
            caloriesKcal = calories,
            minutesZone1 = z1.roundToInt(), minutesZone2 = z2.roundToInt(), minutesZone3 = z3.roundToInt(),
            minutesZone4 = z4.roundToInt(), minutesZone5 = z5.roundToInt(),
            type = type,
            autoDetected = autoDetected,
            minutesZone0 = z0.roundToInt()
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

    private fun parseCsv(file: File): List<Reading> {
        if (!file.exists()) return emptyList()
        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)
        val result = mutableListOf<Reading>()
        file.forEachLine { line ->
            if (line.startsWith("timestamp") || line.isBlank()) return@forEachLine
            val parts = line.split(",")
            if (parts.size < 2) return@forEachLine
            try {
                val time = sdf.parse(parts[0])?.time ?: return@forEachLine
                val bpm = parts[1].toIntOrNull() ?: return@forEachLine
                result.add(Reading(time, bpm))
            } catch (e: Exception) { }
        }
        // Ordenado y sin duplicados: el historial de la pulsera puede llegar después de lecturas en directo
        return result.sortedBy { it.timeMillis }.distinctBy { it.timeMillis / 1000 }
    }
}
