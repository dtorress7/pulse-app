package com.pulseapp.android

/**
 * Estima la frecuencia respiratoria (respiraciones por minuto) a partir de
 * los intervalos RR de la ventana de sueño, usando el efecto de arritmia
 * sinusal respiratoria: el pulso se acelera al inhalar y se frena al exhalar,
 * y ese ciclo se repite al ritmo de la respiración.
 *
 * Método: suaviza la serie RR (media móvil), detecta picos locales (cada
 * pico = un ciclo respiratorio), y mide la distancia media entre picos.
 * Es una aproximación práctica, no un análisis espectral completo — funciona
 * razonablemente bien en tramos de sueño estable, pero puede fallar en
 * tramos con mucho movimiento o pocos datos RR.
 */
class RespiratoryRateCalculator {

    fun estimate(rrIntervalsMs: List<Double>): Double? {
        if (rrIntervalsMs.size < 30) return null // necesita datos suficientes para un ciclo fiable

        // Suaviza con media móvil de 5 muestras para quitar ruido de latido a latido
        val smoothed = movingAverage(rrIntervalsMs, windowSize = 5)
        if (smoothed.size < 10) return null

        // Detecta picos locales (máximos): cada uno marca aprox. el momento de inhalar
        val peakIndices = mutableListOf<Int>()
        for (i in 2 until smoothed.size - 2) {
            if (smoothed[i] > smoothed[i - 1] && smoothed[i] > smoothed[i - 2] &&
                smoothed[i] > smoothed[i + 1] && smoothed[i] > smoothed[i + 2]
            ) {
                peakIndices.add(i)
            }
        }
        if (peakIndices.size < 3) return null

        // Distancia media entre picos, en número de latidos
        val gaps = mutableListOf<Int>()
        for (i in 1 until peakIndices.size) {
            gaps.add(peakIndices[i] - peakIndices[i - 1])
        }
        val avgGapBeats = gaps.average()

        // Duración media de un latido en esta ventana (en segundos)
        val avgBeatDurationSec = rrIntervalsMs.average() / 1000.0

        // Duración de un ciclo respiratorio completo = nº de latidos por ciclo * duración de un latido
        val cycleDurationSec = avgGapBeats * avgBeatDurationSec
        if (cycleDurationSec <= 0) return null

        val breathsPerMinute = 60.0 / cycleDurationSec

        // Rango fisiológico plausible durante el sueño: 8-25 rpm. Fuera de eso, descartamos (ruido).
        return if (breathsPerMinute in 8.0..25.0) breathsPerMinute else null
    }

    private fun movingAverage(values: List<Double>, windowSize: Int): List<Double> {
        if (values.size < windowSize) return values
        val result = mutableListOf<Double>()
        for (i in 0..values.size - windowSize) {
            val window = values.subList(i, i + windowSize)
            result.add(window.average())
        }
        return result
    }
}
