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
        const val BASELINE_MINUTES = 7 * 60 + 50 // 7h50 (adulto 18–64, ajustado a tu histórico de WHOOP)
        private const val PREFS = "pulseapp_sleep"

        /** Hora de despertar elegida en Inicio ("Editar hora de despertar"), en minutos del día. Por defecto 7:30. */
        fun wakeMinute(ctx: android.content.Context): Int =
            ctx.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE).getInt("wake_minute", 7 * 60 + 30)

        fun setWakeMinute(ctx: android.content.Context, minuteOfDay: Int) =
            ctx.getSharedPreferences(PREFS, android.content.Context.MODE_PRIVATE).edit().putInt("wake_minute", minuteOfDay).apply()

        /**
         * Deuda tras una noche, como WHOOP (18/10): la mitad de lo que te faltó para la necesidad de esa noche
         * (base + esfuerzo de la víspera + deuda que traías). Ajustado con 152 noches del export de WHOOP: error medio 1,5 min
         * (la fórmula anterior, ×0,7 por día sobre la base, se quedaba muy por encima). Sin dato de esa noche, la deuda se reduce a la mitad.
         */
        fun nextDebt(debtBefore: Int, base: Int, prevDayStrain: Double?, slept: Int?): Int {
            if (slept == null) return debtBefore / 2
            val need = base + Formulas.sleepNeedFromStrain(prevDayStrain ?: 0.0) + debtBefore
            return Math.round((need - slept) / 2.0).toInt().coerceAtLeast(0)
        }

        /** Deuda acumulada tras la última noche guardada, recorriendo las noches de la más antigua a la más reciente. */
        fun debtFrom(rowsOldestFirst: List<com.pulseapp.android.data.DailyMetrics>, base: Int): Int {
            val strainByDate = rowsOldestFirst.associate { it.date to it.strain }
            var debt = 0
            rowsOldestFirst.forEach { r ->
                val prev = java.time.LocalDate.parse(r.date).minusDays(1).toString()
                debt = nextDebt(debt, base, strainByDate[prev], r.sleepMinutes)
            }
            return debt
        }

        /** Sueño base según la edad (recomendaciones de la National Sleep Foundation / AASM). */
        fun baselineForAge(age: Int?): Int = when {
            age == null -> BASELINE_MINUTES
            age < 14 -> 10 * 60
            age < 18 -> 9 * 60
            age >= 65 -> 7 * 60 + 30
            else -> BASELINE_MINUTES
        }
    }

    /**
     * Necesidad de la noche que acabas de dormir: usa el esfuerzo de AYER (el de hoy apenas ha empezado por la mañana).
     * Si la última noche terminó hace más de 20 h, es la de esta noche.
     */
    suspend fun planForLastNight(db: AppDatabase, summary: DailySummary): SleepPlan {
        val end = summary.sleepEndMillis
        val justSlept = end != null && System.currentTimeMillis() - end < 20 * 3_600_000L
        var strain: Double? = summary.strain
        if (justSlept) {
            val cal = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }
            val key = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(cal.time)
            db.dailyMetricsDao().getByDate(key)?.strain?.let { strain = it }
        }
        return computeTonightPlan(db, strain)
    }

    /** [debtOverride]: deuda ya calculada (p. ej. la de después de la última noche); null = la de las noches guardadas. */
    suspend fun computeTonightPlan(db: AppDatabase, todayStrain: Double?, wakeUpHour: Int = 7, wakeUpMinute: Int = 30,
                                   debtOverride: Int? = null): SleepPlan {
        val strainMinutes = todayStrain?.let { Formulas.sleepNeedFromStrain(it) } ?: 0

        val debtMinutes = debtOverride ?: computeAccumulatedDebt(db, baselineForAge(db.userProfileDao().getOnce()?.ageYears()))

        // Siestas de hoy (detectadas por AutoActivityScanner, 21/10): restan de la necesidad de esta noche, como en WHOOP
        val dayStart = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0); set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val napMinutes = db.activitySessionDao().getAll()
            .filter { it.type == Formulas.NAP_TYPE && it.startMillis >= dayStart }
            .sumOf { ((it.endMillis - it.startMillis) / 60_000L).toInt() }

        val baseline = baselineForAge(db.userProfileDao().getOnce()?.ageYears())
        val totalNeed = baseline + strainMinutes + debtMinutes - napMinutes

        val bedtime = computeSuggestedBedtime(totalNeed, wakeUpHour, wakeUpMinute)

        return SleepPlan(
            baselineMinutes = baseline,
            strainAdjustmentMinutes = strainMinutes,
            debtAdjustmentMinutes = debtMinutes,
            napAdjustmentMinutes = napMinutes,
            totalNeedMinutes = totalNeed,
            suggestedBedtime = bedtime
        )
    }

    private suspend fun computeAccumulatedDebt(db: AppDatabase, base: Int): Int {
        // Recorre del más antiguo al más reciente (la deuda se reparte a la mitad cada noche: 14 noches sobran)
        val lastDays = db.dailyMetricsDao().getLastDays(14)
        return debtFrom(lastDays.sortedBy { it.date }, base)
    }

    private fun computeSuggestedBedtime(needMinutes: Int, wakeUpHour: Int, wakeUpMinute: Int): String {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, wakeUpHour)
        cal.set(Calendar.MINUTE, wakeUpMinute)
        cal.add(Calendar.MINUTE, -needMinutes)
        return "%02d:%02d".format(cal.get(Calendar.HOUR_OF_DAY), cal.get(Calendar.MINUTE))
    }
}
