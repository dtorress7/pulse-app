import Foundation

/// Un segundo de acelerómetro + giroscopio de la WHOOP 5.0 (100 muestras). Formato verificado con la prueba del 14/10:
///   mensaje tipo 43, 1244 bytes, cabecera AA 01 D4 04
///   [11..12] contador · [15..18] hora unix · [22..23] nº de muestras (100) · [24..25] válidas
///   [28..627] ACELERÓMETRO: 100 X, 100 Y, 100 Z (int16 LE), 4096 = 1 g
///   [628..639] sub-cabecera del giroscopio · [640..1239] GIROSCOPIO 100 X/Y/Z, 16,4 = 1 °/s
///   [1240..1243] CRC32 de [8..1239] · -32768 = muestra no válida (NaN)
struct ImuSecond {
    let unixTime: Int64
    let seq: Int
    let ax: [Float], ay: [Float], az: [Float]   // en g
    let gx: [Float], gy: [Float], gz: [Float]   // en °/s (NaN si el giro aún no arrancó)
    var size: Int { return ax.count }
}

enum WhoopImuDecoder {
    static let messageSize = 1244
    static let typeImu = 43
    static let accelCountsPerG: Float = 4096
    static let gyroCountsPerDps: Float = 16.4
    private static let invalid = -32768
    private static let accelOffset = 28
    private static let gyroHeaderOffset = 628
    private static let gyroOffset = 640
    private static let crcOffset = 1240

    /// nil si el mensaje no es un IMU válido (tamaño, tipo o CRC incorrectos).
    static func decode(_ m: [UInt8]) -> ImuSecond? {
        if m.count < messageSize { return nil }
        if m[0] != 0xAA || Int(m[8]) != typeImu { return nil }
        let crc = Crc.crc32(m, from: 8, count: crcOffset - 8)
        if Int64(crc) != Bytes.u32(m, crcOffset) { return nil }

        let n = Bytes.u16(m, 22)
        if n <= 0 || n > 100 { return nil }
        let gyroCount = Bytes.u16(m, gyroHeaderOffset)
        let gyroValid = Bytes.u16(m, gyroHeaderOffset + 2)
        let gyroOn = gyroCount == 100 && gyroValid > 0

        func axis(_ base: Int, _ idx: Int, _ scale: Float, _ enabled: Bool) -> [Float] {
            var out = [Float](repeating: Float.nan, count: n)
            if !enabled { return out }
            for i in 0..<n {
                let raw = Bytes.s16(m, base + (idx * 100 + i) * 2)
                out[i] = raw == invalid ? Float.nan : Float(raw) / scale
            }
            return out
        }

        return ImuSecond(
            unixTime: Bytes.u32(m, 15), seq: Bytes.u16(m, 11),
            ax: axis(accelOffset, 0, accelCountsPerG, true),
            ay: axis(accelOffset, 1, accelCountsPerG, true),
            az: axis(accelOffset, 2, accelCountsPerG, true),
            gx: axis(gyroOffset, 0, gyroCountsPerDps, gyroOn),
            gy: axis(gyroOffset, 1, gyroCountsPerDps, gyroOn),
            gz: axis(gyroOffset, 2, gyroCountsPerDps, gyroOn))
    }
}

/// Contador de pasos en tiempo real a partir del acelerómetro de muñeca (100 Hz).
///  1. Módulo de la aceleración |a| (en g).
///  2. Señal = media de 0,1 s − media de 1 s (quita la gravedad), alineadas en el tiempo.
///  3. Pico > 0,08 g separado ≥ 0,3 s del anterior = paso candidato.
///  4. Solo cuenta si hay ritmo: 4 pasos seguidos con intervalos de 0,3–1,5 s y parecidos entre sí.
///  Se descartan los golpes de más de 3 g y los giros rápidos de muñeca (> 250 °/s de media).
final class ImuStepCounter {

    private(set) var totalSteps = 0

    private let fast = Ring(10)
    private let slow = Ring(100)
    private let gyro = Ring(100)
    private var magWindow = [Float](repeating: 0, count: 100)
    private var fastHistory = [Float](repeating: 0, count: 46)   // DELAY + 1
    private var fastHistoryCount = 0
    private var fastHistoryPos = 0

    private var index: Int64 = 0
    private var x1: Float = 0
    private var x2: Float = 0
    private var lastPeak: Int64 = Int64.min / 2
    private var run = [Int64]()
    private var inRun = false

    private static let slowN = 100
    private static let delay = 45
    private static let peakThresholdG: Float = 0.08
    private static let minGapSamples: Int64 = 30
    private static let minRun = 4
    private static let maxStepG: Float = 3.0
    private static let maxStepGyroDps: Float = 250

    /// Llamar si se pierden datos (hueco de conexión): corta la racha de pasos en curso.
    func gap() { run.removeAll() }

    /// Procesa un segundo entero. Devuelve los pasos nuevos contados en ese segundo.
    func feed(_ s: ImuSecond) -> Int {
        let before = totalSteps
        for i in 0..<s.size {
            let ax = s.ax[i], ay = s.ay[i], az = s.az[i]
            if ax.isNaN || ay.isNaN || az.isNaN { continue }
            let gx = s.gx[i], gy = s.gy[i], gz = s.gz[i]
            let g: Float = (gx.isNaN || gy.isNaN || gz.isNaN) ? 0 : (gx * gx + gy * gy + gz * gz).squareRoot()
            sample((ax * ax + ay * ay + az * az).squareRoot(), g)
        }
        return totalSteps - before
    }

    private func sample(_ mag: Float, _ gyroMag: Float) {
        fast.add(mag)
        slow.add(mag)
        gyro.add(gyroMag)
        magWindow[Int(index % Int64(ImuStepCounter.slowN))] = mag

        fastHistory[fastHistoryPos] = fast.mean()
        fastHistoryPos = (fastHistoryPos + 1) % fastHistory.count
        if fastHistoryCount < fastHistory.count { fastHistoryCount += 1 }
        // media rápida de hace DELAY muestras (queda centrada con la media lenta)
        let delayedFast = fastHistory[fastHistoryPos % fastHistory.count]
        let x = delayedFast - slow.mean()

        let i = index
        index += 1
        let ready = slow.count == ImuStepCounter.slowN && fastHistoryCount == fastHistory.count
        if ready && x1 > ImuStepCounter.peakThresholdG && x1 >= x2 && x1 > x {
            let peak = i - 1 - Int64(ImuStepCounter.delay)
            if peak - lastPeak >= ImuStepCounter.minGapSamples && !isArmShake() { onPeak(peak) }
        }
        x2 = x1
        x1 = x
    }

    private func isArmShake() -> Bool {
        var mx: Float = 0
        for v in magWindow where v > mx { mx = v }
        return mx > ImuStepCounter.maxStepG || gyro.mean() > ImuStepCounter.maxStepGyroDps
    }

    private func onPeak(_ p: Int64) {
        if !run.isEmpty {
            let dt = Float(p - run[run.count - 1]) / 100
            let prev: Float = run.count > 1 ? Float(run[run.count - 1] - run[run.count - 2]) / 100 : dt
            let rhythmic = dt >= 0.3 && dt <= 1.5 && max(dt, prev) / min(dt, prev) < 1.6
            if !rhythmic { run.removeAll() }
        }
        lastPeak = p
        run.append(p)
        if run.count > 8 { run.removeFirst() }
        if run.count == ImuStepCounter.minRun && !inRun {
            totalSteps += ImuStepCounter.minRun; inRun = true
        } else if run.count >= ImuStepCounter.minRun && inRun {
            totalSteps += 1
        }
        if run.count == 1 { inRun = false }
    }

    private final class Ring {
        let capacity: Int
        private var data: [Float]
        private var pos = 0
        private(set) var count = 0
        private var sum = 0.0
        init(_ capacity: Int) { self.capacity = capacity; data = [Float](repeating: 0, count: capacity) }
        func add(_ v: Float) {
            if count == capacity { sum -= Double(data[pos]) } else { count += 1 }
            data[pos] = v
            sum += Double(v)
            pos = (pos + 1) % capacity
        }
        func mean() -> Float { return count == 0 ? 0 : Float(sum / Double(count)) }
    }
}
