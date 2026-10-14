package com.pulseapp.android

import java.util.zip.CRC32

/**
 * Protocolo Whoop 5.0/MG, basado en la documentación pública de los proyectos
 * NOOP/ZHOOP (ingeniería inversa verificada byte a byte contra capturas reales).
 * No usa código propietario de Whoop, solo el formato de trama BLE.
 */
object WhoopProtocol {

    // El "saludo" fijo que despierta el canal de comandos, siempre los mismos 16 bytes
    val CLIENT_HELLO: ByteArray = hexToBytes("AA0108000001E67123019101363E5C8D")

    // Opcodes de comandos seguros (solo lectura o inofensivos)
    const val CMD_TOGGLE_REALTIME_HR = 3
    const val CMD_SET_CLOCK = 10
    const val CMD_GET_CLOCK = 11
    const val CMD_SEND_HISTORICAL_DATA = 22
    const val CMD_HISTORICAL_DATA_RESULT = 23
    const val CMD_GET_BATTERY_LEVEL = 26
    const val CMD_GET_DATA_RANGE = 34
    const val CMD_SEND_R10_R11_REALTIME = 63   // [0] = parar el chorro de datos crudos (IMU) / [1] = activarlo
    const val CMD_EXIT_HIGH_FREQ_SYNC = 97

    /** Órdenes que pueden borrar datos, reiniciar o reflashear la pulsera: NUNCA se envían. */
    val FORBIDDEN_COMMANDS = setOf(25, 29, 32, 36, 37, 38, 45, 99)

    // NUNCA usar estos opcodes (pueden dañar o borrar el reloj):
    // 25 FORCE_TRIM, 29 REBOOT, 32 POWER_CYCLE, 36/37/38 firmware, 45 BLE_DFU, 99 fuel-gauge reset

    fun buildCommand(cmd: Int, seq: Int = 0, payload: ByteArray = byteArrayOf(0), type: Int = 35): ByteArray {
        require(cmd !in FORBIDDEN_COMMANDS) { "Orden $cmd prohibida (destructiva)" }
        val inner0 = byteArrayOf(type.toByte(), seq.toByte(), cmd.toByte()) + payload
        val pad = (4 - inner0.size % 4) % 4
        val inner = inner0 + ByteArray(pad)
        val declLen = inner.size + 4

        val head = byteArrayOf(
            0xAA.toByte(), 0x01,
            (declLen and 0xFF).toByte(), ((declLen shr 8) and 0xFF).toByte(),
            0x00, 0x01
        )
        val c16 = crc16Modbus(head)
        val c32 = crc32(inner)

        return head +
                byteArrayOf((c16 and 0xFF).toByte(), ((c16 shr 8) and 0xFF).toByte()) +
                inner +
                byteArrayOf(
                    (c32 and 0xFF).toByte(), ((c32 shr 8) and 0xFF).toByte(),
                    ((c32 shr 16) and 0xFF).toByte(), ((c32 shr 24) and 0xFF).toByte()
                )
    }

    private fun crc16Modbus(data: ByteArray): Int {
        var crc = 0xFFFF
        for (b in data) {
            crc = crc xor (b.toInt() and 0xFF)
            repeat(8) {
                crc = if (crc and 1 != 0) (crc ushr 1) xor 0xA001 else crc ushr 1
            }
        }
        return crc and 0xFFFF
    }

    private fun crc32(data: ByteArray): Long {
        val c = CRC32()
        c.update(data)
        return c.value
    }

    private fun hexToBytes(hex: String): ByteArray {
        val result = ByteArray(hex.length / 2)
        for (i in result.indices) {
            val index = i * 2
            result[i] = ((Character.digit(hex[index], 16) shl 4) +
                    Character.digit(hex[index + 1], 16)).toByte()
        }
        return result
    }

    fun bytesToHex(bytes: ByteArray): String {
        return bytes.joinToString(" ") { "%02X".format(it) }
    }
        data class BioRecord(
        val unixTime: Long, val heartRate: Int, val rrIntervalsMs: List<Int>,
        val skinTempC: Double, val gravityX: Float, val gravityY: Float, val gravityZ: Float
    )

    /** Decodifica un registro "biométrico" v18: pulso, RR, movimiento y temperatura reales. */
    fun decodeBioV18(frame: ByteArray): BioRecord? {
        if (frame.size < 75) return null
        if ((frame[9].toInt() and 0xFF) != 18) return null

        val unix = u32le(frame, 15)
        val hr = frame[22].toInt() and 0xFF
        val rrCount = frame[23].toInt() and 0xFF
        val rrs = mutableListOf<Int>()
        for (i in 0 until rrCount) {
            val o = 24 + 2 * i
            if (o + 2 <= frame.size) rrs.add(u16le(frame, o))
        }
        val gx = f32le(frame, 45)
        val gy = f32le(frame, 49)
        val gz = f32le(frame, 53)
        val skinRaw = u16le(frame, 73)
        val skinC = skinRaw / 128.0

        return BioRecord(unix, hr, rrs, skinC, gx, gy, gz)
    }

    private fun u16le(data: ByteArray, offset: Int): Int {
        return (data[offset].toInt() and 0xFF) or ((data[offset + 1].toInt() and 0xFF) shl 8)
    }

    private fun u32le(data: ByteArray, offset: Int): Long {
        return (data[offset].toLong() and 0xFF) or
                ((data[offset + 1].toLong() and 0xFF) shl 8) or
                ((data[offset + 2].toLong() and 0xFF) shl 16) or
                ((data[offset + 3].toLong() and 0xFF) shl 24)
    }

    private fun f32le(data: ByteArray, offset: Int): Float {
        val bits = (data[offset].toInt() and 0xFF) or
                ((data[offset + 1].toInt() and 0xFF) shl 8) or
                ((data[offset + 2].toInt() and 0xFF) shl 16) or
                ((data[offset + 3].toInt() and 0xFF) shl 24)
        return Float.fromBits(bits)
    }
        data class MetaPacket(val metaTypeByte: Int, val cursorHex: String, val rawHex: String, val ackData: ByteArray?)

    /**
     * Paquetes de metadatos del historial (WHOOP 5.0: tipo en [8] = 49 METADATA o 56 PUFFIN_METADATA).
     * Clase en [10] (u16 en los 56): 1 = HISTORY_START, 2 = HISTORY_END, 3 = HISTORY_COMPLETE.
     * Para confirmar un HISTORY_END se devuelven sus 8 bytes [21..29) (mismo formato que usan goose/noop).
     */
    fun decodeMetaPacket(frame: ByteArray): MetaPacket? {
        if (frame.size < 12) return null
        val type = frame[8].toInt() and 0xFF
        if (type != 49 && type != 56) return null
        val kind = if (type == 56) u16le(frame, 10) else frame[10].toInt() and 0xFF
        val ack = if (frame.size >= 29 + 4) frame.copyOfRange(21, 29) else null
        return MetaPacket(kind, ack?.let { bytesToHex(it) } ?: "", bytesToHex(frame), ack)
    }

        const val CMD_SET_CONFIG = 0x78 // 120 decimal

    /**
     * Construye el comando de activación de una "bandera" de configuración.
     * Formato: b3=0x01, seguido de 40 bytes: nombre (32 bytes, ASCII rellenado
     * con ceros) + valor ('1' o '2' en ASCII) + 7 ceros de relleno.
     */
    fun buildSetConfigFrame(flagName: String, value: Char, seq: Int): ByteArray {
        val nameBytes = ByteArray(32)
        val nameAscii = flagName.toByteArray(Charsets.US_ASCII)
        nameAscii.copyInto(nameBytes, 0, 0, minOf(nameAscii.size, 32))

        val body = nameBytes + value.code.toByte() + ByteArray(7)
        val payload = byteArrayOf(1) + body // b3=0x01 para SET_CONFIG

        return buildCommand(CMD_SET_CONFIG, seq, payload)
    }
    const val CMD_START_RAW_DATA = 81
    const val CMD_TOGGLE_IMU_MODE = 106

    fun buildStartRawDataFrame(seq: Int): ByteArray {
        return buildCommand(CMD_START_RAW_DATA, seq, byteArrayOf(0))
    }

    fun buildToggleImuModeFrame(seq: Int): ByteArray {
        return buildCommand(CMD_TOGGLE_IMU_MODE, seq, byteArrayOf(1, 1))
    }
}
