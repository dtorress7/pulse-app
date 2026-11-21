import Foundation

/// Calibración personal de la recuperación (14/11; v2 21/11, igual que Android `RecoveryCalibration.kt`) con el export de WHOOP de
/// cada persona. WHOOP no usa los mismos números para todos (con el export de Pablo: le pesa más la VFC, le pesa la calificación del
/// sueño y su "escalón" del 10/11 fue al revés), así que con SUS noches se ajustan 6 números: base, VFC, FCR, percentil, calificación
/// del sueño y su escalón desde el 10/11 (solo con ≥ 7 noches a cada lado). Solo se usan si hay ≥ 90 noches y en validación cruzada
/// (10 partes) fallan al menos 0,3 puntos menos que la general.
enum RecoveryCalibration {
    static let minNights = 90
    static let minGain = 0.3
    static let minStepNights = 7
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
        var xs: [[Double]] = []; var ys: [Double] = []; var dates: [String] = []
        for (i, d) in sorted.enumerated() {
            if i < warmup { continue }
            guard let rec = d.whoopRecovery, let hrv = d.avgHrv, hrv > 0, let rhr = d.restingHr, let sleep = d.whoopSleepScore else { continue }
            let prev = Array(sorted[0..<i].reversed().prefix(BaselineProvider.lookbackDays))
            guard let b = BaselineProvider.computeFrom(prev) else { continue }
            let f = Formulas.recoveryFeatures(hrv: hrv, restingHr: rhr, baseline: b)
            let step = d.date >= Formulas.recWhoopStepSince ? 1.0 : 0.0
            xs.append([1.0, f[0], -f[1], f[2], Double(sleep), step])
            ys.append(Double(rec)); dates.append(d.date)
        }
        let n = xs.count
        if n < minNights { return Fit(n: n, coef: nil, cvPersonal: nil, cvGeneral: nil) }
        let after = xs.filter { $0[5] > 0 }.count
        let useStep = after >= minStepNights && n - after >= minStepNights
        let m = useStep ? 6 : 5
        let xm = xs.map { Array($0.prefix(m)) }
        let general = [Formulas.recBias, Formulas.recKHrv, Formulas.recKRhr, Formulas.recKPct]
        var errP = 0.0, errG = 0.0
        for k in 0..<10 {
            var trX: [[Double]] = [], trY: [Double] = []
            for i in 0..<n where i % 10 != k { trX.append(xm[i]); trY.append(ys[i]) }
            guard let c = leastSquares(trX, trY) else { return Fit(n: n, coef: nil, cvPersonal: nil, cvGeneral: nil) }
            for i in 0..<n where i % 10 == k {
                errP += abs(pred(c, xm[i]) - ys[i])
                errG += abs(clamp(general[0] + general[1] * xs[i][1] + general[2] * xs[i][2] + general[3] * xs[i][3] +
                                  Formulas.recoveryStep(dates[i])) - ys[i])
            }
        }
        let cvP = errP / Double(n), cvG = errG / Double(n)
        let all = leastSquares(xm, ys)
        let use = all != nil && cvP <= cvG - minGain
        let meanSleep = xs.reduce(0.0) { $0 + $1[4] } / Double(n)
        var coef: [Double]? = nil
        if use, let a = all { coef = [a[0], a[1], a[2], a[3], a[4], useStep ? a[5] : 0.0, meanSleep] }
        return Fit(n: n, coef: coef, cvPersonal: cvP, cvGeneral: cvG)
    }

    private static func clamp(_ v: Double) -> Double { min(max(v.rounded(), 1), 99) }
    private static func pred(_ c: [Double], _ x: [Double]) -> Double {
        var s = 0.0
        for j in 0..<c.count { s += c[j] * x[j] }
        return clamp(s)
    }

    /// Mínimos cuadrados con las ecuaciones normales (m×m) y eliminación de Gauss.
    static func leastSquares(_ xs: [[Double]], _ ys: [Double]) -> [Double]? {
        guard let m = xs.first?.count else { return nil }
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
