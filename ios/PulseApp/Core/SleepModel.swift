import Foundation

/// Fases del sueño aprendidas del hipnograma de WHOOP (23/10, port 1:1 de SleepModel.kt).
/// 8 noches leídas minuto a minuto de las capturas de WHOOP; dejando cada noche fuera, 81 % de los minutos en la misma fase
/// (las reglas de antes: 49 %). 17 rasgos por minuto → árboles (sleep_model.json) → Viterbi. Orden de fases D, L, P, R
/// = SleepStager.awake/light/deep/rem.
enum SleepModel {

    struct Second { let bpm: Int; let rr: [Double] }
    struct Minute { let still: Double; let gyro: Double; let steps: Double }

    private struct Tree: Decodable { let f: [Int]; let t: [Double]; let l: [Int]; let r: [Int]; let v: [Double] }
    private struct Model: Decodable { let baseline: [Double]; let bias: [Double]; let stay: Double; let trees: [Tree]; let roll: [Int]? }

    /// Archivo del modelo (se puede cambiar antes del primer uso, p. ej. en la comprobación de CI).
    static var modelURL: URL? = Bundle.main.url(forResource: "sleep_model", withExtension: "json")

    private static let model: Model? = {
        guard let url = modelURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Model.self, from: data)
    }()

    final class RawBox { var v: [Double]? = nil; init() {} }

    /// 24/11 (igual que Android): corrección personal del reparto [ligero, profundo, REM] (StagePrior); nil = sin corrección.
    static var personalShift: [Double]? = nil

    /// Fases de cada minuto. `raw` recibe la fracción de ligero/profundo/REM del modelo SIN corregir. Con `shift` se buscan los sesgos
    /// de ligero/profundo/REM que llevan el total de la noche a (fracción del modelo + shift) y se colocan las fases con ellos.
    static func classify(_ secs: [[Second]], _ mot: [Minute?], raw: RawBox? = nil, shift: [Double]? = personalShift) -> [Int]? {
        guard let m = model else { return nil }
        let x = features(secs, mot, roll: m.roll ?? [])
        let n = x.count
        if n == 0 { return nil }
        let k = 4
        var emis = [[Double]](repeating: [Double](repeating: 0, count: k), count: n)
        for i in 0..<n {
            var raw0 = m.baseline
            for (idx, t) in m.trees.enumerated() {
                var node = 0
                while t.f[node] >= 0 { node = x[i][t.f[node]] <= t.t[node] ? t.l[node] : t.r[node] }
                raw0[idx % k] += t.v[node]
            }
            let mx = raw0.max() ?? 0
            let p = (0..<k).map { exp(raw0[$0] - mx + m.bias[$0]) }
            let s = p.reduce(0, +)
            for c in 0..<k { emis[i][c] = log(p[c] / s + 1e-9) }
        }
        var add = [Double](repeating: 0, count: k)
        var st = viterbi(emis, add, m.stay)
        guard let f0 = sleepFractions(st) else { return st }
        raw?.v = f0
        guard let shift = shift else { return st }
        var target = (0..<3).map { max(shiftMinFrac, f0[$0] + shift[$0]) }
        let ts = target.reduce(0, +); for c in 0..<3 { target[c] /= ts }
        var best = st, bestErr = fracError(f0, target)
        var cur = f0
        for _ in 0..<shiftIter {
            if bestErr < 0.01 { return best }
            for c in 0..<3 { add[c + 1] += shiftStep * log(target[c] / max(cur[c], 0.005)) }
            st = viterbi(emis, add, m.stay)
            guard let f = sleepFractions(st) else { return best }
            cur = f
            let e = fracError(cur, target)
            if e < bestErr { bestErr = e; best = st }
        }
        return best
    }

    private static let shiftMinFrac = 0.02
    private static let shiftIter = 25
    private static let shiftStep = 0.7

    private static func sleepFractions(_ st: [Int]) -> [Double]? {
        var c = [0, 0, 0, 0]; for v in st { c[v] += 1 }
        let t = c[1] + c[2] + c[3]
        if t < 30 { return nil }
        return [Double(c[1]) / Double(t), Double(c[2]) / Double(t), Double(c[3]) / Double(t)]
    }

    private static func fracError(_ a: [Double], _ b: [Double]) -> Double { abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]) }

    private static func viterbi(_ emis: [[Double]], _ add: [Double], _ stay: Double) -> [Int] {
        let n = emis.count, k = 4
        let stayL = log(stay), moveL = log((1 - stay) / Double(k - 1))
        var d = (0..<k).map { emis[0][$0] + add[$0] }
        var back = [[Int]](repeating: [Int](repeating: 0, count: k), count: n)
        if n > 1 {
            for i in 1..<n {
                var nd = [Double](repeating: 0, count: k)
                for c in 0..<k {
                    var best = -Double.infinity, arg = 0
                    for p in 0..<k {
                        let v = d[p] + (p == c ? stayL : moveL)
                        if v > best { best = v; arg = p }
                    }
                    nd[c] = best + emis[i][c] + add[c]; back[i][c] = arg
                }
                d = nd
            }
        }
        var st = [Int](repeating: 0, count: n)
        var bestC = 0
        for c in 1..<k where d[c] > d[bestC] { bestC = c }
        st[n - 1] = bestC
        if n > 1 { for i in stride(from: n - 1, through: 1, by: -1) { st[i - 1] = back[i][st[i]] } }
        return st
    }

    // MARK: - Rasgos (idénticos a Kotlin / entrenamiento)

    private static func nanMedian(_ a: [Double], _ from: Int, _ to: Int) -> Double {
        var v = [Double]()
        for j in from...to where !a[j].isNaN { v.append(a[j]) }
        if v.isEmpty { return .nan }
        v.sort(); let h = v.count / 2
        return v.count % 2 == 1 ? v[h] : (v[h - 1] + v[h]) / 2
    }

    private static func nanStd(_ a: [Double], _ from: Int, _ to: Int) -> Double {
        var s = 0.0, c = 0
        for j in from...to where !a[j].isNaN { s += a[j]; c += 1 }
        if c == 0 { return .nan }
        let m = s / Double(c); var q = 0.0
        for j in from...to where !a[j].isNaN { q += (a[j] - m) * (a[j] - m) }
        return (q / Double(c)).squareRoot()
    }

    private static func nanPercentile(_ a: [Double], _ p: Double) -> Double {
        let v = a.filter { !$0.isNaN }.sorted()
        if v.isEmpty { return .nan }
        let pos = p / 100.0 * Double(v.count - 1)
        let lo = Int(pos), hi = min(lo + 1, v.count - 1)
        return v[lo] + (v[hi] - v[lo]) * (pos - Double(lo))
    }

    private static func rmssdLn(_ rr: [Double]) -> Double {
        var out = [Double](); out.reserveCapacity(rr.count)
        for x in rr {
            if let last = out.last, abs(x - last) / last > 0.2 { continue }
            out.append(x)
        }
        if out.count < 20 { return .nan }
        var s = 0.0
        for i in 1..<out.count { let dd = out[i] - out[i - 1]; s += dd * dd }
        return log((s / Double(out.count - 1)).squareRoot())
    }

    private static func mn(_ a: Double, _ b: Double) -> Double { return a.isNaN || b.isNaN ? .nan : min(a, b) }

    /// [roll] (19/11, igual que Android): además de los 17 rasgos, la media de cada uno en ±w minutos para cada w.
    static func features(_ secs: [[Second]], _ mot: [Minute?], roll: [Int] = []) -> [[Double]] {
        let n = secs.count
        func lo(_ i: Int, _ k: Int) -> Int { return max(0, i - k) }
        func hi(_ i: Int, _ k: Int) -> Int { return min(n - 1, i + k) }
        let hr: [Double] = (0..<n).map { i in secs[i].isEmpty ? .nan : Double(secs[i].reduce(0) { $0 + $1.bpm }) / Double(secs[i].count) }
        let hr5 = (0..<n).map { nanMedian(hr, lo($0, 2), hi($0, 2)) }
        let lnr: [Double] = (0..<n).map { i in
            var rr = [Double]()
            for j in lo(i, 3)...hi(i, 3) { for s in secs[j] { rr.append(contentsOf: s.rr) } }
            return rmssdLn(rr)
        }
        let hsd: [Double] = (0..<n).map { i in
            var v = [Double]()
            for j in lo(i, 2)...hi(i, 2) { for s in secs[j] { v.append(Double(s.bpm)) } }
            if v.count <= 30 { return .nan }
            let m = v.reduce(0, +) / Double(v.count)
            return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
        }
        func locmed(_ a: [Double], _ k: Int) -> [Double] { return (0..<n).map { nanMedian(a, lo($0, k), hi($0, k)) } }
        let med30h = locmed(hr5, 30), med10h = locmed(hr5, 10), med90h = locmed(hr5, 90)
        let med30l = locmed(lnr, 30), med90l = locmed(lnr, 90)
        let still = (0..<n).map { mot[$0]?.still ?? .nan }
        let gyro = (0..<n).map { mot[$0]?.gyro ?? .nan }
        let steps = (0..<n).map { mot[$0]?.steps ?? .nan }
        var since = [Double](repeating: 0, count: n)
        var last = -999
        for i in 0..<n {
            if !(still[i] >= 50 && gyro[i] < 3) { last = i }
            since[i] = Double(i - last)
        }
        let hsd10 = (0..<n).map { nanStd(hr, lo($0, 5), hi($0, 5)) }
        let gmax5: [Double] = (0..<n).map { i in
            var mx = Double.nan
            for j in lo(i, 5)...hi(i, 5) where !gyro[j].isNaN && (mx.isNaN || gyro[j] > mx) { mx = gyro[j] }
            return mx
        }
        let p10 = nanPercentile(hr5, 10)
        let lnrMed = nanMedian(lnr, 0, n - 1)
        let base: [[Double]] = (0..<n).map { i in
            let prog = Double(i) / Double(n)
            var row: [Double] = [
                hr5[i] - med30h[i], lnr[i] - med30l[i], log(1 + hsd[i]), log(1 + min(since[i], 240)), prog, prog * prog,
                log(1 + gyro[i]), still[i] / 60, mn(steps[i], 20), hr5[i] - p10, lnr[i] - lnrMed,
                log(1 + hsd10[i]), hr5[i] - med10h[i], hr5[i] - med90h[i], lnr[i] - med90l[i], min(Double(i), 300) / 300, log(1 + gmax5[i])]
            for c in row.indices where row[c].isNaN { row[c] = 0 }
            return row
        }
        if roll.isEmpty { return base }
        let k = base.first?.count ?? 17
        return (0..<n).map { i in
            var out = base[i]
            for w in roll {
                let a = lo(i, w), b = hi(i, w)
                for c in 0..<k {
                    var sum = 0.0
                    for j in a...b { sum += base[j][c] }
                    out.append(sum / Double(b - a + 1))
                }
            }
            return out
        }
    }
}
