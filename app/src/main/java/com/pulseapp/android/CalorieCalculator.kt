package com.pulseapp.android

/**
 * Estima el gasto calórico total del día:
 * - Metabolismo basal (Mifflin-St Jeor), proporcional al tiempo real
 *   transcurrido desde medianoche — no depende de cuántas lecturas de
 *   pulso haya guardadas, así no se descuadra con cortes de conexión.
 * - Sin factor extra (20/10): en el export de WHOOP, lo que quemas fuera de los entrenamientos es de mediana
 *   1644 kcal/24 h ≈ tu metabolismo basal; con el ×1,15 de antes salían ~250 kcal de más al día.
 * - Las calorías de tus actividades guardadas (fútbol, gym...) se SUMAN
 *   aparte — no se mezclan con la base para no contar dos veces lo mismo.
 */
class CalorieCalculator {

    companion object { const val DAY_FACTOR = 1.0 }

    fun basalMetabolicRate(ageYears: Int, weightKg: Float, heightCm: Float, sex: String): Double {
        return if (sex == "M") {
            10 * weightKg + 6.25 * heightCm - 5 * ageYears + 5
        } else {
            10 * weightKg + 6.25 * heightCm - 5 * ageYears - 161
        }
    }

    /** Calorías de una actividad concreta (fórmula de Keytel), usada solo para sesiones guardadas. */
    fun exerciseCalories(avgHr: Double, durationMinutes: Double, ageYears: Int, weightKg: Float, sex: String): Double {
        if (durationMinutes <= 0) return 0.0
        val kcalPerMinute = if (sex == "M") {
            (-55.0969 + (0.6309 * avgHr) + (0.1988 * weightKg) + (0.2017 * ageYears)) / 4.184
        } else {
            (-20.4022 + (0.4472 * avgHr) - (0.1263 * weightKg) + (0.074 * ageYears)) / 4.184
        }
        return kcalPerMinute.coerceAtLeast(0.0) * durationMinutes
    }

    /**
     * Gasto total del día = base metabólica proporcional al tiempo real transcurrido
     * (x1.15 por actividad ligera cotidiana) + calorías de las actividades guardadas hoy.
     */
    fun estimateDailyTotal(
        elapsedMinutesToday: Double,
        activityKcalToday: Double,
        ageYears: Int, weightKg: Float, heightCm: Float, sex: String,
        activityMinutesToday: Double = 0.0,
        restKcalPerDay: Double? = null
    ): Double {
        // 30/10: como WHOOP. Fuera de las actividades WHOOP gasta un ritmo FIJO (tu caso: 1706 kcal/24 h, ±17 en 20 días de la API;
        // mediana 1704 en los 197 días del export) y durante una actividad cuenta SOLO las calorías de la actividad (ya incluyen
        // el basal). Antes se sumaba el basal las 24 h + las actividades → el tiempo de deporte contaba dos veces (29/10: +103 kcal).
        val rate = restKcalPerDay ?: basalMetabolicRate(ageYears, weightKg, heightCm, sex)
        val restMinutes = (elapsedMinutesToday - activityMinutesToday).coerceAtLeast(0.0)
        return rate * (restMinutes / (24 * 60)) * DAY_FACTOR + activityKcalToday
    }
}
