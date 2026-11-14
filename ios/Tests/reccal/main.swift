import Foundation
// Calibración personal y escalón de WHOOP (14/11): Swift = Kotlin (expected.txt sale de check/cmp/CalRef.kt con el export real)
let dir = CommandLine.arguments[1]
UserDefaults.standard.set("2026-10-22", forKey: "pulseapp_whoop_import_until")
Formulas.setPersonalRecovery(nil)
let lines = try! String(contentsOfFile: dir + "/days.csv").split(separator: "\n").dropFirst()
var days: [DailyMetrics] = lines.map { l in
    let p = l.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    var d = DailyMetrics(date: p[0], restingHr: Int(p[2]), avgHrv: Double(p[1]), sleepMinutes: Int(Double(p[4]) ?? 0), strain: nil, vo2Max: nil, caloriesKcal: nil)
    d.respiratoryRate = Double(p[3]); d.whoopRecovery = Int(p[5])
    return d
}
var out: [String] = []
let f = RecoveryCalibration.fit(days)
out.append(String(format: "fit %d %.6f %.6f ", f.n, f.cvPersonal ?? -1, f.cvGeneral ?? -1) + (f.usePersonal ? "true" : "false"))
let shifted = days.map { d -> DailyMetrics in var x = d; if let r = x.whoopRecovery { x.whoopRecovery = min(max(r - 10, 1), 99) }; return x }
let g = RecoveryCalibration.fit(shifted)
out.append(String(format: "shifted %d %.6f %.6f ", g.n, g.cvPersonal ?? -1, g.cvGeneral ?? -1) + (g.usePersonal ? "true " : "false ")
           + (g.coef ?? []).map { String(format: "%.6f", $0) }.joined(separator: " "))
let b = BaselineProvider.computeFrom(Array(days.sorted { $0.date > $1.date }.prefix(30)))
for (d, h, r) in [("2026-11-09", 87.0, 58), ("2026-11-10", 87.0, 58), ("2026-11-14", 94.2, 59)] {
    out.append("rec \(d) \(Formulas.recovery(hrv: h, restingHr: r, respiratoryRate: nil, baseline: b, date: d).total)")
}
let expected = try! String(contentsOfFile: dir + "/expected.txt").split(separator: "\n").map(String.init)
var ok = true
for (i, e) in expected.enumerated() {
    let got = i < out.count ? out[i] : "(nada)"
    if got != e { print("DISTINTO\n  Kotlin: \(e)\n  Swift:  \(got)"); ok = false } else { print("igual: \(got)") }
}
exit(ok ? 0 : 1)
