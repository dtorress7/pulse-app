package com.pulseapp.android

import android.content.Context
import java.util.Calendar

/**
 * 9/11: planificador de sueño y alarma como WHOOP (iOS `Core/SleepAlarm.swift`, mismas reglas).
 * - Modos: hora exacta, objetivo de sueño (vibra cuando has dormido tu meta), en verde (recuperación ≥ 67). La alarma de la
 *   PULSERA queda siempre a la hora de despertar; en los modos inteligentes el móvil la lanza antes (ventana de 90 min).
 * - Meta (IA de WHOOP 9/11): "Lograr mi sueño necesario" al 70/85/100 % o "Mejorar mi sueño" (sin regla publicada → como
 *   lograr al 100 %, PROVISIONAL).
 * - Horario ("Mi horario"): días con su hora y su modo (o sin alarma).
 */
object SleepAlarm {
    const val MODE_EXACT = 0
    const val MODE_GOAL = 1
    const val MODE_GREEN = 2
    const val MODE_NONE = -1
    const val SMART_WINDOW_MIN = 90
    private const val PREFS = "pulseapp_sleep_alarm"

    data class Entry(val days: Int, val minute: Int, val mode: Int)   // days: bit 0 = lunes … bit 6 = domingo

    private fun p(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    fun mode(ctx: Context) = p(ctx).getInt("mode", MODE_EXACT)
    fun setMode(ctx: Context, m: Int) = p(ctx).edit().putInt("mode", m).apply()
    fun goal(ctx: Context) = p(ctx).getInt("goal", 0)
    fun setGoal(ctx: Context, g: Int) = p(ctx).edit().putInt("goal", g).apply()
    fun goalPct(ctx: Context) = p(ctx).getInt("goal_pct", 100)
    fun setGoalPct(ctx: Context, v: Int) = p(ctx).edit().putInt("goal_pct", v).apply()
    fun goalLabel(ctx: Context) = if (goal(ctx) == 1) "Mejorar mi sueño" else "Lograr el ${goalPct(ctx)} % de mi sueño necesario"
    fun scheduleOn(ctx: Context) = p(ctx).getBoolean("schedule_on", false)
    fun setScheduleOn(ctx: Context, on: Boolean) = p(ctx).edit().putBoolean("schedule_on", on).apply()
    fun firedUnix(ctx: Context) = p(ctx).getLong("fired", 0L)
    fun setFiredUnix(ctx: Context, v: Long) = p(ctx).edit().putLong("fired", v).apply()

    fun schedule(ctx: Context): List<Entry> {
        val s = p(ctx).getString("schedule", null)
            ?: return listOf(Entry(0b0011111, SleepPlanner.wakeMinute(ctx), MODE_EXACT), Entry(0b1100000, 9 * 60 + 15, MODE_NONE))
        return s.split(';').mapNotNull { e -> val a = e.split(':').mapNotNull { it.toIntOrNull() }; if (a.size == 3) Entry(a[0], a[1], a[2]) else null }
    }
    fun setSchedule(ctx: Context, e: List<Entry>) =
        p(ctx).edit().putString("schedule", e.joinToString(";") { "${it.days}:${it.minute}:${it.mode}" }).apply()

    fun goalFactor(ctx: Context) = if (goal(ctx) == 1) 1.0 else goalPct(ctx) / 100.0

    /** Lunes = 0 … domingo = 6 */
    fun weekdayIndex(c: Calendar) = (c.get(Calendar.DAY_OF_WEEK) + 5) % 7

    fun dayNames(days: Int): String {
        val n = listOf("LUN.", "MAR.", "MIÉ.", "JUE.", "VIE.", "SÁB.", "DOM.")
        return (0 until 7).filter { days and (1 shl it) != 0 }.joinToString(" · ") { n[it] }
    }

    fun modeName(m: Int) = when (m) {
        MODE_GOAL -> "OBJETIVO DE SUEÑO"
        MODE_GREEN -> "EN VERDE"
        MODE_NONE -> "ALARMA APAGADA"
        else -> "HORA EXACTA"
    }

    data class Next(val unix: Long, val minute: Int, val mode: Int)

    /** La próxima mañana (hoy si la hora aún no ha pasado, si no mañana) con su hora y modo. */
    fun next(ctx: Context, nowMs: Long = System.currentTimeMillis()): Next {
        val sched = scheduleOn(ctx)
        val entries = if (sched) schedule(ctx) else emptyList()
        val fired = firedUnix(ctx)
        for (add in 0..7) {
            val day = Calendar.getInstance().apply { timeInMillis = nowMs; add(Calendar.DAY_OF_MONTH, add) }
            var minute = SleepPlanner.wakeMinute(ctx)
            var m = if (WhoopBackgroundService.alarmEnabled(ctx)) mode(ctx) else MODE_NONE
            if (sched) {
                val wd = weekdayIndex(day)
                val e = entries.firstOrNull { it.days and (1 shl wd) != 0 } ?: continue
                minute = e.minute; m = e.mode
            }
            day.set(Calendar.HOUR_OF_DAY, minute / 60); day.set(Calendar.MINUTE, minute % 60)
            day.set(Calendar.SECOND, 0); day.set(Calendar.MILLISECOND, 0)
            // 10/11: la de hoy sigue siendo "la próxima" hasta 2 min DESPUÉS de su hora (antes, en el último minuto pasaba a la de mañana
            // y PulseApp la reescribía: evento 56 con la hora de mañana; por eso nunca vibraba)
            if (day.timeInMillis <= nowMs - 120_000L) continue
            val u = day.timeInMillis / 1000
            if (u == fired) continue   // ya sonó antes de tiempo esa mañana
            return Next(u, minute, m)
        }
        val w = SleepPlanner.wakeMinute(ctx)
        val c = Calendar.getInstance().apply {
            timeInMillis = nowMs; add(Calendar.DAY_OF_MONTH, 1); set(Calendar.HOUR_OF_DAY, w / 60); set(Calendar.MINUTE, w % 60)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
        }
        return Next(c.timeInMillis / 1000, w, MODE_NONE)
    }

    /** Tiempo medio despierto en la cama (WHOOP lo suma a la meta: "+0:30"). PROVISIONAL: media de las últimas 28 noches redondeada
     *  hacia arriba a 5 min (24 noches de WHOOP 17/10→9/11: 26,8 → 30 = WHOOP; un solo dato). Sin noches, 30. */
    fun avgAwakeMinutes(awake: List<Int?>): Int {
        val v = awake.takeLast(28).filterNotNull().filter { it > 0 }
        if (v.size < 3) return 30
        return Math.ceil(v.average() / 5.0).toInt() * 5
    }

    data class Plan(
        val base: Int, val strain: Int, val debt: Int, val nap: Int, val need: Int,
        val goal: Int, val awake: Int, val inBed: Int, val bedMinute: Int, val wakeMinute: Int, val mode: Int, val alarmUnix: Long,
        /** "Óptimo" de WHOOP y regularidad prevista para mañana (solo con "Mejorar mi sueño"). */
        val optBed: Int? = null, val optWake: Int? = null, val regularity: Int? = null,
        /** Datos con los que se calculó (para rehacerlo en el planificador). */
        val awakeList: List<Int?> = emptyList(), val nights: List<Night> = emptyList(), val naps: List<List<Pair<Int, Int>>> = emptyList()
    )

    /** Una noche guardada: fecha en que acaba (yyyy-MM-dd), inicio y fin en minutos del día (hora local). */
    data class Night(val date: String, val start: Int, val end: Int)

    private fun round(m: Int, q: Int) = Math.round(m.toDouble() / q).toInt() * q
    private fun wrap(m: Int) = ((m % 1440) + 1440) % 1440

    /**
     * Plan de esta noche con la necesidad que ya calcula Inicio (iOS igual; ver SleepAlarm.swift para la comprobación con las capturas
     * de WHOOP del 9/11: Mejorar 7:30 → 22:45/8:45/66 %, 8:30 → 23:15/9:15/74 %, Óptimo 22:45–7:35).
     * - Óptimo (PROVISIONAL): tiempo en cama al 100 % redondeado a 5 min acabando a tu hora media de despertar (28 noches del mismo tipo de día).
     * - Mejorar (PROVISIONAL): a mitad de camino entre la hora para tu necesidad y la del Óptimo, redondeado a 15 min.
     * - Regularidad prevista = Formulas.sleepConsistency con las 3 noches anteriores.
     */
    fun plan(ctx: Context, awake: List<Int?>, p: SleepPlan, nights: List<Night> = emptyList(), naps: List<List<Pair<Int, Int>>> = emptyList(),
             nowMs: Long = System.currentTimeMillis()): Plan {
        val nx = next(ctx, nowMs)
        val aw = avgAwakeMinutes(awake)
        val fullInBed = p.totalNeedMinutes + aw
        var goalMin = Math.round(p.totalNeedMinutes * goalFactor(ctx)).toInt()
        var inBed = goalMin + aw
        var bed = wrap(nx.minute - inBed)
        val wakeDay = java.time.Instant.ofEpochSecond(nx.unix).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        val weekend = wakeDay.dayOfWeek.value >= 6
        var optBed: Int? = null
        var optWake: Int? = null
        val cutoff = wakeDay.minusDays(28).toString()
        val same = nights.filter { n ->
            n.date >= cutoff && (try { java.time.LocalDate.parse(n.date).dayOfWeek.value >= 6 } catch (_: Exception) { return@filter false }) == weekend
        }
        if (same.size >= 5) {
            val w = round(Math.round(same.map { it.end }.average()).toInt(), 5)
            optWake = w
            optBed = wrap(w - round(fullInBed, 5))
        }
        var regularity: Int? = null
        if (goal(ctx) == 1) {
            val needBed = nx.minute - fullInBed
            var b = needBed
            optBed?.let { ob -> val o = if (ob > 720) ob - 1440 else ob; b = Math.round((needBed + o) / 2.0).toInt() }
            bed = wrap(round(b, 15))
            inBed = wrap(nx.minute - bed)
            goalMin = inBed - aw
            val prev = nights.takeLast(3)
            if (prev.isNotEmpty()) {
                val all = prev.map { Formulas.standardNight(it.date, it.start, it.end) } + Formulas.standardNight(wakeDay.toString(), bed, nx.minute)
                val np = naps.takeLast(prev.size) + listOf(emptyList())
                regularity = Formulas.sleepConsistency(all, if (np.size == all.size) np else null)
            }
        }
        return Plan(p.baselineMinutes, p.strainAdjustmentMinutes, p.debtAdjustmentMinutes, p.napAdjustmentMinutes, p.totalNeedMinutes,
            goalMin, aw, inBed, bed, nx.minute, nx.mode, nx.unix, optBed, optWake, regularity, awake, nights, naps)
    }

    /** ¿Hay que despertar ya? (modos inteligentes, dentro de la ventana antes de la hora de despertar) */
    fun shouldWakeEarly(mode: Int, asleepMinutes: Int?, goalMinutes: Int, recovery: Int?): Boolean = when (mode) {
        MODE_GOAL -> (asleepMinutes ?: 0) >= goalMinutes
        MODE_GREEN -> (recovery ?: 0) >= 67
        else -> false
    }
}
