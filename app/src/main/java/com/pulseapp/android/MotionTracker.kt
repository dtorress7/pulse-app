package com.pulseapp.android

import java.io.File
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Resumen de movimiento por minuto (lo que usarán Sueño, Actividades y Pasos).
 *
 *   enmoMg      intensidad del movimiento (media de |a| − 1 g, en mili-g). Quieto ≈ 0,
 *               andando ≈ 90–220, brazo fuerte / deporte ≈ 700–2700.
 *   gyroDps     giro medio de la muñeca (°/s). Quieto ≈ 1–4, andando ≈ 90–150.
 *   stillSecs   segundos del minuto sin moverse (desviación de |a| < 15 mg).
 *   gravX/Y/Z   orientación media de la muñeca (para detectar postura tumbado / cambios de postura).
 */
data class MotionMinute(
    val minuteStartUnix: Long,
    val seconds: Int,
    val steps: Int,
    val enmoMg: Float,
    val gyroDps: Float,
    val stillSecs: Int,
    val gravX: Float, val gravY: Float, val gravZ: Float,
) {
    fun toCsv(): String = String.format(
        Locale.US, "%d,%d,%d,%.1f,%.1f,%d,%.3f,%.3f,%.3f",
        minuteStartUnix, seconds, steps, enmoMg, gyroDps, stillSecs, gravX, gravY, gravZ,
    )

    companion object {
        const val CSV_HEADER = "minute_unix,seconds,steps,enmo_mg,gyro_dps,still_secs,grav_x,grav_y,grav_z"

        fun fromCsv(line: String): MotionMinute? {
            val p = line.split(',')
            if (p.size < 9) return null
            return try {
                MotionMinute(
                    p[0].toLong(), p[1].toInt(), p[2].toInt(), p[3].toFloat(), p[4].toFloat(),
                    p[5].toInt(), p[6].toFloat(), p[7].toFloat(), p[8].toFloat(),
                )
            } catch (e: NumberFormatException) {
                null
            }
        }
    }
}

/**
 * Recibe los segundos IMU decodificados, cuenta pasos y guarda un resumen por minuto
 * en motion_minutes.csv. Un único objeto compartido por la pantalla experimental y el servicio.
 */
class MotionTracker(private val outFile: File, private val zone: ZoneId = ZoneId.systemDefault()) {

    private val steps = ImuStepCounter()
    private var lastUnix = -1L
    private var lastSeq = -1

    var stepsToday = 0
        private set
    private var stepsDay: LocalDate? = null

    // acumuladores del minuto en curso
    private var minuteStart = -1L
    private var secs = 0
    private var minuteSteps = 0
    private var enmoSum = 0.0
    private var gyroSum = 0.0
    private var gyroN = 0
    private var still = 0
    private var gxs = 0.0
    private var gys = 0.0
    private var gzs = 0.0
    private var gravN = 0

    var lastSecondEnmoMg = 0f
        private set

    /** Devuelve el minuto que se acaba de cerrar (si este segundo empezó uno nuevo), o null. */
    @Synchronized
    fun feed(s: ImuSecond): MotionMinute? {
        if (lastUnix >= 0 && s.unixTime <= lastUnix) return null // duplicado o desordenado
        // huecos: si falta algún segundo, se corta la racha de pasos
        if (lastUnix >= 0 && (s.unixTime - lastUnix > 2 || ((s.seq - lastSeq) and 0xFFFF) > 2)) {
            steps.gap()
        }
        lastUnix = s.unixTime
        lastSeq = s.seq

        val minute = s.unixTime - (s.unixTime % 60)
        var closed: MotionMinute? = null
        if (minute != minuteStart) {
            if (minuteStart >= 0) closed = closeMinute()
            minuteStart = minute
        }

        val newSteps = steps.feed(s)
        minuteSteps += newSteps
        addToToday(s.unixTime, newSteps)

        // estadísticas del segundo
        var enmo = 0.0
        var magSum = 0.0
        var magSq = 0.0
        var n = 0
        var gSum = 0.0
        var gN = 0
        var sx = 0.0; var sy = 0.0; var sz = 0.0
        for (i in 0 until s.size) {
            val ax = s.ax[i]; val ay = s.ay[i]; val az = s.az[i]
            if (ax.isNaN() || ay.isNaN() || az.isNaN()) continue
            val m = sqrt(ax * ax + ay * ay + az * az).toDouble()
            enmo += max(m - 1.0, 0.0)
            magSum += m; magSq += m * m; n++
            sx += ax; sy += ay; sz += az
            val gx = s.gx[i]; val gy = s.gy[i]; val gz = s.gz[i]
            if (!gx.isNaN() && !gy.isNaN() && !gz.isNaN()) {
                gSum += sqrt(gx * gx + gy * gy + gz * gz).toDouble(); gN++
            }
        }
        if (n > 0) {
            val mean = magSum / n
            val sd = sqrt(max(magSq / n - mean * mean, 0.0))
            lastSecondEnmoMg = (1000 * enmo / n).toFloat()
            enmoSum += lastSecondEnmoMg
            if (sd < STILL_SD_G) still++
            gxs += sx / n; gys += sy / n; gzs += sz / n; gravN++
            secs++
        }
        if (gN > 0) { gyroSum += gSum / gN; gyroN++ }
        return closed
    }

    /** Guarda el minuto a medias (llamar al parar la captura). */
    @Synchronized
    fun flush(): MotionMinute? = if (secs > 0) closeMinute().also { minuteStart = -1 } else null

    private fun closeMinute(): MotionMinute? {
        val mm = if (secs == 0) null else MotionMinute(
            minuteStartUnix = minuteStart,
            seconds = secs,
            steps = minuteSteps,
            enmoMg = (enmoSum / secs).toFloat(),
            gyroDps = if (gyroN > 0) (gyroSum / gyroN).toFloat() else 0f,
            stillSecs = still,
            gravX = (gxs / max(gravN, 1)).toFloat(),
            gravY = (gys / max(gravN, 1)).toFloat(),
            gravZ = (gzs / max(gravN, 1)).toFloat(),
        )
        secs = 0; minuteSteps = 0; enmoSum = 0.0; gyroSum = 0.0; gyroN = 0; still = 0
        gxs = 0.0; gys = 0.0; gzs = 0.0; gravN = 0
        mm?.let { save(it) }
        return mm
    }

    private fun addToToday(unix: Long, newSteps: Int) {
        val day = Instant.ofEpochSecond(unix).atZone(zone).toLocalDate()
        if (day != stepsDay) {
            stepsDay = day
            stepsToday = loadStepsFor(day)
        }
        stepsToday += newSteps
    }

    /** Suma los pasos ya guardados hoy (por si la app se reinició a mitad del día). */
    private fun loadStepsFor(day: LocalDate): Int = readMinutes(outFile)
        .filter { Instant.ofEpochSecond(it.minuteStartUnix).atZone(zone).toLocalDate() == day }
        .sumOf { it.steps }

    private fun save(m: MotionMinute) {
        try {
            if (!outFile.exists() || outFile.length() == 0L) outFile.writeText(MotionMinute.CSV_HEADER + "\n")
            outFile.appendText(m.toCsv() + "\n")
        } catch (_: Exception) {
        }
    }

    companion object {
        const val FILE_NAME = "motion_minutes.csv"
        private const val STILL_SD_G = 0.015

        fun readMinutes(file: File): List<MotionMinute> {
            if (!file.exists()) return emptyList()
            return file.readLines().drop(1).mapNotNull { MotionMinute.fromCsv(it) }
        }
    }
}
