package com.pulseapp.android

import com.pulseapp.android.data.ActivitySession
import java.io.File
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
        autoDetected: Boolean = false
    ): ActivitySession? {
        val readings = parseCsv(file).filter { it.timeMillis in startMillis..endMillis }
        if (readings.isEmpty()) return null

        val hrMax = 208.0 - 0.7 * ageYears
        val avgHr = readings.map { it.bpm }.average()
        val maxHr = readings.maxOf { it.bpm }

                var z0 = 0; var z1 = 0; var z2 = 0; var z3 = 0; var z4 = 0; var z5 = 0
        var strainTotal = 0.0

        for (i in 1 until readings.size) {
            val deltaMin = (readings[i].timeMillis - readings[i - 1].timeMillis) / 60000.0
            if (deltaMin <= 0 || deltaMin > 8) continue
            val pct = readings[i].bpm / hrMax
            when {
                pct < 0.5 -> z0 += deltaMin.toInt().coerceAtLeast(0)
                pct < 0.6 -> z1 += deltaMin.toInt().coerceAtLeast(0)
                pct < 0.7 -> z2 += deltaMin.toInt().coerceAtLeast(0)
                pct < 0.8 -> z3 += deltaMin.toInt().coerceAtLeast(0)
                pct < 0.9 -> z4 += deltaMin.toInt().coerceAtLeast(0)
                else -> z5 += deltaMin.toInt().coerceAtLeast(0)
            }
            val weight = when {
                pct < 0.5 -> 0.0; pct < 0.6 -> 1.0; pct < 0.7 -> 2.0
                pct < 0.8 -> 3.0; pct < 0.9 -> 4.0; else -> 5.0
            }
            strainTotal += deltaMin * weight
        }
        val strain = (strainTotal / 200.0 * 21.0).coerceIn(0.0, 21.0)

        val durationMinutes = (endMillis - startMillis) / 60000.0
        val calories = estimateCalories(avgHr, durationMinutes, ageYears, weightKg, sex)

        return ActivitySession(
            startMillis = startMillis,
            endMillis = endMillis,
            avgHr = avgHr.toInt(),
            maxHr = maxHr,
            strain = strain,
            caloriesKcal = calories,
            minutesZone1 = z1, minutesZone2 = z2, minutesZone3 = z3,
            minutesZone4 = z4, minutesZone5 = z5,
            type = type,
            autoDetected = autoDetected,
            minutesZone0 = z0
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
        return result.sortedBy { it.timeMillis }
    }
}
