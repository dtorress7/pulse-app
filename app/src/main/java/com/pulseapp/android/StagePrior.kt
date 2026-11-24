package com.pulseapp.android

import com.pulseapp.android.data.AppDatabase
import java.io.File
import java.util.Locale

/**
 * Corrección personal de las fases del sueño (24/11).
 *
 * El modelo de fases (SleepModel) se entrenó solo con las noches del primer usuario. Coloca bien el sueño de otras personas pero se
 * equivoca en el reparto: a Pablo le daba 0 min de REM en sus 3 noches (WHOOP 117–155) y a Nico 11–74 (WHOOP 85–139), todo a ligero.
 * Con su historial importado de WHOOP se sabe qué parte de su sueño suele ser ligero/profundo/REM; se compara con lo que da el modelo
 * en SUS noches de PulseApp (stage_raw.csv, sin corregir) y la diferencia (menos 0,02 de margen, × n/(n+1) con n noches) se suma a
 * cada noche: SleepModel busca los sesgos que llevan la noche a ese reparto y coloca las fases con ellos.
 *
 * Comprobado (código real, check/nico/sp/SP.kt) usando para cada noche solo sus OTRAS noches y el historial de WHOOP anterior (lo más
 * pesimista: 1–2 noches): Pablo 3 noches error L/P/R 133/16/134 → 59/14/57 min; Nico 2 noches 93/27/69 → 60/19/44. Con todas sus noches
 * (como en la app): Nico 20/11 40/328/59/42 (WHOOP 46/262/79/85), 23/11 45/494/94/114 (47/482/89/139); Pablo REM 0 → 79/84/98
 * (155/117/131). Tus noches: tu diferencia es ≤ 0,02 en las tres fases → sin corrección, todo igual.
 */
object StagePrior {
    const val FILE = "stage_raw.csv"
    private const val MIN_WHOOP_NIGHTS = 7
    private const val WHOOP_NIGHTS = 60
    private const val RAW_NIGHTS = 30
    private const val DEAD_ZONE = 0.02

    @Synchronized
    fun record(dir: File?, date: String, raw: DoubleArray?) {
        if (dir == null || raw == null || raw.sum() <= 0.0) return
        try {
            val f = File(dir, FILE)
            val lines = (if (f.exists()) f.readLines() else emptyList()).filter { it.isNotBlank() && !it.startsWith("$date,") }.toMutableList()
            lines.add(String.format(Locale.US, "%s,%.4f,%.4f,%.4f", date, raw[0], raw[1], raw[2]))
            lines.sort()
            f.writeText((if (lines.size > 200) lines.takeLast(200) else lines).joinToString("\n") + "\n")
        } catch (_: Exception) { }
    }

    @Synchronized
    fun rawNights(dir: File?): List<DoubleArray> {
        if (dir == null) return emptyList()
        return try {
            val f = File(dir, FILE)
            if (!f.exists()) return emptyList()
            f.readLines().mapNotNull { l ->
                val p = l.split(",")
                if (p.size != 4) null else doubleArrayOf(p[1].toDouble(), p[2].toDouble(), p[3].toDouble())
            }.takeLast(RAW_NIGHTS)
        } catch (_: Exception) { emptyList() }
    }

    /** [whoop] = (ligero, profundo, REM) en minutos de tus noches importadas de WHOOP; [raw] = fracciones del modelo en tus noches. */
    fun shift(whoop: List<IntArray>, raw: List<DoubleArray>): DoubleArray? {
        val w = whoop.filter { it.sum() > 0 }.takeLast(WHOOP_NIGHTS)
        if (w.size < MIN_WHOOP_NIGHTS || raw.isEmpty()) return null
        val wm = DoubleArray(3) { c -> w.sumOf { it[c].toDouble() / it.sum() } / w.size }
        val rm = DoubleArray(3) { c -> raw.sumOf { it[c] } / raw.size }
        val sh = raw.size / (raw.size + 1.0)
        val out = DoubleArray(3) { val v = sh * (wm[it] - rm[it]); Math.signum(v) * maxOf(0.0, Math.abs(v) - DEAD_ZONE) }
        return if (out.all { it == 0.0 }) null else out
    }

    /** Recalcula la corrección con lo guardado y la deja puesta en SleepModel. */
    suspend fun refresh(db: AppDatabase, dir: File?): DoubleArray? {
        val until = Formulas.whoopImportUntil()
        val whoop = if (until.isEmpty()) emptyList() else db.dailyMetricsDao().getLastDays(400)
            .filter { it.date <= until && it.lightMinutes != null && it.deepMinutes != null && it.remMinutes != null }
            .sortedBy { it.date }
            .map { intArrayOf(it.lightMinutes!!, it.deepMinutes!!, it.remMinutes!!) }
        val s = shift(whoop, rawNights(dir))
        SleepModel.personalShift = s
        return s
    }
}
