package com.pulseapp.android

import android.content.Context
import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.AppDatabase
import com.pulseapp.android.data.DailyMetrics
import java.io.File
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.zip.ZipInputStream

/**
 * Importa el historial del export de WHOOP (23/10): "my_whoop_data_….zip" o sus CSV sueltos
 * (physiological_cycles.csv, sueño.csv, entrenamientos.csv).
 *
 * - Cada ciclo con noche → fila del día en que te despertaste (la noche que TERMINA ese día + el esfuerzo de ese ciclo),
 *   igual que las filas que guarda PulseApp. Hoy no se importa (hoy lo calcula PulseApp en directo).
 * - Entrenamientos y siestas → actividades. Si se solapan con una de PulseApp, manda la de WHOOP.
 * - WHOOP manda en todo lo anterior a hoy: los días y actividades de PulseApp que se sustituyen se copian antes en
 *   whoop_import_backup_<fecha>.csv (no se pierde nada).
 * - Después la línea base (VFC, FC reposo, respiración), la regularidad, la deuda y las medias de 30 días salen de tu
 *   historial de WHOOP, y cada noche nueva de PulseApp se suma encima.
 */
object WhoopImport {

    data class Result(val days: Int, val sessions: Int, val naps: Int, val replacedDays: Int, val replacedSessions: Int,
                      val from: String?, val until: String?, val backup: File?)

    /** Lee un zip del export o un CSV suelto. Devuelve nombre de archivo (sin carpeta) → contenido. */
    fun readInput(input: InputStream, displayName: String?): Map<String, String> {
        val bytes = input.readBytes()
        val isZip = bytes.size > 4 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()
        if (!isZip) return mapOf((displayName ?: "archivo.csv").substringAfterLast('/') to String(bytes, Charsets.UTF_8))
        val out = HashMap<String, String>()
        ZipInputStream(bytes.inputStream()).use { zip ->
            while (true) {
                val e = zip.nextEntry ?: break
                if (!e.isDirectory && e.name.endsWith(".csv", ignoreCase = true)) {
                    out[e.name.substringAfterLast('/')] = String(zip.readBytes(), Charsets.UTF_8)
                }
            }
        }
        return out
    }

    // ---------- CSV ----------

    fun parseCsv(text: String): List<Map<String, String>> {
        val rows = splitRows(text.removePrefix("﻿"))
        if (rows.isEmpty()) return emptyList()
        val header = rows[0].map { it.trim() }
        return rows.drop(1).filter { r -> r.any { it.isNotBlank() } }.map { r ->
            header.indices.associate { i -> header[i] to (r.getOrNull(i)?.trim() ?: "") }
        }
    }

    private fun splitRows(text: String): List<List<String>> {
        val rows = ArrayList<List<String>>()
        var row = ArrayList<String>()
        val cur = StringBuilder()
        var q = false
        var i = 0
        while (i < text.length) {
            val c = text[i]
            when {
                q && c == '"' && i + 1 < text.length && text[i + 1] == '"' -> { cur.append('"'); i++ }
                c == '"' -> q = !q
                !q && c == ',' -> { row.add(cur.toString()); cur.setLength(0) }
                !q && (c == '\n' || c == '\r') -> {
                    if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++
                    row.add(cur.toString()); cur.setLength(0); rows.add(row); row = ArrayList()
                }
                else -> cur.append(c)
            }
            i++
        }
        if (cur.isNotEmpty() || row.isNotEmpty()) { row.add(cur.toString()); rows.add(row) }
        return rows
    }

    private fun Map<String, String>.num(vararg keys: String): Double? {
        for (k in keys) { val v = this[k]?.replace(',', '.')?.toDoubleOrNull(); if (v != null) return v }
        return null
    }
    private fun Map<String, String>.str(vararg keys: String): String? {
        for (k in keys) { val v = this[k]; if (!v.isNullOrBlank()) return v }
        return null
    }

    private val tsFmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
    private fun millis(s: String?): Long? = s?.let { runCatching { tsFmt.parse(it)?.time }.getOrNull() }
    private fun minuteOfDay(s: String): Int? = runCatching { s.substring(11, 13).toInt() * 60 + s.substring(14, 16).toInt() }.getOrNull()

    /** Nombre de WHOOP → tipo de PulseApp (los que no están en la lista se quedan con el nombre de WHOOP). */
    fun mapSport(name: String): String {
        val n = name.lowercase()
        return when {
            "fútbol" in n || "futbol" in n || "soccer" in n -> "Fútbol"
            "pádel" in n || "padel" in n -> "Pádel"
            "pickleball" in n -> "Pickleball"
            "funcional" in n -> "Entrenamiento funcional"
            "fuerza" in n || "potencia" in n || "weightlifting" in n -> "Entrenamiento de fuerza"
            "caminar" in n || "senderismo" in n || "walking" in n || "hiking" in n -> "Caminar"
            "correr" in n || "running" in n -> "Correr"
            "ciclismo" in n || "bicicleta" in n || "cycling" in n -> "Ciclismo"
            n == "actividad" || n == "activity" -> "Otro"
            else -> name
        }
    }

    // ---------- Importar ----------

    class Parsed(val days: LinkedHashMap<String, DailyMetrics>, val sessions: List<ActivitySession>, val naps: Int)

    /** Días (hasta ayer) y actividades del export, sin tocar la base de datos. */
    fun parse(files: Map<String, String>, today: String, now: Long): Parsed {
        fun find(vararg names: String): List<Map<String, String>> {
            val key = files.keys.firstOrNull { k -> names.any { k.equals(it, ignoreCase = true) } } ?: return emptyList()
            return parseCsv(files.getValue(key))
        }
        val cycles = find("physiological_cycles.csv")
        val sleeps = find("sueño.csv", "sleeps.csv", "sueno.csv")
        val workouts = find("entrenamientos.csv", "workouts.csv")

        // Fases y despertares de sueño.csv por inicio de sueño (por si el ciclo no las trae)
        val sleepByStart = sleeps.filter { it["Siesta"] != "true" }.associateBy { it["Inicio del sueño"] ?: "" }

        // ---------- Días ----------
        val newDays = LinkedHashMap<String, DailyMetrics>()
        for (c in cycles) {
            val wake = c.str("Inicio de la vigilia") ?: continue
            val start = c.str("Inicio del sueño") ?: continue
            val date = wake.take(10)
            if (date >= today) continue
            val s = sleepByStart[start] ?: c
            newDays[date] = DailyMetrics(
                date = date,
                restingHr = c.num("Frecuencia cardíaca en reposo (lpm)")?.toInt(),
                avgHrv = c.num("Variabilidad de la frecuencia cardíaca (ms)"),
                sleepMinutes = s.num("Duración del sueño (min)")?.toInt(),
                strain = c.num("Esfuerzo del día"),
                vo2Max = null,
                caloriesKcal = c.num("Energía quemada (cal)"),
                sleepStartMinuteOfDay = minuteOfDay(start),
                sleepEndMinuteOfDay = minuteOfDay(wake),
                sleepEfficiencyPct = s.num("Eficiencia del sueño %")?.toInt(),
                respiratoryRate = s.num("Frecuencia respiratoria (rpm)"),
                lightMinutes = s.num("Duración de sueño ligero (min)")?.toInt(),
                deepMinutes = s.num("Duración de sueño profundo (SWS) (min)")?.toInt(),
                remMinutes = s.num("Duración de sueño REM (min)")?.toInt(),
                awakeMinutes = s.num("Tempo despierto/a (min)", "Tiempo despierto/a (min)")?.toInt(),
                wakeEpisodes = null,
                latencyMinutes = null,
                whoopRecovery = c.num("Puntuación de recuperación (%)")?.toInt(),
                whoopSleepScore = s.num("Calificación del sueño (%)")?.toInt(),
                whoopConsistency = s.num("Regularidad del sueño %")?.toInt(),
                whoopSleepNeed = s.num("Sueño necesario (min)")?.toInt()
            )
        }

        // ---------- Actividades (entrenos + siestas) ----------
        val newSessions = ArrayList<ActivitySession>()
        for (w in workouts) {
            val a = millis(w.str("Hora de inicio del entrenamiento")) ?: continue
            val b = millis(w.str("Hora de finalización del entrenamiento")) ?: continue
            if (b <= a || a > now) continue
            val mins = (b - a) / 60000.0
            val z = (1..5).map { i -> (w.num("Zona FC $i%") ?: 0.0) / 100.0 * mins }
            val z0 = (mins - z.sum()).coerceAtLeast(0.0)
            newSessions.add(ActivitySession(
                startMillis = a, endMillis = b + 999,
                avgHr = w.num("FC promedio (lpm)")?.toInt() ?: 0, maxHr = w.num("FC máx. (lpm)")?.toInt() ?: 0,
                strain = w.num("Esfuerzo de actividad") ?: 0.0, caloriesKcal = w.num("Energía quemada (cal)") ?: 0.0,
                minutesZone1 = Math.round(z[0]).toInt(), minutesZone2 = Math.round(z[1]).toInt(), minutesZone3 = Math.round(z[2]).toInt(),
                minutesZone4 = Math.round(z[3]).toInt(), minutesZone5 = Math.round(z[4]).toInt(),
                type = mapSport(w.str("Nombre de la actividad") ?: "Otro"), autoDetected = false,
                minutesZone0 = Math.round(z0).toInt()))
        }
        var naps = 0
        for (s in sleeps.filter { it["Siesta"] == "true" }) {
            val a = millis(s.str("Inicio del sueño")) ?: continue
            val b = millis(s.str("Inicio de la vigilia")) ?: continue
            if (b <= a || a > now) continue
            newSessions.add(ActivitySession(startMillis = a, endMillis = b, avgHr = 0, maxHr = 0, strain = 0.0, caloriesKcal = 0.0,
                minutesZone1 = 0, minutesZone2 = 0, minutesZone3 = 0, minutesZone4 = 0, minutesZone5 = 0,
                type = Formulas.NAP_TYPE, autoDetected = false))
            naps++
        }

        return Parsed(newDays, newSessions, naps)
    }

    suspend fun import(context: Context, files: Map<String, String>): Result {
        val db = AppDatabase.getInstance(context)
        val dayFmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        val p = parse(files, dayFmt.format(Date()), System.currentTimeMillis())
        val newDays = p.days
        val newSessions = p.sessions
        val naps = p.naps

        // ---------- Copia de lo que se sustituye ----------
        val dao = db.dailyMetricsDao()
        val replacedDays = newDays.keys.mapNotNull { dao.getByDate(it) }
        val existingSessions = db.activitySessionDao().getAll()
        val replacedSessions = existingSessions.filter { old -> newSessions.any { n -> n.startMillis < old.endMillis && n.endMillis > old.startMillis } }
        var backup: File? = null
        if (replacedDays.isNotEmpty() || replacedSessions.isNotEmpty()) {
            val dir = context.getExternalFilesDir(null)
            backup = File(dir, "whoop_import_backup_${SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())}.csv")
            backup.printWriter().use { pw ->
                pw.println("#dias")
                pw.println("date,restingHr,avgHrv,sleepMinutes,strain,vo2Max,caloriesKcal,sleepStart,sleepEnd,efficiency,resp,light,deep,rem,awake,wakeEpisodes,latency")
                for (d in replacedDays) pw.println(listOf(d.date, d.restingHr, d.avgHrv, d.sleepMinutes, d.strain, d.vo2Max, d.caloriesKcal,
                    d.sleepStartMinuteOfDay, d.sleepEndMinuteOfDay, d.sleepEfficiencyPct, d.respiratoryRate, d.lightMinutes, d.deepMinutes,
                    d.remMinutes, d.awakeMinutes, d.wakeEpisodes, d.latencyMinutes).joinToString(",") { it?.toString() ?: "" })
                pw.println("#actividades")
                pw.println("start,end,avgHr,maxHr,strain,kcal,z0,z1,z2,z3,z4,z5,type,auto")
                for (s in replacedSessions) pw.println(listOf(s.startMillis, s.endMillis, s.avgHr, s.maxHr, s.strain, s.caloriesKcal,
                    s.minutesZone0, s.minutesZone1, s.minutesZone2, s.minutesZone3, s.minutesZone4, s.minutesZone5,
                    "\"${s.type}\"", s.autoDetected).joinToString(","))
            }
        }

        // ---------- Guardar ----------
        for ((date, d) in newDays) {
            val old = replacedDays.firstOrNull { it.date == date }
            dao.save(d.copy(vo2Max = old?.vo2Max))   // WHOOP no exporta VO₂ máx por día: se conserva el de PulseApp
        }
        for (s in replacedSessions) db.activitySessionDao().delete(s)
        for (s in newSessions) db.activitySessionDao().save(s)

        val until = newDays.keys.maxOrNull()
        if (until != null) Formulas.setWhoopImportUntil(context, until)
        return Result(newDays.size, newSessions.size - naps, naps, replacedDays.size, replacedSessions.size,
            newDays.keys.minOrNull(), until, backup)
    }
}
