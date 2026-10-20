import Foundation

/// Resumen del día: noche más reciente (últimas 30 h), FC en reposo, VFC, esfuerzo, fases...
struct MetricsCalculator {
    let ageYears: Int
    var male: Bool = true

    private var hrMax: Double { return Formulas.hrMax(ageYears: ageYears) }

    func analyze(hrLog: HrLog, motionFile: URL = AppPaths.file(MotionTracker.fileName), now: Int64 = TimeUtil.nowMillis()) -> DailySummary {
        // Solo hace falta lo reciente: la noche (últimas 30 h) y el ciclo del día
        let readings = hrLog.readings(from: now - 36 * 3_600_000, to: now + 3_600_000)
        if readings.isEmpty { return DailySummary.empty() }
        let totalReadings = readings.count

        // Noche = desde las 18:00 de AYER (igual que DailyMetricsUpdater). Con las últimas 30 h entraba el final de la noche
        // anterior, bajaba el umbral del detector y el inicio dependía de la hora a la que abrías la app (19→20: 00:50 / 00:00).
        let eve18 = TimeUtil.startOfDay(now) - 6 * 3_600_000
        let recent = readings.filter { $0.timeMillis >= eve18 }
        let sleep = SleepDetector.detect(recent.map { ($0.timeMillis, $0.bpm) })
        let restWindow: (Int64, Int64)? = sleep.map { ($0.startMillis, $0.endMillis) }

        // Ciclo del día como WHOOP: empieza al dormirte (si la noche acabó hace menos de 20 h); si no, a las 00:00.
        let midnight = TimeUtil.startOfDay(now)
        var cycleStart = midnight
        if let s = sleep, now - s.endMillis < 20 * 3_600_000 { cycleStart = s.startMillis }
        let cycleReadings = readings.filter { $0.timeMillis >= cycleStart }
        var avgHr: Int? = nil
        if !cycleReadings.isEmpty {
            var sum = 0.0
            for r in cycleReadings { sum += Double(r.bpm) }
            avgHr = Int(sum / Double(cycleReadings.count))
        }

        // Con movimiento grabado esa noche, las fases (y el tiempo despierto) salen de SleepStager.
        // La ventana de las fases ya viene recortada: empieza al dormirse y acaba al despertar (17/10).
        var staged: SleepStager.Result? = nil
        if let s = sleep {
            staged = SleepStager.stageNight(hrLog: hrLog, motionFile: motionFile, startMillis: s.startMillis, endMillis: s.endMillis)
        }
        let window: (Int64, Int64)? = staged.map { ($0.startMillis, $0.endMillis - 1) } ?? restWindow

        // FC en reposo y VFC SOLO con la ventana de sueño (igual que WHOOP)
        var sleepReadings = [HrReading]()
        if let w = window { sleepReadings = readings.filter { $0.timeMillis >= w.0 && $0.timeMillis <= w.1 } }
        // Sin noche registrada no hay FC en reposo real (de día sale ~15 lpm más alta): se deja vacía
        let restingHr: Int? = sleepReadings.isEmpty ? nil : MetricsCalculator.findRestingHr(sleepReadings)
        // VFC: con fases, la de los tramos de sueño profundo (como WHOOP)
        let avgHrv: Double? = sleepReadings.isEmpty ? nil : NightMetrics.hrv(sleepReadings, staged: staged)
        var vo2Max: Double? = nil
        if let r = restingHr, r > 0 { vo2Max = 15.3 * (hrMax / Double(r)) }
        let strain = Formulas.strainOf(readings: cycleReadings.map { ($0.timeMillis, $0.bpm) },
                                       restingHr: restingHr, hrMax: hrMax, male: male)

        let respiratoryRate: Double? = sleepReadings.isEmpty ? nil : RespiratoryRateCalculator.estimate(sleepReadings.flatMap { $0.rr })

        var summary = DailySummary.empty()
        summary.restingHr = restingHr
        summary.avgHr = avgHr
        summary.avgHrv = avgHrv
        summary.vo2Max = vo2Max
        summary.strain = strain
        summary.sleepMinutes = staged?.asleepMinutes ?? sleep?.asleepMinutes
        summary.timeInBedMinutes = staged?.minutes ?? sleep?.inBedMinutes
        summary.awakeMinutes = staged?.awakeMinutes ?? sleep?.awakeMinutes
        if let w = window {
            summary.sleepStart = TimeUtil.timestamp(w.0)
            summary.sleepEnd = TimeUtil.timestamp(w.1)
            summary.sleepStartMinuteOfDay = TimeUtil.minuteOfDay(w.0)
            summary.sleepEndMinuteOfDay = TimeUtil.minuteOfDay(w.1)
            summary.sleepStartMillis = w.0
            summary.sleepEndMillis = w.1
        }
        summary.sleepEfficiencyPct = staged?.efficiencyPct ?? sleep?.efficiencyPct
        summary.respiratoryRate = respiratoryRate
        summary.totalReadings = totalReadings
        summary.stages = staged
        summary.restStartMillis = sleep?.startMillis
        return summary
    }

    /// Descarta intervalos RR que difieren >20 % del anterior (artefactos de movimiento, no VFC real).
    static func filterRRArtifacts(_ rr: [Double]) -> [Double] {
        if rr.count < 2 { return rr }
        var filtered = [rr[0]]
        for i in 1..<rr.count {
            let prev = filtered[filtered.count - 1]
            if abs(rr[i] - prev) / prev <= 0.20 { filtered.append(rr[i]) }
        }
        return filtered
    }

    static func computeRMSSD(_ rrRaw: [Double]) -> Double? {
        let rr = filterRRArtifacts(rrRaw)
        if rr.count < 2 { return nil }
        var sumSq = 0.0
        for i in 1..<rr.count { let d = rr[i] - rr[i - 1]; sumSq += d * d }
        return (sumSq / Double(rr.count - 1)).squareRoot()
    }

    /// FC en reposo = mediana de toda la ventana de sueño (cuadra con WHOOP: 58 vs 57, 59 vs 59).
    static func findRestingHr(_ readings: [HrReading]) -> Int? {
        if readings.isEmpty { return nil }
        let s = readings.map { $0.bpm }.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}

// MARK: - Necesidad de sueño

/// Necesidad de sueño = base (por edad) + esfuerzo + deuda − siestas.
enum SleepPlanner {
    static let baselineMinutes = 7 * 60 + 50   // 7:50 (adulto 18–64, ajustado a tu histórico de WHOOP)

    static func baselineForAge(_ age: Int?) -> Int {
        guard let a = age else { return baselineMinutes }
        if a < 14 { return 10 * 60 }
        if a < 18 { return 9 * 60 }
        if a >= 65 { return 7 * 60 + 30 }
        return baselineMinutes
    }

    // Hora de despertar elegida en Inicio ("El sueño de esta noche"), 7:30 si no se ha cambiado
    private static let wakeKey = "pulseapp_wake_minute"
    static func wakeMinute() -> Int {
        let v = UserDefaults.standard.object(forKey: wakeKey) as? Int
        return v ?? (7 * 60 + 30)
    }
    static func setWakeMinute(_ m: Int) { UserDefaults.standard.set(m, forKey: wakeKey) }

    /// Deuda tras una noche, como WHOOP (18/10): la mitad de lo que te faltó para la necesidad de esa noche
    /// (base + esfuerzo de la víspera + deuda que traías). Ajustado con 152 noches del export de WHOOP: error medio 1,5 min.
    /// Sin dato de esa noche, la deuda se reduce a la mitad.
    static func nextDebt(_ debtBefore: Int, base: Int, prevDayStrain: Double?, slept: Int?) -> Int {
        guard let s = slept else { return debtBefore / 2 }
        let need = base + Formulas.sleepNeedFromStrain(prevDayStrain ?? 0) + debtBefore
        return max(Int((Double(need - s) / 2).rounded()), 0)
    }

    /// Deuda acumulada tras la última noche guardada, de la más antigua a la más reciente.
    static func debtFrom(_ rowsOldestFirst: [DailyMetrics], base: Int) -> Int {
        var strain = [String: Double]()
        for r in rowsOldestFirst { if let s = r.strain { strain[r.date] = s } }
        var debt = 0
        for r in rowsOldestFirst { debt = nextDebt(debt, base: base, prevDayStrain: strain[Day.add(r.date, -1)], slept: r.sleepMinutes) }
        return debt
    }

    /// Necesidad de la noche que acabas de dormir: usa el esfuerzo de AYER (el de hoy apenas ha empezado).
    /// Si la última noche terminó hace más de 20 h, es la de esta noche.
    static func planForLastNight(store: AppStore, summary: DailySummary) -> SleepPlan {
        var strain: Double? = summary.strain
        if let end = summary.sleepEndMillis, TimeUtil.nowMillis() - end < 20 * 3_600_000 {
            let yesterday = TimeUtil.addDays(TimeUtil.nowMillis(), -1)
            if let s = store.getDay(TimeUtil.dayKey(yesterday))?.strain { strain = s }
        }
        return computeTonightPlan(store: store, todayStrain: strain)
    }

    /// [debtOverride]: deuda ya calculada (la de después de la última noche); nil = la de las noches guardadas.
    static func computeTonightPlan(store: AppStore, todayStrain: Double?, wakeHour: Int = 7, wakeMinute: Int = 30,
                                   debtOverride: Int? = nil) -> SleepPlan {
        let strainMinutes = todayStrain.map { Formulas.sleepNeedFromStrain($0) } ?? 0
        let base = baselineForAge(store.getProfile()?.ageYears())
        let debt = debtOverride ?? computeAccumulatedDebt(store: store, base: base)
        let nap = 0   // pendiente: detección de siestas
        let total = base + strainMinutes + debt - nap
        return SleepPlan(baselineMinutes: base, strainAdjustmentMinutes: strainMinutes, debtAdjustmentMinutes: debt,
                         napAdjustmentMinutes: nap, totalNeedMinutes: total,
                         suggestedBedtime: suggestedBedtime(total, wakeHour, wakeMinute))
    }

    /// Deuda tras las noches guardadas (se reparte a la mitad cada noche: 14 noches sobran).
    private static func computeAccumulatedDebt(store: AppStore, base: Int) -> Int {
        return debtFrom(store.lastDays(14).sorted { $0.date < $1.date }, base: base)
    }

    private static func suggestedBedtime(_ need: Int, _ h: Int, _ m: Int) -> String {
        var total = (h * 60 + m - need) % 1440
        if total < 0 { total += 1440 }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Actividades

enum ActivityRecorder {

    /// Resumen de una sesión a partir del pulso entre [startMillis] y [endMillis].
    static func summarize(hrLog: HrLog, startMillis: Int64, endMillis: Int64, ageYears: Int, weightKg: Double, sex: String,
                          type: String = "Sin clasificar", autoDetected: Bool = false, restingHr: Int? = nil) -> ActivitySession? {
        let readings = hrLog.readings(from: startMillis, to: endMillis)
        if readings.isEmpty { return nil }

        let hrMax = Formulas.hrMax(ageYears: ageYears)
        var sum = 0.0
        var maxHr = 0
        for r in readings { sum += Double(r.bpm); if r.bpm > maxHr { maxHr = r.bpm } }
        let avgHr = sum / Double(readings.count)

        // Minutos por zona en decimales (con lecturas cada segundo, truncar cada tramo daba siempre 0)
        var z = [Double](repeating: 0, count: 6)
        var trimpTotal = 0.0
        let rhr = restingHr ?? Formulas.defaultRestingHr
        let bounds = Formulas.zoneBounds(hrMax: hrMax)
        if readings.count > 1 {
            for i in 1..<readings.count {
                let deltaMin = Double(readings[i].timeMillis - readings[i - 1].timeMillis) / 60000.0
                if deltaMin <= 0 || deltaMin > 8 { continue }
                z[Formulas.zoneOf(readings[i].bpm, bounds)] += deltaMin
                trimpTotal += Formulas.trimp(minutes: deltaMin, hr: readings[i].bpm, restingHr: rhr, hrMax: hrMax, male: sex != "F")
            }
        }
        let strain = Formulas.strainFromTrimp(trimpTotal)
        let durationMinutes = Double(endMillis - startMillis) / 60000.0
        // Calorías por tiempo en cada zona (ajustadas con el export de WHOOP); Keytel daba ~1,8× más
        let b = Formulas.bmr() > 0 ? Formulas.bmr()
            : CalorieCalculator.basalMetabolicRate(ageYears: ageYears, weightKg: weightKg, heightCm: 175, sex: sex)
        let calories = durationMinutes > 0 ? Formulas.activityKcal(zoneMinutes: z, bmrPerDay: b) : 0
        return ActivitySession(id: 0, startMillis: startMillis, endMillis: endMillis, avgHr: Int(avgHr), maxHr: maxHr,
                               strain: strain, caloriesKcal: calories,
                               minutesZone1: Int(z[1].rounded()), minutesZone2: Int(z[2].rounded()),
                               minutesZone3: Int(z[3].rounded()), minutesZone4: Int(z[4].rounded()),
                               minutesZone5: Int(z[5].rounded()), type: type, autoDetected: autoDetected,
                               minutesZone0: Int(z[0].rounded()))
    }
}
