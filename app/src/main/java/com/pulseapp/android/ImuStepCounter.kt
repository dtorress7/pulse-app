package com.pulseapp.android

import kotlin.math.sqrt

/**
 * Contador de pasos en tiempo real a partir del acelerómetro de muñeca (100 Hz).
 *
 * Calibrado con la prueba del 14/10:
 *   quieto 2 min → 0 pasos · andando ~2 min → 153 (≈ 90 pasos/min).
 *   Mover el brazo fuerte suma algunos "pasos" falsos (~30/min), como en casi todas las pulseras;
 *   se descartan los golpes de más de 3 g y los giros rápidos de muñeca (> 250 °/s de media).
 *
 * Método:
 *   1. Módulo de la aceleración |a| (en g).
 *   2. Señal = media de 0,1 s − media de 1 s (quita la gravedad), alineadas en el tiempo.
 *   3. Pico > 0,08 g separado ≥ 0,3 s del anterior = paso candidato.
 *   4. Sólo cuenta si hay ritmo: 8 pasos seguidos (25/10; antes 4) con intervalos de 0,3–1,5 s y parecidos entre sí.
 */
class ImuStepCounter {

    var totalSteps = 0
        private set

    private val fast = Ring(FAST)
    private val slow = Ring(SLOW)
    private val gyro = Ring(SLOW)
    private val magWindow = FloatArray(SLOW)
    private val fastHistory = FloatArray(DELAY + 1)
    private var fastHistoryCount = 0
    private var fastHistoryPos = 0

    private var index = 0L
    private var x1 = 0f
    private var x2 = 0f
    private var lastPeak = Long.MIN_VALUE / 2
    private val run = ArrayList<Long>()

    /** Llamar si se pierden datos (hueco de conexión): corta la racha de pasos en curso. */
    fun gap() {
        run.clear()
    }

    /** Procesa un segundo entero. Devuelve los pasos nuevos contados en ese segundo. */
    fun feed(s: ImuSecond): Int {
        val before = totalSteps
        for (i in 0 until s.size) {
            val ax = s.ax[i]; val ay = s.ay[i]; val az = s.az[i]
            if (ax.isNaN() || ay.isNaN() || az.isNaN()) continue
            val gx = s.gx[i]; val gy = s.gy[i]; val gz = s.gz[i]
            val g = if (gx.isNaN() || gy.isNaN() || gz.isNaN()) 0f else sqrt(gx * gx + gy * gy + gz * gz)
            sample(sqrt(ax * ax + ay * ay + az * az), g)
        }
        return totalSteps - before
    }

    private fun sample(mag: Float, gyroMag: Float) {
        fast.add(mag)
        slow.add(mag)
        gyro.add(gyroMag)
        magWindow[(index % SLOW).toInt()] = mag

        fastHistory[fastHistoryPos] = fast.mean()
        fastHistoryPos = (fastHistoryPos + 1) % fastHistory.size
        if (fastHistoryCount < fastHistory.size) fastHistoryCount++
        // valor de la media rápida de hace DELAY muestras (queda centrada con la media lenta)
        val delayedFast = fastHistory[fastHistoryPos % fastHistory.size]
        val x = delayedFast - slow.mean()

        val i = index
        index++
        val ready = slow.count == SLOW && fastHistoryCount == fastHistory.size
        if (ready && x1 > PEAK_THRESHOLD_G && x1 >= x2 && x1 > x) {
            val peak = i - 1 - DELAY
            if (peak - lastPeak >= MIN_GAP_SAMPLES && !isArmShake()) onPeak(peak)
        }
        x2 = x1
        x1 = x
    }

    private fun isArmShake(): Boolean {
        var max = 0f
        for (v in magWindow) if (v > max) max = v
        return max > MAX_STEP_G || gyro.mean() > MAX_STEP_GYRO_DPS
    }

    private fun onPeak(p: Long) {
        if (run.isNotEmpty()) {
            val dt = (p - run[run.size - 1]) / 100f
            val prev = if (run.size > 1) (run[run.size - 1] - run[run.size - 2]) / 100f else dt
            val rhythmic = dt in 0.3f..1.5f && maxOf(dt, prev) / minOf(dt, prev) < 2.2f
            if (!rhythmic) run.clear()
        }
        lastPeak = p
        run.add(p)
        if (run.size > 10) run.removeAt(0)
        when {
            run.size == MIN_RUN && !inRun -> { totalSteps += MIN_RUN; inRun = true }
            run.size >= MIN_RUN && inRun -> totalSteps += 1
        }
        if (run.size == 1) inRun = false
    }

    private var inRun = false

    private class Ring(val capacity: Int) {
        private val data = FloatArray(capacity)
        private var pos = 0
        var count = 0
            private set
        private var sum = 0.0
        fun add(v: Float) {
            if (count == capacity) sum -= data[pos] else count++
            data[pos] = v
            sum += v
            pos = (pos + 1) % capacity
        }
        fun mean(): Float = if (count == 0) 0f else (sum / count).toFloat()
    }

    companion object {
        private const val FAST = 10          // 0,1 s
        private const val SLOW = 100         // 1 s
        private const val DELAY = 45         // alinea la media rápida con el centro de la lenta
        private const val PEAK_THRESHOLD_G = 0.08f
        private const val MIN_GAP_SAMPLES = 30   // 0,3 s entre pasos como mínimo
        // 25/10: 4 → 8 pasos seguidos con ritmo antes de contar (sentado gesticulando sumaba 4–20 por minuto sueltos).
        // Al llegar a 8 se suman los 8 de golpe, así andar de verdad no pierde ninguno (prueba de 100 pasos: 100).
        private const val MIN_RUN = 8
        // 26/10 (pruebas grabadas): andar rápido daba 12 de 40 (picos de 3 g, giro 200–300 °/s y ritmo algo irregular) →
        // 3 g → 4 g, 250 → 350 °/s y ritmo 1,6 → 2,2. Andar normal/móvil/bolsillo/rápido/escaleras: 27/27/27/42/26 (reales 26/26/26/40/25).
        private const val MAX_STEP_G = 4.0f
        private const val MAX_STEP_GYRO_DPS = 350f
    }
}
