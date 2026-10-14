package com.pulseapp.android

import com.pulseapp.android.data.AppDatabase
import java.util.Calendar

data class SleepPlan(
    val baselineMinutes: Int,      // ~7h50 fijo, tu "mínimo vital"
    val strainAdjustmentMinutes: Int,  // se suma según el esfuerzo del día
    val debtAdjustmentMinutes: Int,    // se suma según la deuda de sueño previa
    val napAdjustmentMinutes: Int,     // se resta si has echado siesta (de momento siempre 0, no detectamos siestas todavía)
    val totalNeedMinutes: Int,         // suma final: cuánto necesitas dormir esta noche
    val suggestedBedtime: String?      // hora sugerida de ir a la cama, si sabemos cuándo quieres despertar
)

/**
 * Implementa la fórmula: Necesidad de sueño = Baseline + Strain + Deuda previa - Siestas
 *
 * - Baseline: fijo en 7h50 (470 min), como indicaste que es tu caso.
 * - Strain: convierte tu Strain del día (0-21) en minutos extra de sueño necesarios.
 *   Aproximación: cada punto de Strain por encima de 8 añade ~6 minutos.
 * - Deuda previa: diferencia entre lo que necesitabas y lo que dormiste, acumulada
 *   de los últimos días guardados en daily_metrics (con cierto decaimiento).
 * - Siestas: no detectamos siestas todavía (necesitaría datos de acelerómetro/movimiento
 *   que no tenemos), así que este ajuste siempre es 0 por ahora.
 */
class SleepPlanner {

    companion object {
        const val BASELINE_MINUTES = 7 * 60 + 50 // 7h50
    }

    suspend fun computeTonightPlan(db: AppDatabase, todayStrain: Double?, wakeUpHour: Int = 7, wakeUpMinute: Int = 30): SleepPlan {
        val strainMinutes = todayStrain?.let {
            ((it - 8.0).coerceAtLeast(0.0) * 6.0).toInt()
        } ?: 0

        val debtMinutes = computeAccumulatedDebt(db)

        val napMinutes = 0 // pendiente: necesitaríamos detección de siestas

        val totalNeed = BASELINE_MINUTES + strainMinutes + debtMinutes - napMinutes

        val bedtime = computeSuggestedBedtime(totalNeed, wakeUpHour, wakeUpMinute)

        return SleepPlan(
            baselineMinutes = BASELINE_MINUTES,
            strainAdjustmentMinutes = strainMinutes,
            debtAdjustmentMinutes = debtMinutes,
            napAdjustmentMinutes = napMinutes,
            totalNeedMinutes = totalNeed,
            suggestedBedtime = bedtime
        )
    }

    private suspend fun computeAccumulatedDebt(db: AppDatabase): Int {
        val lastDays = db.dailyMetricsDao().getLastDays(7)
        var debt = 0
        // Recorre del más antiguo al más reciente, con decaimiento (los días viejos pesan menos)
        lastDays.sortedBy { it.date }.forEachIndexed { index, day ->
            val slept = day.sleepMinutes ?: return@forEachIndexed
            val diff = BASELINE_MINUTES - slept
            if (diff > 0) {
                val decay = 0.7 // cada día que pasa, la deuda anterior pesa un 70% menos
                debt = (debt * decay + diff).toInt()
            } else {
                debt = (debt * 0.7).toInt() // si dormiste bien, la deuda decae igualmente
            }
        }
        return debt.coerceAtLeast(0)
    }

    private fun computeSuggestedBedtime(needMinutes: Int, wakeUpHour: Int, wakeUpMinute: Int): String {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, wakeUpHour)
        cal.set(Calendar.MINUTE, wakeUpMinute)
        cal.add(Calendar.MINUTE, -needMinutes)
        return "%02d:%02d".format(cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE))
    }
}
