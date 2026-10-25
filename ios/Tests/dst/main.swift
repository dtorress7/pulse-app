import Foundation

// Comprobación en CI (macOS): cambio de hora del 25/10/2026 en hr_log.csv (HrLog.repairDstOnce + lectura con desfase).
struct HrReading { let timeMillis: Int64; let bpm: Int; let rr: [Double] }

TimeUtil.timeZone = TimeZone(identifier: "Europe/Madrid")!
UserDefaults.standard.removeObject(forKey: "pulseapp_dst_repair_v1")
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dstcheck-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let url = dir.appendingPathComponent("hr_log.csv")
var text = "timestamp,bpm,rr_intervals_ms\n"
func add(_ h: Int, _ m: Int, _ s: Int, _ bpm: Int) { text += String(format: "2026-10-25T%02d:%02d:%02d,%d,\"900.0\"\n", h, m, s, bpm) }
for m in 50..<60 { add(1, m, 0, 55) }                       // 01:50–01:59 verano (23:50Z–23:59Z del 24)
for m in 0..<60 {                                           // 1.ª pasada 02:00–02:59 verano (00:00Z–00:59Z)
    add(2, m, 0, 60)
    if m == 20 { add(2, 10, 30, 61) }                       // historial que llega 10 min tarde (sigue en la 1.ª pasada)
}
for m in 0..<60 { add(2, m, 0, 70) }                        // 2.ª pasada 02:00–02:59 invierno (01:00Z–01:59Z)
for m in 0..<10 { add(3, m, 0, 80) }                        // 03:00–03:09 invierno (02:00Z–02:09Z)
try! text.write(to: url, atomically: true, encoding: .utf8)

var fail = 0
func check(_ ok: Bool, _ msg: String) { if !ok { fail += 1; print("::error::Cambio de hora: \(msg)") } }

let log = HrLog(url: url)
check(log.repairDstOnce(), "no arregló el archivo")
check(!log.repairDstOnce(), "lo arregló dos veces")
let r = log.allReadings()
check(r.count == 10 + 60 + 1 + 60 + 10, "lecturas \(r.count) (esperaba 141)")
let base: Int64 = 1_792_886_400_000   // 2026-10-25T00:00:00Z
for x in r {
    let mz = (x.timeMillis - base) / 60_000      // minutos desde las 00:00Z
    switch x.bpm {
    case 55: check(mz < 0 && mz >= -10, "55 a \(mz)")
    case 60, 61: check(mz >= 0 && mz < 60, "1.ª pasada a \(mz)")
    case 70: check(mz >= 60 && mz < 120, "2.ª pasada a \(mz)")
    case 80: check(mz >= 120 && mz < 130, "03:xx a \(mz)")
    default: check(false, "bpm \(x.bpm)")
    }
}
check(TimeUtil.logTimestamp(base + 3_600_000) == "2026-10-25T02:00:00+01:00", "escritura \(TimeUtil.logTimestamp(base + 3_600_000))")
check(TimeUtil.logTimestamp(base) == "2026-10-25T02:00:00+02:00", "escritura \(TimeUtil.logTimestamp(base))")
check(TimeUtil.logTimestamp(base + 10 * 3_600_000) == "2026-10-25T11:00:00", "escritura normal \(TimeUtil.logTimestamp(base + 10 * 3_600_000))")
// Escribir con desfase y volver a leer
log.append(timeMillis: base + 3_600_000 + 30_000, bpm: 99, rr: [])
let r2 = log.readings(from: base + 3_600_000, to: base + 3_600_000 + 60_000)
check(r2.contains { $0.bpm == 99 && $0.timeMillis == base + 3_600_000 + 30_000 }, "lectura de una línea con desfase")
if fail == 0 { print("::notice::Cambio de hora: 141 lecturas en su sitio, escritura y lectura con desfase OK") } else { exit(1) }
