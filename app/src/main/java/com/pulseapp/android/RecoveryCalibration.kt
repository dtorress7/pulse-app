package com.pulseapp.android

import com.pulseapp.android.data.DailyMetrics
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Calibración personal de la recuperación (14/11; v2 21/11) con el export de WHOOP de cada persona.
 *
 * La fórmula general se ajustó con las 200 noches del primer usuario. Con el export de Pablo (192 noches, 21/11) se vio que
 * WHOOP NO usa los mismos números para todos: a él le pesa más la VFC (78 frente a 39 por unidad de ln), le pesa la calificación
 * del sueño (+0,5 puntos por punto; al usuario 0) y el "escalón" del 10/11 le fue al revés (−5; al usuario +7,4). Ni normalizar
 * por la variación de cada uno (z) ni una fórmula común con los dos sirven: ajustada con uno y probada con el otro falla 5,4–7,3.
 * Así que con SUS noches importadas se ajustan 6 números: base, VFC, FCR, percentil, calificación del sueño (de WHOOP) y su escalón
 * desde el 10/11 (solo si hay ≥ [MIN_STEP_NIGHTS] noches a cada lado). Misma línea base que la app (BaselineProvider, 30 días).
 * Pablo: validación cruzada general 5,6 → personal ≈ 3,8; ajustando hasta el 15/9 y probando después 4,6 → 3,7.
 * Solo se usa si hay ≥ [MIN_NIGHTS] noches y en validación cruzada (10 partes) falla ≥ [MIN_GAIN] menos que la general.
 */
object RecoveryCalibration {
    const val MIN_NIGHTS = 90
    const val MIN_GAIN = 0.3
    const val MIN_STEP_NIGHTS = 7
    private const val WARMUP = 10

    data class Fit(val n: Int, val coef: DoubleArray?, val cvPersonal: Double?, val cvGeneral: Double?) {
        val usePersonal get() = coef != null
    }

    /** [days] en cualquier orden; usa los que tienen recuperación de WHOOP, VFC, FCR y calificación del sueño de WHOOP. */
    fun fit(days: List<DailyMetrics>): Fit {
        val sorted = days.sortedBy { it.date }
        val xs = ArrayList<DoubleArray>(); val ys = ArrayList<Double>(); val dates = ArrayList<String>()
        for ((i, d) in sorted.withIndex()) {
            if (i < WARMUP) continue
            val rec = d.whoopRecovery ?: continue
            val hrv = d.avgHrv?.takeIf { it > 0 } ?: continue
            val rhr = d.restingHr ?: continue
            val sleep = d.whoopSleepScore ?: continue
            val prev = sorted.subList(0, i).asReversed().take(BaselineProvider.LOOKBACK_DAYS)
            val b = BaselineProvider().computeFrom(prev) ?: continue
            val f = Formulas.recoveryFeatures(hrv, rhr, b)
            val step = if (Formulas.inStepWindow(d.date)) 1.0 else 0.0
            // misma forma que Formulas.recovery con 7 números: c0 + c1·ΔVFC − c2·ΔFCR + c3·Φ + c4·calificación + c5·escalón
            xs.add(doubleArrayOf(1.0, f[0], -f[1], f[2], sleep.toDouble(), step))
            ys.add(rec.toDouble()); dates.add(d.date)
        }
        val n = xs.size
        if (n < MIN_NIGHTS) return Fit(n, null, null, null)
        val after = xs.count { it[5] > 0 }
        val useStep = after >= MIN_STEP_NIGHTS && n - after >= MIN_STEP_NIGHTS
        val m = if (useStep) 6 else 5
        val xm = xs.map { it.copyOf(m) }
        val general = doubleArrayOf(Formulas.REC_BIAS, Formulas.REC_K_HRV, Formulas.REC_K_RHR, Formulas.REC_K_PCT)
        var errP = 0.0; var errG = 0.0
        for (k in 0 until 10) {
            val trX = ArrayList<DoubleArray>(); val trY = ArrayList<Double>()
            for (i in 0 until n) if (i % 10 != k) { trX.add(xm[i]); trY.add(ys[i]) }
            val c = leastSquares(trX, trY) ?: return Fit(n, null, null, null)
            for (i in 0 until n) if (i % 10 == k) {
                errP += abs(pred(c, xm[i]) - ys[i])
                errG += abs(clamp(general[0] + general[1] * xs[i][1] + general[2] * xs[i][2] + general[3] * xs[i][3] +
                    Formulas.recoveryStep(dates[i])) - ys[i])
            }
        }
        val cvP = errP / n; val cvG = errG / n
        val all = leastSquares(xm, ys)
        val use = all != null && cvP <= cvG - MIN_GAIN
        val meanSleep = xs.sumOf { it[4] } / n
        val coef = if (use) doubleArrayOf(all!![0], all[1], all[2], all[3], all[4], if (useStep) all[5] else 0.0, meanSleep) else null
        return Fit(n, coef, cvP, cvG)
    }

    private fun clamp(v: Double) = v.roundToInt().coerceIn(1, 99).toDouble()
    private fun pred(c: DoubleArray, x: DoubleArray): Double {
        var s = 0.0
        for (j in c.indices) s += c[j] * x[j]
        return clamp(s)
    }

    /** Mínimos cuadrados con las ecuaciones normales (m×m) y eliminación de Gauss. */
    fun leastSquares(xs: List<DoubleArray>, ys: List<Double>): DoubleArray? {
        val m = xs.firstOrNull()?.size ?: return null
        val a = Array(m) { DoubleArray(m + 1) }
        for ((x, y) in xs.zip(ys)) for (r in 0 until m) { for (c in 0 until m) a[r][c] += x[r] * x[c]; a[r][m] += x[r] * y }
        for (col in 0 until m) {
            var piv = col
            for (r in col + 1 until m) if (abs(a[r][col]) > abs(a[piv][col])) piv = r
            if (abs(a[piv][col]) < 1e-12) return null
            val t = a[col]; a[col] = a[piv]; a[piv] = t
            for (r in 0 until m) if (r != col) {
                val f = a[r][col] / a[col][col]
                for (c in col..m) a[r][c] -= f * a[col][c]
            }
        }
        return DoubleArray(m) { a[it][m] / a[it][it] }
    }
}
