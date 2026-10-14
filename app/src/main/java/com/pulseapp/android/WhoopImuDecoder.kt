package com.pulseapp.android

import java.util.zip.CRC32

/**
 * Un segundo de datos del acelerómetro + giroscopio del WHOOP 5.0 (100 muestras).
 *
 * Formato verificado con la prueba del 14/10 (quieto / andando / brazo fuerte):
 *   mensaje tipo 43 (0x2B), 1244 bytes, cabecera AA 01 D4 04
 *   [11..12]  u16 contador de mensajes (sube 1 por segundo; si salta, se perdieron segundos)
 *   [15..18]  u32 hora unix (segundos)
 *   [22..23]  nº de muestras (100)   [24..25] muestras válidas   [26..27] = 3 ejes
 *   [28..627] ACELERÓMETRO: 100 X, luego 100 Y, luego 100 Z (int16 LE)
 *             4096 cuentas = 1 g, rango ±8 g (en reposo |a| ≈ 0,99 g)
 *   [628..639] sub-cabecera del giroscopio (100, válidas, 05 02, ceros)
 *   [640..1239] GIROSCOPIO: 100 X, 100 Y, 100 Z (int16 LE)
 *             16,4 cuentas = 1 °/s, rango ±2000 °/s (comprobado integrando giros)
 *   [1240..1243] CRC32 (zlib) de los bytes [8..1239]
 *   -32768 (00 80) = muestra no válida → se guarda como NaN.
 */
class ImuSecond(
    val unixTime: Long,
    val seq: Int,
    val ax: FloatArray, val ay: FloatArray, val az: FloatArray, // en g
    val gx: FloatArray, val gy: FloatArray, val gz: FloatArray, // en °/s (NaN si el giro aún no arrancó)
) {
    val size: Int get() = ax.size
}

object WhoopImuDecoder {

    const val MESSAGE_SIZE = 1244
    const val TYPE_IMU = 43
    const val ACCEL_COUNTS_PER_G = 4096f
    const val GYRO_COUNTS_PER_DPS = 16.4f
    private const val INVALID = -32768

    private const val ACCEL_OFFSET = 28
    private const val GYRO_HEADER_OFFSET = 628
    private const val GYRO_OFFSET = 640
    private const val CRC_OFFSET = 1240

    /** Devuelve null si el mensaje no es un IMU válido (tamaño, tipo o CRC incorrectos). */
    fun decode(m: ByteArray): ImuSecond? {
        if (m.size < MESSAGE_SIZE) return null
        if ((m[0].toInt() and 0xFF) != 0xAA || (m[8].toInt() and 0xFF) != TYPE_IMU) return null

        val crc = CRC32().apply { update(m, 8, CRC_OFFSET - 8) }.value
        if (crc != u32(m, CRC_OFFSET)) return null

        val n = u16(m, 22)
        if (n <= 0 || n > 100) return null
        val gyroCount = u16(m, GYRO_HEADER_OFFSET)
        val gyroValid = u16(m, GYRO_HEADER_OFFSET + 2)

        fun axis(base: Int, idx: Int, scale: Float, enabled: Boolean) = FloatArray(n) { i ->
            val raw = s16(m, base + (idx * 100 + i) * 2)
            if (!enabled || raw == INVALID) Float.NaN else raw / scale
        }

        val gyroOn = gyroCount == 100 && gyroValid > 0
        return ImuSecond(
            unixTime = u32(m, 15),
            seq = u16(m, 11),
            ax = axis(ACCEL_OFFSET, 0, ACCEL_COUNTS_PER_G, true),
            ay = axis(ACCEL_OFFSET, 1, ACCEL_COUNTS_PER_G, true),
            az = axis(ACCEL_OFFSET, 2, ACCEL_COUNTS_PER_G, true),
            gx = axis(GYRO_OFFSET, 0, GYRO_COUNTS_PER_DPS, gyroOn),
            gy = axis(GYRO_OFFSET, 1, GYRO_COUNTS_PER_DPS, gyroOn),
            gz = axis(GYRO_OFFSET, 2, GYRO_COUNTS_PER_DPS, gyroOn),
        )
    }

    private fun u16(b: ByteArray, o: Int) = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)
    private fun s16(b: ByteArray, o: Int) = u16(b, o).toShort().toInt()
    private fun u32(b: ByteArray, o: Int): Long =
        (b[o].toLong() and 0xFF) or ((b[o + 1].toLong() and 0xFF) shl 8) or
            ((b[o + 2].toLong() and 0xFF) shl 16) or ((b[o + 3].toLong() and 0xFF) shl 24)
}
