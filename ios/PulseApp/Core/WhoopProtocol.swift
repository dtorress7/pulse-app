import Foundation

/// Protocolo WHOOP 5.0/MG (mismo que la versión Android): ingeniería inversa de trama BLE, sin código de WHOOP.
enum WhoopProtocol {

    /// El "saludo" fijo que despierta el canal de comandos.
    static let clientHello: [UInt8] = Bytes.fromHex("AA0108000001E67123019101363E5C8D")

    // Órdenes seguras (solo lectura o inofensivas)
    static let cmdToggleRealtimeHr = 3
    static let cmdSetClock = 10
    static let cmdGetClock = 11
    static let cmdSendHistoricalData = 22
    static let cmdHistoricalDataResult = 23
    static let cmdGetBatteryLevel = 26
    static let cmdGetDataRange = 34
    static let cmdExitHighFreqSync = 97
    static let cmdSetConfig = 0x78
    static let cmdStartRawData = 81
    static let cmdToggleImuMode = 106

    /// Órdenes que pueden borrar datos, reiniciar o reflashear la pulsera: NUNCA se envían.
    /// 25 FORCE_TRIM, 29 REBOOT, 32 POWER_CYCLE, 36/37/38 firmware, 45 BLE_DFU, 99 reset del medidor de batería.
    static let forbiddenCommands: Set<Int> = [25, 29, 32, 36, 37, 38, 45, 99]

    /// Devuelve nil (y no construye nada) si la orden está prohibida.
    static func buildCommand(_ cmd: Int, seq: Int = 0, payload: [UInt8] = [0], type: Int = 35) -> [UInt8]? {
        if forbiddenCommands.contains(cmd) { return nil }
        var inner: [UInt8] = [UInt8(type & 0xFF), UInt8(seq & 0xFF), UInt8(cmd & 0xFF)]
        inner.append(contentsOf: payload)
        let pad = (4 - inner.count % 4) % 4
        if pad > 0 { inner.append(contentsOf: [UInt8](repeating: 0, count: pad)) }
        let declLen = inner.count + 4

        let head: [UInt8] = [0xAA, 0x01, UInt8(declLen & 0xFF), UInt8((declLen >> 8) & 0xFF), 0x00, 0x01]
        let c16 = Crc.crc16Modbus(head)
        let c32 = Crc.crc32(inner)

        var out = head
        out.append(UInt8(c16 & 0xFF)); out.append(UInt8((c16 >> 8) & 0xFF))
        out.append(contentsOf: inner)
        out.append(UInt8(c32 & 0xFF)); out.append(UInt8((c32 >> 8) & 0xFF))
        out.append(UInt8((c32 >> 16) & 0xFF)); out.append(UInt8((c32 >> 24) & 0xFF))
        return out
    }

    struct BioRecord {
        let unixTime: Int64
        let heartRate: Int
        let rrIntervalsMs: [Int]
        let skinTempC: Double
        let gravityX: Float
        let gravityY: Float
        let gravityZ: Float
    }

    /// Registro "biométrico" v18 del historial: pulso, RR, movimiento y temperatura reales.
    static func decodeBioV18(_ frame: [UInt8]) -> BioRecord? {
        if frame.count < 75 { return nil }
        if Int(frame[9]) != 18 { return nil }
        let unix = Bytes.u32(frame, 15)
        let hr = Int(frame[22])
        let rrCount = Int(frame[23])
        var rrs = [Int]()
        for i in 0..<rrCount {
            let o = 24 + 2 * i
            if o + 2 <= frame.count { rrs.append(Bytes.u16(frame, o)) }
        }
        let gx = Bytes.f32(frame, 45)
        let gy = Bytes.f32(frame, 49)
        let gz = Bytes.f32(frame, 53)
        let skinC = Double(Bytes.u16(frame, 73)) / 128.0
        return BioRecord(unixTime: unix, heartRate: hr, rrIntervalsMs: rrs, skinTempC: skinC,
                         gravityX: gx, gravityY: gy, gravityZ: gz)
    }

    struct MetaPacket {
        let kind: Int
        let ackData: [UInt8]?
    }

    /// Metadatos del historial: tipo en [8] = 49 METADATA o 56 PUFFIN_METADATA.
    /// Clase en [10] (u16 en los 56): 1 = HISTORY_START, 2 = HISTORY_END, 3 = HISTORY_COMPLETE.
    /// Para confirmar un HISTORY_END se devuelven sus 8 bytes [21..29).
    static func decodeMetaPacket(_ frame: [UInt8]) -> MetaPacket? {
        if frame.count < 12 { return nil }
        let type = Int(frame[8])
        if type != 49 && type != 56 { return nil }
        let kind = type == 56 ? Bytes.u16(frame, 10) : Int(frame[10])
        let ack: [UInt8]? = frame.count >= 29 + 4 ? Array(frame[21..<29]) : nil
        return MetaPacket(kind: kind, ackData: ack)
    }

    /// Activación de una "bandera" de configuración (no se usa en la app, se conserva por compatibilidad con Android).
    static func buildSetConfigFrame(flagName: String, value: Character, seq: Int) -> [UInt8]? {
        var nameBytes = [UInt8](repeating: 0, count: 32)
        let ascii = Array(flagName.utf8)
        for i in 0..<min(ascii.count, 32) { nameBytes[i] = ascii[i] }
        var body = nameBytes
        body.append(value.asciiValue ?? 0x31)
        body.append(contentsOf: [UInt8](repeating: 0, count: 7))
        var payload: [UInt8] = [1]
        payload.append(contentsOf: body)
        return buildCommand(cmdSetConfig, seq: seq, payload: payload)
    }
}
