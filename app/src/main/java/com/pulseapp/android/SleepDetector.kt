package com.pulseapp.android

import java.util.Calendar

/**
 * Detección del sueño solo con el pulso (mientras no tengamos el movimiento de la noche).
 *
 * Ajustada con tu noche del 14→15/10 comparada con WHOOP (23:17–07:20, 42 min despierto, eficiencia 92 %):
 *  - Pulso medio por minuto, suavizado con una media de 3 minutos.
 *  - Umbral = 1,30 × media del 10 % de lecturas más bajas de la noche.
 *  - Empieza en el primer minuto por debajo del umbral; tolera hasta 30 min seguidos por encima
 *    (despertares y REM suben el pulso); termina cuando pasa más de 30 min por encima o se acaban los datos.
 *  - Mínimo 90 min. Si hay varias ventanas, se coge la última (la noche más reciente).
 *  - Minutos "despierto" = minutos de la ventana por encima del umbral.
 * Resultado con esa noche: 23:20–07:24, 39 min despierto, eficiencia 92 % (WHOOP: 23:17–07:20, 42 min, 92 %).
 * Antes (1,25 y 20 min) cortaba en una subida de pulso a las 00:15 y daba 00:45.
 */
object SleepDetector {

    const val THRESHOLD_MULTIPLIER = 1.30
    const val GRACE_MINUTES = 30
    const val MIN_DURATION_MINUTES = 90
    const val DISCONNECT_GAP_MINUTES = 10
    const val SMOOTH_MINUTES = 3

    data class SleepWindow(
        val startMillis: Long,
        val endMillis: Long,
        val inBedMinutes: Int,
        val awakeMinutes: Int,
        val efficiencyPct: Int,
        val thresholdBpm: Double
    ) {
        val asleepMinutes get() = (inBedMinutes - awakeMinutes).coerceAtLeast(0)
    }

    /** Solo cuenta como posible noche lo que pasa entre las 20:00 y las 15:00. */
    fun isNightHour(timeMillis: Long): Boolean {
        val h = Calendar.getInstance().apply { this.timeInMillis = timeMillis }.get(Calendar.HOUR_OF_DAY)
        return h >= 20 || h < 15   // hasta las 15:00: te puedes despertar a las 12–14 (en tu export, hasta las 14:26)
    }

    private fun isSmallHours(timeMillis: Long): Boolean =
        Calendar.getInstance().apply { this.timeInMillis = timeMillis }.get(Calendar.HOUR_OF_DAY) < 6

    /** [readings] = (hora en ms, pulso), en cualquier orden. */
    fun detect(readings: List<Pair<Long, Int>>): SleepWindow? {
        val night = readings.filter { isNightHour(it.first) && it.second in 25..230 }.sortedBy { it.first }
        if (night.size < 60) return null

        // Medias por minuto y suavizado
        val perMinute = LinkedHashMap<Long, MutableList<Int>>()
        night.forEach { perMinute.getOrPut(it.first / 60000) { mutableListOf() }.add(it.second) }
        val keys = perMinute.keys.toList()
        val raw = perMinute.values.map { it.average() }
        val smooth = raw.indices.map { i -> raw.subList(maxOf(0, i - SMOOTH_MINUTES + 1), i + 1).average() }

        val sorted = night.map { it.second }.sorted()
        val low10 = sorted.take((sorted.size / 10).coerceAtLeast(1)).average()
        val threshold = low10 * THRESHOLD_MULTIPLIER

        val windows = mutableListOf<Pair<Int, Int>>()   // índices de inicio y fin en keys
        var start: Int? = null
        var aboveSince: Int? = null
        fun close(endIdx: Int) {
            val s = start ?: return
            if (keys[endIdx] - keys[s] >= MIN_DURATION_MINUTES) windows.add(s to endIdx)
        }
        for (i in keys.indices) {
            if (i > 0 && keys[i] - keys[i - 1] > DISCONNECT_GAP_MINUTES) {
                close(aboveSince?.let { it - 1 }?.coerceAtLeast(0) ?: (i - 1))
                start = null; aboveSince = null
            }
            if (smooth[i] <= threshold) {
                aboveSince = null
                if (start == null) start = i
            } else if (start != null) {
                if (aboveSince == null) aboveSince = i
                else if (keys[i] - keys[aboveSince!!] > GRACE_MINUTES) {
                    close((aboveSince!! - 1).coerceAtLeast(start!!))
                    start = null; aboveSince = null
                }
            }
        }
        if (start != null) close(keys.size - 1)
        // La NOCHE es la ventana que más se solapa con las 00:00–06:00 (21/10: una reunión quieto de 9:30 a 11:29 con el pulso
        // bajo salía como "la última ventana" y se tomaba como la noche).
        val (s, e) = windows.maxWithOrNull(compareBy<Pair<Int, Int>>({ w -> (w.first..w.second).count { isSmallHours(keys[it] * 60_000L) } },
            { w -> keys[w.second] - keys[w.first] })) ?: return null
        // 31/10: si ninguna ventana tiene al menos 30 min de madrugada, NO hay noche (antes se cogía la más larga: la noche 30→31 no se
        // grabó y salió "sueño" 9:38–12:40, calificación 31 % y recuperación 24 %). En el export de WHOOP las noches empiezan 22:36–01:54.
        if ((s..e).count { isSmallHours(keys[it] * 60_000L) } < 30) return null

        val inBed = (keys[e] - keys[s]).toInt()
        val minutesInWindow = (s..e).count()
        val awakeMinutes = (s..e).count { smooth[it] > threshold }
        val efficiency = if (minutesInWindow > 0) ((minutesInWindow - awakeMinutes) * 100 / minutesInWindow) else 0
        return SleepWindow(keys[s] * 60000, keys[e] * 60000, inBed, awakeMinutes, efficiency.coerceIn(0, 100), threshold)
    }
}
