package com.pulseapp.android

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Guarda cada lectura de pulso en un CSV dentro del almacenamiento
 * específico de la app (visible desde un explorador de archivos Android
 * en Android/data/com.pulseapp.android/files/hr_log.csv, o exportable
 * fácilmente compartiéndolo).
 */
class DataStore(context: Context) {

    private val file: File = File(context.getExternalFilesDir(null), "hr_log.csv")
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)

    init {
        if (!file.exists()) {
            file.writeText("timestamp,bpm,rr_intervals_ms\n")
        }
    }

    @Synchronized
    fun append(bpm: Int, rrIntervals: List<Double>) {
        val timestamp = dateFormat.format(Date())
        val rrString = rrIntervals.joinToString("|") {
            String.format(Locale.US, "%.1f", it)
        }
        file.appendText("$timestamp,$bpm,\"$rrString\"\n")
    }

    fun getFile(): File = file
}
