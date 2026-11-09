package com.pulseapp.android

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 9/11: temperatura de la piel de cada noche, como WHOOP.
 *
 * Los registros v18 de la pulsera traen la temperatura (u16 en [73..74]); whoop_bio_log.csv la guarda como u16/128.
 * Comprobado con 9 noches (19→21/10 y 3→9/11): mediana durante el sueño × 1,28 (= u16/100) = skin_temp_celsius de WHOOP
 * con r 1,000 y error 0,01 °C dejando cada noche fuera. WHOOP enseña la DIFERENCIA con la media de las 30 noches anteriores
 * (9/11: 34,68 − 33,80 = +0,88, WHOOP +0,9).
 *
 * Valor de cada noche en skin_temp_days.csv ("fecha,°C"): se calcula una vez cuando la noche ya está cerrada.
 */
object SkinTemp {
    const val FACTOR = 1.28
    private const val FILE = "skin_temp_days.csv"
    private const val BIO = "whoop_bio_log.csv"
    private val tsFmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)

    /** Mediana de la temperatura entre [fromMs, toMs] en la escala de WHOOP; null con menos de 100 lecturas. */
    fun nightValue(dir: File?, fromMs: Long, toMs: Long): Double? {
        if (dir == null || toMs <= fromMs) return null
        val from = synchronized(tsFmt) { tsFmt.format(Date(fromMs)) }
        val to = synchronized(tsFmt) { tsFmt.format(Date(toMs)) }
        val vals = ArrayList<Double>()
        for (name in listOf("whoop_bio_log_anterior.csv", BIO)) {
            val f = File(dir, name)
            if (!f.exists()) continue
            try {
                f.bufferedReader().useLines { lines ->
                    for (line in lines) {
                        if (line.length < 20) continue
                        val ts = line.substring(0, 19)
                        if (ts < from || ts > to) continue
                        // timestamp,bpm,"rr|rr",temp,gx,gy,gz → la temperatura va tras la comilla de cierre
                        val q = line.lastIndexOf('"')
                        val rest = if (q >= 0) line.substring(q + 2) else line.split(',').drop(3).joinToString(",")
                        val t = rest.substringBefore(',').toDoubleOrNull() ?: continue
                        if (t > 15 && t < 45) vals.add(t)
                    }
                }
            } catch (_: Exception) { }
        }
        if (vals.size < 100) return null
        vals.sort()
        val m = if (vals.size % 2 == 1) vals[vals.size / 2] else (vals[vals.size / 2 - 1] + vals[vals.size / 2]) / 2
        return m * FACTOR
    }

    @Synchronized
    fun loadAll(dir: File?): Map<String, Double> {
        if (dir == null) return emptyMap()
        return try {
            val f = File(dir, FILE)
            if (!f.exists()) return emptyMap()
            f.readLines().mapNotNull { l -> val p = l.split(','); if (p.size == 2) p[1].toDoubleOrNull()?.let { p[0] to it } else null }.toMap()
        } catch (_: Exception) { emptyMap() }
    }

    fun save(dir: File?, date: String, value: Double) = saveAll(dir, mapOf(date to value))

    @Synchronized
    fun saveAll(dir: File?, values: Map<String, Double>) {
        if (dir == null || values.isEmpty()) return
        try {
            val f = File(dir, FILE)
            val lines = (if (f.exists()) f.readLines() else emptyList()).filter { l -> l.isNotBlank() && values.keys.none { l.startsWith("$it,") } }.toMutableList()
            for ((d, v) in values) lines.add(d + "," + "%.3f".format(Locale.US, v))
            lines.sort()
            f.writeText((if (lines.size > 400) lines.takeLast(400) else lines).joinToString("\n") + "\n")
        } catch (_: Exception) { }
    }

    private var memoKey: String? = null
    private var memoVal: Double? = null

    /** La noche de hoy (aún puede cambiar): no se guarda en el archivo, solo se recuerda mientras la ventana no cambie. */
    @Synchronized
    fun todayValue(dir: File?, date: String, fromMs: Long, toMs: Long): Double? {
        val k = "$date,${fromMs / 60_000},${toMs / 60_000}"
        if (k != memoKey) { memoVal = nightValue(dir, fromMs, toMs); memoKey = k }
        return memoVal
    }

    /** Calcula y guarda la noche que acaba en [date] si no estaba ya guardada. */
    fun ensure(dir: File?, date: String, fromMs: Long, toMs: Long): Double? {
        loadAll(dir)[date]?.let { return it }
        val v = nightValue(dir, fromMs, toMs) ?: return null
        save(dir, date, v)
        return v
    }

    /** Diferencia con la media de las noches anteriores (hasta 30), como WHOOP, y su rango ± 0,85 sd. Null con < 3 noches. */
    data class Deviation(val diff: Double, val lo: Double, val hi: Double)

    fun deviation(all: Map<String, Double>, date: String, today: Double?): Deviation? {
        if (today == null) return null
        val prev = all.filterKeys { it < date }.toSortedMap().values.toList().takeLast(30)
        if (prev.size < 3) return null
        val mean = prev.average()
        val sd = if (prev.size > 1) kotlin.math.sqrt(prev.sumOf { (it - mean) * (it - mean) } / (prev.size - 1)) else 0.0
        return Deviation(today - mean, -0.85 * sd, 0.85 * sd)
    }
}
