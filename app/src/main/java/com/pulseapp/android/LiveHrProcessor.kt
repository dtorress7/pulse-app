package com.pulseapp.android

import android.content.Context
import com.pulseapp.android.data.AppDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Actividad iniciada a mano en Inicio. Se guarda en disco para que no se pierda aunque Android
 * cierre la pantalla mientras el móvil está en la mochila.
 */
object ActivityState {
    private const val PREFS = "pulseapp_state"
    private const val KEY_START = "manual_activity_start"

    fun manualStart(context: Context): Long? =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(KEY_START, 0L).takeIf { it > 0 }

    fun setManualStart(context: Context, start: Long?) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong(KEY_START, start ?: 0L).apply()
    }
}

/**
 * Procesa cada lectura de pulso con SU hora (en directo o del historial):
 * detección automática de actividades y cálculo del día anterior al cambiar de día.
 * Regla de actividad: media de 4 min > 60 % FCmáx durante 8 min → empieza; < 55 % durante 5 min → termina.
 */
class LiveHrProcessor(
    private val context: Context,
    private val scope: CoroutineScope,
    private val csvFile: File,
    private val onActivitySaved: (String) -> Unit
) {
    private val recent = ArrayDeque<Pair<Long, Int>>()
    private var recording = false
    private var autoStart: Long? = null
    private var aboveSince: Long? = null
    private var belowSince: Long? = null
    private var lastDay: String? = null
    private var lastTime = 0L
    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    fun feed(timeMillis: Long, bpm: Int, hrMax: Double) {
        // Solo lecturas en orden: si llega algo más antiguo (historial ya cubierto), no altera el estado
        if (timeMillis <= lastTime) return
        if (timeMillis - lastTime > 10 * 60_000L) { recent.clear(); aboveSince = null; belowSince = null }
        lastTime = timeMillis
        checkDayRollover(timeMillis)

        recent.addLast(timeMillis to bpm)
        while (recent.isNotEmpty() && timeMillis - recent.first().first > 4 * 60_000L) recent.removeFirst()
        val pct = recent.map { it.second }.average() / hrMax

        if (ActivityState.manualStart(context) != null) {
            aboveSince = null; belowSince = null
            if (recording) { recording = false; autoStart = null } // la manual manda
            return
        }
        if (!recording) {
            if (pct > 0.6) {
                val since = aboveSince ?: timeMillis.also { aboveSince = it }
                if (timeMillis - since > 8 * 60_000L) { recording = true; autoStart = since; aboveSince = null }
            } else aboveSince = null
        } else {
            if (pct < 0.55) {
                val since = belowSince ?: timeMillis.also { belowSince = it }
                if (timeMillis - since > 5 * 60_000L) {
                    val start = autoStart!!
                    recording = false; autoStart = null; belowSince = null
                    saveAuto(start, since)
                }
            } else belowSince = null
        }
    }

    private fun saveAuto(start: Long, end: Long) {
        scope.launch {
            val db = AppDatabase.getInstance(context)
            // No duplicar si ya hay una actividad guardada que se solapa
            if (db.activitySessionDao().getAll().any { it.startMillis < end && it.endMillis > start }) return@launch
            val profile = db.userProfileDao().getOnce()
            val session = ActivityRecorder().summarize(
                csvFile, start, end,
                ageYears = profile?.ageYears() ?: 30,
                weightKg = profile?.weightKg ?: 75f,
                sex = profile?.sex ?: "M",
                type = "Sin clasificar",
                autoDetected = true,
                restingHr = BaselineProvider().compute(db)?.avgRestingHr?.toInt()
            ) ?: return@launch
            Formulas.updateObservedHrMax(context, session.maxHr)
            db.activitySessionDao().save(session)
            onActivitySaved("Actividad detectada guardada (${(end - start) / 60000} min)")
        }
    }

    private fun checkDayRollover(timeMillis: Long) {
        val day = dayFormat.format(java.util.Date(timeMillis))
        if (day == lastDay) return
        lastDay = day
        scope.launch {
            val db = AppDatabase.getInstance(context)
            val profile = db.userProfileDao().getOnce()
            DailyMetricsUpdater().updateYesterdayIfNeeded(
                db, csvFile,
                ageYears = profile?.ageYears() ?: 30,
                weightKg = profile?.weightKg ?: 75f,
                sex = profile?.sex ?: "M"
            )
        }
    }
}
