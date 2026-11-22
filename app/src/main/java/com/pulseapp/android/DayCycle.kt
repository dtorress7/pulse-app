package com.pulseapp.android

import java.time.LocalDate
import java.time.ZoneId

/**
 * Día "de sueño a sueño" como WHOOP (22/11, a petición del usuario y de Pablo). En WHOOP el día (ciclo) NO cambia a las 00:00:
 * empieza cuando te duermes y acaba cuando vuelves a dormirte (API: el ciclo empieza exactamente en el inicio del sueño, p. ej.
 * 21/11 21:50:43Z = inicio editado de la noche, y se crea al despertar). El día lleva la fecha del día en que te despiertas.
 * Si son las 00:30 y aún no has dormido, sigues en el día anterior (misma recuperación, el esfuerzo sigue sumando).
 *
 * Una noche cuenta como el comienzo del día nuevo si tiene ≥ 3 h dormido y acaba después de las 03:00 de ese día (export de
 * WHOOP, 199 noches: dormido mínimo 3:29 y despertar más temprano 06:29 → así un rato quieto en el sofá antes de las 3 no abre
 * el día nuevo). iOS: Core/DayCycle.swift (mismas reglas).
 */
object DayCycle {
    const val MIN_ASLEEP_MIN = 180
    const val MIN_END_HOUR = 3

    /** ¿La noche que acaba en [date] abre ya el día [date]? */
    fun opensDay(asleepMinutes: Int?, endMillis: Long?, date: LocalDate, zone: ZoneId = ZoneId.systemDefault()): Boolean {
        if (asleepMinutes == null || endMillis == null || asleepMinutes < MIN_ASLEEP_MIN) return false
        return endMillis >= date.atStartOfDay(zone).plusHours(MIN_END_HOUR.toLong()).toInstant().toEpochMilli()
    }

    /** Inicio del día [date]: el comienzo de su noche (minutos del día guardados) o, sin noche, las 00:00. */
    fun startMillis(date: LocalDate, sleepStartMinute: Int?, sleepEndMinute: Int?, zone: ZoneId = ZoneId.systemDefault()): Long {
        val d0 = date.atStartOfDay(zone).toInstant().toEpochMilli()
        if (sleepStartMinute == null || sleepEndMinute == null) return d0
        return if (sleepStartMinute > sleepEndMinute) d0 - (1440 - sleepStartMinute) * 60_000L else d0 + sleepStartMinute * 60_000L
    }

    @Volatile private var current: LocalDate? = null
    @Volatile private var currentAt = 0L

    /** Lo fija Inicio cada vez que calcula hoy. */
    fun setToday(date: LocalDate) { current = date; currentAt = System.currentTimeMillis() }

    /** Día en curso (para las pantallas que eligen "hoy" + desplazamiento). Si no se ha calculado hace poco, el día del reloj. */
    fun today(zone: ZoneId = ZoneId.systemDefault()): LocalDate {
        val cal = LocalDate.now(zone)
        val c = current ?: return cal
        if (System.currentTimeMillis() - currentAt > 6 * 3_600_000L || c < cal.minusDays(1) || c > cal) return cal
        return c
    }
}
