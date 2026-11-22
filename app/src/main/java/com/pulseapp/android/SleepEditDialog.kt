package com.pulseapp.android

import android.app.Activity
import android.app.TimePickerDialog
import androidx.appcompat.app.AlertDialog
import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * "Editar sueño" (22/11), como en WHOOP: cambiar la hora en que te acostaste/dormiste y la de despertar de una noche.
 * La noche pasa a ser exactamente ese tramo (ver [SleepEdits]); "Restablecer" vuelve a la detección automática.
 * [date] = día en que te despertaste. [onSaved] se llama en el hilo principal tras guardar o restablecer.
 */
object SleepEditDialog {
    private val zone: ZoneId = ZoneId.systemDefault()

    private fun fmt(ms: Long): String {
        val t = Instant.ofEpochMilli(ms).atZone(zone).toLocalTime()
        return String.format("%02d:%02d", t.hour, t.minute)
    }

    /** Hora del reloj → instante de esa noche: de 12:00 a 23:59 es la víspera, de 00:00 a 11:59 el día del despertar. */
    private fun toMillis(date: LocalDate, h: Int, m: Int): Long =
        (if (h >= 12) date.minusDays(1) else date).atTime(LocalTime.of(h, m)).atZone(zone).toInstant().toEpochMilli()

    fun show(a: Activity, dir: File, date: LocalDate, fromMs: Long, toMs: Long, onSaved: (Long, Long?) -> Unit) {
        val key = date.toString()
        val edited = SleepEdits.forDate(dir, key) != null
        var start = fromMs; var end = toMs
        fun open() {
            val items = arrayOf("Inicio del sueño:  ${fmt(start)}", "Fin del sueño:  ${fmt(end)}")
            val b = AlertDialog.Builder(a)
                .setTitle("Editar sueño")
                .setItems(items) { _, w ->
                    val cur = Instant.ofEpochMilli(if (w == 0) start else end).atZone(zone).toLocalTime()
                    TimePickerDialog(a, { _, h, m ->
                        if (w == 0) start = toMillis(date, h, m) else end = toMillis(date, h, m)
                        open()
                    }, cur.hour, cur.minute, true).apply { setOnCancelListener { open() } }.show()
                }
                .setPositiveButton("Guardar") { _, _ ->
                    val min = (end - start) / 60_000L
                    if (min < 60 || min > 16 * 60) {
                        AlertDialog.Builder(a).setTitle("Horas no válidas")
                            .setMessage("El sueño tiene que durar entre 1 y 16 horas (ahora ${fmt(start)}–${fmt(end)}).")
                            .setPositiveButton("Corregir") { _, _ -> open() }.show()
                    } else {
                        SleepEdits.save(dir, key, start, end)
                        onSaved(start, end)
                    }
                }
                .setNegativeButton("Cancelar", null)
            if (edited) b.setNeutralButton("Restablecer") { _, _ -> SleepEdits.clear(dir, key); onSaved(fromMs, null) }
            b.show()
        }
        open()
    }
}
