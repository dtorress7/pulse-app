package com.pulseapp.android

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Guarda el flujo completo del Whoop (pulso + RR + temperatura + movimiento)
 * en un CSV aparte del pulso normal — así no interfiere con lo que ya funciona.
 */
class WhoopDataStore(context: Context) {

    private val file: File = File(context.getExternalFilesDir(null), "whoop_bio_log.csv")
    private val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US)

    init {
        if (!file.exists()) {
            file.writeText("timestamp,bpm,rr_ms,skin_temp_c,gravity_x,gravity_y,gravity_z\n")
        }
    }

    @Synchronized
    fun append(bio: WhoopProtocol.BioRecord) {
        val timestamp = dateFormat.format(Date())
        val rrString = bio.rrIntervalsMs.joinToString("|")
        val line = "$timestamp,${bio.heartRate},\"$rrString\"," +
                "${"%.2f".format(Locale.US, bio.skinTempC)}," +
                "${"%.3f".format(Locale.US, bio.gravityX)}," +
                "${"%.3f".format(Locale.US, bio.gravityY)}," +
                "${"%.3f".format(Locale.US, bio.gravityZ)}\n"
        file.appendText(line)
    }

    fun getFile(): File = file
}
