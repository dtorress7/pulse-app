import Foundation

/// Calibración personal de la recuperación (14/11, igual que Android `RecoveryCalibration.kt`) con el export de WHOOP de cada persona:
/// se ajustan los 4 números de la fórmula (base, VFC, FCR, percentil) con SUS noches importadas y solo se usan si hay ≥ 90 noches y en
/// validación cruzada (10 partes) fallan al menos 0,3 puntos menos que la general. Las noches desde el 10/11 se ajustan sin el escalón.
enum RecoveryCalibration {
    static let minNights = 90
    static let minGain = 0.3
    private static let warmup = 10

    struct Fit {
        var n: Int
        var coef: [Double]?
        var cvPersonal: Double?
        var cvGeneral: Double?
        var usePersonal: Bool { coef != nil }
    }

    static func fit(_ days: [DailyMetrics]) -> Fit {
        let sorted = days.sorted { $0.date < $1.date }
        var xs: [[Double]] = []; var ys: [Double] = []
        for (i, d) in sorted.enumerated() {
            if i < warmup { continue }
            guard let rec = d.whoopRecovery, let hrv = d.avgHrv, hrv > 0, let rhr = d.restingHr else { continue }
            let prev = Array(sorted[0..<i].reversed().prefix(BaselineProvider.lookbackDays))
            guard let b = BaselineProvider.computeFrom(prev) else { continue }
            let f = Formulas.recoveryFeatures(hrv: hrv, restingHr: rhr, baseline: b)
            xs.append([1.0, f[0], -f[1], f[2]])
            ys.append(Double(rec) - Formulas.recoveryStep(d.date))
        }
        let n = xs.count
        if n < minNights { return Fit(n: n, coef: nil, cvPersonal: nil, cvGeneral: nil) }
        let general = [Formulas.recBias, Formulas.recKHrv, Formulas.recKRhr, Formulas.recKPct]
        var errP = 0.0, errG = 0.0
        for k in 0..<10 {
            var trX: [[Double]] = [], trY: [Double] = []
            for i in 0..<n where i % 10 != k { trX.append(xs[i]); trY.append(ys[i]) }
            guard let c = leastSquares(trX, trY) else { return Fit(n: n, coef: nil, cvPersonal: nil, cvGeneral: nil) }
            for i in 0..<n where i % 10 == k { errP += abs(pred(c, xs[i]) - ys[i]); errG += abs(pred(general, xs[i]) - ys[i]) }
        }
        let cvP = errP / Double(n), cvG = errG / Double(n)
        let all = leastSquares(xs, ys)
        let use = all != nil && cvP <= cvG - minGain
        return Fit(n: n, coef: use ? all : nil, cvPersonal: cvP, cvGeneral: cvG)
    }

    private static func pred(_ c: [Double], _ x: [Double]) -> Double {
        let v = (c[0] * x[0] + c[1] * x[1] + c[2] * x[2] + c[3] * x[3]).rounded()
        return min(max(v, 1), 99)
    }

    /// Mínimos cuadrados con las ecuaciones normales (4×4) y eliminación de Gauss.
    static func leastSquares(_ xs: [[Double]], _ ys: [Double]) -> [Double]? {
        let m = 4
        var a = Array(repeating: Array(repeating: 0.0, count: m + 1), count: m)
        for (x, y) in zip(xs, ys) { for r in 0..<m { for c in 0..<m { a[r][c] += x[r] * x[c] }; a[r][m] += x[r] * y } }
        for col in 0..<m {
            var piv = col
            for r in (col + 1)..<m where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            if abs(a[piv][col]) < 1e-12 { return nil }
            a.swapAt(col, piv)
            for r in 0..<m where r != col {
                let f = a[r][col] / a[col][col]
                for c in col...m { a[r][c] -= f * a[col][c] }
            }
        }
        return (0..<m).map { a[$0][m] / a[$0][$0] }
    }
}
