package com.pulseapp.android

import android.app.Activity
import android.app.Dialog
import android.app.TimePickerDialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.pulseapp.android.ui.LoadingView

/**
 * 9/11: planificador de sueño como WHOOP (Android, con diálogos; la versión de iOS tiene pantallas propias).
 * Mensaje de la alarma, meta (lograr / mejorar), tiempo en cama con su desglose, alarma on/off, modo, hora y "Mi horario".
 * Al cambiar algo se guarda en la pulsera con la pantalla "Guardando…" (logo de PulseApp) hasta que responde.
 */
object SleepPlannerDialogs {
    private fun hm(m: Int) = "%d:%02d".format(m / 60, Math.abs(m) % 60)
    private fun clock(m: Int) = ((m % 1440) + 1440).let { x -> "%02d:%02d".format((x % 1440) / 60, x % 60) }

    fun show(a: Activity, base: SleepAlarm.Plan?, onChange: () -> Unit) {
        // Se recalcula con la meta, el modo y la hora de ahora (el tiempo despierto es el de Inicio)
        val plan = base?.let { SleepAlarm.plan(a, it.awakeList, SleepPlan(it.base, it.strain, it.debt, it.nap, it.need, null), it.nights, it.naps) }
        val nx = SleepAlarm.next(a)
        val alarmOn = nx.mode != SleepAlarm.MODE_NONE
        val pct = if (SleepAlarm.goal(a) == 1) "100 %" else "${SleepAlarm.goalPct(a)} %"
        val msg = StringBuilder()
        if (plan != null) {
            if (SleepAlarm.goal(a) == 1 && plan.regularity != null)
                msg.append("Acuéstate hoy a las ${clock(plan.bedMinute)} para lograr un ${plan.regularity} % de regularidad del sueño mañana.\n\n")
            else {
                msg.append(if (alarmOn) "Tu alarma se activará a las ${clock(plan.wakeMinute)}${if (plan.mode == SleepAlarm.MODE_EXACT) "" else " como muy tarde"}. " else "")
                msg.append("Acuéstate a las ${clock(plan.bedMinute)} para obtener el $pct del sueño requerido.\n\n")
            }
            msg.append("TIEMPO EN CAMA ${hm(plan.inBed)}  (${clock(plan.bedMinute)} – ${clock(plan.wakeMinute)})\n")
            if (plan.optBed != null && plan.optWake != null) msg.append("ÓPTIMO ${clock(plan.optBed)} – ${clock(plan.optWake)}\n")
            msg.append("Necesidad ${hm(plan.need)} = referencia ${hm(plan.base)} + esfuerzo ${hm(plan.strain)} + deuda ${hm(plan.debt)} − siestas ${hm(Math.abs(plan.nap))}\n")
            msg.append("Meta $pct ${hm(plan.goal)} + tiempo promedio despierto ${hm(plan.awake)}")
        } else msg.append("Aún no hay datos de esta noche para calcular tu plan.")
        val sched = SleepAlarm.scheduleOn(a)
        val items = arrayOf(
            "Mañana quiero: " + SleepAlarm.goalLabel(a),
            "Alarma: " + if (WhoopBackgroundService.alarmEnabled(a)) "activada" else "desactivada",
            "Alarma establecida en: " + SleepAlarm.modeName(SleepAlarm.mode(a)),
            "Hora de despertar: " + clock(SleepPlanner.wakeMinute(a)),
            "Mi horario: " + if (sched) "activado" else "desactivado",
        )
        AlertDialog.Builder(a)
            .setTitle("Planificador de sueño")
            .setMessage(msg.toString() + if (sched) "\n\n«Mi horario» está activado: la alarma de cada día sale de ahí." else "")
            .setPositiveButton("Opciones") { _, _ ->
                AlertDialog.Builder(a).setTitle("Planificador de sueño").setItems(items) { _, w ->
                    val reopen = { onChange(); show(a, base, onChange) }
                    when (w) {
                        0 -> AlertDialog.Builder(a).setTitle("Selecciona tu meta de sueño")
                            .setSingleChoiceItems(arrayOf("Lograr el 70 % de mi sueño necesario", "Lograr el 85 % de mi sueño necesario",
                                "Lograr el 100 % de mi sueño necesario", "Mejorar mi sueño (regularidad; de momento 100 %, provisional)"),
                                if (SleepAlarm.goal(a) == 1) 3 else when (SleepAlarm.goalPct(a)) { 70 -> 0; 85 -> 1; else -> 2 }) { d, g ->
                                if (g == 3) SleepAlarm.setGoal(a, 1) else { SleepAlarm.setGoal(a, 0); SleepAlarm.setGoalPct(a, listOf(70, 85, 100)[g]) }
                                d.dismiss(); reopen()
                            }.show()
                        1 -> { WhoopBackgroundService.setAlarmEnabled(a, !WhoopBackgroundService.alarmEnabled(a)); save(a, reopen) }
                        2 -> pickMode(a, false, SleepAlarm.mode(a)) { m -> SleepAlarm.setMode(a, m); save(a, reopen) }
                        3 -> { val cur = SleepPlanner.wakeMinute(a)
                            TimePickerDialog(a, { _, h, m -> SleepPlanner.setWakeMinute(a, h * 60 + m); save(a, reopen) }, cur / 60, cur % 60, true)
                                .apply { setTitle("Establece tu hora de despertar") }.show() }
                        4 -> schedule(a) { onChange() }
                    }
                }.show()
            }
            .setNegativeButton("Cerrar", null)
            .show()
    }

    private fun pickMode(a: Activity, allowNone: Boolean, current: Int, onPick: (Int) -> Unit) {
        val modes = mutableListOf(SleepAlarm.MODE_EXACT to "Hora exacta — despierta a una hora específica",
            SleepAlarm.MODE_GOAL to "Objetivo de sueño — despierta cuando alcances tu meta de sueño",
            SleepAlarm.MODE_GREEN to "En verde — despierta cuando tu recuperación esté en verde")
        if (allowNone) modes.add(SleepAlarm.MODE_NONE to "No usar alarma")
        AlertDialog.Builder(a).setTitle("Elige tu modo de alarma")
            .setSingleChoiceItems(modes.map { it.second }.toTypedArray(), modes.indexOfFirst { it.first == current }) { d, i ->
                d.dismiss(); onPick(modes[i].first)
            }.show()
    }

    /** "Mi horario": activar, editar o quitar tramos (días → modo → hora). */
    private fun schedule(a: Activity, onChange: () -> Unit) {
        val on = SleepAlarm.scheduleOn(a)
        val entries = SleepAlarm.schedule(a).toMutableList()
        val labels = entries.map { "${SleepAlarm.dayNames(it.days)}  ${clock(it.minute)}  ${SleepAlarm.modeName(it.mode)}" }.toMutableList()
        val used = entries.fold(0) { acc, e -> acc or e.days }
        if (used != 0b1111111) labels.add("+ Añadir días")
        AlertDialog.Builder(a).setTitle("Mi horario (" + (if (on) "activado" else "desactivado") + ")")
            .setItems(labels.toTypedArray()) { _, i ->
                if (i == entries.size) editEntry(a, SleepAlarm.Entry(0b1111111 and used.inv(), SleepPlanner.wakeMinute(a), SleepAlarm.MODE_EXACT), used) { e ->
                    entries.add(e); SleepAlarm.setSchedule(a, entries.filter { it.days != 0 }); if (on) save(a, onChange) else onChange()
                } else AlertDialog.Builder(a).setTitle(labels[i]).setItems(arrayOf("Editar", "Eliminar")) { _, w ->
                    if (w == 0) editEntry(a, entries[i], used and entries[i].days.inv()) { e ->
                        entries[i] = e; SleepAlarm.setSchedule(a, entries.filter { it.days != 0 }); if (on) save(a, onChange) else onChange()
                    } else { entries.removeAt(i); SleepAlarm.setSchedule(a, entries); if (on) save(a, onChange) else onChange() }
                }.show()
            }
            .setPositiveButton(if (on) "Desactivar horario" else "Activar horario") { _, _ ->
                SleepAlarm.setScheduleOn(a, !on); save(a, onChange)
            }
            .setNegativeButton("Cerrar", null).show()
    }

    private fun editEntry(a: Activity, e: SleepAlarm.Entry, otherDays: Int, onSave: (SleepAlarm.Entry) -> Unit) {
        val names = arrayOf("Lunes", "Martes", "Miércoles", "Jueves", "Viernes", "Sábado", "Domingo")
        val free = (0 until 7).filter { otherDays and (1 shl it) == 0 }
        val checked = free.map { e.days and (1 shl it) != 0 }.toBooleanArray()
        AlertDialog.Builder(a).setTitle("Selecciona días con horas de despertar repetidas")
            .setMultiChoiceItems(free.map { names[it] }.toTypedArray(), checked) { _, i, c -> checked[i] = c }
            .setPositiveButton("Siguiente") { _, _ ->
                val days = free.filterIndexed { i, _ -> checked[i] }.fold(0) { acc, d -> acc or (1 shl d) }
                if (days == 0) return@setPositiveButton
                pickMode(a, true, e.mode) { m ->
                    TimePickerDialog(a, { _, h, mi -> onSave(SleepAlarm.Entry(days, h * 60 + mi, m)) }, e.minute / 60, e.minute % 60, true)
                        .apply { setTitle("Establece tu hora de despertar") }.show()
                }
            }
            .setNegativeButton("Cancelar", null).show()
    }

    /** Guarda en la pulsera con "Guardando… Mantén tu WHOOP cerca" y el logo animado, luego "¡Correcto!". */
    fun save(a: Activity, after: () -> Unit) {
        WhoopBackgroundService.markAlarmSave(1)
        WhoopBackgroundService.start(a, WhoopBackgroundService.ACTION_ALARM)
        val d = Dialog(a, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        val dp = a.resources.displayMetrics.density
        val col = LinearLayout(a).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; setBackgroundColor(Color.BLACK); setPadding((30 * dp).toInt(), 0, (30 * dp).toInt(), 0) }
        val loading = LoadingView(a).apply { text = "GUARDANDO" }
        col.addView(loading, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (320 * dp).toInt()))
        val tv = TextView(a).apply { text = "Mantén tu WHOOP cerca mientras se guarda la alarma."; setTextColor(Color.WHITE); textSize = 16f; gravity = Gravity.CENTER }
        col.addView(tv)
        d.setContentView(col)
        d.window?.setBackgroundDrawable(ColorDrawable(Color.BLACK))
        d.setCancelable(false)
        d.show()
        val h = Handler(Looper.getMainLooper())
        val t0 = System.currentTimeMillis()
        val poll = object : Runnable {
            override fun run() {
                val st = WhoopBackgroundService.alarmSave
                if (st == 1 && System.currentTimeMillis() - t0 < 12_000L) { h.postDelayed(this, 300); return }
                col.removeView(loading)
                tv.textSize = 20f
                tv.text = if (st == 2) "✓\n\n¡CORRECTO!\nTu alarma se ha guardado."
                          else "!\n\nNO SE PUDO GUARDAR\nLa pulsera no está conectada. Se guardará sola en cuanto se conecte."
                tv.setTextColor(if (st == 2) Color.parseColor("#00F88A") else Color.parseColor("#F9C718"))
                WhoopBackgroundService.alarmSave = 0
                h.postDelayed({ try { d.dismiss() } catch (_: Exception) { }; after() }, 1600L)
            }
        }
        h.postDelayed(poll, 600)
    }
}
