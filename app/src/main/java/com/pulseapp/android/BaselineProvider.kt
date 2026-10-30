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
    val respSd: Double? = null,
    /** Media simple de ln VFC de esas noches (para el percentil de la recuperación, 30/10); null con < 7 noches. */
    val lnHrvMean30: Double? = null
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
         * 23/10: la VFC nueva (NightMetrics) se recalcula para todas las noches con pulso guardado (desde el 14/10), así que
         * cuentan las noches desde el 15/10. Antes (17/10): desde el 17/10 la VFC salía del sueño profundo y la respiración del análisis espectral (valores más altos
         * y en la escala de WHOOP). Los días guardados antes con el método viejo no entran en esas dos medias
         * para no mezclar escalas.
         */
        const val NEW_METHOD_SINCE = "2026-10-15"

        /** VFC/respiración de ese día en la escala de WHOOP: calculada con el método nuevo o importada de WHOOP (23/10). */
        fun sameScale(date: String): Boolean = date >= NEW_METHOD_SINCE || date <= Formulas.whoopImportUntil()
    }

    suspend fun compute(db: AppDatabase): PersonalBaseline? = computeFrom(db.dailyMetricsDao().getLastDays(LOOKBACK_DAYS))

    /**
     * Línea base con los días que se le pasan (de más reciente a más antiguo, como getLastDays).
     * Para un día pasado D se le pasan los días anteriores a D: así su recuperación sale igual que la habría dado ese día.
     */
    fun computeFrom(lastDaysNewestFirst: List<com.pulseapp.android.data.DailyMetrics>): PersonalBaseline? {
        // Solo noches de verdad (≥ 3 h dormido): un día sin noche registrada no debe mover tu media
        val days = lastDaysNewestFirst.take(LOOKBACK_DAYS).filter { (it.sleepMinutes ?: 0) >= 180 }
        val newMethod = days.filter { sameScale(it.date) }
        val validHrv = newMethod.mapNotNull { it.avgHrv?.takeIf { v -> v > 0 } }
        val validRhr = days.mapNotNull { it.restingHr?.toDouble() }
        val validResp = newMethod.mapNotNull { it.respiratoryRate?.takeIf { r -> r in 8.0..25.0 } }

        if (validHrv.isEmpty() || validRhr.isEmpty()) return null
        // getLastDays devuelve de más reciente a más antiguo: se invierte para la media ponderada.
        // 23/10: la media empieza en tu línea base de WHOOP antes de usar PulseApp (88 ms / 58,5 lpm) y cada noche la mueve,
        // como si tuviera tu historial. Antes empezaba en la 1.ª noche propia: con pocas noches la media quedaba baja
        // (las dos primeras fueron 69 y 76) y la recuperación salía ~10–15 puntos alta. Con 9 noches: error medio 12,7 → 3,8.
        val lnHrv = validHrv.map { ln(it) }
        val lnHrvEwma = ewma(lnHrv.reversed(), ln(Formulas.FALLBACK_HRV))
        return PersonalBaseline(
            avgHrv = kotlin.math.exp(lnHrvEwma),
            avgRestingHr = ewma(validRhr.reversed(), Formulas.FALLBACK_RHR),
            daysUsed = minOf(validHrv.size, validRhr.size),
            lnHrvMean = lnHrvEwma,
            lnHrvSd = maxOf(sd(lnHrv), MIN_LN_HRV_SD),
            rhrSd = maxOf(sd(validRhr), MIN_RHR_SD),
            respMean = if (validResp.size >= MIN_DAYS_REQUIRED) validResp.average() else null,
            respSd = if (validResp.size >= MIN_DAYS_REQUIRED) maxOf(sd(validResp), MIN_RESP_SD) else null,
            lnHrvMean30 = if (lnHrv.size >= 7) lnHrv.average() else null
        )
    }

    private fun ewma(oldestFirst: List<Double>, prior: Double): Double {
        var m = prior
        for (v in oldestFirst) m += EWMA_ALPHA * (v - m)
        return m
    }

    private fun sd(values: List<Double>): Double {
        if (values.size < 2) return 0.0
        val m = values.average()
        return sqrt(values.sumOf { (it - m) * (it - m) } / (values.size - 1))
    }
}
