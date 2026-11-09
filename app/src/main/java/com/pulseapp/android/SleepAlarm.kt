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
            if (day.timeInMillis <= nowMs + 60_000L) continue
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
        val goal: Int, val awake: Int, val inBed: Int, val bedMinute: Int, val wakeMinute: Int, val mode: Int, val alarmUnix: Long
    )

    /** Plan de esta noche con la necesidad que ya calcula Inicio. `awake` = tiempo despierto de las noches guardadas (en orden). */
    fun plan(ctx: Context, awake: List<Int?>, p: SleepPlan, nowMs: Long = System.currentTimeMillis()): Plan {
        val nx = next(ctx, nowMs)
        val goalMin = Math.round(p.totalNeedMinutes * goalFactor(ctx)).toInt()
        val aw = avgAwakeMinutes(awake)
        val inBed = goalMin + aw
        val bed = ((nx.minute - inBed) % 1440 + 1440) % 1440
        return Plan(p.baselineMinutes, p.strainAdjustmentMinutes, p.debtAdjustmentMinutes, p.napAdjustmentMinutes, p.totalNeedMinutes,
            goalMin, aw, inBed, bed, nx.minute, nx.mode, nx.unix)
    }

    /** ¿Hay que despertar ya? (modos inteligentes, dentro de la ventana antes de la hora de despertar) */
    fun shouldWakeEarly(mode: Int, asleepMinutes: Int?, goalMinutes: Int, recovery: Int?): Boolean = when (mode) {
        MODE_GOAL -> (asleepMinutes ?: 0) >= goalMinutes
        MODE_GREEN -> (recovery ?: 0) >= 67
        else -> false
    }
}
