import Foundation

/// Detección del sueño solo con el pulso (ajustada con la noche del 14→15/10 frente a WHOOP):
///  - Pulso medio por minuto, suavizado con una media de 3 minutos.
///  - Umbral = 1,30 × media del 10 % de lecturas más bajas de la noche.
///  - Empieza en el primer minuto por debajo del umbral; tolera hasta 30 min seguidos por encima.
///  - Mínimo 90 min. Si hay varias ventanas, se coge la última.
enum SleepDetector {

    static let thresholdMultiplier = 1.30
    static let graceMinutes = 30
    static let minDurationMinutes = 90
    static let disconnectGapMinutes = 10
    static let smoothMinutes = 3

    struct SleepWindow {
        let startMillis: Int64
        let endMillis: Int64
        let inBedMinutes: Int
        let awakeMinutes: Int
        let efficiencyPct: Int
        let thresholdBpm: Double
        var asleepMinutes: Int { return max(inBedMinutes - awakeMinutes, 0) }
    }

    /// Solo cuenta como posible sueño lo que pasa entre las 20:00 y las 12:00.
    static func isNightHour(_ timeMillis: Int64) -> Bool {
        let h = TimeUtil.parts(timeMillis).hour
        return h >= 20 || h < 15   // hasta las 15:00: te puedes despertar a las 12–14 (en tu export, hasta las 14:26)
    }

    /// [readings] = (hora en ms, pulso), en cualquier orden.
    static func detect(_ readings: [(Int64, Int)]) -> SleepWindow? {
        let night = readings.filter { isNightHour($0.0) && $0.1 >= 25 && $0.1 <= 230 }.sorted { $0.0 < $1.0 }
        if night.count < 60 { return nil }

        // Medias por minuto (en orden de aparición) y suavizado
        var keys = [Int64]()
        var sums = [Double]()
        var counts = [Int]()
        for r in night {
            let k = r.0 / 60000
            if let last = keys.last, last == k {
                sums[sums.count - 1] += Double(r.1)
                counts[counts.count - 1] += 1
            } else {
                keys.append(k); sums.append(Double(r.1)); counts.append(1)
            }
        }
        let raw = (0..<keys.count).map { sums[$0] / Double(counts[$0]) }
        var smooth = [Double](repeating: 0, count: raw.count)
        for i in 0..<raw.count {
            let lo = max(0, i - smoothMinutes + 1)
            var s = 0.0
            for j in lo...i { s += raw[j] }
            smooth[i] = s / Double(i - lo + 1)
        }

        let sorted = night.map { $0.1 }.sorted()
        let take = max(sorted.count / 10, 1)
        var low10 = 0.0
        for i in 0..<take { low10 += Double(sorted[i]) }
        low10 /= Double(take)
        let threshold = low10 * thresholdMultiplier

        var windows = [(Int, Int)]()
        var start: Int? = nil
        var aboveSince: Int? = nil

        func close(_ endIdx: Int) {
            guard let s = start else { return }
            if keys[endIdx] - keys[s] >= Int64(minDurationMinutes) { windows.append((s, endIdx)) }
        }

        for i in 0..<keys.count {
            if i > 0 && keys[i] - keys[i - 1] > Int64(disconnectGapMinutes) {
                if let a = aboveSince { close(max(a - 1, 0)) } else { close(i - 1) }
                start = nil; aboveSince = nil
            }
            if smooth[i] <= threshold {
                aboveSince = nil
                if start == nil { start = i }
            } else if let s = start {
                if aboveSince == nil {
                    aboveSince = i
                } else if let a = aboveSince, keys[i] - keys[a] > Int64(graceMinutes) {
                    close(max(a - 1, s))
                    start = nil; aboveSince = nil
                }
            }
        }
        if start != nil { close(keys.count - 1) }
        // La NOCHE es la ventana que más se solapa con las 00:00–06:00 (21/10: una reunión quieto de 9:30 a 11:29 se tomaba
        // como la noche por ser la última ventana). Si ninguna toca la madrugada, la más larga.
        func score(_ w: (Int, Int)) -> (Int, Int64) {
            var n = 0
            for i in w.0...w.1 where TimeUtil.parts(keys[i] * 60_000).hour < 6 { n += 1 }
            return (n, keys[w.1] - keys[w.0])
        }
        guard let (s, e) = windows.max(by: { score($0) < score($1) }) else { return nil }

        let inBed = Int(keys[e] - keys[s])
        let minutesInWindow = e - s + 1
        var awake = 0
        for i in s...e where smooth[i] > threshold { awake += 1 }
        let efficiency = minutesInWindow > 0 ? (minutesInWindow - awake) * 100 / minutesInWindow : 0
        return SleepWindow(startMillis: keys[s] * 60000, endMillis: keys[e] * 60000, inBedMinutes: inBed,
                           awakeMinutes: awake, efficiencyPct: min(max(efficiency, 0), 100), thresholdBpm: threshold)
    }
}
