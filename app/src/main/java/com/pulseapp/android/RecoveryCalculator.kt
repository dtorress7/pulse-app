package com.pulseapp.android

/**
 * Recovery ponderado según cómo lo describes en Whoop:
 * - HRV + FC reposo = núcleo duro (60% combinado), comparados con tu línea base
 * - Sueño = peso medio-alto (40%): horas dormidas vs necesidad (fórmula del
 *   Sleep Planner) + eficiencia del sueño
 *
 * Pendiente de añadir cuando construyamos Frecuencia Respiratoria: le
 * restaremos peso a estos tres para dárselo a esa nueva señal, tal y como
 * la pesa Whoop (peso medio, solo penaliza si se desvía de tu normal).
 */
class RecoveryCalculator {

    fun calculate(
        nightlyHrv: Double?,
        restingHr: Int?,
        sleptMinutes: Int?,
        targetSleepMinutes: Int,
        sleepEfficiencyPct: Int?,
        baseline: PersonalBaseline? = null
    ): Int {
        val hrvComponent = nightlyHrv?.let { hrv ->
            if (baseline != null) {
                ((hrv / baseline.avgHrv) * 100.0).coerceIn(0.0, 130.0).let { if (it > 100) 100.0 else it }
            } else {
                (((hrv - 20.0) / 80.0) * 100.0).coerceIn(0.0, 100.0)
            }
        } ?: 50.0

        val rhrComponent = restingHr?.let { rhr ->
            if (baseline != null) {
                ((baseline.avgRestingHr / rhr) * 100.0).coerceIn(0.0, 130.0).let { if (it > 100) 100.0 else it }
            } else {
                (((80 - rhr) / 40.0) * 100.0).coerceIn(0.0, 100.0)
            }
        } ?: 50.0

        val sleepPerformancePct = if (sleptMinutes != null && targetSleepMinutes > 0) {
            ((sleptMinutes.toDouble() / targetSleepMinutes) * 100.0).coerceIn(0.0, 100.0)
        } else 40.0

        val sleepComponent = if (sleepEfficiencyPct != null) {
            sleepPerformancePct * 0.7 + sleepEfficiencyPct * 0.3
        } else {
            sleepPerformancePct
        }

        val recovery = hrvComponent * 0.35 + rhrComponent * 0.25 + sleepComponent * 0.40
        return recovery.toInt().coerceIn(0, 100)
    }
}
