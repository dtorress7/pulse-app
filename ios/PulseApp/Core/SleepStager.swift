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

    // Ronda grande 22/10 (igual que Android): ajustados con las 7 noches con movimiento y WHOOP.
    private static let localWindow = 61
    private static let deepHrv = -0.05
    private static let deepHrvSlope = 0.0
    private static let deepHr = -0.5
    private static let remHrv = -0.1
    private static let remHrvSlope = 0.3
    private static let remHr = -1.0
    private static let remNoFirstMin = 45
    private static let deepNoLastMin = 45
    private static let minRun = 4

    private static let minWindowMinutes = 90
    /// La noche empieza en el primer tramo de al menos estos minutos sin despertar (17/10).
    private static let onsetRun = 10   // 24/10: 15 → 10 (igual que Android)
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
    /// Inicio y fin de la noche por QUIETUD (21/10), igual que Android (SleepStager.motionBounds): minuto quieto = ≥50 s sin
    /// moverse, giro < 2,5 °/s y 0 pasos. Ancla = primer tramo quieto ≥15 min que llega a la ventana del pulso; inicio = hacia atrás
    /// saltando giros (≤5 min, ≤12 pasos) hasta el primer tramo ≥15 min; fin = último tramo ≥15 min que empieza antes del fin
    /// del pulso (si después hay movimiento grabado), alargado por ratos quietos separados por ≤2 min de giros (≤15 pasos).
    static func motionBounds(_ startMillis: Int64, _ endMillis: Int64, _ motion: [MotionMinute]) -> (Int64, Int64) {
        var byMin = [Int64: MotionMinute](minimumCapacity: motion.count)
        for mm in motion { byMin[mm.minuteStartUnix / 60] = mm }
        func still(_ m: MotionMinute?) -> Bool {
            guard let m = m else { return false }
            return m.stillSecs >= 50 && m.gyroDps < 2.5 && m.steps == 0
        }
        let m0 = startMillis / 60_000, m1 = endMillis / 60_000
        var runs = [(Int64, Int64)]()
        var k = m0 - 180
        while k <= m1 + 120 {
            if !still(byMin[k]) { k += 1; continue }
            let a = k
            var b = k, j = k + 1
            while j <= m1 + 120 {
                if still(byMin[j]) { b = j; j += 1 }
                else if still(byMin[j + 1]) { j += 1 }
                else { break }
            }
            runs.append((a, b)); k = b + 1
        }
        let long = runs.filter { $0.1 - $0.0 + 1 >= 15 }
        guard let anchor = long.first(where: { $0.1 >= m0 && $0.0 <= m1 }) else { return (startMillis, endMillis) }
        var onset = anchor.0
        var m = anchor.0 - 1
        while true {
            var b = m, steps = 0
            while let x = byMin[b], !still(x), m - b < 6 { steps += x.steps; b -= 1 }
            if byMin[b] == nil || m - b > 5 || steps > 12 { break }
            var q = b
            while still(byMin[q]) { q -= 1 }
            if b - q >= 10 { onset = q + 1 }   // 24/10: 15 → 10
            if b == q { break }
            m = q
        }
        var end = m1
        if let last = long.filter({ $0.0 >= onset && $0.0 <= m1 }).max(by: { $0.0 < $1.0 }), last.1 < m1 {
            var after = 0
            var t = last.1 + 1
            while t <= m1 { if byMin[t] != nil { after += 1 }; t += 1 }
            if after * 2 >= Int(m1 - last.1) {
                end = last.1
                while true {
                    var b = end + 1, steps = 0
                    while let x = byMin[b], !still(x), b - end <= 3 { steps += x.steps; b += 1 }
                    if b - end - 1 > 2 || steps > 40 || !still(byMin[b]) { break }   // 3/11: 15 → 40 pasos (levantarse 2 min y volver a dormir sigue siendo noche)
                    while still(byMin[b + 1]) { b += 1 }
                    end = b
                }
                end = min(end, m1)
            }
        }
        return (onset * 60_000, end * 60_000)
    }

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
        let (start, end) = motionBounds(startMillis, endMillis, allMotion)
        let lo = start / 60_000, hi = end / 60_000
        let motion = allMotion.filter { $0.minuteStartUnix / 60 >= lo && $0.minuteStartUnix / 60 <= hi }
        var computed: Result? = nil
        if !motion.isEmpty {
            let readings = hrLog.readings(from: start, to: end)
            computed = stage(startMillis: start, endMillis: end, readings: readings, motion: motion)
        }
        cacheLock.lock()
        cacheKey = key; cacheValue = computed
        cacheLock.unlock()
        return computed
    }

    /// Fases de una SIESTA (2/11, igual que Android `stageNap`): el mismo clasificador sobre la ventana de la siesta (mínimo 20 min) y sin
    /// REM en los primeros 60 min. Siesta del 1/11 15:51–17:35 → 2/74/22/0 (WHOOP 7/51/40/0).
    static func stageNap(hrLog: HrLog, motionFile: URL, startMillis: Int64, endMillis: Int64) -> Result? {
        if !FileManager.default.fileExists(atPath: motionFile.path) { return nil }
        let lo = startMillis / 60_000, hi = endMillis / 60_000
        let motion = MotionTracker.readMinutes(motionFile).filter { $0.minuteStartUnix / 60 >= lo && $0.minuteStartUnix / 60 <= hi }
        if motion.isEmpty { return nil }
        guard let r = stage(startMillis: startMillis, endMillis: endMillis, readings: hrLog.readings(from: startMillis, to: endMillis),
                            motion: motion, minWindow: 20) else { return nil }
        var st = r.stages
        for i in 0..<min(60, st.count) where st[i] == rem { st[i] = light }
        return Result(startMinute: r.startMinute, stages: st)
    }

    static func stage(startMillis: Int64, endMillis: Int64, readings: [HrReading], motion: [MotionMinute], minWindow: Int = minWindowMinutes) -> Result? {
        let m0 = startMillis / 60_000
        let m1 = endMillis / 60_000
        let n = Int(m1 - m0 + 1)
        if n < minWindow { return nil }

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
        var gyro = [Double](repeating: 0, count: n)
        for mm in motion {
            let i = Int(mm.minuteStartUnix / 60 - m0)
            if i < 0 || i >= n { continue }
            hasMotion[i] = true
            moveSecs[i] = max(mm.seconds - mm.stillSecs, 0)
            steps[i] = mm.steps
            gx[i] = Double(mm.gravX); gy[i] = Double(mm.gravY); gz[i] = Double(mm.gravZ)
            gyro[i] = Double("\(mm.gyroDps)") ?? Double(mm.gyroDps)
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

        // ---- Clasificación (23/10): modelo aprendido del hipnograma de WHOOP (igual que Android); despertares de las reglas ----
        var secs = [[SleepModel.Second]](repeating: [], count: n)
        for r in readings {
            let i = Int(r.timeMillis / 60_000 - m0)
            if i >= 0 && i < n { secs[i].append(SleepModel.Second(bpm: r.bpm, rr: r.rr)) }
        }
        var mot = [SleepModel.Minute?](repeating: nil, count: n)
        for mm in motion {
            let i = Int(mm.minuteStartUnix / 60 - m0)
            if i >= 0 && i < n {
                mot[i] = SleepModel.Minute(still: Double(mm.stillSecs), gyro: Double("\(mm.gyroDps)") ?? Double(mm.gyroDps), steps: Double(mm.steps))
            }
        }
        if var ms = SleepModel.classify(secs, mot) {
            for k in 0..<n { ms[k] = aw[k] ? awake : (ms[k] == awake ? light : ms[k]) }
            let (a0, b0) = trimBounds(ms, hr: hrm, gyro: gyro, steps: steps, off: 0)
            // 5/11 (igual que Android): segunda pasada SOLO sobre la noche recortada. El "progreso" de la noche del modelo depende de la
            // ventana, que crecía por la mañana: 5/11 a las 8:00 VFC 94,0 / recuperación 69 y a las 8:15 93,1 / 67.
            if b0 - a0 >= minWindow, a0 < b0, var ms2 = SleepModel.classify(Array(secs[a0..<b0]), Array(mot[a0..<b0])) {
                for k in 0..<ms2.count { ms2[k] = aw[a0 + k] ? awake : (ms2[k] == awake ? light : ms2[k]) }
                let (a1, b1) = trimBounds(ms2, hr: hrm, gyro: gyro, steps: steps, off: a0, keepStart: true)
                if b1 > a1 { return Result(startMinute: m0 + Int64(a0 + a1), stages: Array(ms2[a1..<b1])) }
            }
            return Result(startMinute: m0 + Int64(a0), stages: Array(ms[a0..<b0]))
        }
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
        let (a, b) = trimBounds(st, hr: hrm, gyro: gyro, steps: steps, off: 0)
        return Result(startMinute: m0 + Int64(a), stages: Array(st[a..<b]))
    }

    /// [inicio, fin) de la noche: del primer tramo de ≥ onsetRun min sin despertar al último minuto dormido.
    static func trimBounds(_ st: [Int], hr: [Double]? = nil, gyro: [Double]? = nil, steps: [Int]? = nil, off: Int = 0,
                           keepStart: Bool = false) -> (Int, Int) {
        let n = st.count
        var start = -1
        var i = 0
        // 7/11 (igual que Android): en la 2.ª pasada el inicio ya está decidido; un despertar corto justo después no lo retrasa
        if keepStart { start = (0..<n).first { st[$0] != awake } ?? -1; i = n }
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
        // 1/11 (igual que Android): un despertar de ≥ 5 min seguido de < 30 min "dormido" al final = remolonear despierto:
        // la noche acaba en ese despertar (31/10→1/11: 10:37 → 10:11, WHOOP 10:12). Las otras 15 noches no cambian.
        while true {
            var s = end
            while s > start && st[s - 1] != awake { s -= 1 }
            if s <= start { break }
            var a = s
            while a > start && st[a - 1] == awake { a -= 1 }
            if a > start && end - s < finalDozeMax && s - a >= finalWakeMin { end = a } else { break }
        }
        guard let hr = hr, let gyro = gyro, let steps = steps else { return (start, end) }
        // 7/11 (igual que Android): tumbado despierto en la cama antes de dormirse (giros pequeños de muñeca ≥ 15 % de los minutos)
        // seguido de un despertar ≥ 5 min en los primeros 40 min → la noche empieza después (23:02 → 23:40, WHOOP 23:39).
        if !keepStart {
            var j = start
            while j < end && st[j] != awake { j += 1 }
            if j < end && j - start < onsetPreMax {
                var k = j
                while k < end && st[k] == awake { k += 1 }
                let fid = (start..<j).filter { gyro[off + $0] >= fidgetGyro }.count
                if k - j >= onsetWakeMin && k < end && Double(fid) >= onsetFidget * Double(j - start) { start = k }
            }
        }
        // 7/11 (igual que Android): despierto y quieto en la cama al final (con el móvil): el pulso se queda ≥ 7 lpm por encima de la
        // media hora de antes desde un giro/paso/despertar hasta el final (≥ 10 min) → la noche acaba ahí (09:48 → 09:17, WHOOP 09:19).
        let lo = max(start + endBefore, end - endLook), hi = end - endHrMin - 1
        if lo <= hi {
            for t in lo...hi {
                let ev = gyro[off + t] >= endEventGyro || steps[off + t] > 0 || st[t] == awake
                if !ev { continue }
                let after = ((t + 1)..<end).map { hr[off + $0] }.filter { !$0.isNaN }
                let before = ((t - endBefore)..<t).map { hr[off + $0] }.filter { !$0.isNaN }
                if after.count < endHrMin || before.count < 10 { continue }
                if median(after) >= median(before) + endHrRise {
                    // 7/11: los giros (≥ 3 °/s) de los 3 min siguientes son aún el despertar: acaba en el último (WHOOP 09:19)
                    var t2 = t
                    let top = min(t + endCluster, end - 1)
                    if t + 1 <= top { for u in (t + 1)...top where gyro[off + u] >= fidgetGyro || steps[off + u] > 0 { t2 = u } }
                    end = t2 + 1; break
                }
            }
        }
        // 9/11: despierto tumbado (sofá/cama) DESPUÉS de levantarse: 8/11 10:15–13:16 giros ≥ 3 °/s en el 48 % de los minutos y la
        // noche se alargaba hasta las 13:16 (WHOOP 09:53). Dormido, en 24 noches, ningún tramo de 45 min pasa del 24 %. Si desde un
        // minuto inquieto hasta el final (≥ 45 min) y sus primeros 45 min tienen ≥ 40 % de minutos inquietos, la noche acaba antes.
        if end > start {
            var cnt = 0, tot = 0, cut = -1
            var fid = [Int](repeating: 0, count: end - start + 1), has = [Int](repeating: 0, count: end - start + 1)
            for t in stride(from: end - 1, through: start, by: -1) {
                let g = gyro[off + t]
                let k = t - start
                has[k] = has[k + 1] + (g > 0 ? 1 : 0); fid[k] = fid[k + 1] + (g >= fidgetGyro ? 1 : 0)
                if g > 0 { tot += 1; if g >= fidgetGyro { cnt += 1 } }
                if g < fidgetGyro || end - t < endRestlessMin { continue }
                let k2 = k + endRestlessMin
                let wt = has[k] - has[k2], wf = fid[k] - fid[k2]
                if tot >= endRestlessMin / 2 && Double(cnt) >= endRestlessFrac * Double(tot)
                    && wt >= endRestlessMin / 2 && Double(wf) >= endRestlessFrac * Double(wt) { cut = t }
            }
            if cut > start {
                var e = cut
                while e > start && st[e - 1] == awake { e -= 1 }
                end = e
            }
        }
        return (start, end)
    }

    private static let endRestlessMin = 45
    private static let endRestlessFrac = 0.40
    private static let onsetPreMax = 40
    private static let onsetWakeMin = 5
    private static let onsetFidget = 0.15
    private static let fidgetGyro = 3.0
    private static let endBefore = 30
    private static let endLook = 120
    private static let endHrMin = 10
    private static let endHrRise = 7.0
    private static let endEventGyro = 6.0
    private static let endCluster = 3

    private static let finalWakeMin = 5
    private static let finalDozeMax = 30

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

/// Fases minuto a minuto de cada noche guardada (25/10): para pintar en Sueño dónde cae cada fase en días pasados.
/// sleep_stages.csv: "fecha,minuto de inicio (unix/60),fases" con una cifra por minuto (0 despierto, 1 ligero, 2 profundo, 3 REM).
enum SleepStagesStore {
    private static let lock = NSLock()
    static var url: URL { return AppPaths.file("sleep_stages.csv") }

    static func save(_ date: String, _ r: SleepStager.Result) {
        lock.lock(); defer { lock.unlock() }
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.removeAll { $0.hasPrefix(date + ",") }
        lines.append(date + "," + String(r.startMinute) + "," + r.stages.map { String($0) }.joined())
        lines.sort()
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func load(_ date: String) -> SleepStager.Result? {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix(date + ",") {
            let p = line.split(separator: ",")
            guard p.count == 3, let start = Int64(p[1]) else { return nil }
            let st = p[2].compactMap { $0.wholeNumberValue }.filter { $0 >= 0 && $0 <= 3 }
            return st.isEmpty ? nil : SleepStager.Result(startMinute: start, stages: st)
        }
        return nil
    }
}
