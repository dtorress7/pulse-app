import Foundation

/// Noches editadas a mano (22/11, igual que Android `SleepEdits`), como "Editar sueño" de WHOOP: la noche es EXACTAMENTE ese tramo en cama
/// (sin buscar el inicio/fin por quietud ni recortar) y las fases, la VFC, la FCR y la respiración salen solo de él.
/// sleep_edits.csv: "fecha del despertar,inicio ms,fin ms" (la última línea de cada fecha manda; inicio 0 = edición quitada).
enum SleepEdits {
    static let fileName = "sleep_edits.csv"
    struct Edit { let date: String; let startMillis: Int64; let endMillis: Int64 }

    private static let lock = NSLock()
    private static var cacheStamp = ""
    private static var cache = [Edit]()

    static func stamp(_ dir: URL) -> String {
        let f = dir.appendingPathComponent(fileName)
        guard let at = try? FileManager.default.attributesOfItem(atPath: f.path) else { return "-" }
        let m = (at[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (at[.size] as? NSNumber)?.int64Value ?? 0
        return "\(m):\(s)"
    }

    static func all(_ dir: URL) -> [Edit] {
        lock.lock(); defer { lock.unlock() }
        let s = stamp(dir)
        if s == cacheStamp { return cache }
        var order = [String](); var byDate = [String: Edit]()
        if let text = try? String(contentsOf: dir.appendingPathComponent(fileName), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let p = line.trimmingCharacters(in: .whitespaces).split(separator: ",").map(String.init)
                if p.count < 3 { continue }
                guard let a = Int64(p[1]), let b = Int64(p[2]) else { continue }
                if a <= 0 || b <= a { byDate[p[0]] = nil; continue }
                if byDate[p[0]] == nil { order.append(p[0]) }
                byDate[p[0]] = Edit(date: p[0], startMillis: a, endMillis: b)
            }
        }
        cache = order.compactMap { byDate[$0] }
        cacheStamp = s
        return cache
    }

    static func forDate(_ dir: URL, _ date: String) -> Edit? { all(dir).first { $0.date == date } }

    /// Edición que se solapa con la noche detectada [from, to] (la que más se solapa).
    static func find(_ dir: URL, _ from: Int64, _ to: Int64) -> Edit? {
        all(dir).filter { $0.startMillis < to && $0.endMillis > from }
            .max { min($0.endMillis, to) - max($0.startMillis, from) < min($1.endMillis, to) - max($1.startMillis, from) }
    }

    private static func append(_ dir: URL, _ line: String) {
        let f = dir.appendingPathComponent(fileName)
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    static func save(_ dir: URL, _ date: String, _ startMillis: Int64, _ endMillis: Int64) { append(dir, "\(date),\(startMillis),\(endMillis)\n") }
    static func clear(_ dir: URL, _ date: String) { append(dir, "\(date),0,0\n") }

    // ---- 23/11: noches procesadas ("FIN DEL SUEÑO"). sleep_caps.csv: "fecha del despertar,hora a la que se procesó (ms)" ----
    static let capsFile = "sleep_caps.csv"
    private static var capsStampValue = ""
    private static var caps = [(String, Int64)]()

    static func capsStamp(_ dir: URL) -> String {
        let f = dir.appendingPathComponent(capsFile)
        guard let at = try? FileManager.default.attributesOfItem(atPath: f.path) else { return "-" }
        let m = (at[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let sz = (at[.size] as? NSNumber)?.int64Value ?? 0
        return "\(m):\(sz)"
    }

    private static func allCaps(_ dir: URL) -> [(String, Int64)] {
        lock.lock(); defer { lock.unlock() }
        let st = capsStamp(dir)
        if st == capsStampValue { return caps }
        var out = [(String, Int64)]()
        if let text = try? String(contentsOf: dir.appendingPathComponent(capsFile), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let p = line.trimmingCharacters(in: .whitespaces).split(separator: ",").map(String.init)
                if p.count >= 2, let v = Int64(p[1]) { out.append((p[0], v)) }
            }
        }
        caps = out; capsStampValue = st
        return out
    }

    /// Hora a la que se procesó la noche detectada [from, to] (si cae dentro de ella): los datos de después no la alargan.
    static func capFor(_ dir: URL, _ from: Int64, _ to: Int64) -> Int64? {
        allCaps(dir).map { $0.1 }.filter { $0 > from && $0 <= to }.min()
    }

    static func saveCap(_ dir: URL, _ date: String, _ atMillis: Int64) {
        if allCaps(dir).contains(where: { $0.0 == date }) { return }   // la primera vez manda
        let f = dir.appendingPathComponent(capsFile)
        let line = "\(date),\(atMillis)\n"
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }
}
