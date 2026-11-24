import Foundation

/// Corrección personal de las fases del sueño (24/11, igual que Android `StagePrior.kt`). El modelo de fases se entrenó solo con las
/// noches del primer usuario: a Pablo le daba 0 min de REM y a Nico muy poco. Con el historial importado de WHOOP se compara su reparto
/// habitual de ligero/profundo/REM con lo que da el modelo en SUS noches de PulseApp (stage_raw.csv, sin corregir) y la diferencia
/// (menos 0,02 de margen, × n/(n+1)) se suma a cada noche. Al usuario (diferencia ≤ 0,02) no le cambia nada.
enum StagePrior {
    private static let lock = NSLock()
    static var url: URL { return AppPaths.file("stage_raw.csv") }
    private static let minWhoopNights = 7, whoopNights = 60, rawNightsMax = 30
    private static let deadZone = 0.02

    static func record(_ date: String, _ raw: [Double]?) {
        guard let raw = raw, raw.count == 3, raw.reduce(0, +) > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.removeAll { $0.hasPrefix(date + ",") }
        lines.append(String(format: "%@,%.4f,%.4f,%.4f", date, raw[0], raw[1], raw[2]))
        lines.sort()
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func rawNights() -> [[Double]] {
        lock.lock(); defer { lock.unlock() }
        let lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n")
        let v: [[Double]] = lines.compactMap { l in
            let p = l.split(separator: ",")
            guard p.count == 4, let a = Double(p[1]), let b = Double(p[2]), let c = Double(p[3]) else { return nil }
            return [a, b, c]
        }
        return Array(v.suffix(rawNightsMax))
    }

    /// `whoop` = (ligero, profundo, REM) en minutos de tus noches importadas de WHOOP; `raw` = fracciones del modelo en tus noches.
    static func shift(whoop: [[Int]], raw: [[Double]]) -> [Double]? {
        let w = Array(whoop.filter { $0.reduce(0, +) > 0 }.suffix(whoopNights))
        if w.count < minWhoopNights || raw.isEmpty { return nil }
        let wm = (0..<3).map { c in w.reduce(0.0) { $0 + Double($1[c]) / Double($1.reduce(0, +)) } / Double(w.count) }
        let rm = (0..<3).map { c in raw.reduce(0.0) { $0 + $1[c] } / Double(raw.count) }
        let sh = Double(raw.count) / (Double(raw.count) + 1)
        let out = (0..<3).map { i -> Double in let v = sh * (wm[i] - rm[i]); return (v < 0 ? -1.0 : 1.0) * max(0, abs(v) - deadZone) }
        return out.allSatisfy { $0 == 0 } ? nil : out
    }

    @discardableResult
    static func refresh(store: AppStore) -> [Double]? {
        let until = WhoopImport.importedUntil()
        var whoop = [[Int]]()
        if !until.isEmpty {
            for d in store.lastDays(400).sorted(by: { $0.date < $1.date }) where d.date <= until {
                if let l = d.lightMinutes, let p = d.deepMinutes, let r = d.remMinutes { whoop.append([l, p, r]) }
            }
        }
        let s = shift(whoop: whoop, raw: rawNights())
        SleepModel.personalShift = s
        return s
    }
}
