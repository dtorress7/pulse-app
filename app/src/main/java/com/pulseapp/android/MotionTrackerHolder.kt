package com.pulseapp.android

import android.content.Context
import java.io.File

/** Un único MotionTracker para toda la app (pantalla experimental + servicio en segundo plano). */
object MotionTrackerHolder {
    @Volatile private var instance: MotionTracker? = null

    fun get(context: Context): MotionTracker =
        instance ?: synchronized(this) {
            instance ?: MotionTracker(
                File(context.applicationContext.getExternalFilesDir(null), MotionTracker.FILE_NAME)
            ).also { instance = it }
        }

    /** Pasos de hoy para mostrarlos en la pantalla principal (0 si aún no hay datos). */
    fun stepsToday(): Int = instance?.stepsToday ?: 0
}
