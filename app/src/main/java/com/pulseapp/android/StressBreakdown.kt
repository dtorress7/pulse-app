package com.pulseapp.android

/**
 * Reparto del estrés en minutos (bajo < 1, medio 1–2, alto ≥ 2) como el Monitor de estrés de WHOOP:
 * DÍA TOTAL, SIN ACTIVIDAD (fuera del sueño y de las actividades) y SUEÑO. Cada punto de la serie son 5 min.
 */
object StressBreakdown {

    data class Mins(val low: Int, val mid: Int, val high: Int) {
        val total get() = low + mid + high
    }

    data class Day(val total: Mins, val noActivity: Mins, val sleep: Mins)

    private const val POINT_MIN = 5

    fun of(points: List<StressPoint>, sleep: List<LongRange>, activities: List<LongRange>): Day {
        val t = IntArray(3); val n = IntArray(3); val s = IntArray(3)
        for (p in points) {
            val center = p.timeMillis + POINT_MIN * 30_000L
            val level = when { p.score < 1f -> 0; p.score < 2f -> 1; else -> 2 }
            t[level] += POINT_MIN
            val inSleep = sleep.any { center in it }
            val inActivity = activities.any { center in it }
            if (inSleep) s[level] += POINT_MIN
            else if (!inActivity) n[level] += POINT_MIN
        }
        return Day(Mins(t[0], t[1], t[2]), Mins(n[0], n[1], n[2]), Mins(s[0], s[1], s[2]))
    }

    /** Media de varios días (redondeada al minuto). */
    fun average(days: List<Day>): Day? {
        if (days.isEmpty()) return null
        fun avg(pick: (Day) -> Mins) = Mins(
            Math.round(days.map { pick(it).low }.average()).toInt(),
            Math.round(days.map { pick(it).mid }.average()).toInt(),
            Math.round(days.map { pick(it).high }.average()).toInt()
        )
        return Day(avg { it.total }, avg { it.noActivity }, avg { it.sleep })
    }

    /** Diferencia como la enseña WHOOP: flecha y porcentaje frente al día habitual. */
    fun delta(today: Int, habitual: Int): Pair<Trend, String> = when {
        today == 0 && habitual == 0 -> Trend.SAME to "0:00"
        habitual == 0 -> Trend.UP to "—"
        today == habitual -> Trend.SAME to "0 %"
        else -> {
            val pct = Math.round(kotlin.math.abs(today - habitual) * 100.0 / habitual)
            (if (today > habitual) Trend.UP else Trend.DOWN) to "$pct %"
        }
    }
}
