import Foundation

/// Resumen de movimiento por minuto (lo que usan Sueño, Actividades y Pasos).
///   enmoMg   intensidad (media de |a| − 1 g, en mili-g). Quieto ≈ 0, andando ≈ 90–220, deporte ≈ 700–2700.
///   gyroDps  giro medio de la muñeca (°/s). Quieto ≈ 1–4, andando ≈ 90–150.
///   stillSecs segundos del minuto sin moverse (desviación de |a| < 15 mg).
///   grav*    orientación media de la muñeca (postura tumbado / cambios de postura).
struct MotionMinute {
    let minuteStartUnix: Int64
    let seconds: Int
    let steps: Int
    let enmoMg: Float
    let gyroDps: Float
    let stillSecs: Int
    let gravX: Float, gravY: Float, gravZ: Float

    static let csvHeader = "minute_unix,seconds,steps,enmo_mg,gyro_dps,still_secs,grav_x,grav_y,grav_z"

    func toCsv() -> String {
        return String(format: "%lld,%d,%d,%.1f,%.1f,%d,%.3f,%.3f,%.3f",
                      minuteStartUnix, seconds, steps, Double(enmoMg), Double(gyroDps), stillSecs,
                      Double(gravX), Double(gravY), Double(gravZ))
    }

    static func fromCsv(_ line: Substring) -> MotionMinute? {
        let p = line.split(separator: ",", omittingEmptySubsequences: false)
        if p.count < 9 { return nil }
        guard let a = Int64(p[0]), let b = Int(p[1]), let c = Int(p[2]), let d = Float(p[3]), let e = Float(p[4]),
              let f = Int(p[5]), let g = Float(p[6]), let h = Float(p[7]), let i = Float(p[8]) else { return nil }
        return MotionMinute(minuteStartUnix: a, seconds: b, steps: c, enmoMg: d, gyroDps: e, stillSecs: f,
                            gravX: g, gravY: h, gravZ: i)
    }
}

/// Recibe los segundos IMU decodificados, cuenta pasos y guarda un resumen por minuto en motion_minutes.csv.
final class MotionTracker {

    static let fileName = "motion_minutes.csv"
    private static let stillSdG = 0.015

    private let outFile: URL
    private let steps = ImuStepCounter()
    private var lastUnix: Int64 = -1
    private var lastSeq = -1
    private let lock = NSLock()

    private(set) var stepsToday = 0
    private var stepsDay: String? = nil

    private var minuteStart: Int64 = -1
    private var secs = 0
    private var minuteSteps = 0
    private var enmoSum = 0.0
    private var gyroSum = 0.0
    private var gyroN = 0
    private var still = 0
    private var gxs = 0.0, gys = 0.0, gzs = 0.0
    private var gravN = 0
    private(set) var lastSecondEnmoMg: Float = 0

    init(outFile: URL) { self.outFile = outFile }

    /// Devuelve el minuto que se acaba de cerrar (si este segundo empezó uno nuevo), o nil.
    @discardableResult
    func feed(_ s: ImuSecond) -> MotionMinute? {
        lock.lock()
        defer { lock.unlock() }
        if lastUnix >= 0 && s.unixTime <= lastUnix { return nil }   // duplicado o desordenado
        // huecos: si falta algún segundo, se corta la racha de pasos
        if lastUnix >= 0 && (s.unixTime - lastUnix > 2 || ((s.seq - lastSeq) & 0xFFFF) > 2) { steps.gap() }
        lastUnix = s.unixTime
        lastSeq = s.seq

        let minute = s.unixTime - (s.unixTime % 60)
        var closed: MotionMinute? = nil
        if minute != minuteStart {
            if minuteStart >= 0 { closed = closeMinute() }
            minuteStart = minute
        }

        let newSteps = steps.feed(s)
        minuteSteps += newSteps
        addToToday(s.unixTime, newSteps)

        var enmo = 0.0, magSum = 0.0, magSq = 0.0
        var n = 0
        var gSum = 0.0
        var gN = 0
        var sx = 0.0, sy = 0.0, sz = 0.0
        for i in 0..<s.size {
            let ax = s.ax[i], ay = s.ay[i], az = s.az[i]
            if ax.isNaN || ay.isNaN || az.isNaN { continue }
            let m = Double((ax * ax + ay * ay + az * az).squareRoot())
            enmo += max(m - 1.0, 0.0)
            magSum += m; magSq += m * m; n += 1
            sx += Double(ax); sy += Double(ay); sz += Double(az)
            let gx = s.gx[i], gy = s.gy[i], gz = s.gz[i]
            if !gx.isNaN && !gy.isNaN && !gz.isNaN {
                gSum += Double((gx * gx + gy * gy + gz * gz).squareRoot()); gN += 1
            }
        }
        if n > 0 {
            let mean = magSum / Double(n)
            let sd = max(magSq / Double(n) - mean * mean, 0.0).squareRoot()
            lastSecondEnmoMg = Float(1000 * enmo / Double(n))
            enmoSum += Double(lastSecondEnmoMg)
            if sd < MotionTracker.stillSdG { still += 1 }
            gxs += sx / Double(n); gys += sy / Double(n); gzs += sz / Double(n); gravN += 1
            secs += 1
        }
        if gN > 0 { gyroSum += gSum / Double(gN); gyroN += 1 }
        return closed
    }

    /// Guarda el minuto a medias (llamar al parar la captura).
    @discardableResult
    func flush() -> MotionMinute? {
        lock.lock()
        defer { lock.unlock() }
        if secs > 0 {
            let m = closeMinute()
            minuteStart = -1
            return m
        }
        return nil
    }

    private func closeMinute() -> MotionMinute? {
        var mm: MotionMinute? = nil
        if secs > 0 {
            let gn = Double(max(gravN, 1))
            mm = MotionMinute(minuteStartUnix: minuteStart, seconds: secs, steps: minuteSteps,
                              enmoMg: Float(enmoSum / Double(secs)),
                              gyroDps: gyroN > 0 ? Float(gyroSum / Double(gyroN)) : 0,
                              stillSecs: still,
                              gravX: Float(gxs / gn), gravY: Float(gys / gn), gravZ: Float(gzs / gn))
        }
        secs = 0; minuteSteps = 0; enmoSum = 0; gyroSum = 0; gyroN = 0; still = 0
        gxs = 0; gys = 0; gzs = 0; gravN = 0
        if let m = mm { save(m) }
        return mm
    }

    private func addToToday(_ unix: Int64, _ newSteps: Int) {
        let day = TimeUtil.dayKey(unix * 1000)
        if day != stepsDay {
            stepsDay = day
            stepsToday = MotionTracker.stepsFor(day: day, file: outFile)
        }
        stepsToday += newSteps
    }

    /// Suma los pasos ya guardados ese día (por si la app se reinició a mitad del día).
    static func stepsFor(day: String, file: URL) -> Int {
        var total = 0
        for m in readMinutes(file) where TimeUtil.dayKey(m.minuteStartUnix * 1000) == day { total += m.steps }
        return total
    }

    private func save(_ m: MotionMinute) {
        var text = ""
        let size = (try? FileManager.default.attributesOfItem(atPath: outFile.path)[.size] as? NSNumber)?.int64Value ?? 0
        if !FileManager.default.fileExists(atPath: outFile.path) || size == 0 { text = MotionMinute.csvHeader + "\n" }
        text += m.toCsv() + "\n"
        let data = Data(text.utf8)
        if let h = try? FileHandle(forWritingTo: outFile) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: outFile)
        }
    }

    static func readMinutes(_ file: URL) -> [MotionMinute] {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return [] }
        var out = [MotionMinute]()
        var first = true
        text.enumerateLines { line, _ in
            if first { first = false; return }
            if let m = MotionMinute.fromCsv(Substring(line)) { out.append(m) }
        }
        return out
    }
}

/// Reensambla los mensajes IMU (tipo 43/51) que la WHOOP manda troceados (5 × 244 + 24 = 1244 bytes).
/// Un mensaje empieza con AA 01 + longitud (u16 LE) y mide declLen + 8 bytes.
final class WhoopImuReassembler {
    private var buffer = [UInt8]()
    private var expectedTotal = 0
    private(set) var lastConsumed = false

    func feed(_ chunk: [UInt8]) -> [UInt8]? {
        lastConsumed = true
        if chunk.count >= 9 && chunk[0] == 0xAA && chunk[1] == 0x01 {
            let declLen = Bytes.u16(chunk, 2)
            let type = Int(chunk[8])
            if declLen > 1000 && (type == 43 || type == 51) {
                buffer = chunk
                expectedTotal = declLen + 8
                return checkComplete()
            }
        }
        if expectedTotal == 0 { lastConsumed = false; return nil }
        buffer.append(contentsOf: chunk)
        return checkComplete()
    }

    private func checkComplete() -> [UInt8]? {
        if buffer.count >= expectedTotal {
            let m = Array(buffer[0..<expectedTotal])
            buffer.removeAll()
            expectedTotal = 0
            return m
        }
        return nil
    }
}
