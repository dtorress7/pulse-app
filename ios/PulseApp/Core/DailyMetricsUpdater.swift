import Foundation

/// Guarda el resumen del día anterior (una vez) al cambiar de día: noche que TERMINÓ ese día, esfuerzo, calorías...
enum DailyMetricsUpdater {

    static func updateYesterdayIfNeeded(store: AppStore, hrLog: HrLog, motionFile: URL, ageYears: Int, weightKg: Double, sex: String) {
        let now = TimeUtil.nowMillis()
        let yesterdayKey = TimeUtil.dayKey(TimeUtil.addDays(now, -1))
        if store.getDay(yesterdayKey) != nil { return }
        guard let dayStart = TimeUtil.parseDayKey(yesterdayKey) else { return }
        let dayEnd = TimeUtil.addDays(dayStart, 1)

        // La noche que TERMINÓ ese día: de las 18:00 de la víspera a las 14:00. Y el día natural para el esfuerzo.
        let nightFrom = dayStart - 6 * 3_600_000
        let nightTo = dayStart + 14 * 3_600_000
        let all = hrLog.readings(from: nightFrom, to: max(nightTo, dayEnd))
        let dayReadings = all.filter { $0.timeMillis >= dayStart && $0.timeMillis < dayEnd }
        if dayReadings.isEmpty { return }

        let hrMax = Formulas.hrMax(ageYears: ageYears)
        let nightReadings = all.filter { $0.timeMillis >= nightFrom && $0.timeMillis <= nightTo }
        let sleep = SleepDetector.detect(nightReadings.map { ($0.timeMillis, $0.bpm) })
        // Con movimiento grabado esa noche, el tiempo despierto sale de SleepStager y la ventana se recorta (17/10)
        var staged: SleepStager.Result? = nil
        if let s = sleep {
            staged = SleepStager.stageNight(hrLog: hrLog, motionFile: motionFile, startMillis: s.startMillis, endMillis: s.endMillis)
        }
        let window: (Int64, Int64)? = staged.map { ($0.startMillis, $0.endMillis - 1) } ?? sleep.map { ($0.startMillis, $0.endMillis) }
        var sleepWindowReadings = [HrReading]()
        if let w = window { sleepWindowReadings = nightReadings.filter { $0.timeMillis >= w.0 && $0.timeMillis <= w.1 } }

        let restingHr: Int? = sleepWindowReadings.isEmpty ? nil : MetricsCalculator.findRestingHr(sleepWindowReadings)
        let avgHrv: Double? = sleepWindowReadings.isEmpty ? nil : NightMetrics.hrv(sleepWindowReadings, staged: staged)
        var vo2: Double? = nil
        if let r = restingHr, r > 0 { vo2 = 15.3 * (hrMax / Double(r)) }
        let strain = Formulas.strainOf(readings: dayReadings.map { ($0.timeMillis, $0.bpm) }, restingHr: restingHr,
                                       hrMax: hrMax, male: sex != "F")
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

        store.saveDay(DailyMetrics(date: yesterdayKey, restingHr: restingHr, avgHrv: avgHrv, sleepMinutes: sleepMinutes,
                                   strain: strain, vo2Max: vo2, caloriesKcal: calories,
                                   sleepStartMinuteOfDay: startMinute, sleepEndMinuteOfDay: endMinute,
                                   sleepEfficiencyPct: efficiency, respiratoryRate: resp,
                                   lightMinutes: staged?.lightMinutes, deepMinutes: staged?.deepMinutes,
                                   remMinutes: staged?.remMinutes, awakeMinutes: staged?.awakeMinutes,
                                   wakeEpisodes: staged?.awakenings,
                                   latencyMinutes: latency))
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
/// Regla: media de 4 min > 60 % FCmáx durante 8 min → empieza; < 55 % durante 5 min → termina.
final class LiveHrProcessor {
    private let store: AppStore
    private let hrLog: HrLog
    private let onActivitySaved: (String) -> Void

    private var recent = [(Int64, Int)]()
    private var recording = false
    private var autoStart: Int64? = nil
    private var aboveSince: Int64? = nil
    private var belowSince: Int64? = nil
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
        if timeMillis - lastTime > 10 * 60_000 { recent.removeAll(); aboveSince = nil; belowSince = nil }
        lastTime = timeMillis
        checkDayRollover(timeMillis)

        recent.append((timeMillis, bpm))
        while let f = recent.first, timeMillis - f.0 > 4 * 60_000 { recent.removeFirst() }
        var sum = 0.0
        for r in recent { sum += Double(r.1) }
        let pct = sum / Double(recent.count) / hrMax

        if ActivityState.manualStart() != nil {
            aboveSince = nil; belowSince = nil
            if recording { recording = false; autoStart = nil }   // la manual manda
            return
        }
        if !recording {
            if pct > 0.6 {
                let since = aboveSince ?? timeMillis
                aboveSince = since
                if timeMillis - since > 8 * 60_000 { recording = true; autoStart = since; aboveSince = nil }
            } else {
                aboveSince = nil
            }
        } else {
            if pct < 0.55 {
                let since = belowSince ?? timeMillis
                belowSince = since
                if timeMillis - since > 5 * 60_000, let start = autoStart {
                    recording = false; autoStart = nil; belowSince = nil
                    saveAuto(start, since)
                }
            } else {
                belowSince = nil
            }
        }
    }

    private func saveAuto(_ start: Int64, _ end: Int64) {
        queue.async { [store, hrLog, onActivitySaved] in
            // No duplicar si ya hay una actividad guardada que se solapa
            if store.allSessions().contains(where: { $0.startMillis < end && $0.endMillis > start }) { return }
            let profile = store.getProfile()
            let rhr = BaselineProvider.compute(store: store).map { Int($0.avgRestingHr) }
            guard let session = ActivityRecorder.summarize(
                hrLog: hrLog, startMillis: start, endMillis: end,
                ageYears: profile?.ageYears() ?? 30, weightKg: profile?.weightKg ?? 75, sex: profile?.sex ?? "M",
                type: "Sin clasificar", autoDetected: true, restingHr: rhr) else { return }
            Formulas.updateObservedHrMax(session.maxHr)
            store.saveSession(session)
            onActivitySaved("Actividad detectada guardada (\((end - start) / 60000) min)")
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
