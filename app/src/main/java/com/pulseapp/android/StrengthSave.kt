package com.pulseapp.android

import android.content.Context
import com.pulseapp.android.data.ActivitySession
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.ZoneId

/** Guardar un entreno de fuerza: crea/actualiza la actividad, enlaza sus series y rehace su esfuerzo (y el del día). */
object StrengthSave {
    const val TYPE = "Entrenamiento de fuerza"

    /** Rehace la actividad [id] con su pulso y sus series. Devuelve la actividad guardada o null si no hay pulso. */
    suspend fun resummarize(ctx: Context, id: Long, newType: String? = null): ActivitySession? = withContext(Dispatchers.IO) {
        Formulas.init(ctx)
        val db = AppDatabase.getInstance(ctx)
        val s = db.activitySessionDao().getById(id) ?: return@withContext null
        val profile = db.userProfileDao().getOnce()
        val file = File(ctx.getExternalFilesDir(null), "hr_log.csv")
        val type = newType ?: s.type
        val fresh = ActivityRecorder().summarize(file, s.startMillis, s.endMillis,
            ageYears = profile?.ageYears() ?: 30, weightKg = profile?.weightKg ?: 70f, sex = profile?.sex ?: "M",
            type = type, autoDetected = s.autoDetected, restingHr = BaselineProvider().compute(db)?.avgRestingHr?.toInt())
            ?: return@withContext null
        val saved = fresh.copy(id = s.id)
        db.activitySessionDao().update(saved)
        recalcDayOf(ctx, db, s.startMillis)
        saved
    }

    suspend fun recalcDayOf(ctx: Context, db: AppDatabase, millis: Long) {
        val profile = db.userProfileDao().getOnce() ?: return
        val date = Instant.ofEpochMilli(millis).atZone(ZoneId.systemDefault()).toLocalDate().toString()
        DailyMetricsUpdater().recalcDay(db, File(ctx.getExternalFilesDir(null), "hr_log.csv"), date,
            profile.ageYears(), profile.weightKg, profile.sex)
    }

    /**
     * Termina el entrenamiento en curso: guarda la actividad (de su inicio a ahora) con sus series. Si la detección automática
     * ya había guardado ese rato y no lo has tocado, se sustituye. Devuelve el id o null si no hay pulso.
     */
    suspend fun finishLive(ctx: Context, w: Strength.Workout, endMs: Long): Long? = withContext(Dispatchers.IO) {
        Formulas.init(ctx)
        val db = AppDatabase.getInstance(ctx)
        val dao = db.activitySessionDao()
        val start = w.startMs
        val end = endMs.coerceAtLeast(start + 60_000L)
        // Primero las series (la carga muscular se busca por la hora), con un id provisional
        w.endMs = end
        w.id = -start
        Strength.saveLog(w)
        val profile = db.userProfileDao().getOnce()
        val file = File(ctx.getExternalFilesDir(null), "hr_log.csv")
        val s = ActivityRecorder().summarize(file, start, end, ageYears = profile?.ageYears() ?: 30, weightKg = profile?.weightKg ?: 70f,
            sex = profile?.sex ?: "M", type = TYPE, autoDetected = false, restingHr = BaselineProvider().compute(db)?.avgRestingHr?.toInt())
        if (s == null) { Strength.deleteLog(-start); return@withContext null }
        for (o in dao.getAll()) {
            val ov = minOf(o.endMillis, end) - maxOf(o.startMillis, start)
            if (o.autoDetected && ov > 0 && ov * 2 >= minOf(o.endMillis - o.startMillis, end - start)) dao.delete(o)
        }
        val id = dao.save(s)
        Strength.deleteLog(-start)
        w.id = id
        Strength.saveLog(w)
        recalcDayOf(ctx, db, start)
        id
    }
}
