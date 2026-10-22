package com.pulseapp.android

import android.content.Context
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Detección automática de actividades como WHOOP (20/10): repasa el pulso de las últimas 36 h (en directo o del
 * historial de la pulsera, llegue cuando llegue) con [Formulas.detectActivities] y guarda como "Sin clasificar" las
 * actividades ya terminadas (fin hace ≥ 10 min) que no se solapen con otra guardada ni con una actividad manual en curso.
 * Se llama desde el servicio de la pulsera y al abrir Inicio, como mucho cada 5 min.
 */
object AutoActivityScanner {
    @Volatile private var lastRun = 0L

    suspend fun scan(context: Context, csvFile: File, force: Boolean = false): Int = withContext(Dispatchers.IO) {
        recalcAllOnce(context, csvFile)
        scanInner(context, csvFile, force)
    }

    /**
     * Una sola vez tras actualizar (20/10): rehace zonas, calorías y esfuerzo de las actividades guardadas con las
     * fórmulas nuevas (zonas por reserva de FC y calorías por zona). Mismo inicio, fin y deporte; si no hay pulso, se deja.
     */
    private suspend fun recalcAllOnce(context: Context, csvFile: File) {
        val sp = context.getSharedPreferences("pulseapp_formulas", Context.MODE_PRIVATE)
        if (sp.getInt("act_recalc", 0) >= 3 || !csvFile.exists()) return
        val db = AppDatabase.getInstance(context)
        val profile = db.userProfileDao().getOnce() ?: return
        Formulas.init(context)
        if (Formulas.bmr() <= 0) Formulas.setBmr(context,
            CalorieCalculator().basalMetabolicRate(profile.ageYears(), profile.weightKg, profile.heightCm, profile.sex))
        val rhr = BaselineProvider().compute(db)?.avgRestingHr?.toInt()
        rhr?.let { Formulas.setZoneRestingHr(context, it) }
        for (old in db.activitySessionDao().getAll()) {
            val fresh = ActivityRecorder().summarize(
                csvFile, old.startMillis, old.endMillis,
                ageYears = profile.ageYears(), weightKg = profile.weightKg, sex = profile.sex,
                type = old.type, autoDetected = old.autoDetected, restingHr = rhr
            ) ?: continue
            val keep = if (old.type == Formulas.NAP_TYPE) fresh.copy(strain = 0.0, caloriesKcal = 0.0) else fresh
            db.activitySessionDao().update(keep.copy(id = old.id))
        }
        sp.edit().putInt("act_recalc", 3).apply()   // 3 = curva de esfuerzo v2 del 22/10
    }

    private suspend fun scanInner(context: Context, csvFile: File, force: Boolean): Int {
        val now = System.currentTimeMillis()
        if (!force && now - lastRun < 5 * 60_000L) return 0
        lastRun = now
        if (!csvFile.exists()) return 0
        val db = AppDatabase.getInstance(context)
        val profile = db.userProfileDao().getOnce() ?: return 0
        Formulas.init(context)
        val hrMax = Formulas.hrMax(profile.ageYears())

        val readings = SleepStager.parseHr(csvFile, now - 36 * 3_600_000L, now)
        val perMin = java.util.TreeMap<Long, IntArray>()
        for (r in readings) {
            val a = perMin.getOrPut(r.timeMillis / 60_000L) { IntArray(2) }
            a[0] += r.bpm; a[1]++
        }
        val minutes = perMin.entries.filter { it.value[1] >= 20 }.map { it.key to it.value[0].toDouble() / it.value[1] }
        val rhr0 = BaselineProvider().compute(db)?.avgRestingHr?.toInt() ?: Formulas.zoneRestingHr()
        val motion = MotionTracker.readMinutes(File(csvFile.parentFile, MotionTracker.FILE_NAME))
            .filter { it.minuteStartUnix * 1000L >= now - 36 * 3_600_000L }
        val naps = Formulas.detectNaps(minutes, motion, rhr0)
        val found = Formulas.detectActivities(minutes, hrMax).map { Triple(it.first, it.second, false) } +
            naps.map { Triple(it.first, it.second, true) }
        if (found.isEmpty()) return 0

        val manual = ActivityState.manualStart(context)
        val existing = db.activitySessionDao().getAll()
        val rhr = BaselineProvider().compute(db)?.avgRestingHr?.toInt()
        var saved = 0
        for ((m0, m1, nap) in found) {
            val start = m0 * 60_000L
            val end = m1 * 60_000L + 59_999L
            if (now - end < 10 * 60_000L) continue                       // aún puede seguir
            if (manual != null && manual <= end) continue                  // la manual manda
            if (existing.any { it.startMillis < end && it.endMillis > start }) continue
            val session = ActivityRecorder().summarize(
                csvFile, start, end,
                ageYears = profile.ageYears(), weightKg = profile.weightKg, sex = profile.sex,
                type = if (nap) Formulas.NAP_TYPE else "Sin clasificar", autoDetected = true, restingHr = rhr
            ) ?: continue
            if (!nap) Formulas.updateObservedHrMax(context, session.maxHr)
            // Siesta: sin esfuerzo ni calorías extra (ese rato ya lo cuenta la base del día)
            db.activitySessionDao().save(if (nap) session.copy(strain = 0.0, caloriesKcal = 0.0) else session)
            saved++
        }
        return saved
    }
}
