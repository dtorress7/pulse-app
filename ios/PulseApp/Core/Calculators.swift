import Foundation

// MARK: - Línea base personal

/// Media y variación normal de tus últimas noches (hasta 30 días, solo noches con ≥ 3 h dormido).
/// La VFC se trabaja en logaritmo (ln RMSSD); la media es ponderada exponencialmente (span 14 días, como WHOOP).
enum BaselineProvider {
    static let minDaysRequired = 3
    static let lookbackDays = 30
    private static let ewmaAlpha = 2.0 / (14.0 + 1.0)
    private static let minLnHrvSd = 0.08
    private static let minRhrSd = 1.5
    private static let minRespSd = 0.4

    /// VFC y respiración solo de noches calculadas con el método del 17/10 (VFC del sueño profundo, respiración espectral),
    /// igual que Android: las anteriores tienen otra escala y desplazarían tu media.
    /// 23/10: las noches guardadas se recalculan con la VFC nueva (DailyMetricsUpdater.recalcPastNightsOnce): cuentan desde el 15/10.
    static let newMethodSince = "2026-10-15"

    /// VFC/respiración de ese día en la escala de WHOOP: método nuevo o importada de WHOOP (23/10).
    static func sameScale(_ date: String) -> Bool { return date >= newMethodSince || date <= WhoopImport.importedUntil() }

    static func compute(store: AppStore) -> PersonalBaseline? {
        return computeFrom(store.lastDays(lookbackDays))
    }

    /// Línea base con los días que se le pasan (de más reciente a más antiguo, como lastDays).
    /// Para un día pasado D se le pasan los días anteriores a D: así su recuperación sale igual que la habría dado ese día.
    static func computeFrom(_ lastDaysNewestFirst: [DailyMetrics]) -> PersonalBaseline? {
        let days = Array(lastDaysNewestFirst.prefix(lookbackDays)).filter { ($0.sleepMinutes ?? 0) >= 180 }
        let newMethod = days.filter { sameScale($0.date) }
        let validHrv = newMethod.compactMap { d -> Double? in
            if let v = d.avgHrv, v > 0 { return v }
            return nil
        }
        let validRhr = days.compactMap { d -> Double? in
            if let v = d.restingHr { return Double(v) }
            return nil
        }
        let validResp = newMethod.compactMap { d -> Double? in
            if let r = d.respiratoryRate, r >= 8.0, r <= 25.0 { return r }
            return nil
        }
        if validHrv.isEmpty || validRhr.isEmpty { return nil }
        // lastDays viene de más reciente a más antiguo: se invierte para la media ponderada.
        // 14/11: la media parte de la MEDIANA de las noches de la ventana (de cada persona), igual que Android.
        // Antes partía de 88 ms / 58,5 lpm (el primer usuario): a otra persona sin export importado le daba rojo semanas.
        let lnHrv = validHrv.map { log($0) }
        let lnEwma = ewma(Array(lnHrv.reversed()), prior: median(lnHrv))
        let respOk = validResp.count >= minDaysRequired
        return PersonalBaseline(
            avgHrv: exp(lnEwma),
            avgRestingHr: ewma(Array(validRhr.reversed()), prior: median(validRhr)),
            daysUsed: min(validHrv.count, validRhr.count),
            lnHrvMean: lnEwma,
            lnHrvSd: max(sd(lnHrv), minLnHrvSd),
            rhrSd: max(sd(validRhr), minRhrSd),
            respMean: respOk ? validResp.reduce(0, +) / Double(validResp.count) : nil,
            respSd: respOk ? max(sd(validResp), minRespSd) : nil,
            lnHrvMean30: lnHrv.count >= 7 ? lnHrv.reduce(0, +) / Double(lnHrv.count) : nil,
            stressHrv: { let v = Array(validHrv.prefix(stressNights)); return v.reduce(0, +) / Double(v.count) }(),
            stressRhr: { let v = Array(validRhr.prefix(stressNights)); return v.reduce(0, +) / Double(v.count) }())
    }
    /// Noches de la referencia del estrés (media simple, 23/11, igual que Android).
    static let stressNights = 14

    private static func ewma(_ oldestFirst: [Double], prior: Double) -> Double {
        var m = prior
        for v in oldestFirst { m += ewmaAlpha * (v - m) }
        return m
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    private static func sd(_ values: [Double]) -> Double {
        if values.count < 2 { return 0 }
        let m = values.reduce(0, +) / Double(values.count)
        var s = 0.0
        for v in values { s += (v - m) * (v - m) }
        return (s / Double(values.count - 1)).squareRoot()
    }
}

// MARK: - Recuperación

struct RecoveryBreakdown {
    let total: Int
    let hrvDeltaPct: Double?
    let rhrDelta: Double?
    let respPenalty: Bool
    let personalBaseline: Bool
}

enum RecoveryCalculator {
    static func breakdown(nightlyHrv: Double?, restingHr: Int?, baseline: PersonalBaseline?,
                          respiratoryRate: Double? = nil, sleepScore: Int? = nil, asleepMinutes: Int? = nil) -> RecoveryBreakdown {
        let r = Formulas.recovery(hrv: nightlyHrv, restingHr: restingHr, respiratoryRate: respiratoryRate, baseline: baseline,
                                  sleepScore: sleepScore, asleepMinutes: asleepMinutes)
        return RecoveryBreakdown(total: r.total, hrvDeltaPct: r.hrvDeltaPct, rhrDelta: r.rhrDelta,
                                 respPenalty: r.respPenalty, personalBaseline: r.usedPersonalBaseline)
    }
}

// MARK: - Calorías

/// Gasto calórico: metabolismo basal (Mifflin-St Jeor) proporcional al tiempo transcurrido
/// + calorías de las actividades guardadas (por zonas) sumadas aparte.
enum CalorieCalculator {
    static func basalMetabolicRate(ageYears: Int, weightKg: Double, heightCm: Double, sex: String) -> Double {
        if sex == "M" { return 10 * weightKg + 6.25 * heightCm - 5 * Double(ageYears) + 5 }
        return 10 * weightKg + 6.25 * heightCm - 5 * Double(ageYears) - 161
    }

    /// Calorías de una actividad concreta (Keytel).
    static func exerciseCalories(avgHr: Double, durationMinutes: Double, ageYears: Int, weightKg: Double, sex: String) -> Double {
        if durationMinutes <= 0 { return 0 }
        let age = Double(ageYears)
        let perMin: Double
        if sex == "M" {
            perMin = (-55.0969 + (0.6309 * avgHr) + (0.1988 * weightKg) + (0.2017 * age)) / 4.184
        } else {
            perMin = (-20.4022 + (0.4472 * avgHr) - (0.1263 * weightKg) + (0.074 * age)) / 4.184
        }
        return max(perMin, 0.0) * durationMinutes
    }

    static func estimateDailyTotal(elapsedMinutesToday: Double, activityKcalToday: Double,
                                   ageYears: Int, weightKg: Double, heightCm: Double, sex: String,
                                   activityMinutesToday: Double = 0, restKcalPerDay: Double? = nil) -> Double {
        // 30/10 (igual que Android): fuera de las actividades WHOOP gasta un ritmo FIJO (tu caso 1706 kcal/24 h) y durante una
        // actividad cuenta SOLO las calorías de la actividad. Antes el tiempo de deporte contaba dos veces (29/10: +103 kcal).
        let rate = restKcalPerDay ?? basalMetabolicRate(ageYears: ageYears, weightKg: weightKg, heightCm: heightCm, sex: sex)
        let restMinutes = max(0, elapsedMinutesToday - activityMinutesToday)
        return rate * (restMinutes / (24 * 60)) + activityKcalToday
    }
}

// MARK: - Respiración

/// Frecuencia respiratoria (rpm) desde los RR de la noche (arritmia sinusal respiratoria): media móvil de 5,
/// picos locales = ciclos, distancia media entre picos. Aproximación práctica (aparcada en Android también).
/// Frecuencia respiratoria por la arritmia sinusal respiratoria, método espectral (17/10, igual que Android):
/// tramos de 2 min de latidos → RR remuestreado a 4 Hz, sin media ni tendencia, ventana de Hann → frecuencia con
/// más energía entre 0,1 y 0,5 Hz. Mediana de los tramos (≥10). Antes daba 8 rpm frente a 13,1 de WHOOP.
enum RespiratoryRateCalculator {
    private static let segmentSeconds = 120.0
    private static let fs = 4.0

    /// 24/11 (igual que Android): si faltan latidos (< 90 % del tiempo cubierto por RR, historial de la pulsera de Nico o Pablo) el
    /// método de siempre juntaba latidos no seguidos y salía 0 u 8 rpm (WHOOP 12,8 / 17,3) → `estimateSparse`.
    static func estimate(_ readings: [HrReading]) -> Double? {
        let items: [(Int64, [Double])] = readings.map { ($0.timeMillis, $0.rr.filter { $0 >= 300 && $0 <= 2000 }) }
        if NightMetrics.coverage(items) < NightMetrics.fullCoverage { return estimateSparse(items) }
        let rr = items.flatMap { $0.1 }
        if rr.count < 200 { return nil }
        var estimates = [Double]()
        var i = 0
        let n = rr.count
        while i < n {
            var j = i
            var acc = 0.0
            while j < n && acc < segmentSeconds { acc += rr[j] / 1000.0; j += 1 }
            if acc < segmentSeconds * 0.9 { break }
            if let r = segmentRate(Array(rr[i..<j])) { estimates.append(r) }
            i = j
        }
        if estimates.count < 10 { return nil }
        let med = median(estimates)
        return (med >= 8.0 && med <= 25.0) ? med : nil
    }

    private static func median(_ v: [Double]) -> Double {
        let e = v.sorted(); let m = e.count
        return m % 2 == 1 ? e[m / 2] : (e[m / 2 - 1] + e[m / 2]) / 2.0
    }

    /// Con latidos perdidos: cada RR en su hora (la de la lectura; varios RR de una lectura, hacia atrás), tramos de 2 min (≥ 30 latidos,
    /// sin huecos > 8 s, artefactos > 20 % fuera, sin tendencia) → periodograma de Lomb-Scargle 0,1–0,5 Hz; mediana de ≥ 10 tramos.
    /// Nico 23/11 11,7 (WHOOP 12,8), Pablo 17,4/18,0/17,4 (17,3/17,4/17,5).
    static func estimateSparse(_ items: [(Int64, [Double])]) -> Double? {
        var beats = [(Double, Double)]()
        for (t, rr) in items {
            var acc = 0.0
            for k in rr.indices.reversed() { beats.append(((Double(t) + 500 - acc) / 1000.0, rr[k])); acc += rr[k] }
        }
        beats.sort { $0.0 < $1.0 }
        var t = [Double](), y = [Double]()
        for (tt, r) in beats {
            if let last = y.last, abs(r - last) > 0.2 * last { continue }
            t.append(tt); y.append(r)
        }
        if t.count < 200 { return nil }
        var estimates = [Double]()
        var w0 = t[0], a = 0
        while w0 < t[t.count - 1] {
            while a < t.count && t[a] < w0 { a += 1 }
            var b = a
            while b < t.count && t[b] < w0 + segmentSeconds { b += 1 }
            w0 += segmentSeconds
            if b - a < sparseMinBeats { continue }
            var maxGap = 0.0
            if b - a > 1 { for k in (a + 1)..<b { maxGap = max(maxGap, t[k] - t[k - 1]) } }
            if maxGap > sparseMaxGapS { continue }
            if let r = lombRate(Array(t[a..<b]), Array(y[a..<b])) { estimates.append(r) }
        }
        if estimates.count < 10 { return nil }
        let med = median(estimates)
        return (med >= 8.0 && med <= 25.0) ? med : nil
    }

    private static let sparseMinBeats = 30
    private static let sparseMaxGapS = 8.0

    private static func lombRate(_ t: [Double], _ y0: [Double]) -> Double? {
        let n = t.count
        let tm = t.reduce(0, +) / Double(n), ym = y0.reduce(0, +) / Double(n)
        var num = 0.0, den = 0.0
        for k in 0..<n { num += (t[k] - tm) * (y0[k] - ym); den += (t[k] - tm) * (t[k] - tm) }
        let slope = den > 0 ? num / den : 0
        var y = (0..<n).map { y0[$0] - ym - slope * (t[$0] - tm) }
        let yMean = y.reduce(0, +) / Double(n)
        for k in 0..<n { y[k] -= yMean }
        var bestF = 0.0, bestP = -1.0
        var step = 0
        while true {
            let f = 0.1 + Double(step) * 0.005
            if f > 0.5 + 1e-9 { break }
            let w = 2 * Double.pi * f
            var s2 = 0.0, c2 = 0.0
            for k in 0..<n { s2 += sin(2 * w * t[k]); c2 += cos(2 * w * t[k]) }
            let tau = atan2(s2, c2) / (2 * w)
            var yc = 0.0, ys = 0.0, cc = 0.0, ss = 0.0
            for k in 0..<n {
                let c = cos(w * (t[k] - tau)), s = sin(w * (t[k] - tau))
                yc += y[k] * c; ys += y[k] * s; cc += c * c; ss += s * s
            }
            let pw = yc * yc / cc + ys * ys / ss
            if pw > bestP { bestP = pw; bestF = f }
            step += 1
        }
        return bestP > 0 ? bestF * 60.0 : nil
    }

    private static func segmentRate(_ seg: [Double]) -> Double? {
        var ok = [seg[0]]
        var bad = 0
        for k in 1..<seg.count {
            if abs(seg[k] - ok[ok.count - 1]) <= 0.2 * ok[ok.count - 1] { ok.append(seg[k]) } else { bad += 1 }
        }
        if Double(bad) > Double(seg.count) * 0.1 || ok.count < 4 { return nil }
        var t = [Double](repeating: 0, count: ok.count)
        var acc = 0.0
        for k in 0..<ok.count { acc += ok[k] / 1000.0; t[k] = acc }
        let m = Int((t[t.count - 1] - t[0]) * fs)
        if m < 64 { return nil }
        var y = [Double](repeating: 0, count: m)
        var p = 0
        for q in 0..<m {
            let tt = t[0] + Double(q) / fs
            while p < t.count - 2 && t[p + 1] < tt { p += 1 }
            let f = min(max((tt - t[p]) / (t[p + 1] - t[p]), 0.0), 1.0)
            y[q] = ok[p] + (ok[p + 1] - ok[p]) * f
        }
        let mean = y.reduce(0, +) / Double(m)
        let mx = Double(m - 1) / 2.0
        var num = 0.0, den = 0.0
        for q in 0..<m { num += (Double(q) - mx) * (y[q] - mean); den += (Double(q) - mx) * (Double(q) - mx) }
        let slope = num / den
        for q in 0..<m {
            y[q] = (y[q] - mean - slope * (Double(q) - mx)) * (0.5 - 0.5 * cos(2 * Double.pi * Double(q) / Double(m - 1)))
        }
        var bestF = 0.0, bestP = -1.0, total = 0.0
        var step = 0
        while true {
            let f = 0.1 + Double(step) * 0.005
            if f > 0.5 + 1e-9 { break }
            let w = 2 * Double.pi * f / fs
            var re = 0.0, im = 0.0
            for q in 0..<m { re += y[q] * cos(w * Double(q)); im += y[q] * sin(w * Double(q)) }
            let pw = re * re + im * im
            total += pw
            if pw > bestP { bestP = pw; bestF = f }
            step += 1
        }
        return (total > 0 && bestP / total > 0.05) ? bestF * 60.0 : nil
    }
}

/// VFC de la noche como WHOOP (17/10): con fases (≥20 min de profundo), media de los RMSSD de los tramos de
/// sueño profundo ponderada por su duración; si no, toda la ventana. Tus 2 noches: 87 / 104 ms (WHOOP 80 / 108)
/// frente a 70 / 87 de toda la noche.
/// VFC de la noche como WHOOP (24/10, igual que Android): media ponderada del RMSSD de los tramos de profundo (≥5 min) de las fases
/// del modelo → 7,9966 · p^0,55945 (error medio 1,5 ms con 10 noches). Sin fases o con <10 min de profundo: el método del 23/10
/// (tramos de 2 min de toda la noche → 0,07664 · m^1,6237).
enum NightMetrics {
    private static let windowMs: Int64 = 120_000
    private static let minRrPerWindow = 60
    private static let minWindows = 10
    static let hrvK = 0.0766391
    static let hrvExp = 1.6237416
    static let deepK = 7.9965785
    static let deepExp = 0.5594471

    /// 25/10: media de los dos métodos (profundo y toda la noche). 10 noches: error medio 2,6 → 1,8 ms, máx 11 → 5
    /// (noche tras el partido del 24/10: profundo 82, toda la noche 66, WHOOP 71; noche larga del 24: 94 / 100, WHOOP 92).
    static func hrv(_ readings: [HrReading], staged: SleepStager.Result?) -> Double? {
        if let st = staged, let v = stageHrv(readings, staged: st) { return v }
        return hrvOld(readings, staged: staged)
    }

    /// 1/11 (igual que Android): VFC = e^0,0819 · P^0,3808 · L^0,6030, P y L = media del RMSSD de los tramos de 2 min dentro del
    /// profundo y del ligero (filtro de artefactos 30 %). 16 noches de WHOOP dejando cada una fuera: 1,9 → 1,42 ms (máx 5,3 → 3,4).
    /// 4/11 (igual que Android): fuera los tramos de 2 min con el pulso medio > FC en reposo de la noche (mediana) + 12 (tras el fútbol
    /// el primer profundo iba a 72–77 lpm y hundía la VFC: 74,6 vs WHOOP 80,1). 19 noches dejando cada una fuera 1,76 → 1,45 ms.
    /// 24/11 (igual que Android): RMSSD solo con diferencias entre latidos SEGUIDOS. Con el historial de la pulsera con ~57 % de los
    /// latidos (Nico, Pablo) se restaban intervalos no seguidos y la VFC salía alta (Nico 23/11 63,6 vs WHOOP 54 → ahora 51,5).
    /// Una lectura sigue a la anterior si el tiempo entre las dos ≤ sus RR + 0,5 s. Con ≥ 90 % del tiempo cubierto (pulso en directo)
    /// se calcula como siempre.
    static let gapTolMs = 500.0
    static let fullCoverage = 0.9
    static func coverage(_ items: [(Int64, [Double])]) -> Double {
        let withRr = items.filter { !$0.1.isEmpty }
        guard withRr.count >= 2, let first = withRr.first, let last = withRr.last else { return 0 }
        let span = Double(last.0 - first.0) + first.1.reduce(0, +)
        let beats = withRr.reduce(0.0) { $0 + $1.1.reduce(0, +) }
        return span > 0 ? beats / span : 0
    }
    static func rmssdAdjacent(_ items: [(Int64, [Double])], maxJump: Double) -> Double? {
        if coverage(items) >= fullCoverage { return MetricsCalculator.computeRMSSD(items.flatMap { $0.1 }, maxJump: maxJump) }
        var prev: Double? = nil
        var prevT = Int64.min
        var sumSq = 0.0, n = 0
        for (t, rr) in items where !rr.isEmpty {
            let joins = prev != nil && Double(t - prevT) <= rr.reduce(0, +) + gapTolMs
            for (k, r) in rr.enumerated() {
                guard let p = prev, k > 0 || joins else { prev = r; continue }
                if abs(r - p) / p <= maxJump { let d = r - p; sumSq += d * d; n += 1; prev = r }
            }
            prevT = t
        }
        if n < 1 { return nil }
        return (sumSq / Double(n)).squareRoot()
    }

    static let stageHighHr = 12.0
    static let stageC = 0.03828059
    static let stageDeepExp = 0.38089473
    static let stageLightExp = 0.61171261
    static func stageHrv(_ readings: [HrReading], staged r: SleepStager.Result) -> Double? {
        let st = r.stages
        var deep = [Int64: [(Int64, [Double])]](), light = [Int64: [(Int64, [Double])]]()
        var hrSum = [Int64: Double](), hrN = [Int64: Int]()
        let sortedBpm = readings.map { $0.bpm }.sorted()
        guard !sortedBpm.isEmpty else { return nil }
        let n = sortedBpm.count
        let ref = n % 2 == 0 ? Double(sortedBpm[n / 2 - 1] + sortedBpm[n / 2]) / 2 : Double(sortedBpm[n / 2])
        for x in readings where !x.rr.isEmpty {
            let i = Int(x.timeMillis / 60_000 - r.startMinute)
            if i < 0 || i >= st.count { continue }
            let rr = x.rr.filter { $0 >= 300 && $0 <= 2000 }
            let w = x.timeMillis / windowMs
            if st[i] == SleepStager.deep { deep[w, default: []].append((x.timeMillis, rr)) }
            else if st[i] == SleepStager.light { light[w, default: []].append((x.timeMillis, rr)) }
            else { continue }
            let k = w * 8 + Int64(st[i])
            hrSum[k, default: 0] += Double(x.bpm); hrN[k, default: 0] += 1
        }
        func mean(_ m: [Int64: [(Int64, [Double])]], _ stage: Int) -> Double? {
            var v = [Double]()
            for k in m.keys.sorted() {
                guard let items = m[k], items.reduce(0, { $0 + $1.1.count }) >= minRrPerWindow else { continue }
                let hk = k * 8 + Int64(stage)
                if let c = hrN[hk], let s = hrSum[hk], s / Double(c) > ref + stageHighHr { continue }
                guard let x = rmssdAdjacent(items, maxJump: 0.30) else { continue }
                v.append(x)
            }
            return v.count < 10 ? nil : v.reduce(0, +) / Double(v.count)
        }
        guard let p = mean(deep, SleepStager.deep), let l = mean(light, SleepStager.light) else { return nil }
        return exp(stageC + stageDeepExp * log(p) + stageLightExp * log(l))
    }

    /// Método del 25/10 (media de profundo calibrado y toda la noche): solo si no hay fases suficientes.
    static func hrvOld(_ readings: [HrReading], staged: SleepStager.Result?) -> Double? {
        let whole = wholeNightHrv(readings)
        if let st = staged, let deep = deepHrv(readings, staged: st) {
            if let w = whole { return (deep + w) / 2 }
            return deep
        }
        return whole
    }

    static func deepHrv(_ readings: [HrReading], staged r: SleepStager.Result) -> Double? {
        let st = r.stages
        let n = st.count
        var perMinute = [[Double]](repeating: [], count: n)
        for x in readings {
            let i = Int(x.timeMillis / 60_000 - r.startMinute)
            if i >= 0 && i < n { perMinute[i].append(contentsOf: x.rr.filter { $0 >= 300 && $0 <= 2000 }) }
        }
        var weighted = 0.0
        var weight = 0
        var i = 0
        while i < n {
            var j = i
            while j < n && st[j] == st[i] { j += 1 }
            if st[i] == SleepStager.deep && j - i >= 5 {
                var rr = [Double]()
                for k in i..<j { rr.append(contentsOf: perMinute[k]) }
                if rr.count > 2, let v = MetricsCalculator.computeRMSSD(rr) { weighted += v * Double(j - i); weight += j - i }
            }
            i = j
        }
        if weight < 10 { return nil }
        return deepK * pow(weighted / Double(weight), deepExp)
    }

    static func wholeNightHrv(_ readings: [HrReading]) -> Double? {
        var windows = [Int64: [(Int64, [Double])]]()
        for x in readings where !x.rr.isEmpty {
            windows[x.timeMillis / windowMs, default: []].append((x.timeMillis, x.rr.filter { $0 >= 300 && $0 <= 2000 }))
        }
        var values = [Double]()
        for k in windows.keys.sorted() {
            guard let items = windows[k], items.reduce(0, { $0 + $1.1.count }) >= minRrPerWindow,
                  let v = rmssdAdjacent(items, maxJump: 0.20) else { continue }
            values.append(v)
        }
        if values.count < minWindows { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return hrvK * pow(mean, hrvExp)
    }
}

// MARK: - Estrés

/// Estrés 0–3 por ventanas de 5 minutos de las últimas 24 h: pulso y VFC frente a tu línea base (23/10, igual que Android,
/// ajustado con la curva de WHOOP del 22→23/10 y el estrés del sueño de 4 noches):
///   z = 3,4 · (FC − FCR base) / (FCmáx − FCR base) + 0,2 · ln(VFC base / VFC);  estrés = 0,3 + 2,7 · (1 − e^(−z))
enum StressCalculator {
    static let minScore = 0.117
    // 5/11 (igual que Android): un punto por MINUTO y curva reajustada con 14 días de WHOOP (antes 0,3 / 3,4 / 0,2 / 1, cada 5 min)
    static let kHr = 4.029
    static let kHrv = 0.307
    static let stressExp = 1.217

    static func analyze(hrLog: HrLog, restingHr: Int?, baseline: PersonalBaseline?) -> StressSummary {
        let now = TimeUtil.nowMillis()
        let readings = hrLog.readings(from: now - 24 * 3_600_000, to: now + 60_000)
        if readings.isEmpty { return StressSummary(currentScore: nil, level: "BAJO", lastUpdateMinute: nil, series: []) }

        let baselineRhr = baseline?.stressRhr ?? baseline?.avgRestingHr ?? Formulas.fallbackRhr
        let baselineHrv = baseline?.stressHrv ?? baseline?.avgHrv ?? Formulas.fallbackHrv

        let windowMillis: Int64 = 60 * 1000
        var groups = [Int64: [HrReading]]()
        for r in readings { groups[r.timeMillis / windowMillis, default: []].append(r) }
        var series = [StressPoint]()
        for key in groups.keys.sorted() {
            guard let w = groups[key], w.count >= 30 else { continue }   // al menos ~30 s de datos
            var hrSum = 0.0
            var rr = [Double]()
            for r in w { hrSum += Double(r.bpm); rr.append(contentsOf: r.rr) }
            let score = computeScore(avgHr: hrSum / Double(w.count), windowHrv: computeRMSSD(rr),
                                     baselineRhr: baselineRhr, baselineHrv: baselineHrv)
            let t = key * windowMillis
            series.append(StressPoint(minuteOfDay: TimeUtil.minuteOfDay(t), score: score, timeMillis: t))
        }

        let current = series.last
        var level = "ALTO"
        if current == nil || current!.score < 1 { level = "BAJO" } else if current!.score < 2 { level = "MEDIO" }
        return StressSummary(currentScore: current?.score, level: level, lastUpdateMinute: current?.minuteOfDay, series: series)
    }

    /// Serie de estrés (un punto cada 5 min) entre [from] y [to) con la misma fórmula que [analyze].
    /// 26/11: dormido, un minuto con el pulso ≥ FCR de referencia + 19 es estrés ALTO (igual que Android SLEEP_HIGH_HR).
    static let sleepHighHr = 19.0
    static func seriesBetween(_ readings: [HrReading], from: Int64, to: Int64, baseline: PersonalBaseline?,
                              sleep: [ClosedRange<Int64>] = []) -> [StressPoint] {
        let baselineRhr = baseline?.stressRhr ?? baseline?.avgRestingHr ?? Formulas.fallbackRhr
        let baselineHrv = baseline?.stressHrv ?? baseline?.avgHrv ?? Formulas.fallbackHrv
        let windowMillis: Int64 = 60 * 1000
        var groups = [Int64: [HrReading]]()
        for r in readings where r.timeMillis >= from && r.timeMillis < to {
            groups[r.timeMillis / windowMillis, default: []].append(r)
        }
        var series = [StressPoint]()
        for key in groups.keys.sorted() {
            guard let w = groups[key], w.count >= 30 else { continue }
            var hrSum = 0.0
            var rr = [Double]()
            for r in w { hrSum += Double(r.bpm); rr.append(contentsOf: r.rr) }
            let avgHr = hrSum / Double(w.count)
            var score = computeScore(avgHr: avgHr, windowHrv: computeRMSSD(rr),
                                     baselineRhr: baselineRhr, baselineHrv: baselineHrv)
            let t = key * windowMillis
            if avgHr >= baselineRhr + sleepHighHr && sleep.contains(where: { $0.contains(t + windowMillis / 2) }) { score = max(score, 2) }
            series.append(StressPoint(minuteOfDay: TimeUtil.minuteOfDay(t), score: score, timeMillis: t))
        }
        return series
    }

    private static func computeScore(avgHr: Double, windowHrv: Double?, baselineRhr: Double, baselineHrv: Double) -> Float {
        let hrMax = Double(Formulas.observedHrMax() ?? 195)
        let reserve = max(hrMax - baselineRhr, 60.0)
        var z = kHr * (avgHr - baselineRhr) / reserve
        if let h = windowHrv, h > 0 { z += kHrv * log(baselineHrv / h) }
        let s = minScore + (3.0 - minScore) * (1.0 - exp(-pow(max(z, 0.0), stressExp)))
        return Float(min(max(s, 0.0), 3.0))
    }

    /// RMSSD descartando saltos > 20 % (artefactos), mínimo 10 diferencias válidas.
    private static func computeRMSSD(_ rr: [Double]) -> Double? {
        var sum = 0.0
        var n = 0
        if rr.count < 2 { return nil }
        for i in 1..<rr.count {
            let d = rr[i] - rr[i - 1]
            if abs(d) <= 0.2 * rr[i - 1] { sum += d * d; n += 1 }
        }
        return n >= 10 ? (sum / Double(n)).squareRoot() : nil
    }
}
