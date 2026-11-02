package com.pulseapp.android

import com.pulseapp.android.data.ActivitySession
import java.io.File

/**
 * Fases de cada SIESTA (2/11), como el detalle de siesta de WHOOP (horas de sueño, sueño reparador, despierto/ligero/profundo/REM y
 * "esta siesta redujo tu sueño requerido por N minutos"). Se calculan una vez con [SleepStager.stageNap] y se guardan en nap_stages.csv
 * ("inicio,fin,minutoInicioFases,fases" con las fases como dígitos 0–3; "-" si no se pudieron calcular, p. ej. sin movimiento grabado).
 */
object NapStages {
    const val FILE_NAME = "nap_stages.csv"
    @Volatile var dir: File? = null
    private val cache = HashMap<String, SleepStager.Result?>()
    private var loaded = false

    private fun key(s: ActivitySession) = "${s.startMillis},${s.endMillis}"

    @Synchronized private fun loadFile() {
        if (loaded) return
        loaded = true
        val f = dir?.let { File(it, FILE_NAME) } ?: return
        if (!f.exists()) return
        f.forEachLine { l ->
            val p = l.split(',')
            if (p.size < 4) return@forEachLine
            val k = "${p[0]},${p[1]}"
            cache[k] = if (p[3] == "-") null else p[2].toLongOrNull()?.let { m0 -> SleepStager.Result(m0, IntArray(p[3].length) { p[3][it] - '0' }) }
        }
    }

    /** Solo lo ya calculado (rápido). */
    @Synchronized fun cached(s: ActivitySession): SleepStager.Result? { loadFile(); return cache[key(s)] }

    /** Calcula si hace falta (lee hr_log.csv: llamar fuera del hilo principal). */
    fun get(s: ActivitySession): SleepStager.Result? {
        synchronized(this) { loadFile(); if (cache.containsKey(key(s))) return cache[key(s)] }
        val d = dir ?: return null
        val r = try { SleepStager.stageNap(File(d, "hr_log.csv"), File(d, MotionTracker.FILE_NAME), s.startMillis, s.endMillis) } catch (e: Exception) { null }
        synchronized(this) {
            cache[key(s)] = r
            try {
                File(d, FILE_NAME).appendText("${key(s)},${r?.startMinute ?: 0},${r?.stages?.joinToString("") ?: "-"}\n")
            } catch (_: Exception) { }
        }
        return r
    }

    /** Minutos dormido de la siesta: los de sus fases si están calculadas; si no, el 95 % del tiempo (lo que resta WHOOP de media). */
    fun asleepMinutes(s: ActivitySession): Int =
        cached(s)?.asleepMinutes ?: Math.round((s.endMillis - s.startMillis) / 60_000.0 * Formulas.NAP_ASLEEP_FRACTION).toInt()
}
