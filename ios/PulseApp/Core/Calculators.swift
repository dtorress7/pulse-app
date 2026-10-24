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
        // 23/10: la media parte de tu línea base de WHOOP antes de PulseApp (88 ms / 58,5 lpm), igual que Android.
        let lnHrv = validHrv.map { log($0) }
        let lnEwma = ewma(Array(lnHrv.reversed()), prior: log(Formulas.fallbackHrv))
        let respOk = validResp.count >= minDaysRequired
        return PersonalBaseline(
            avgHrv: exp(lnEwma),
            avgRestingHr: ewma(Array(validRhr.reversed()), prior: Formulas.fallbackRhr),
            daysUsed: min(validHrv.count, validRhr.count),
            lnHrvMean: lnEwma,
            lnHrvSd: max(sd(lnHrv), minLnHrvSd),
            rhrSd: max(sd(validRhr), minRhrSd),
            respMean: respOk ? validResp.reduce(0, +) / Double(validResp.count) : nil,
            respSd: respOk ? max(sd(validResp), minRespSd) : nil)
    }

    private static func ewma(_ oldestFirst: [Double], prior: Double) -> Double {
        var m = prior
        for v in oldestFirst { m += ewmaAlpha * (v - m) }
        return m
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
                          respiratoryRate: Double? = nil) -> RecoveryBreakdown {
        let r = Formulas.recovery(hrv: nightlyHrv, restingHr: restingHr, respiratoryRate: respiratoryRate, baseline: baseline)
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
                                   ageYears: Int, weightKg: Double, heightCm: Double, sex: String) -> Double {
        let bmr = basalMetabolicRate(ageYears: ageYears, weightKg: weightKg, heightCm: heightCm, sex: sex)
        // Sin ×1,15 (20/10): fuera de los entrenamientos WHOOP da de mediana 1644 kcal/24 h ≈ tu metabolismo basal
        return bmr * (elapsedMinutesToday / (24 * 60)) + activityKcalToday
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

    static func estimate(_ input: [Double]) -> Double? {
        let rr = input.filter { $0 >= 300 && $0 <= 2000 }
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
        estimates.sort()
        let m = estimates.count
        let median = m % 2 == 1 ? estimates[m / 2] : (estimates[m / 2 - 1] + estimates[m / 2]) / 2.0
        return (median >= 8.0 && median <= 25.0) ? median : nil
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

    static func hrv(_ readings: [HrReading], staged: SleepStager.Result?) -> Double? {
        if let st = staged, let v = deepHrv(readings, staged: st) { return v }
        return wholeNightHrv(readings)
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
        var windows = [Int64: [Double]]()
        for x in readings where !x.rr.isEmpty {
            windows[x.timeMillis / windowMs, default: []].append(contentsOf: x.rr.filter { $0 >= 300 && $0 <= 2000 })
        }
        var values = [Double]()
        for k in windows.keys.sorted() {
            guard let rr = windows[k], rr.count >= minRrPerWindow, let v = MetricsCalculator.computeRMSSD(rr) else { continue }
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
    static let minScore = 0.3
    static let kHr = 3.4
    static let kHrv = 0.2

    static func analyze(hrLog: HrLog, restingHr: Int?, baseline: PersonalBaseline?) -> StressSummary {
        let now = TimeUtil.nowMillis()
        let readings = hrLog.readings(from: now - 24 * 3_600_000, to: now + 60_000)
        if readings.isEmpty { return StressSummary(currentScore: nil, level: "BAJO", lastUpdateMinute: nil, series: []) }

        let baselineRhr = baseline?.avgRestingHr ?? Formulas.fallbackRhr
        let baselineHrv = baseline?.avgHrv ?? Formulas.fallbackHrv

        let windowMillis: Int64 = 5 * 60 * 1000
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
    static func seriesBetween(_ readings: [HrReading], from: Int64, to: Int64, baseline: PersonalBaseline?) -> [StressPoint] {
        let baselineRhr = baseline?.avgRestingHr ?? Formulas.fallbackRhr
        let baselineHrv = baseline?.avgHrv ?? Formulas.fallbackHrv
        let windowMillis: Int64 = 5 * 60 * 1000
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
            let score = computeScore(avgHr: hrSum / Double(w.count), windowHrv: computeRMSSD(rr),
                                     baselineRhr: baselineRhr, baselineHrv: baselineHrv)
            let t = key * windowMillis
            series.append(StressPoint(minuteOfDay: TimeUtil.minuteOfDay(t), score: score, timeMillis: t))
        }
        return series
    }

    private static func computeScore(avgHr: Double, windowHrv: Double?, baselineRhr: Double, baselineHrv: Double) -> Float {
        let hrMax = Double(Formulas.observedHrMax() ?? 195)
        let reserve = max(hrMax - baselineRhr, 60.0)
        var z = kHr * (avgHr - baselineRhr) / reserve
        if let h = windowHrv, h > 0 { z += kHrv * log(baselineHrv / h) }
        let s = minScore + (3.0 - minScore) * (1.0 - exp(-max(z, 0.0)))
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
