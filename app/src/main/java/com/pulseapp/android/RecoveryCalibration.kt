package com.pulseapp.android

import com.pulseapp.android.data.DailyMetrics
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Calibración personal de la recuperación (14/11) con el export de WHOOP de cada persona.
 *
 * La fórmula general se ajustó con las 200 noches del primer usuario. Para otra persona se ajustan los mismos 4 números
 * (base, peso de la VFC, de la FCR y del percentil) con SUS noches importadas (recuperación de WHOOP + VFC + FCR), usando la
 * misma línea base que la app (BaselineProvider con los 30 días anteriores). Solo se usan si:
 *  - hay al menos [MIN_NIGHTS] noches (con las 200 noches del primer usuario: ajustar con las últimas 30 daba 5,5 de error
 *    hacia delante, con 90 3,6 y con 190 3,3, frente a 3,2 de la general), y
 *  - en validación cruzada (10 partes) sobre esas noches fallan menos que la general al menos [MIN_GAIN] puntos.
 * Si no, se queda la general. Las noches desde el 10/11 se ajustan quitando el escalón de WHOOP ([Formulas.REC_WHOOP_STEP]).
 */
object RecoveryCalibration {
    const val MIN_NIGHTS = 90
    const val MIN_GAIN = 0.3
    private const val WARMUP = 10

    data class Fit(val n: Int, val coef: DoubleArray?, val cvPersonal: Double?, val cvGeneral: Double?) {
        val usePersonal get() = coef != null
    }

    /** [days] en cualquier orden; usa los que tienen recuperación de WHOOP, VFC y FCR. */
    fun fit(days: List<DailyMetrics>): Fit {
        val sorted = days.sortedBy { it.date }
        val xs = ArrayList<DoubleArray>(); val ys = ArrayList<Double>()
        for ((i, d) in sorted.withIndex()) {
            if (i < WARMUP) continue
            val rec = d.whoopRecovery ?: continue
            val hrv = d.avgHrv?.takeIf { it > 0 } ?: continue
            val rhr = d.restingHr ?: continue
            val prev = sorted.subList(0, i).asReversed().take(BaselineProvider.LOOKBACK_DAYS)
            val b = BaselineProvider().computeFrom(prev) ?: continue
            val f = Formulas.recoveryFeatures(hrv, rhr, b)
            // misma forma que Formulas.recovery: c0 + c1·ΔVFC − c2·ΔFCR + c3·Φ
            xs.add(doubleArrayOf(1.0, f[0], -f[1], f[2]))
            ys.add(rec - Formulas.recoveryStep(d.date))
        }
        val n = xs.size
        if (n < MIN_NIGHTS) return Fit(n, null, null, null)
        val general = doubleArrayOf(Formulas.REC_BIAS, Formulas.REC_K_HRV, Formulas.REC_K_RHR, Formulas.REC_K_PCT)
        var errP = 0.0; var errG = 0.0
        for (k in 0 until 10) {
            val trX = ArrayList<DoubleArray>(); val trY = ArrayList<Double>()
            for (i in 0 until n) if (i % 10 != k) { trX.add(xs[i]); trY.add(ys[i]) }
            val c = leastSquares(trX, trY) ?: return Fit(n, null, null, null)
            for (i in 0 until n) if (i % 10 == k) { errP += abs(pred(c, xs[i]) - ys[i]); errG += abs(pred(general, xs[i]) - ys[i]) }
        }
        val cvP = errP / n; val cvG = errG / n
        val all = leastSquares(xs, ys)
        val use = all != null && cvP <= cvG - MIN_GAIN
        return Fit(n, if (use) all else null, cvP, cvG)
    }

    private fun pred(c: DoubleArray, x: DoubleArray): Double =
        (c[0] * x[0] + c[1] * x[1] + c[2] * x[2] + c[3] * x[3]).roundToInt().coerceIn(1, 99).toDouble()

    /** Mínimos cuadrados con las ecuaciones normales (4×4) y eliminación de Gauss. */
    fun leastSquares(xs: List<DoubleArray>, ys: List<Double>): DoubleArray? {
        val m = 4
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
