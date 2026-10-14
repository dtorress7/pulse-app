package com.pulseapp.android

import android.content.Context
import java.io.File

/** Guarda los mensajes IMU crudos: una línea por segundo "unixTime,HEX". */
class WhoopImuRawStore(context: Context) {

    private val file = File(context.getExternalFilesDir(null), "whoop_imu_raw.txt")
    private val maxBytes = 12_000_000L // tope de seguridad (~80 min)

    @Synchronized
    fun append(message: ByteArray) {
        if (message.size < 19 || file.length() > maxBytes) return
        val ts = (message[15].toLong() and 0xFF) or
                ((message[16].toLong() and 0xFF) shl 8) or
                ((message[17].toLong() and 0xFF) shl 16) or
                ((message[18].toLong() and 0xFF) shl 24)
        val hex = message.joinToString("") { "%02X".format(it) }
        file.appendText("$ts,$hex\n")
    }

    fun getFile(): File = file
    fun clear() { if (file.exists()) file.writeText("") }
}
