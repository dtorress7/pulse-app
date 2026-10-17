package com.pulseapp.android

import com.pulseapp.android.data.AppDatabase
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * Línea base personal: media y variación normal de tus últimas noches (hasta 14).
 * La VFC se trabaja en logaritmo (ln RMSSD), como en los estudios de rendimiento deportivo,
 * porque así las subidas y bajadas son simétricas.
 */
data class PersonalBaseline(
    val avgHrv: Double,
    val avgRestingHr: Double,
    val daysUsed: Int,
    val lnHrvMean: Double = ln(avgHrv),
    val lnHrvSd: Double = 0.12,
    val rhrSd: Double = 2.5,
    val respMean: Double? = null,
    val respSd: Double? = null
)

class BaselineProvider {

    companion object {
        const val MIN_DAYS_REQUIRED = 3
        const val LOOKBACK_DAYS = 30
        /** Media ponderada exponencial con "span" de 14 días: las noches recientes pesan más (ajustado a WHOOP). */
        private const val EWMA_ALPHA = 2.0 / (14 + 1)

        // Variación mínima: evita que con pocos días casi idénticos un cambio pequeño parezca enorme
        private const val MIN_LN_HRV_SD = 0.08
        private const val MIN_RHR_SD = 1.5
        private const val MIN_RESP_SD = 0.4

        /**
         * Desde el 17/10 la VFC sale del sueño profundo y la respiración del análisis espectral (valores más altos
         * y en la escala de WHOOP). Los días guardados antes con el método viejo no entran en esas dos medias
         * para no mezclar escalas (hasta tener 3 noches nuevas se usa la referencia 86 ms).
         */
        const val NEW_METHOD_SINCE = "2026-10-17"
    }

    suspend fun compute(db: AppDatabase): PersonalBaseline? = computeFrom(db.dailyMetricsDao().getLastDays(LOOKBACK_DAYS))

    /**
     * Línea base con los días que se le pasan (de más reciente a más antiguo, como getLastDays).
     * Para un día pasado D se le pasan los días anteriores a D: así su recuperación sale igual que la habría dado ese día.
     */
    fun computeFrom(lastDaysNewestFirst: List<com.pulseapp.android.data.DailyMetrics>): PersonalBaseline? {
        // Solo noches de verdad (≥ 3 h dormido): un día sin noche registrada no debe mover tu media
        val days = lastDaysNewestFirst.take(LOOKBACK_DAYS).filter { (it.sleepMinutes ?: 0) >= 180 }
        val newMethod = days.filter { it.date >= NEW_METHOD_SINCE }
        val validHrv = newMethod.mapNotNull { it.avgHrv?.takeIf { v -> v > 0 } }
        val validRhr = days.mapNotNull { it.restingHr?.toDouble() }
        val validResp = newMethod.mapNotNull { it.respiratoryRate?.takeIf { r -> r in 8.0..25.0 } }

        if (validHrv.size < MIN_DAYS_REQUIRED || validRhr.size < MIN_DAYS_REQUIRED) {
            return null
        }
        // getLastDays devuelve de más reciente a más antiguo: se invierte para la media ponderada
        val lnHrv = validHrv.map { ln(it) }
        val lnHrvEwma = ewma(lnHrv.reversed())
        return PersonalBaseline(
            avgHrv = kotlin.math.exp(lnHrvEwma),
            avgRestingHr = ewma(validRhr.reversed()),
            daysUsed = minOf(validHrv.size, validRhr.size),
            lnHrvMean = lnHrvEwma,
            lnHrvSd = maxOf(sd(lnHrv), MIN_LN_HRV_SD),
            rhrSd = maxOf(sd(validRhr), MIN_RHR_SD),
            respMean = if (validResp.size >= MIN_DAYS_REQUIRED) validResp.average() else null,
            respSd = if (validResp.size >= MIN_DAYS_REQUIRED) maxOf(sd(validResp), MIN_RESP_SD) else null
        )
    }

    private fun ewma(oldestFirst: List<Double>): Double {
        var m = oldestFirst.first()
        for (v in oldestFirst.drop(1)) m += EWMA_ALPHA * (v - m)
        return m
    }

    private fun sd(values: List<Double>): Double {
        if (values.size < 2) return 0.0
        val m = values.average()
        return sqrt(values.sumOf { (it - m) * (it - m) } / (values.size - 1))
    }
}
