import Foundation

/// Fases de cada SIESTA (2/11, igual que Android `NapStages`): se calculan una vez con `SleepStager.stageNap` y se guardan en
/// nap_stages.csv ("inicio,fin,minutoInicioFases,fases" con las fases como dígitos 0–3; "-" si no se pudieron calcular).
enum NapStages {
    static let fileName = "nap_stages.csv"
    private static let lock = NSLock()
    private static var cache = [String: SleepStager.Result?]()
    private static var loaded = false

    private static func key(_ s: ActivitySession) -> String { return "\(s.startMillis),\(s.endMillis)" }

    private static func loadFileLocked() {
        if loaded { return }
        loaded = true
        guard let text = try? String(contentsOf: AppPaths.file(fileName), encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let p = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            if p.count < 4 { continue }
            let k = p[0] + "," + p[1]
            if p[3] == "-" { cache[k] = .some(nil); continue }
            guard let m0 = Int64(p[2]) else { continue }
            cache[k] = .some(SleepStager.Result(startMinute: m0, stages: p[3].compactMap { Int(String($0)) }))
        }
    }

    /// Solo lo ya calculado (rápido).
    static func cached(_ s: ActivitySession) -> SleepStager.Result? {
        lock.lock(); defer { lock.unlock() }
        loadFileLocked()
        return cache[key(s)] ?? nil
    }

    /// Calcula si hace falta (lee hr_log.csv: llamar fuera del hilo principal).
    static func get(_ s: ActivitySession, hrLog: HrLog) -> SleepStager.Result? {
        lock.lock()
        loadFileLocked()
        if let v = cache[key(s)] { lock.unlock(); return v }
        lock.unlock()
        let r = SleepStager.stageNap(hrLog: hrLog, motionFile: AppPaths.file(MotionTracker.fileName), startMillis: s.startMillis, endMillis: s.endMillis)
        lock.lock(); defer { lock.unlock() }
        cache[key(s)] = .some(r)
        let line = "\(key(s)),\(r?.startMinute ?? 0),\(r.map { $0.stages.map(String.init).joined() } ?? "-")\n"
        let url = AppPaths.file(fileName)
        if !FileManager.default.fileExists(atPath: url.path) { try? "".write(to: url, atomically: true, encoding: .utf8) }
        if let h = try? FileHandle(forWritingTo: url), let d = line.data(using: .utf8) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        return r
    }

    /// Minutos dormido de la siesta: los de sus fases si están calculadas; si no, el 95 % del tiempo.
    static func asleepMinutes(_ s: ActivitySession) -> Int {
        if let r = cached(s) { return r.asleepMinutes }
        return Int((Double(s.endMillis - s.startMillis) / 60_000.0 * Formulas.napAsleepFraction).rounded())
    }
}
