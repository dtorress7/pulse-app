package com.pulseapp.android

import com.pulseapp.android.data.AppDatabase

data class PersonalBaseline(val avgHrv: Double, val avgRestingHr: Double, val daysUsed: Int)

/**
 * Calcula la línea base personal a partir de los últimos días guardados en
 * daily_metrics. Requiere un mínimo de 3 días para considerarse fiable —
 * con menos, devuelve null y quien lo use debe recurrir a un valor genérico.
 */
class BaselineProvider {

    companion object {
        const val MIN_DAYS_REQUIRED = 3
        const val LOOKBACK_DAYS = 14
    }

    suspend fun compute(db: AppDatabase): PersonalBaseline? {
        val days = db.dailyMetricsDao().getLastDays(LOOKBACK_DAYS)
        val validHrv = days.mapNotNull { it.avgHrv }
        val validRhr = days.mapNotNull { it.restingHr }

        if (validHrv.size < MIN_DAYS_REQUIRED || validRhr.size < MIN_DAYS_REQUIRED) {
            return null
        }

        return PersonalBaseline(
            avgHrv = validHrv.average(),
            avgRestingHr = validRhr.average(),
            daysUsed = minOf(validHrv.size, validRhr.size)
        )
    }
}
