import Foundation

// Comprobación en CI (4/11): la VFC de la noche en Swift (NightMetrics.hrv) da lo mismo que Android con dos noches reales
// (3→4/11 tras el fútbol y 19→20/10 tras 2 h de funcional). nights.csv: "#night,día,minuto de inicio,fases,VFC de Kotlin"
// seguido de las lecturas de la ventana de sueño "ms,lpm,rr|rr…".
// 24/11: + respiración de Kotlin (campo 6) y las mismas 2 noches con huecos ("-huecos": RR enteros y 1 de cada 3 lecturas sin RR,
// como el historial de la pulsera de Nico) para comprobar la VFC con latidos seguidos y la respiración de Lomb-Scargle.
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/vfc/nights.csv"
let text = try! String(contentsOfFile: path, encoding: .utf8)
var nights: [(String, Int64, [Int], Double, [HrReading], Double)] = []
for line in text.split(separator: "\n") {
    if line.hasPrefix("#night") {
        let p = line.split(separator: ",")
        nights.append((String(p[1]), Int64(p[2])!, p[3].map { Int(String($0))! }, Double(p[4])!, [], p.count > 5 ? Double(p[5])! : -2))
        continue
    }
    let p = line.split(separator: ",", omittingEmptySubsequences: false)
    let rr = p.count > 2 ? p[2].split(separator: "|").compactMap { Double($0) } : []
    nights[nights.count - 1].4.append(HrReading(timeMillis: Int64(p[0])!, bpm: Int(p[1])!, rr: rr))
}
var bad = 0
for (day, start, stages, ref, readings, respRef) in nights {
    let st = SleepStager.Result(startMinute: start, stages: stages)
    let v = NightMetrics.hrv(readings, staged: st) ?? -1
    let ok = abs(v - ref) < 0.01
    print("::notice::VFC \(day): Swift \(String(format: "%.4f", v)) / Kotlin \(String(format: "%.4f", ref)) \(ok ? "iguales" : "DISTINTAS")")
    if !ok { bad += 1 }
    if respRef > -2 {
        let r = RespiratoryRateCalculator.estimate(readings) ?? -1
        let rok = abs(r - respRef) < 0.001
        print("::notice::Respiración \(day): Swift \(r) / Kotlin \(respRef) \(rok ? "iguales" : "DISTINTAS")")
        if !rok { bad += 1 }
    }
}
if bad > 0 { print("::error::La VFC o la respiración en Swift no coinciden con Android en \(bad) noches"); exit(1) }
