import Foundation

/// Fases del sueño (Despierto / Ligero / Profundo / REM) con movimiento + pulso + VFC, minuto a minuto.
/// Se ejecuta SOLO sobre la ventana que ya detectó SleepDetector y SOLO si esa noche hay movimiento
/// (motion_minutes.csv, "Movimiento y pasos" activado). Sin movimiento no se inventan fases.
/// Es el mismo algoritmo que en Android (SleepStager.kt), calibrado con dos noches de WHOOP.
///
/// 1) DESPIERTO: minuto "agitado" si hay movimiento (≥10 s o pasos) y el pulso sube ≥6 lpm sobre su base local,
///    o movimiento fuerte (≥30 s), o pulso ≥ +15 con giro/cambio de postura. Grupos con huecos ≤2 min, 1 min antes y
///    hasta 2 después; vale si dura ≥3 min o el pulso sube ≥12 lpm.
/// 2) Del resto (lejos de un despertar) se miran pulso y VFC (RMSSD 7 min, en logaritmo) respecto a la mediana
///    de los 90 min de alrededor: PROFUNDO = VFC alta y pulso bajo; REM = VFC baja y pulso alto. El resto es LIGERO.
enum SleepStager {

    static let awake = 0
    static let light = 1
    static let deep = 2
    static let rem = 3

    private static let wakeMoveSecs = 10
    private static let wakeSpike = 6.0
    private static let wakeBigMoveSecs = 30
    private static let wakeSpikeHigh = 15.0
    private static let wakeGap = 2
    private static let wakeTail = 2
    private static let wakeMinMinutes = 3
    private static let wakeMinSpike = 12.0

    private static let localWindow = 91
    private static let deepHrv = 0.0
    private static let deepHrvSlope = 0.3
    private static let deepHr = -0.5
    private static let remHrv = -0.2
    private static let remHrvSlope = 0.4     // 17/10: REM más fácil al final de la noche
    private static let remHr = 0.0
    private static let remNoFirstMin = 45
    private static let deepNoLastMin = 45
    private static let minRun = 4

    private static let minWindowMinutes = 90
    /// La noche empieza en el primer tramo de al menos estos minutos sin despertar (17/10).
    private static let onsetRun = 15
    private static let minMotionCoverage = 0.6

    final class Result {
        let startMinute: Int64
        let stages: [Int]
        init(startMinute: Int64, stages: [Int]) { self.startMinute = startMinute; self.stages = stages }

        var minutes: Int { return stages.count }
        func count(_ stage: Int) -> Int { return stages.filter { $0 == stage }.count }
        var awakeMinutes: Int { return count(SleepStager.awake) }
        var lightMinutes: Int { return count(SleepStager.light) }
        var deepMinutes: Int { return count(SleepStager.deep) }
        var remMinutes: Int { return count(SleepStager.rem) }
        var asleepMinutes: Int { return minutes - awakeMinutes }
        var efficiencyPct: Int {
            return minutes > 0 ? min(max(asleepMinutes * 100 / minutes, 0), 100) : 0
        }
        /// Número de despertares (tramos "despierto" seguidos).
        var awakenings: Int {
            var n = 0
            for i in 0..<stages.count where stages[i] == SleepStager.awake && (i == 0 || stages[i - 1] != SleepStager.awake) { n += 1 }
            return n
        }
        var startMillis: Int64 { return startMinute * 60_000 }
        var endMillis: Int64 { return (startMinute + Int64(minutes)) * 60_000 }
    }

    // Caché: Inicio lo pide una vez por minuto y casi siempre no ha cambiado nada
    private static let cacheLock = NSLock()
    private static var cacheKey: String? = nil
    private static var cacheValue: Result? = nil

    /// Lee los archivos y clasifica la ventana. nil si no hay movimiento o datos suficientes.
    /// Inicio del sueño por QUIETUD (20/10), igual que Android: tras entrenar el pulso sigue alto la primera hora de sueño.
    /// Hacia atrás desde el inicio: ráfagas de ≤5 min con ≤12 pasos (cambios de postura) y, antes de cada una, un tramo
    /// de quietud total (≥50 s quieto, giro <3 °/s, sin pasos) de ≥15 min. 19→20: 23:12 (WHOOP 23:11); las demás noches igual.
    static func extendOnsetByStillness(_ startMillis: Int64, _ motion: [MotionMinute]) -> Int64 {
        var byMin = [Int64: MotionMinute](minimumCapacity: motion.count)
        for mm in motion { byMin[mm.minuteStartUnix / 60] = mm }
        func still(_ m: MotionMinute?) -> Bool {
            guard let m = m else { return false }
            return m.stillSecs >= 50 && m.gyroDps < 3 && m.steps == 0
        }
        var m = startMillis / 60_000 - 1
        var best = startMillis / 60_000
        var first = true
        while true {
            var b = m; var stepsB = 0
            while let x = byMin[b], !still(x), m - b < 6 { stepsB += x.steps; b -= 1 }
            if byMin[b] == nil || m - b > 5 || stepsB > 12 { break }
            var k = b
            while still(byMin[k]) { k -= 1 }
            if b - k < (first ? 1 : 15) { break }
            if b - k >= 15 { best = k + 1 }
            first = false
            m = k
        }
        return best * 60_000
    }

    static func stageNight(hrLog: HrLog, motionFile: URL, startMillis: Int64, endMillis: Int64) -> Result? {
        if !FileManager.default.fileExists(atPath: motionFile.path) { return nil }
        let msize = (try? FileManager.default.attributesOfItem(atPath: motionFile.path)[.size] as? NSNumber)?.int64Value ?? 0
        let key = "\(startMillis)-\(endMillis)-\(msize)-\(hrLog.fileSize() / 200_000)"
        cacheLock.lock()
        if key == cacheKey { let v = cacheValue; cacheLock.unlock(); return v }
        cacheLock.unlock()

        let allMotion = MotionTracker.readMinutes(motionFile)
        let start = extendOnsetByStillness(startMillis, allMotion)
        let lo = start / 60_000, hi = endMillis / 60_000
        let motion = allMotion.filter { $0.minuteStartUnix / 60 >= lo && $0.minuteStartUnix / 60 <= hi }
        var computed: Result? = nil
        if !motion.isEmpty {
            let readings = hrLog.readings(from: start, to: endMillis)
            computed = stage(startMillis: start, endMillis: endMillis, readings: readings, motion: motion)
        }
        cacheLock.lock()
        cacheKey = key; cacheValue = computed
        cacheLock.unlock()
        return computed
    }

    static func stage(startMillis: Int64, endMillis: Int64, readings: [HrReading], motion: [MotionMinute]) -> Result? {
        let m0 = startMillis / 60_000
        let m1 = endMillis / 60_000
        let n = Int(m1 - m0 + 1)
        if n < minWindowMinutes { return nil }

        // ---- Pulso y RR por minuto ----
        var hrSum = [Double](repeating: 0, count: n)
        var hrCnt = [Int](repeating: 0, count: n)
        var rrLists = [[Double]](repeating: [], count: n)
        for r in readings {
            let i = Int(r.timeMillis / 60_000 - m0)
            if i < 0 || i >= n { continue }
            hrSum[i] += Double(r.bpm)
            hrCnt[i] += 1
            rrLists[i].append(contentsOf: r.rr)
        }
        var hrRaw = [Double](repeating: Double.nan, count: n)
        var validHr = 0
        for i in 0..<n where hrCnt[i] >= 20 { hrRaw[i] = hrSum[i] / Double(hrCnt[i]); validHr += 1 }
        if Double(validHr) < Double(n) * 0.6 { return nil }
        let hrm = interp(hrRaw)

        // ---- Movimiento por minuto ----
        var moveSecs = [Int](repeating: 0, count: n)
        var steps = [Int](repeating: 0, count: n)
        var hasMotion = [Bool](repeating: false, count: n)
        var gx = [Double](repeating: 0, count: n), gy = [Double](repeating: 0, count: n), gz = [Double](repeating: 0, count: n)
        for mm in motion {
            let i = Int(mm.minuteStartUnix / 60 - m0)
            if i < 0 || i >= n { continue }
            hasMotion[i] = true
            moveSecs[i] = max(mm.seconds - mm.stillSecs, 0)
            steps[i] = mm.steps
            gx[i] = Double(mm.gravX); gy[i] = Double(mm.gravY); gz[i] = Double(mm.gravZ)
        }
        if Double(hasMotion.filter { $0 }.count) < Double(n) * minMotionCoverage { return nil }
        var dg = [Double](repeating: 0, count: n)
        var prev = -1
        for i in 0..<n {
            if !hasMotion[i] { continue }
            if prev >= 0 {
                let dx = gx[i] - gx[prev], dy = gy[i] - gy[prev], dz = gz[i] - gz[prev]
                dg[i] = (dx * dx + dy * dy + dz * dz).squareRoot()
            }
            prev = i
        }

        // ---- 1) Despertares ----
        var base = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var w = [Double]()
            for j in max(0, i - 20)...min(n - 1, i + 20) { w.append(hrm[j]) }
            w.sort()
            base[i] = w[w.count / 3]
        }
        var sp = [Double](repeating: 0, count: n)
        for i in 0..<n { sp[i] = hrm[i] - base[i] }
        var ar = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let mv = moveSecs[i]
            let a = (mv >= wakeMoveSecs || steps[i] > 0) && sp[i] >= wakeSpike
            let b = mv >= wakeBigMoveSecs
            let c = sp[i] >= wakeSpikeHigh && (mv >= 3 || dg[i] >= 0.8)
            ar[i] = a || b || c
        }
        var eps = [[Int]]()
        var ii = 0
        while ii < n {
            if ar[ii] {
                var j = ii
                var last = ii
                while j < n && j - last <= wakeGap {
                    if ar[j] { last = j }
                    j += 1
                }
                let s = max(0, ii - 1)
                var e = last
                var k = e + 1
                var t = 0
                while k < n && t < wakeTail && sp[k] >= wakeSpike { e = k; k += 1; t += 1 }
                eps.append([s, e])
                ii = last + 1
            } else {
                ii += 1
            }
        }
        var merged = [[Int]]()
        for ep in eps {
            if var lastEp = merged.last, ep[0] <= lastEp[1] + 1 {
                lastEp[1] = max(lastEp[1], ep[1])
                merged[merged.count - 1] = lastEp
            } else {
                merged.append(ep)
            }
        }
        var aw = [Bool](repeating: false, count: n)
        for ep in merged {
            let len = ep[1] - ep[0] + 1
            var peak = 0.0
            for k in ep[0]...ep[1] where sp[k] > peak { peak = sp[k] }
            if len >= wakeMinMinutes || peak >= wakeMinSpike {
                for k in ep[0]...ep[1] { aw[k] = true }
            }
        }

        // ---- 2) Señales de pulso y VFC ----
        let hrs = rollMedian(hrm, 5)
        var sumSq = [Double](repeating: 0, count: n)
        var cnt = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let x = rrLists[i]
            if x.count < 2 { continue }
            for k in 0..<(x.count - 1) {
                let a = x[k], b = x[k + 1]
                if abs(b - a) < 0.2 * a && a > 300 && a < 2000 { sumSq[i] += (b - a) * (b - a); cnt[i] += 1 }
            }
        }
        var lrmRaw = [Double](repeating: Double.nan, count: n)
        var validL = 0
        for i in 0..<n {
            var s = 0.0
            var c = 0
            for j in max(0, i - 3)...min(n - 1, i + 3) { s += sumSq[j]; c += cnt[j] }
            if c >= 40 { lrmRaw[i] = log((s / Double(c)).squareRoot()); validL += 1 }
        }
        if Double(validL) < Double(n) * 0.4 { return nil }
        let lrm = interp(lrmRaw)

        let awakeIdx = (0..<n).filter { !aw[$0] }
        if awakeIdx.isEmpty { return Result(startMinute: m0, stages: [Int](repeating: awake, count: n)) }
        let globalHr = median(awakeIdx.map { hrs[$0] })
        let globalLr = median(awakeIdx.map { lrm[$0] })
        var xh = [Double](repeating: 0, count: n)
        var xl = [Double](repeating: 0, count: n)
        let half = localWindow / 2
        for i in 0..<n {
            var hv = [Double]()
            var lv = [Double]()
            for k in max(0, i - half)..<min(n, i + half + 1) where !aw[k] { hv.append(hrs[k]); lv.append(lrm[k]) }
            let hl = hv.isEmpty ? globalHr : median(hv)
            let ll = lv.isEmpty ? globalLr : median(lv)
            xh[i] = hrs[i] - hl
            xl[i] = lrm[i] - ll
        }

        // ---- Clasificación ----
        var st = [Int](repeating: light, count: n)
        for i in 0..<n where aw[i] { st[i] = awake }
        for i in 0..<n {
            if aw[i] { continue }
            var near = false
            for j in max(0, i - 2)...min(n - 1, i + 2) where aw[j] { near = true; break }
            if near { continue }
            let prog = Double(i) / Double(max(1, n - 1))
            let deepThr = deepHrv + deepHrvSlope * (prog - 0.5)
            if xl[i] >= deepThr && xh[i] <= deepHr && i <= n - deepNoLastMin { st[i] = deep }
            else if xl[i] <= remHrv + remHrvSlope * (prog - 0.5) && xh[i] >= remHr && i >= remNoFirstMin { st[i] = rem }
        }
        // Tramos cortos de profundo/REM → ligero
        var i = 0
        while i < n {
            var j = i
            while j < n && st[j] == st[i] { j += 1 }
            if (st[i] == deep || st[i] == rem) && j - i < minRun { for k in i..<j { st[k] = light } }
            i = j
        }
        // Recorte: fuera el rato en la cama antes de dormirse y después de despertarse
        let (a, b) = trimBounds(st)
        return Result(startMinute: m0 + Int64(a), stages: Array(st[a..<b]))
    }

    /// [inicio, fin) de la noche: del primer tramo de ≥ onsetRun min sin despertar al último minuto dormido.
    static func trimBounds(_ st: [Int]) -> (Int, Int) {
        let n = st.count
        var start = -1
        var i = 0
        while i < n {
            if st[i] == awake { i += 1; continue }
            var j = i
            while j < n && st[j] != awake { j += 1 }
            if j - i >= onsetRun { start = i; break }
            i = j
        }
        if start < 0 { return (0, n) }
        var end = n
        while end > start && st[end - 1] == awake { end -= 1 }
        return (start, end)
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let n = s.count
        if n == 0 { return Double.nan }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    private static func interp(_ v: [Double]) -> [Double] {
        let n = v.count
        var out = v
        var idx = [Int]()
        for i in 0..<n where !v[i].isNaN { idx.append(i) }
        if idx.isEmpty { return out }
        var lo = -1
        var p = 0
        for i in 0..<n {
            if !v[i].isNaN { lo = i; continue }
            while p < idx.count && idx[p] < i { p += 1 }
            let hi = p < idx.count ? idx[p] : -1
            if lo < 0 {
                out[i] = v[hi]
            } else if hi < 0 {
                out[i] = v[lo]
            } else {
                out[i] = v[lo] + (v[hi] - v[lo]) * Double(i - lo) / Double(hi - lo)
            }
        }
        return out
    }

    private static func rollMedian(_ v: [Double], _ w: Int) -> [Double] {
        let h = w / 2
        var out = [Double](repeating: Double.nan, count: v.count)
        for i in 0..<v.count {
            var x = [Double]()
            for j in max(0, i - h)...min(v.count - 1, i + h) where !v[j].isNaN { x.append(v[j]) }
            out[i] = x.isEmpty ? Double.nan : median(x)
        }
        return out
    }
}
