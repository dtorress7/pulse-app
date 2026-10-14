package com.pulseapp.android

/**
 * Recuperación calibrada con tu histórico de WHOOP (ver Formulas.recovery):
 * lo que decide la nota es tu VFC de esta noche frente a tu media reciente,
 * con un pequeño ajuste por la FC en reposo y una alerta si la respiración sube mucho.
 */
data class RecoveryBreakdown(
    val total: Int,
    val hrvDeltaPct: Double?,
    val rhrDelta: Double?,
    val respPenalty: Boolean,
    val personalBaseline: Boolean
)

class RecoveryCalculator {

    /** Firma antigua conservada: el sueño ya no entra en la nota (en tus datos de WHOOP no la cambia). */
    @Suppress("UNUSED_PARAMETER")
    fun calculate(
        nightlyHrv: Double?,
        restingHr: Int?,
        sleptMinutes: Int?,
        targetSleepMinutes: Int,
        sleepEfficiencyPct: Int?,
        baseline: PersonalBaseline? = null,
        respiratoryRate: Double? = null
    ): Int = breakdown(nightlyHrv, restingHr, baseline, respiratoryRate).total

    fun breakdown(
        nightlyHrv: Double?,
        restingHr: Int?,
        baseline: PersonalBaseline?,
        respiratoryRate: Double? = null
    ): RecoveryBreakdown {
        val r = Formulas.recovery(nightlyHrv, restingHr, respiratoryRate, baseline)
        return RecoveryBreakdown(r.total, r.hrvDeltaPct, r.rhrDelta, r.respPenalty, r.usedPersonalBaseline)
    }
}
