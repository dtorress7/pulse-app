import Foundation

/// Guarda el resumen del día anterior (una vez) al cambiar de día: noche que TERMINÓ ese día, esfuerzo, calorías...
enum DailyMetricsUpdater {

    static func updateYesterdayIfNeeded(store: AppStore, hrLog: HrLog, motionFile: URL, ageYears: Int, weightKg: Double, sex: String) {
        recalcPastNightsOnce(store: store, hrLog: hrLog, motionFile: motionFile, ageYears: ageYears, weightKg: weightKg, sex: sex)
        let now = TimeUtil.nowMillis()
        let yesterdayKey = TimeUtil.dayKey(TimeUtil.addDays(now, -1))
        if store.getDay(yesterdayKey) != nil { return }
        if let d = computeDay(store: store, hrLog: hrLog, motionFile: motionFile, key: yesterdayKey,
                              ageYears: ageYears, weightKg: weightKg, sex: sex) { store.saveDay(d) }
    }

    static let recalcKey = "pulseapp_night_recalc"

    /// Una sola vez tras actualizar (23/10, VFC y recuperación nuevas): rehace con las fórmulas de ahora los días guardados
    /// que tengan pulso guardado, para que la línea base de VFC esté en la misma escala. Sin pulso, se dejan igual.
    static func recalcPastNightsOnce(store: AppStore, hrLog: HrLog, motionFile: URL, ageYears: Int, weightKg: Double, sex: String) {
        if UserDefaults.standard.integer(forKey: recalcKey) >= 5 { return }   // 5 (26/10): modelo de fases con 11 noches
        let today = TimeUtil.dayKey(TimeUtil.nowMillis())
        let importUntil = WhoopImport.importedUntil()
        for row in store.lastDays(60) where row.date < today && (importUntil.isEmpty || row.date > importUntil) {
            if let d = computeDay(store: store, hrLog: hrLog, motionFile: motionFile, key: row.date,
                                  ageYears: ageYears, weightKg: weightKg, sex: sex) { store.saveDay(d) }
        }
        UserDefaults.standard.set(5, forKey: recalcKey)
    }

    private static func computeDay(store: AppStore, hrLog: HrLog, motionFile: URL, key yesterdayKey: String,
                                   ageYears: Int, weightKg: Double, sex: String) -> DailyMetrics? {
        guard let dayStart = TimeUtil.parseDayKey(yesterdayKey) else { return nil }
        let dayEnd = TimeUtil.addDays(dayStart, 1)

        // La noche que TERMINÓ ese día: de las 18:00 de la víspera a las 14:00. Y el día natural para el esfuerzo.
        let nightFrom = dayStart - 6 * 3_600_000
        let nightTo = dayStart + 15 * 3_600_000
        let all = hrLog.readings(from: nightFrom, to: max(nightTo, dayEnd))
        let dayReadings = all.filter { $0.timeMillis >= dayStart && $0.timeMillis < dayEnd }
        if dayReadings.isEmpty { return nil }

        let hrMax = Formulas.hrMax(ageYears: ageYears)
        let nightReadings = all.filter { $0.timeMillis >= nightFrom && $0.timeMillis <= nightTo }
        let sleep = SleepDetector.detect(nightReadings.map { ($0.timeMillis, $0.bpm) })
        // Con movimiento grabado esa noche, el tiempo despierto sale de SleepStager y la ventana se recorta (17/10)
        var staged: SleepStager.Result? = nil
        if let s = sleep {
            staged = SleepStager.stageNight(hrLog: hrLog, motionFile: motionFile, startMillis: s.startMillis, endMillis: s.endMillis)
            if let st = staged { SleepStagesStore.save(yesterdayKey, st) }   // para la gráfica de fases de días pasados
        }
        let window: (Int64, Int64)? = staged.map { ($0.startMillis, $0.endMillis - 1) } ?? sleep.map { ($0.startMillis, $0.endMillis) }
        var sleepWindowReadings = [HrReading]()
        if let w = window { sleepWindowReadings = nightReadings.filter { $0.timeMillis >= w.0 && $0.timeMillis <= w.1 } }

        let restingHr: Int? = sleepWindowReadings.isEmpty ? nil : MetricsCalculator.findRestingHr(sleepWindowReadings)
        let avgHrv: Double? = sleepWindowReadings.isEmpty ? nil : NightMetrics.hrv(sleepWindowReadings, staged: staged)
        var vo2: Double? = nil
        if let r = restingHr, r > 0 { vo2 = 15.3 * (hrMax / Double(r)) }
        var strain = Formulas.strainOf(readings: dayReadings.map { ($0.timeMillis, $0.bpm) }, restingHr: restingHr,
                                       hrMax: hrMax, male: sex != "F")
        // Día con fuerza/funcional: + carga muscular, como WHOOP (22/10)
        let strengthMin = store.allSessions().filter { $0.startMillis >= dayStart && $0.startMillis < dayEnd }
            .reduce(0.0) { $0 + Formulas.muscleMinutes($1.type, Double($1.endMillis - $1.startMillis) / 60000.0) }
        strain = Formulas.addStrength(strain, strengthMin)
        let sleepMinutes = staged?.asleepMinutes ?? sleep?.asleepMinutes
        let efficiency = staged?.efficiencyPct ?? sleep?.efficiencyPct
        var startMinute: Int? = nil
        var endMinute: Int? = nil
        if let w = window {
            startMinute = TimeUtil.minuteOfDay(w.0)
            endMinute = TimeUtil.minuteOfDay(w.1)
        }
        let resp: Double? = sleepWindowReadings.isEmpty ? nil : RespiratoryRateCalculator.estimate(sleepWindowReadings.flatMap { $0.rr })

        var sum = 0.0
        for r in dayReadings { sum += Double(r.bpm) }
        let avgHr = sum / Double(dayReadings.count)
        let durationMinutes = Double(dayReadings.count) / 60.0
        let calories = CalorieCalculator.exerciseCalories(avgHr: avgHr, durationMinutes: durationMinutes,
                                                          ageYears: ageYears, weightKg: weightKg, sex: sex)

        var latency: Int? = nil
        if let st = staged, let sl = sleep { latency = max(Int((st.startMillis - sl.startMillis) / 60_000), 0) }

        return DailyMetrics(date: yesterdayKey, restingHr: restingHr, avgHrv: avgHrv, sleepMinutes: sleepMinutes,
                                   strain: strain, vo2Max: vo2, caloriesKcal: calories,
                                   sleepStartMinuteOfDay: startMinute, sleepEndMinuteOfDay: endMinute,
                                   sleepEfficiencyPct: efficiency, respiratoryRate: resp,
                                   lightMinutes: staged?.lightMinutes, deepMinutes: staged?.deepMinutes,
                                   remMinutes: staged?.remMinutes, awakeMinutes: staged?.awakeMinutes,
                                   wakeEpisodes: staged?.awakenings,
                                   latencyMinutes: latency)
    }
}

// MARK: - Actividad manual y automática

/// Actividad iniciada a mano en Inicio: se guarda en disco para que no se pierda si iOS cierra la pantalla.
enum ActivityState {
    private static let key = "pulseapp_manual_activity_start"

    static func manualStart() -> Int64? {
        let v = Int64(UserDefaults.standard.double(forKey: key))
        return v > 0 ? v : nil
    }

    static func setManualStart(_ start: Int64?) {
        UserDefaults.standard.set(Double(start ?? 0), forKey: key)
    }
}

/// Procesa cada lectura de pulso con SU hora (en directo o del historial):
/// detección automática de actividades y cálculo del día anterior al cambiar de día.
/// Actividades automáticas: AutoActivityScanner (cada 5 min).
final class LiveHrProcessor {
    private let store: AppStore
    private let hrLog: HrLog
    private let onActivitySaved: (String) -> Void

    private var lastScan: Int64 = 0
    private var lastDay: String? = nil
    private var lastTime: Int64 = 0
    private let queue = DispatchQueue(label: "pulseapp.liveprocessor", qos: .utility)

    init(store: AppStore, hrLog: HrLog, onActivitySaved: @escaping (String) -> Void) {
        self.store = store
        self.hrLog = hrLog
        self.onActivitySaved = onActivitySaved
    }

    func feed(timeMillis: Int64, bpm: Int, hrMax: Double) {
        // Solo lecturas en orden: si llega algo más antiguo (historial ya cubierto), no altera el estado
        if timeMillis <= lastTime { return }
        lastTime = timeMillis
        checkDayRollover(timeMillis)

        // Actividades automáticas (20/10): cada 5 min se repasa el pulso guardado con AutoActivityScanner
        // (la regla de antes, lectura a lectura, empezaba y acababa tarde).
        if timeMillis - lastScan > 5 * 60_000 {
            lastScan = timeMillis
            queue.async { [store, hrLog, onActivitySaved] in
                let n = AutoActivityScanner.scan(store: store, hrLog: hrLog)
                if n > 0 { onActivitySaved("Actividad detectada automáticamente (\(n))") }
            }
        }
    }

    private func checkDayRollover(_ timeMillis: Int64) {
        let day = TimeUtil.dayKey(timeMillis)
        if day == lastDay { return }
        lastDay = day
        queue.async { [store, hrLog] in
            let profile = store.getProfile()
            DailyMetricsUpdater.updateYesterdayIfNeeded(
                store: store, hrLog: hrLog, motionFile: AppPaths.file(MotionTracker.fileName),
                ageYears: profile?.ageYears() ?? 30, weightKg: profile?.weightKg ?? 75, sex: profile?.sex ?? "M")
        }
    }
}
