package com.pulseapp.android

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Hora de cada línea de hr_log.csv (25/10, cambio de hora).
 *
 * El archivo guarda la hora LOCAL "yyyy-MM-ddTHH:mm:ss" sin zona. El último domingo de octubre la hora 02:00–03:00 se repite
 * y las dos pasadas quedaban con la misma hora: al leer se quedaba una y se perdía la otra (25/10: 1 h de la noche).
 * Ahora, cerca de un cambio de hora (±2 h) se escribe también el desfase: "2026-10-25T02:30:00+01:00". Los lectores
 * usan [parse], que respeta el desfase si está y si no lee la hora local como siempre. El resto del año no cambia nada.
 */
object HrTime {

    private val local = ThreadLocal.withInitial { SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US) }
    private val utc = ThreadLocal.withInitial {
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
    }

    private const val NEAR_MS = 2 * 3_600_000L

    /** Hora local; con el desfase (+hh:mm) si está a menos de 2 h de un cambio de hora. */
    fun format(timeMillis: Long): String {
        val base = local.get()!!.format(Date(timeMillis))
        val tz = TimeZone.getDefault()
        if (tz.getOffset(timeMillis - NEAR_MS) == tz.getOffset(timeMillis + NEAR_MS)) return base
        return base + suffix(tz.getOffset(timeMillis))
    }

    private fun suffix(offsetMs: Int): String {
        val m = offsetMs / 60_000
        val a = kotlin.math.abs(m)
        return String.format(Locale.US, "%s%02d:%02d", if (m < 0) "-" else "+", a / 60, a % 60)
    }

    /** Primer campo de la línea ("2026-10-25T02:30:00" o con "+01:00") → ms unix; null si no es una hora. */
    fun parse(field: String): Long? {
        if (field.length < 19) return null
        val s = field.substring(0, 19)
        if (field.length >= 25 && (field[19] == '+' || field[19] == '-') && field[22] == ':') {
            val h = field.substring(20, 22).toIntOrNull() ?: return null
            val m = field.substring(23, 25).toIntOrNull() ?: return null
            val off = (h * 60 + m) * 60_000L * (if (field[19] == '-') -1 else 1)
            val t = try { utc.get()!!.parse(s)?.time } catch (e: Exception) { null } ?: return null
            return t - off
        }
        return try { local.get()!!.parse(s)?.time } catch (e: Exception) { null }
    }

    // ---------- Arreglo único del 25/10/2026 (y de cualquier otro cambio de hora ya guardado sin desfase) ----------

    /**
     * Las líneas de la hora repetida sin desfase se escribieron en orden: primero la pasada de verano y luego la de invierno.
     * Se recorre el archivo en orden; dentro de la hora repetida, cuando la hora vuelve atrás ≥ 30 min empieza la 2.ª pasada.
     * Se reescriben esas líneas con su desfase. Devuelve cuántas líneas se han marcado (0 = no había nada que arreglar).
     */
    fun repairFile(file: File): Int {
        if (!file.exists()) return 0
        val tz = TimeZone.getDefault()
        val u = utc.get()!!
        // ¿Hay alguna hora repetida en las líneas? (primera pasada rápida, sin escribir)
        fun ambiguous(naiveUtc: Long): Pair<Int, Int>? {
            val o1 = tz.getOffset(naiveUtc - 3 * 3_600_000L)   // antes del cambio (verano)
            val o2 = tz.getOffset(naiveUtc + 3 * 3_600_000L)   // después (invierno)
            if (o1 <= o2) return null
            val t1 = naiveUtc - o1; val t2 = naiveUtc - o2
            return if (tz.getOffset(t1) == o1 && tz.getOffset(t2) == o2) o1 to o2 else null
        }
        var any = false
        file.forEachLine { line ->
            if (any || line.length < 20 || line[0] != '2' || line[19] != ',') return@forEachLine
            if (line[11] !in '0'..'3') return@forEachLine
            val n = try { u.parse(line.substring(0, 19))?.time } catch (e: Exception) { null } ?: return@forEachLine
            if (ambiguous(n) != null) any = true
        }
        if (!any) return 0
        val tmp = File(file.parentFile, file.name + ".dst.tmp")
        var marked = 0
        var maxNaive = Long.MIN_VALUE
        var second = false
        tmp.bufferedWriter().use { w ->
            file.forEachLine { line ->
                if (line.length >= 20 && line[0] == '2' && line[19] == ',') {
                    val n = try { u.parse(line.substring(0, 19))?.time } catch (e: Exception) { null }
                    val amb = n?.let { ambiguous(it) }
                    if (n != null && amb != null) {
                        if (!second && maxNaive != Long.MIN_VALUE && n < maxNaive - 30 * 60_000L) second = true
                        if (n > maxNaive) maxNaive = n
                        w.write(line.substring(0, 19)); w.write(suffix(if (second) amb.second else amb.first)); w.write(line.substring(19)); w.write("\n")
                        marked++
                        return@forEachLine
                    } else if (n != null && maxNaive != Long.MIN_VALUE && n > maxNaive + 3_600_000L) {
                        maxNaive = Long.MIN_VALUE; second = false   // pasado el cambio: listo para el siguiente
                    }
                }
                w.write(line); w.write("\n")
            }
        }
        val backup = File(file.parentFile, "hr_log_antes_cambio_hora.csv")
        if (!backup.exists()) file.copyTo(backup)
        if (!tmp.renameTo(file)) { file.delete(); tmp.renameTo(file) }
        return marked
    }
}
