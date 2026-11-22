package com.pulseapp.android

import java.io.File
import java.util.Locale

/**
 * Noches editadas a mano (22/11), como "Editar sueño" de WHOOP. El 21→22/11 el usuario estuvo tumbado viendo una película desde las
 * 21:50 (quieto y con el pulso a 54–60, igual que dormido): WHOOP y PulseApp empezaron la noche a esa hora y en WHOOP lo cambió a mano
 * a las 22:50. Con una edición, la noche es EXACTAMENTE ese tramo en cama (sin buscar el inicio/fin por quietud ni recortar) y las
 * fases, el tiempo despierto, la VFC, la FCR y la respiración se calculan solo dentro de él.
 * Archivo sleep_edits.csv junto a hr_log.csv: "fecha del despertar,inicio ms,fin ms" (una línea por noche; la última manda).
 */
object SleepEdits {
    const val FILE_NAME = "sleep_edits.csv"

    data class Edit(val date: String, val startMillis: Long, val endMillis: Long)

    private var cacheStamp = ""
    private var cache: List<Edit> = emptyList()

    fun stamp(dir: File): String {
        val f = File(dir, FILE_NAME)
        return if (f.exists()) "${f.lastModified()}:${f.length()}" else "-"
    }

    @Synchronized
    fun all(dir: File): List<Edit> {
        val s = stamp(dir)
        if (s == cacheStamp) return cache
        val f = File(dir, FILE_NAME)
        val byDate = LinkedHashMap<String, Edit>()
        if (f.exists()) f.forEachLine { line ->
            val p = line.trim().split(',')
            if (p.size < 3) return@forEachLine
            val a = p[1].toLongOrNull() ?: return@forEachLine
            val b = p[2].toLongOrNull() ?: return@forEachLine
            if (a <= 0L || b <= a) byDate.remove(p[0]) else byDate[p[0]] = Edit(p[0], a, b)   // inicio 0 = edición quitada
        }
        cache = byDate.values.toList(); cacheStamp = s
        return cache
    }

    fun forDate(dir: File, date: String): Edit? = all(dir).firstOrNull { it.date == date }

    /** Edición que se solapa con la noche detectada [from, to] (si hay varias, la que más se solapa). */
    fun find(dir: File, from: Long, to: Long): Edit? = all(dir)
        .filter { it.startMillis < to && it.endMillis > from }
        .maxByOrNull { minOf(it.endMillis, to) - maxOf(it.startMillis, from) }

    @Synchronized
    fun save(dir: File, date: String, startMillis: Long, endMillis: Long) {
        File(dir, FILE_NAME).appendText(String.format(Locale.US, "%s,%d,%d\n", date, startMillis, endMillis))
    }

    @Synchronized
    fun clear(dir: File, date: String) {
        File(dir, FILE_NAME).appendText("$date,0,0\n")
    }
}
