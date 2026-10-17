import Foundation

/// Rutas de los archivos de la app. Están en "Documentos", visibles desde la app Archivos del iPhone
/// (Archivos → En mi iPhone → PulseApp), para compartir hr_log.csv, motion_minutes.csv y los registros.
enum AppPaths {
    static var baseDir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d
    }()
    static func file(_ name: String) -> URL { return baseDir.appendingPathComponent(name) }

    static let hrLog = "hr_log.csv"
    static let motion = MotionTracker.fileName
    static let serviceLog = "whoop_service_log.txt"
    static let historyRaw = "whoop_history_raw.txt"
    static let bioLog = "whoop_bio_log.csv"
}

/// Base de datos sencilla en JSON (perfil, días guardados y actividades). Sustituye a Room de Android.
/// Hay muy pocos datos (una fila por día), así que se guarda el archivo entero tras cada cambio.
final class AppStore {

    static let shared = AppStore(dir: AppPaths.baseDir)

    private let lock = NSLock()
    private let profileURL: URL
    private let daysURL: URL
    private let sessionsURL: URL

    private var profile: UserProfile?
    private var days: [String: DailyMetrics] = [:]
    private var sessions: [ActivitySession] = []
    private var nextId: Int64 = 1

    init(dir: URL) {
        profileURL = dir.appendingPathComponent("profile.json")
        daysURL = dir.appendingPathComponent("daily_metrics.json")
        sessionsURL = dir.appendingPathComponent("activity_sessions.json")
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: profileURL) { profile = try? dec.decode(UserProfile.self, from: d) }
        if let d = try? Data(contentsOf: daysURL), let arr = try? dec.decode([DailyMetrics].self, from: d) {
            for m in arr { days[m.date] = m }
        }
        if let d = try? Data(contentsOf: sessionsURL), let arr = try? dec.decode([ActivitySession].self, from: d) {
            sessions = arr
            nextId = (arr.map { $0.id }.max() ?? 0) + 1
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        if let d = try? enc.encode(value) { try? d.write(to: url, options: .atomic) }
    }

    // ---------- Perfil ----------
    func getProfile() -> UserProfile? {
        lock.lock(); defer { lock.unlock() }
        return profile
    }

    func saveProfile(_ p: UserProfile) {
        lock.lock(); defer { lock.unlock() }
        profile = p
        write(p, to: profileURL)
    }

    // ---------- Días ----------
    func saveDay(_ m: DailyMetrics) {
        lock.lock(); defer { lock.unlock() }
        days[m.date] = m
        write(Array(days.values), to: daysURL)
    }

    /// Varios días de una vez (importación): un solo guardado del archivo.
    func saveDays(_ list: [DailyMetrics]) {
        if list.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        for m in list { days[m.date] = m }
        write(Array(days.values), to: daysURL)
    }

    func getDay(_ date: String) -> DailyMetrics? {
        lock.lock(); defer { lock.unlock() }
        return days[date]
    }

    /// Los últimos [n] días guardados, del más reciente al más antiguo.
    func lastDays(_ n: Int) -> [DailyMetrics] {
        lock.lock(); defer { lock.unlock() }
        let sorted = days.values.sorted { $0.date > $1.date }
        return Array(sorted.prefix(n))
    }

    // ---------- Actividades ----------
    @discardableResult
    func saveSession(_ s: ActivitySession) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        var copy = s
        copy.id = nextId
        nextId += 1
        sessions.append(copy)
        write(sessions, to: sessionsURL)
        return copy.id
    }

    func updateSession(_ s: ActivitySession) {
        lock.lock(); defer { lock.unlock() }
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
        write(sessions, to: sessionsURL)
    }

    /// Varias actividades de una vez (importación), con id nuevo cada una.
    func saveSessions(_ list: [ActivitySession]) {
        if list.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        for s in list {
            var copy = s
            copy.id = nextId
            nextId += 1
            sessions.append(copy)
        }
        write(sessions, to: sessionsURL)
    }

    /// Borra el registro de una actividad (el pulso guardado no se toca).
    func deleteSession(id: Int64) {
        lock.lock(); defer { lock.unlock() }
        sessions.removeAll { $0.id == id }
        write(sessions, to: sessionsURL)
    }

    /// Más reciente primero.
    func allSessions() -> [ActivitySession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.sorted { $0.startMillis > $1.startMillis }
    }

    func session(id: Int64) -> ActivitySession? {
        lock.lock(); defer { lock.unlock() }
        return sessions.first { $0.id == id }
    }
}
