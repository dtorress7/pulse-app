package com.pulseapp.android

/**
 * Reensambla los mensajes IMU (tipo 43/51) que el Whoop 5/MG manda troceados
 * en notificaciones BLE (5 x 244 + 24 = 1244 bytes). Un mensaje empieza con
 * AA 01 + longitud declarada (u16 LE) y mide declLen + 8 bytes en total.
 */
class WhoopImuReassembler {

    private val buffer = java.io.ByteArrayOutputStream()
    private var expectedTotal = 0

    /** Devuelve el mensaje completo cuando está listo, o null si aún faltan trozos. */
    fun feed(chunk: ByteArray): ByteArray? {
        if (chunk.size >= 9 && (chunk[0].toInt() and 0xFF) == 0xAA && chunk[1].toInt() == 0x01) {
            val declLen = (chunk[2].toInt() and 0xFF) or ((chunk[3].toInt() and 0xFF) shl 8)
            val type = chunk[8].toInt() and 0xFF
            if (declLen > 1000 && (type == 43 || type == 51)) {
                buffer.reset()
                buffer.write(chunk)
                expectedTotal = declLen + 8
                return checkComplete()
            }
        }
        if (expectedTotal == 0) return null // trozo suelto sin cabecera: se ignora
        buffer.write(chunk)
        return checkComplete()
    }

    private fun checkComplete(): ByteArray? {
        if (buffer.size() >= expectedTotal) {
            val message = buffer.toByteArray().copyOf(expectedTotal)
            buffer.reset()
            expectedTotal = 0
            return message
        }
        return null
    }
}
