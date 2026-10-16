import Foundation

/// Ajustes de la conexión con la WHOOP (se guardan en UserDefaults).
enum WhoopSettings {
    private static let kDevice = "pulseapp_whoop_device_id"
    private static let kAuto = "pulseapp_whoop_auto_connect"
    private static let kImu = "pulseapp_whoop_imu_enabled"
    private static let kAck = "pulseapp_whoop_ack_history"

    /// Identificador de la pulsera (en iOS no hay dirección MAC: CoreBluetooth da un UUID por iPhone).
    static var deviceId: String? {
        get { return UserDefaults.standard.string(forKey: kDevice) }
        set { UserDefaults.standard.set(newValue, forKey: kDevice) }
    }
    /// true si quieres la pulsera conectada siempre (se apaga solo con "Desconectar").
    static var autoConnect: Bool {
        get { return UserDefaults.standard.bool(forKey: kAuto) }
        set { UserDefaults.standard.set(newValue, forKey: kAuto) }
    }
    static var imuEnabled: Bool {
        get { return UserDefaults.standard.bool(forKey: kImu) }
        set { UserDefaults.standard.set(newValue, forKey: kImu) }
    }
    /// -1 = aún no ha elegido · 0 = no confirmar (WHOOP conserva los datos) · 1 = confirmar (PulseApp descarga todo).
    static var ackMode: Int {
        get {
            if UserDefaults.standard.object(forKey: kAck) == nil { return -1 }
            return UserDefaults.standard.integer(forKey: kAck)
        }
        set { UserDefaults.standard.set(newValue, forKey: kAck) }
    }

    static func ackLabel(_ mode: Int) -> String {
        switch mode {
        case 1: return "Historial: PulseApp descarga todo"
        case 0: return "Historial: WHOOP conserva los datos"
        default: return "Historial: elegir quién se queda los datos"
        }
    }
}

/// Escritura en bloques de un archivo de texto (menos batería que abrir el archivo en cada línea).
final class BufferedAppender {
    private let url: URL
    private let maxBytes: Int64
    private var buffer = Data()
    private var lastFlush = Date()
    private let lock = NSLock()
    private let flushSeconds: Double

    init(url: URL, maxBytes: Int64, flushSeconds: Double = 3) {
        self.url = url
        self.maxBytes = maxBytes
        self.flushSeconds = flushSeconds
    }

    func append(_ line: String) {
        lock.lock()
        buffer.append(Data(line.utf8))
        let due = buffer.count > 16_384 || Date().timeIntervalSince(lastFlush) > flushSeconds
        lock.unlock()
        if due { flush() }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if buffer.isEmpty { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxBytes { buffer.removeAll(); return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(buffer)
            try? h.close()
        } else {
            try? buffer.write(to: url)
        }
        buffer.removeAll(keepingCapacity: true)
        lastFlush = Date()
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        try? Data().write(to: url)
    }
}

/// Registro del servicio: en memoria (la pantalla "Mi WHOOP" lo muestra siempre) y en whoop_service_log.txt.
final class ServiceLog {
    static let shared = ServiceLog()

    private let lock = NSLock()
    private(set) var lines = [String]()
    private let file = BufferedAppender(url: AppPaths.file(AppPaths.serviceLog), maxBytes: 3_000_000, flushSeconds: 2)
    var onUpdate: (() -> Void)? = nil

    func log(_ msg: String) {
        let stamp = TimeUtil.timestamp(TimeUtil.nowMillis()).suffix(8)
        let line = "\(stamp) \(msg)"
        lock.lock()
        lines.insert(line, at: 0)
        if lines.count > 400 { lines.removeLast() }
        lock.unlock()
        file.append(line + "\n")
        onUpdate?()
    }

    func snapshot(_ n: Int = 150) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.prefix(n))
    }

    func flush() { file.flush() }
}

/// Guarda el flujo completo del WHOOP (pulso + RR + temperatura + gravedad) en whoop_bio_log.csv.
final class WhoopBioStore {
    private let appender: BufferedAppender
    init(url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "timestamp,bpm,rr_ms,skin_temp_c,gravity_x,gravity_y,gravity_z\n".write(to: url, atomically: true, encoding: .utf8)
        }
        appender = BufferedAppender(url: url, maxBytes: 60_000_000, flushSeconds: 10)
    }
    func append(_ bio: WhoopProtocol.BioRecord) {
        let t = bio.unixTime > 1_600_000_000 ? bio.unixTime * 1000 : TimeUtil.nowMillis()
        let rr = bio.rrIntervalsMs.map { String($0) }.joined(separator: "|")
        let line = TimeUtil.timestamp(t) + "," + String(bio.heartRate) + ",\"" + rr + "\"," +
            String(format: "%.2f,%.3f,%.3f,%.3f\n", bio.skinTempC, Double(bio.gravityX), Double(bio.gravityY), Double(bio.gravityZ))
        appender.append(line)
    }
    func flush() { appender.flush() }
}
