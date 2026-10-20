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
 * Actividades automáticas: AutoActivityScanner (cada 5 min).
 */
class LiveHrProcessor(
    private val context: Context,
    private val scope: CoroutineScope,
    private val csvFile: File,
    private val onActivitySaved: (String) -> Unit
) {
    private var lastScan = 0L
    private var lastDay: String? = null
    private var lastTime = 0L
    private val dayFormat = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    fun feed(timeMillis: Long, bpm: Int, hrMax: Double) {
        // Solo lecturas en orden: si llega algo más antiguo (historial ya cubierto), no altera el estado
        if (timeMillis <= lastTime) return
        lastTime = timeMillis
        checkDayRollover(timeMillis)

        // Actividades automáticas (20/10): ya no se decide aquí lectura a lectura (empezaba y acababa tarde);
        // cada 5 min se repasa el pulso guardado con AutoActivityScanner (misma regla que WHOOP en el funcional del 19/10).
        if (timeMillis - lastScan > 5 * 60_000L) {
            lastScan = timeMillis
            scope.launch {
                val n = AutoActivityScanner.scan(context, csvFile)
                if (n > 0) onActivitySaved("Actividad detectada automáticamente ($n)")
            }
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
