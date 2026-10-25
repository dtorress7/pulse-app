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
        if (sp.getInt("act_recalc", 0) >= 5 || !csvFile.exists()) return
        val db = AppDatabase.getInstance(context)
        val profile = db.userProfileDao().getOnce() ?: return
        Formulas.init(context)
        if (Formulas.bmr() <= 0) Formulas.setBmr(context,
            CalorieCalculator().basalMetabolicRate(profile.ageYears(), profile.weightKg, profile.heightCm, profile.sex))
        val rhr = BaselineProvider().compute(db)?.avgRestingHr?.toInt()
        rhr?.let { Formulas.setZoneRestingHr(context, it) }
        val importUntil = Formulas.whoopImportUntil()
        val dayFmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        for (old in db.activitySessionDao().getAll()) {
            // Las importadas de WHOOP se quedan con los números de WHOOP
            if (importUntil.isNotEmpty() && dayFmt.format(java.util.Date(old.startMillis)) <= importUntil) continue
            val fresh = ActivityRecorder().summarize(
                csvFile, old.startMillis, old.endMillis,
                ageYears = profile.ageYears(), weightKg = profile.weightKg, sex = profile.sex,
                type = old.type, autoDetected = old.autoDetected, restingHr = rhr
            ) ?: continue
            val keep = if (old.type == Formulas.NAP_TYPE) fresh.copy(strain = 0.0, caloriesKcal = 0.0) else fresh
            db.activitySessionDao().update(keep.copy(id = old.id))
        }
        sp.edit().putInt("act_recalc", 5).apply()   // 5 = esfuerzo v4 del 25/10 (paseos)
    }

    private suspend fun scanInner(context: Context, csvFile: File, force: Boolean): Int {
        val now = System.currentTimeMillis()
        if (!force && now - lastRun < 5 * 60_000L) return 0
        lastRun = now
        if (!csvFile.exists()) return 0
        // Una vez (25/10): se repasan los últimos 7 días con la detección nueva (alarga el fútbol del 24/10 que se guardó
        // cortado, añade los paseos y quita la "siesta" que era el final de la noche).
        val sp = context.getSharedPreferences("pulseapp_formulas", Context.MODE_PRIVATE)
        val rescan = sp.getInt("act_rescan", 0) < 1
        val windowMs = if (rescan) 7 * 86_400_000L else 36 * 3_600_000L
        val db = AppDatabase.getInstance(context)
        val profile = db.userProfileDao().getOnce() ?: return 0
        Formulas.init(context)
        val hrMax = Formulas.hrMax(profile.ageYears())

        val readings = SleepStager.parseHr(csvFile, now - windowMs, now)
        val perMin = java.util.TreeMap<Long, IntArray>()
        for (r in readings) {
            val a = perMin.getOrPut(r.timeMillis / 60_000L) { IntArray(2) }
            a[0] += r.bpm; a[1]++
        }
        val minutes = perMin.entries.filter { it.value[1] >= 20 }.map { it.key to it.value[0].toDouble() / it.value[1] }
        val minuteSet = minutes.map { it.first }.toHashSet()
        val rhr0 = BaselineProvider().compute(db)?.avgRestingHr?.toInt() ?: Formulas.zoneRestingHr()
        val motionList = MotionTracker.readMinutes(File(csvFile.parentFile, MotionTracker.FILE_NAME))
            .filter { it.minuteStartUnix * 1000L >= now - windowMs }
        val motion = HashMap<Long, MotionMinute>(motionList.size * 2)
        for (mm in motionList) motion[mm.minuteStartUnix / 60] = mm
        val naps = Formulas.detectNaps(minutes, motionList, rhr0)
        val acts = Formulas.detectActivities(minutes, hrMax, motion = motion.takeIf { it.isNotEmpty() })
        val walks = Formulas.detectWalks(minutes, motion, hrMax)
            .filter { w -> acts.none { it.first <= w.second && it.second >= w.first } }
        val found = acts.map { Triple(it.first, it.second, "Sin clasificar") } +
            walks.map { Triple(it.first, it.second, Formulas.WALK_TYPE) } +
            naps.map { Triple(it.first, it.second, Formulas.NAP_TYPE) }

        val manual = ActivityState.manualStart(context)
        val existing = db.activitySessionDao().getAll().toMutableList()
        val rhr = BaselineProvider().compute(db)?.avgRestingHr?.toInt()
        var saved = 0
        if (rescan) {
            // "Siestas" automáticas que la detección nueva ya no da (final de la noche): fuera
            for (old in existing.filter { it.autoDetected && it.type == Formulas.NAP_TYPE && it.startMillis >= now - windowMs }) {
                if (naps.none { it.first * 60_000L <= old.endMillis && it.second * 60_000L + 59_999L >= old.startMillis }) {
                    db.activitySessionDao().delete(old); existing.remove(old)
                }
            }
        }
        for ((m0, m1, type) in found) {
            val start = m0 * 60_000L
            val end = m1 * 60_000L + 59_999L
            if (now - end < 10 * 60_000L) continue                       // aún puede seguir
            // 25/10: un hueco de datos no es el final (el pulso del partido llegó tarde y se guardó 19:02–19:25):
            // hacen falta ≥ 5 min de pulso en los 10 min siguientes, o que haya pasado ≥ 1 h
            if (now - end < 60 * 60_000L && (m1 + 1..m1 + 10).count { it in minuteSet } < 5) continue
            if (manual != null && manual <= end) continue                  // la manual manda
            val overlap = existing.filter { it.startMillis < end && it.endMillis > start }
            if (overlap.isNotEmpty()) {
                // Una actividad automática guardada antes de tener todo el pulso se alarga (no si la has editado tú)
                if (type == Formulas.NAP_TYPE || overlap.any { !it.autoDetected || it.type == Formulas.NAP_TYPE }) continue
                val ns = minOf(start, overlap.minOf { it.startMillis }); val ne = maxOf(end, overlap.maxOf { it.endMillis })
                if (ns >= overlap.minOf { it.startMillis } - 60_000L && ne <= overlap.maxOf { it.endMillis } + 60_000L) continue
                val keep = overlap.first()
                val fresh = ActivityRecorder().summarize(
                    csvFile, ns, ne, ageYears = profile.ageYears(), weightKg = profile.weightKg, sex = profile.sex,
                    type = keep.type, autoDetected = true, restingHr = rhr
                ) ?: continue
                db.activitySessionDao().update(fresh.copy(id = keep.id))
                for (o in overlap.drop(1)) db.activitySessionDao().delete(o)
                existing.removeAll(overlap); existing.add(fresh.copy(id = keep.id))
                Formulas.updateObservedHrMax(context, fresh.maxHr)
                saved++
                continue
            }
            val session = ActivityRecorder().summarize(
                csvFile, start, end,
                ageYears = profile.ageYears(), weightKg = profile.weightKg, sex = profile.sex,
                type = type, autoDetected = true, restingHr = rhr
            ) ?: continue
            val nap = type == Formulas.NAP_TYPE
            if (!nap) Formulas.updateObservedHrMax(context, session.maxHr)
            // Siesta: sin esfuerzo ni calorías extra (ese rato ya lo cuenta la base del día)
            val toSave = if (nap) session.copy(strain = 0.0, caloriesKcal = 0.0) else session
            val id = db.activitySessionDao().save(toSave)
            existing.add(toSave.copy(id = id))
            saved++
        }
        if (rescan) sp.edit().putInt("act_rescan", 1).apply()
        return saved
    }
}
