import Foundation

/// 9/11: temperatura de la piel de cada noche, como WHOOP (port 1:1 de Android `SkinTemp.kt`).
/// whoop_bio_log.csv guarda u16/128; mediana durante el sueño × 1,28 (= u16/100) = skin_temp_celsius de WHOOP
/// (9 noches: r 1,000, error 0,01 °C dejando cada noche fuera). WHOOP enseña la diferencia con la media de las 30 noches anteriores.
enum SkinTemp {
    static let factor = 1.28
    private static let lock = NSLock()
    static var url: URL { return AppPaths.file("skin_temp_days.csv") }

    private static func stamp(_ ms: Int64) -> String { return TimeUtil.timestamp(ms) }

    /// Mediana entre [fromMs, toMs] en la escala de WHOOP; nil con menos de 100 lecturas.
    static func nightValue(fromMs: Int64, toMs: Int64) -> Double? {
        if toMs <= fromMs { return nil }
        let from = stamp(fromMs), to = stamp(toMs)
        var vals = [Double]()
        for name in ["whoop_bio_log_anterior.csv", AppPaths.bioLog] {
            let u = AppPaths.file(name)
            forEachLine(u) { line in
                if line.count < 20 { return }
                let ts = String(line.prefix(19))
                if ts < from || ts > to { return }
                // timestamp,bpm,"rr|rr",temp,gx,gy,gz → la temperatura va tras la comilla de cierre
                let rest: Substring
                if let q = line.lastIndex(of: "\"") {
                    let after = line.index(after: q)
                    rest = after < line.endIndex ? line[line.index(after: after)...] : ""
                } else {
                    rest = Substring(line.split(separator: ",", omittingEmptySubsequences: false).dropFirst(3).joined(separator: ","))
                }
                guard let t = Double(rest.split(separator: ",", omittingEmptySubsequences: false).first ?? "") else { return }
                if t > 15 && t < 45 { vals.append(t) }
            }
        }
        if vals.count < 100 { return nil }
        vals.sort()
        let n = vals.count
        let m = n % 2 == 1 ? vals[n / 2] : (vals[n / 2 - 1] + vals[n / 2]) / 2
        return m * factor
    }

    /// Lee el archivo por trozos de 1 MB (el registro puede ocupar 60 MB: no se carga entero en memoria).
    private static func forEachLine(_ u: URL, _ body: (String) -> Void) {
        guard let h = try? FileHandle(forReadingFrom: u) else { return }
        defer { try? h.close() }
        var carry = Data()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            carry.append(chunk)
            guard let lastNl = carry.lastIndex(of: 10) else { continue }
            let block = carry[carry.startIndex...lastNl]
            if let text = String(data: block, encoding: .utf8) { text.enumerateLines { l, _ in body(l) } }
            carry = Data(carry[carry.index(after: lastNl)...])
        }
        if !carry.isEmpty, let text = String(data: carry, encoding: .utf8) { text.enumerateLines { l, _ in body(l) } }
    }

    static func loadAll() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out = [String: Double]()
        for line in text.split(separator: "\n") {
            let p = line.split(separator: ",")
            if p.count == 2, let v = Double(p[1]) { out[String(p[0])] = v }
        }
        return out
    }

    static func save(_ date: String, _ value: Double) { saveAll([date: value]) }

    static func saveAll(_ values: [String: Double]) {
        if values.isEmpty { return }
        lock.lock(); defer { lock.unlock() }
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.removeAll { l in values.keys.contains(where: { l.hasPrefix($0 + ",") }) }
        for (d, v) in values { lines.append(d + "," + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), v)) }
        lines.sort()
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Calcula y guarda la noche que acaba en `date` si no estaba ya guardada.
    @discardableResult
    static func ensure(_ date: String, fromMs: Int64, toMs: Int64) -> Double? {
        if let v = loadAll()[date] { return v }
        guard let v = nightValue(fromMs: fromMs, toMs: toMs) else { return nil }
        save(date, v)
        return v
    }

    private static var memoKey: String? = nil
    private static var memoVal: Double? = nil
    /// La noche de hoy (aún puede cambiar): no se guarda, solo se recuerda mientras la ventana no cambie.
    static func todayValue(_ date: String, fromMs: Int64, toMs: Int64) -> Double? {
        let k = "\(date),\(fromMs / 60_000),\(toMs / 60_000)"
        lock.lock(); let hit = memoKey == k; let cached = memoVal; lock.unlock()
        if hit { return cached }
        let v = nightValue(fromMs: fromMs, toMs: toMs)
        lock.lock(); memoKey = k; memoVal = v; lock.unlock()
        return v
    }

    struct Deviation { let diff: Double; let lo: Double; let hi: Double }

    /// Diferencia con la media de las noches anteriores (hasta 30) y rango ± 0,85 sd. nil con < 3 noches.
    static func deviation(_ all: [String: Double], date: String, today: Double?) -> Deviation? {
        guard let t = today else { return nil }
        let prev = Array(all.filter { $0.key < date }.sorted { $0.key < $1.key }.map { $0.value }.suffix(30))
        if prev.count < 3 { return nil }
        let mean = prev.reduce(0, +) / Double(prev.count)
        let sd = prev.count > 1 ? (prev.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(prev.count - 1)).squareRoot() : 0
        return Deviation(diff: t - mean, lo: -0.85 * sd, hi: 0.85 * sd)
    }
}
