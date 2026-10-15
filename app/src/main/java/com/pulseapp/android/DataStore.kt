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
    fun append(bpm: Int, rrIntervals: List<Double>) = appendAt(System.currentTimeMillis(), bpm, rrIntervals)

    /** Guarda una lectura con su hora real (las del historial de la pulsera llegan con horas pasadas). */
    @Synchronized
    fun appendAt(timeMillis: Long, bpm: Int, rrIntervals: List<Double>) {
        val timestamp = dateFormat.format(Date(timeMillis))
        val rrString = rrIntervals.joinToString("|") {
            String.format(Locale.US, "%.1f", it)
        }
        // Se escribe en bloques (cada 30 lecturas o 30 s) en vez de abrir el archivo cada segundo: ahorra batería
        buffer.append("$timestamp,$bpm,\"$rrString\"\n")
        pending++
        val now = System.currentTimeMillis()
        if (pending >= 30 || now - lastFlush > 30_000L) flush()
    }

    private val buffer = StringBuilder()
    private var pending = 0
    private var lastFlush = System.currentTimeMillis()

    @Synchronized
    fun flush() {
        if (buffer.isEmpty()) return
        try { file.appendText(buffer.toString()) } catch (_: Exception) { }
        buffer.setLength(0); pending = 0; lastFlush = System.currentTimeMillis()
    }

    fun getFile(): File = file
}
