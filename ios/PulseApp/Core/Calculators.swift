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

    static func compute(store: AppStore) -> PersonalBaseline? {
        let days = store.lastDays(lookbackDays).filter { ($0.sleepMinutes ?? 0) >= 180 }
        let validHrv = days.compactMap { d -> Double? in
            if let v = d.avgHrv, v > 0 { return v }
            return nil
        }
        let validRhr = days.compactMap { d -> Double? in
            if let v = d.restingHr { return Double(v) }
            return nil
        }
        let validResp = days.compactMap { d -> Double? in
            if let r = d.respiratoryRate, r >= 8.0, r <= 25.0 { return r }
            return nil
        }
        if validHrv.count < minDaysRequired || validRhr.count < minDaysRequired { return nil }
        // lastDays viene de más reciente a más antiguo: se invierte para la media ponderada
        let lnHrv = validHrv.map { log($0) }
        let lnEwma = ewma(Array(lnHrv.reversed()))
        let respOk = validResp.count >= minDaysRequired
        return PersonalBaseline(
            avgHrv: exp(lnEwma),
            avgRestingHr: ewma(Array(validRhr.reversed())),
            daysUsed: min(validHrv.count, validRhr.count),
            lnHrvMean: lnEwma,
            lnHrvSd: max(sd(lnHrv), minLnHrvSd),
            rhrSd: max(sd(validRhr), minRhrSd),
            respMean: respOk ? validResp.reduce(0, +) / Double(validResp.count) : nil,
            respSd: respOk ? max(sd(validResp), minRespSd) : nil)
    }

    private static func ewma(_ oldestFirst: [Double]) -> Double {
        var m = oldestFirst[0]
        for v in oldestFirst.dropFirst() { m += ewmaAlpha * (v - m) }
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

/// Gasto calórico: metabolismo basal (Mifflin-St Jeor) proporcional al tiempo transcurrido × 1,15 (vida diaria)
/// + calorías de las actividades guardadas (Keytel) sumadas aparte.
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
        return bmr * (elapsedMinutesToday / (24 * 60)) * 1.15 + activityKcalToday
    }
}

// MARK: - Respiración

/// Frecuencia respiratoria (rpm) desde los RR de la noche (arritmia sinusal respiratoria): media móvil de 5,
/// picos locales = ciclos, distancia media entre picos. Aproximación práctica (aparcada en Android también).
enum RespiratoryRateCalculator {
    static func estimate(_ rr: [Double]) -> Double? {
        if rr.count < 30 { return nil }
        let smoothed = movingAverage(rr, 5)
        if smoothed.count < 10 { return nil }
        var peaks = [Int]()
        for i in 2..<(smoothed.count - 2) {
            if smoothed[i] > smoothed[i - 1] && smoothed[i] > smoothed[i - 2] &&
                smoothed[i] > smoothed[i + 1] && smoothed[i] > smoothed[i + 2] { peaks.append(i) }
        }
        if peaks.count < 3 { return nil }
        var gaps = [Double]()
        for i in 1..<peaks.count { gaps.append(Double(peaks[i] - peaks[i - 1])) }
        let avgGap = gaps.reduce(0, +) / Double(gaps.count)
        let avgBeatSec = rr.reduce(0, +) / Double(rr.count) / 1000.0
        let cycle = avgGap * avgBeatSec
        if cycle <= 0 { return nil }
        let bpm = 60.0 / cycle
        return (bpm >= 8.0 && bpm <= 25.0) ? bpm : nil
    }

    private static func movingAverage(_ v: [Double], _ w: Int) -> [Double] {
        if v.count < w { return v }
        var out = [Double]()
        var sum = 0.0
        for i in 0..<v.count {
            sum += v[i]
            if i >= w { sum -= v[i - w] }
            if i >= w - 1 { out.append(sum / Double(w)) }
        }
        return out
    }
}

// MARK: - Estrés

/// Estrés 0–3 por ventanas de 5 minutos de las últimas 24 h: pulso y VFC frente a tu línea base.
///   score = 4,8 · (0,7 · subida de pulso + 0,3 · caída de VFC)   (noche 14→15: 54/38/8 % vs WHOOP 53/42/5 %)
enum StressCalculator {
    static let scale = 4.8
    static let wHr = 0.7
    static let wHrv = 0.3

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

    private static func computeScore(avgHr: Double, windowHrv: Double?, baselineRhr: Double, baselineHrv: Double) -> Float {
        let hrUp = max((avgHr - baselineRhr) / baselineRhr, 0.0)
        var hrvDown = hrUp
        if let h = windowHrv, h > 0 { hrvDown = max(log(baselineHrv / h), 0.0) }
        let s = scale * (wHr * hrUp + wHrv * hrvDown)
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
