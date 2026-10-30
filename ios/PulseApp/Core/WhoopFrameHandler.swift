import Foundation

/// Todo lo que pasa con los datos que llegan de la pulsera, SIN Bluetooth (se puede probar con tramas grabadas):
/// reensamblado de tramas, pulso en directo (estándar 2A37 + propietario), historial con confirmación por bloques,
/// registros v18, movimiento (IMU) y registro en bruto. La capa de Bluetooth (WhoopManager) solo le pasa los bytes
/// y le da una función para enviar órdenes.
final class WhoopFrameHandler {

    // Estado visible para las pantallas
    private(set) var lastBpm: Int? = nil
    private(set) var lastBpmTime: Int64 = 0
    private(set) var liveCount = 0
    private(set) var historyCount = 0
    private(set) var rawCount = 0
    private(set) var offloading = false
    var stepsToday: Int { return motion.stepsToday }

    /// Se llama cuando cambia algo que la pantalla debe mostrar.
    var onChange: (() -> Void)? = nil
    /// Se llama cuando el historial pide cortar la espera ("sin COMPLETE") o termina.
    var onOffloadFinished: (() -> Void)? = nil
    /// Llega algo del historial (registro o metadatos): sirve para rearmar el temporizador de "sin respuesta".
    var onOffloadActivity: (() -> Void)? = nil

    private let hrLog: HrLog
    private let bio: WhoopBioStore
    private let raw: BufferedAppender
    let motion: MotionTracker
    private let processor: LiveHrProcessor
    private let sendCommand: (Int, [UInt8], String) -> Void
    private let log: (String) -> Void
    private let ackModeProvider: () -> Int
    private let hrMaxProvider: () -> Double
    private let nowProvider: () -> Int64

    private var assemblers = [String: [UInt8]]()
    private var writtenSeconds = Set<Int64>()
    private var chunkRecords = 0
    private var offloadRecords = 0
    private var ackedChunks = 0
    private var askedAckOnce = false
    private var responsesLogged = 0
    private var eventsLogged = 0
    private var realtimeLogged = 0
    private var unknownHistLogged = 0
    private var imuMessages = 0

    init(hrLog: HrLog, bio: WhoopBioStore, raw: BufferedAppender, motion: MotionTracker, processor: LiveHrProcessor,
         sendCommand: @escaping (Int, [UInt8], String) -> Void, log: @escaping (String) -> Void,
         ackMode: @escaping () -> Int, hrMax: @escaping () -> Double, now: @escaping () -> Int64 = { TimeUtil.nowMillis() }) {
        self.hrLog = hrLog; self.bio = bio; self.raw = raw; self.motion = motion; self.processor = processor
        self.sendCommand = sendCommand; self.log = log
        self.ackModeProvider = ackMode; self.hrMaxProvider = hrMax; self.nowProvider = now
    }

    // ---------- Control de la descarga ----------

    func beginOffload() {
        offloading = true
        offloadRecords = 0; ackedChunks = 0; chunkRecords = 0; askedAckOnce = false
    }

    func endOffload(quiet: Bool = false) {
        if offloading {
            offloading = false
            if !quiet { log("📚 La pulsera dejó de enviar historial (sin COMPLETE). Recibidos \(offloadRecords) registros; se reintenta en 15 min.") }
        }
    }

    func resetConnection() {
        assemblers.removeAll()
        offloading = false
    }

    // ---------- Entrada de datos ----------

    /// Una notificación de la característica [uuid] (los 8 primeros caracteres del UUID, en minúsculas).
    func handleNotification(uuid: String, data: [UInt8]) {
        if uuid == "00002a37" { handleStandardHr(data); return }
        for frame in assemble(uuid, data) { handleFrame(uuid, frame) }
    }

    /// Pulso estándar (servicio 0x180D, característica 0x2A37).
    func handleStandardHr(_ data: [UInt8]) {
        if data.count < 2 { return }
        let flags = Int(data[0])
        var i = 1
        var bpm = 0
        if flags & 1 != 0 {
            if data.count < 3 { return }
            bpm = Int(data[1]) | (Int(data[2]) << 8); i = 3
        } else {
            bpm = Int(data[1]); i = 2
        }
        if flags & 0x08 != 0 { i += 2 }
        var rr = [Double]()
        if flags & 0x10 != 0 {
            while i + 1 < data.count {
                let ms = Double(Int(data[i]) | (Int(data[i + 1]) << 8)) / 1024.0 * 1000.0
                if ms >= 300 && ms <= 2000 { rr.append(ms) }
                i += 2
            }
        }
        storeHr(nowProvider(), bpm, rr, live: true)
    }

    /// Junta trozos y separa tramas completas: [AA][01][declLen u16]… total = declLen + 8.
    func assemble(_ uuid: String, _ chunk: [UInt8]) -> [[UInt8]] {
        var bytes = assemblers[uuid] ?? []
        bytes.append(contentsOf: chunk)
        var out = [[UInt8]]()
        while true {
            guard let start = bytes.firstIndex(of: 0xAA) else { bytes = []; break }
            if start > 0 { bytes.removeFirst(start) }
            if bytes.count < 8 { break }
            let declLen = Int(bytes[2]) | (Int(bytes[3]) << 8)
            if bytes[1] != 0x01 || declLen < 4 || declLen > 4096 { bytes.removeFirst(1); continue }
            let total = declLen + 8
            if bytes.count < total { break }
            out.append(Array(bytes[0..<total]))
            bytes.removeFirst(total)
        }
        assemblers[uuid] = (bytes.count >= 1 && bytes.count <= 8192) ? bytes : []
        return out
    }

    func handleFrame(_ uuid: String, _ frame: [UInt8]) {
        if frame.count < 12 { return }
        let type = Int(frame[8])
        if type == 43 || type == 51 { handleImu(frame); return }   // movimiento: no se guarda en bruto (es enorme)
        // El pulso en directo (40, 1/s) y los textos internos (50) no se guardan en bruto: gastaba batería
        if type != 40 && type != 50 { recordRaw("RX", uuid, frame) }
        switch type {
        case 47: handleHistoricalRecord(frame)
        case 40: handleRealtime(frame)
        case 49, 56: handleMeta(frame)
        case 36, 38:
            if responsesLogged < 40 {
                responsesLogged += 1
                let code = Int(frame[12])
                let res: String
                switch code {
                case 1: res = "OK"
                case 2: res = "pendiente"
                case 3: res = "fallo"
                case 4: res = "no soportada"
                default: res = "código \(code)"
                }
                log("↩️ Respuesta a la orden \(Int(frame[10])): \(res)")
            }
        case 48, 53, 54:
            if eventsLogged < 20 { eventsLogged += 1; log("🔔 Evento de la pulsera nº \(Int(frame[10]))") }
        default: break
        }
    }

    private func handleHistoricalRecord(_ frame: [UInt8]) {
        if offloading { chunkRecords += 1; offloadRecords += 1; onOffloadActivity?() }
        guard let b = WhoopProtocol.decodeBioV18(frame) else {
            if unknownHistLogged < 3 {
                unknownHistLogged += 1
                log("❔ Registro de historial versión \(Int(frame[9])) aún sin descifrar (\(frame.count) B), guardado en bruto")
            }
            return
        }
        bio.append(b)
        let t = b.unixTime * 1000
        let now = nowProvider()
        if b.unixTime < 1_600_000_000 || t > now + 5 * 60_000 || t < now - 30 * 86_400_000 {
            if historyCount < 5 { log("⚠️ Registro con hora rara (\(b.unixTime)), no se usa") }
            return
        }
        // Contador de pasos de la propia pulsera (30/10): cuenta también cuando el móvil no está cerca
        if let c = BandSteps.counterOf(frame) { BandSteps.record(unix: b.unixTime, counter: c) }
        historyCount += 1
        if historyCount % 600 == 1 { log("📚 Historial: \(historyCount) registros (por \(TimeUtil.timestamp(t).prefix(16)))") }
        storeHr(t, b.heartRate, b.rrIntervalsMs.map { Double($0) }.filter { $0 >= 300 && $0 <= 2000 }, live: false)
    }

    private func handleRealtime(_ frame: [UInt8]) {
        // Pulso en directo propietario (tipo 40, 1 por segundo): hora unix en [10..13] y pulso en [16].
        // Sirve de respaldo si el pulso estándar (2A37) deja de llegar.
        if frame.count < 17 { return }
        let hr = Int(frame[16])
        if hr < 25 || hr > 230 { return }
        if nowProvider() - lastBpmTime < 3000 { return }   // ya llega por el canal estándar
        storeHr(nowProvider(), hr, [], live: true)
        if realtimeLogged == 0 { log("📡 Usando el pulso en directo propio de la WHOOP como respaldo") }
        realtimeLogged += 1
    }

    private func handleMeta(_ frame: [UInt8]) {
        guard let meta = WhoopProtocol.decodeMetaPacket(frame) else { return }
        BandSteps.flush()
        onOffloadActivity?()
        switch meta.kind {
        case 1:
            offloading = true; chunkRecords = 0
            log("📚 La pulsera empieza a enviar el historial…")
        case 2:
            offloading = true
            let mode = ackModeProvider()
            if let ack = meta.ackData {
                if mode == 1 {
                    // Los registros de este bloque ya están escritos en hr_log.csv: se puede confirmar
                    ackedChunks += 1
                    sendCommand(WhoopProtocol.cmdHistoricalDataResult, [1] + ack,
                                "Bloque \(ackedChunks) recibido (\(chunkRecords) registros), pidiendo el siguiente")
                } else if !askedAckOnce {
                    askedAckOnce = true
                    log(mode == -1
                        ? "⏸️ Bloque recibido (\(chunkRecords) registros). Para seguir con el resto hay que confirmar a la pulsera: elige en \"Mi WHOOP\" quién se queda los datos."
                        : "⏸️ Bloque recibido (\(chunkRecords) registros). No confirmo (WHOOP conserva los datos), así que la pulsera no envía más.")
                }
            } else {
                log("⚠️ Fin de bloque sin datos de confirmación")
            }
            chunkRecords = 0
        case 3:
            offloading = false
            log("✅ Historial completo: \(offloadRecords) registros en esta descarga (\(ackedChunks) bloques)")
            offloadRecords = 0
            onOffloadFinished?()
            onChange?()
        default:
            log("🏷️ Metadatos tipo \(meta.kind)")
        }
    }

    private func storeHr(_ timeMillis: Int64, _ bpm: Int, _ rr: [Double], live: Bool) {
        if bpm < 25 || bpm > 230 { return }
        let sec = timeMillis / 1000
        if writtenSeconds.contains(sec) { return }
        writtenSeconds.insert(sec)
        if writtenSeconds.count > 200_000 { writtenSeconds.removeAll() }
        hrLog.append(timeMillis: timeMillis, bpm: bpm, rr: rr)
        processor.feed(timeMillis: timeMillis, bpm: bpm, hrMax: hrMaxProvider())
        if live {
            liveCount += 1
            lastBpm = bpm; lastBpmTime = timeMillis
            if liveCount == 1 { log("🫀 Llega el pulso en directo: \(bpm) ppm") }
            onChange?()
        }
    }

    private func handleImu(_ message: [UInt8]) {
        // El crudo (100 lecturas/s) no se guarda: se guarda el resumen por minuto (pasos, intensidad, quieto, postura).
        imuMessages += 1
        if let sec = WhoopImuDecoder.decode(message) {
            ImuTestRecorder.append(sec)   // solo durante una prueba de pasos (Mi WHOOP)
            if let m = motion.feed(sec), imuMessages % 300 < 60 {
                log("🚶 Minuto: \(m.steps) pasos · \(Int(m.enmoMg)) mg")
            }
        }
    }

    func recordRaw(_ dir: String, _ uuid: String, _ data: [UInt8]) {
        rawCount += 1
        raw.append("\(nowProvider()),\(dir),\(uuid),\(Bytes.hex(data, separator: ""))\n")
    }

    func flush() {
        hrLog.flush(); bio.flush(); raw.flush(); BandSteps.flush()
    }
}
