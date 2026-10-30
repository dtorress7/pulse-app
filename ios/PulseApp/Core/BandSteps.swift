import Foundation

/// Pasos que cuenta la PROPIA pulsera (30/10, igual que Android `BandSteps.kt`). Cada registro v18 del historial trae en [57..58]
/// (u16) el contador de pasos del ciclo de WHOOP. Comprobado con el historial crudo del 19–21/10: el ciclo del 20/10 suma 6029
/// (WHOOP 6015). El historial llega aunque el móvil esté lejos (pádel, fútbol), así esos pasos no se pierden.
/// band_steps.csv: "unix,contador" (segundos), una línea cuando cambia el contador o el minuto.
enum BandSteps {
    static let fileName = "band_steps.csv"
    private static let header = "unix,counter"
    /// Hueco máximo entre muestras seguidas para dar el tramo por cubierto (más = faltó historial).
    private static let maxGapS: Int64 = 1800

    private static let lock = NSLock()
    private static var lastValue = -1
    private static var lastMinute: Int64 = -1
    private static var pending = ""
    private static var pendingLines = 0

    static func counterOf(_ frame: [UInt8]) -> Int? {
        return frame.count < 59 ? nil : Int(frame[57]) | (Int(frame[58]) << 8)
    }

    static func record(unix: Int64, counter: Int, url: URL = AppPaths.file(fileName)) {
        if unix < 1_600_000_000 { return }
        lock.lock(); defer { lock.unlock() }
        let minute = unix / 60
        if counter == lastValue && minute == lastMinute { return }
        lastValue = counter; lastMinute = minute
        pending += "\(unix),\(counter)\n"; pendingLines += 1
        if pendingLines >= 50 { flushLocked(url) }
    }

    static func flush(url: URL = AppPaths.file(fileName)) {
        lock.lock(); defer { lock.unlock() }
        flushLocked(url)
    }

    private static func flushLocked(_ url: URL) {
        if pendingLines == 0 { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { try? (header + "\n").write(to: url, atomically: true, encoding: .utf8) }
        if let h = try? FileHandle(forWritingTo: url), let d = pending.data(using: .utf8) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
            pending = ""; pendingLines = 0
        }
    }

    /// perMinute = pasos de la pulsera por minuto (unix/60) en tramos con historial seguido; covered = esos tramos [a, b] (s);
    /// gaps = huecos sin historial (a, b, pasos que contó la pulsera entre medias).
    struct Data {
        var perMinute: [Int64: Int] = [:]
        var covered: [(Int64, Int64)] = []
        var gaps: [(Int64, Int64, Int)] = []

        func covers(_ unix: Int64) -> Bool {
            var lo = 0, hi = covered.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2, c = covered[mid]
                if unix < c.0 { hi = mid - 1 } else if unix > c.1 { lo = mid + 1 } else { return true }
            }
            return false
        }
    }

    static func read(url: URL = AppPaths.file(fileName)) -> Data {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Data() }
        var samples = [Int64: Int]()
        for line in text.split(separator: "\n") {
            let p = line.split(separator: ",")
            guard p.count >= 2, let t = Int64(p[0]), let v = Int(p[1].trimmingCharacters(in: .whitespaces)) else { continue }
            samples[t] = v
        }
        return fromSamples(samples)
    }

    static func fromSamples(_ samples: [Int64: Int]) -> Data {
        var d = Data()
        var pt: Int64 = -1, pv = 0
        for t in samples.keys.sorted() {
            let v = samples[t]!
            if pt < 0 { d.covered.append((t, t)) } else {
                let inc = v >= pv ? v - pv : v   // si baja, la pulsera reinició el contador (ciclo nuevo)
                if t - pt <= maxGapS {
                    if inc > 0 { d.perMinute[t / 60, default: 0] += inc }
                    d.covered[d.covered.count - 1].1 = t
                } else {
                    d.gaps.append((pt, t, inc))
                    d.covered.append((t, t))
                }
            }
            pt = t; pv = v
        }
        return d
    }

    /// Pasos entre [fromMs, toMs): pulsera donde hay historial seguido, PulseApp donde no, y en un hueco sin historial el mayor de los dos.
    static func merged(_ band: Data, _ imu: [MotionMinute], fromMs: Int64, toMs: Int64) -> Int {
        let m0 = fromMs / 60_000, m1 = toMs / 60_000
        var s = 0
        for (m, v) in band.perMinute where m >= m0 && m < m1 { s += v }
        for x in imu {
            let m = x.minuteStartUnix / 60
            if m >= m0 && m < m1 && !band.covers(x.minuteStartUnix) && !band.covers(x.minuteStartUnix + 59) { s += x.steps }
        }
        for g in band.gaps {
            let gm = g.1 / 60
            if gm < m0 || gm >= m1 { continue }
            let imuInGap = imu.filter { $0.minuteStartUnix >= g.0 && $0.minuteStartUnix <= g.1 }.reduce(0) { $0 + $1.steps }
            s += max(0, g.2 - imuInGap)
        }
        return s
    }

    /// Pasos por día (clave yyyy-MM-dd), con las mismas reglas que merged.
    static func perDay(_ band: Data, _ imu: [MotionMinute]) -> [String: Int] {
        var out = [String: Int]()
        for (m, v) in band.perMinute { out[TimeUtil.dayKey(m * 60_000), default: 0] += v }
        for x in imu where !band.covers(x.minuteStartUnix) && !band.covers(x.minuteStartUnix + 59) {
            out[TimeUtil.dayKey(x.minuteStartUnix * 1000), default: 0] += x.steps
        }
        for g in band.gaps {
            let imuInGap = imu.filter { $0.minuteStartUnix >= g.0 && $0.minuteStartUnix <= g.1 }.reduce(0) { $0 + $1.steps }
            let extra = max(0, g.2 - imuInGap)
            if extra > 0 { out[TimeUtil.dayKey(g.1 * 1000), default: 0] += extra }
        }
        return out
    }

    static func hasData(_ band: Data, fromMs: Int64, toMs: Int64) -> Bool {
        return band.covered.contains { $0.0 * 1000 < toMs && $0.1 * 1000 >= fromMs }
    }
}
