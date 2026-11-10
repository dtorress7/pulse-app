import Foundation

// Comprobación en CI (7/11): las fases y los límites de la noche en Swift (SleepStager.stage, con el modelo y el recorte de inicio/fin
// despierto en la cama) dan lo mismo que Android con 3 noches reales (6→7/11 despierto en la cama al principio y al final, 25→26/10 y
// 4→5/11 de control). nights.csv: "#night,día,inicio ms,fin ms,minuto de inicio de Kotlin,fases de Kotlin", lecturas "ms,lpm,rr|rr…"
// y movimiento "M,<línea de motion_minutes.csv>".
let args = CommandLine.arguments
SleepModel.modelURL = URL(fileURLWithPath: args[2])
let text = try! String(contentsOfFile: args[1], encoding: .utf8)
struct N { var day: String; var s: Int64; var e: Int64; var refStart: Int64; var refStages: String; var ds: Int64 = 0; var de: Int64 = 0; var hr: [HrReading] = []; var mot: [MotionMinute] = []; var wide: [MotionMinute] = [] }
var nights: [N] = []
for line in text.split(separator: "\n") {
    if line.hasPrefix("#night") {
        let p = line.split(separator: ",")
        var n = N(day: String(p[1]), s: Int64(p[2])!, e: Int64(p[3])!, refStart: Int64(p[4])!, refStages: String(p[5]))
        if p.count > 7 { n.ds = Int64(p[6])!; n.de = Int64(p[7])! }
        nights.append(n)
    } else if line.hasPrefix("W,") {
        if let m = MotionMinute.fromCsv(line.dropFirst(2)) { nights[nights.count - 1].wide.append(m) }
    } else if line.hasPrefix("M,") {
        if let m = MotionMinute.fromCsv(line.dropFirst(2)) { nights[nights.count - 1].mot.append(m) }
    } else {
        let p = line.split(separator: ",", omittingEmptySubsequences: false)
        let rr = p.count > 2 ? p[2].split(separator: "|").compactMap { Double($0) } : []
        nights[nights.count - 1].hr.append(HrReading(timeMillis: Int64(p[0])!, bpm: Int(p[1])!, rr: rr))
    }
}
var bad = 0
for n in nights {
    // 10/11: también los límites por movimiento (motionBounds) desde la ventana del detector
    if n.ds > 0 {
        let b = SleepStager.motionBounds(n.ds, n.de, n.wide)
        let okB = b.0 == n.s && b.1 == n.e
        print("::notice::Noche \(n.day): límites por movimiento Swift \(b.0)–\(b.1) / Kotlin \(n.s)–\(n.e) \(okB ? "OK" : "DISTINTO")")
        if !okB { bad += 1 }
    }
    guard let r = SleepStager.stage(startMillis: n.s, endMillis: n.e, readings: n.hr, motion: n.mot) else {
        print("::error::\(n.day): Swift no da noche"); bad += 1; continue
    }
    let s = r.stages.map(String.init).joined()
    let same = zip(s, n.refStages).filter { $0 == $1 }.count
    let ok = r.startMinute == n.refStart && s.count == n.refStages.count && same == s.count
    print("::notice::Noche \(n.day): inicio Swift \(r.startMinute) / Kotlin \(n.refStart), minutos \(s.count) / \(n.refStages.count), fases iguales \(same) \(ok ? "OK" : "DISTINTO")")
    if !ok { bad += 1 }
}
if bad > 0 { print("::error::El recorte/fases de la noche en Swift no coincide con Android en \(bad) noches"); exit(1) }
