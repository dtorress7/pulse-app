import Foundation

/// Guarda el resumen del día anterior (una vez) al cambiar de día: noche que TERMINÓ ese día, esfuerzo, calorías...
enum DailyMetricsUpdater {

    static func updateYesterdayIfNeeded(store: AppStore, hrLog: HrLog, motionFile: URL, ageYears: Int, weightKg: Double, sex: String) {
        StagePrior.refresh(store: store)
        recalcPastNightsOnce(store: store, hrLog: hrLog, motionFile: motionFile, ageYears: ageYears, weightKg: weightKg, sex: sex)
        let now = TimeUtil.nowMillis()
        let yesterdayKey = TimeUtil.dayKey(TimeUtil.addDays(now, -1))
        // 22/11: el día va de sueño a sueño (DayCycle). Ayer se cierra cuando ya ha empezado el día de hoy (has dormido la noche que
        // acaba hoy) o, sin noche, a las 15:00; se guarda una vez cerrado (aunque ya hubiera una fila guardada antes de tiempo).
        if UserDefaults.standard.string(forKey: closedKey) == yesterdayKey { return }
        let importUntil = WhoopImport.importedUntil()
        if !importUntil.isEmpty && yesterdayKey <= importUntil { UserDefaults.standard.set(yesterdayKey, forKey: closedKey); return }
        let todayKey = TimeUtil.dayKey(now)
        let opens = detectNight(hrLog: hrLog, motionFile: motionFile, key: todayKey)
            .map { DayCycle.opensDay(asleepMinutes: $0.asleep, endMillis: $0.window.1, date: todayKey) } ?? false
        if !opens && now < Day.start(todayKey) + 15 * 3_600_000 { return }
        if let d = computeDay(store: store, hrLog: hrLog, motionFile: motionFile, key: yesterdayKey,
                              ageYears: ageYears, weightKg: weightKg, sex: sex) { store.saveDay(d) }
        UserDefaults.standard.set(yesterdayKey, forKey: closedKey)
    }

    static let closedKey = "pulseapp_cycle_closed_day"

    /// La noche que termina el día [key] (de las 18:00 de la víspera a las 15:00 de ese día): ventana recortada y minutos dormido.
    static func detectNight(hrLog: HrLog, motionFile: URL, key: String) -> (window: (Int64, Int64), asleep: Int?)? {
        let d0 = Day.start(key)
        let nightReadings = hrLog.readings(from: d0 - 6 * 3_600_000, to: d0 + 15 * 3_600_000)
        guard let sleep = SleepDetector.detect(nightReadings.map { ($0.timeMillis, $0.bpm) }) else { return nil }
        let staged = SleepStager.stageNight(hrLog: hrLog, motionFile: motionFile, startMillis: sleep.startMillis, endMillis: sleep.endMillis)
        let window = staged.map { ($0.startMillis, $0.endMillis - 1) } ?? (sleep.startMillis, sleep.endMillis)
        return (window, staged?.asleepMinutes ?? sleep.asleepMinutes)
    }

    static let recalcKey = "pulseapp_night_recalc"

    /// Una sola vez tras actualizar (23/10, VFC y recuperación nuevas): rehace con las fórmulas de ahora los días guardados
    /// que tengan pulso guardado, para que la línea base de VFC esté en la misma escala. Sin pulso, se dejan igual.
    static func recalcPastNightsOnce(store: AppStore, hrLog: HrLog, motionFile: URL, ageYears: Int, weightKg: Double, sex: String) {
        if UserDefaults.standard.integer(forKey: recalcKey) >= 27 { return }   // 27 (24/11): reparto de fases corregido con tu historial de WHOOP (StagePrior); 26 (24/11): VFC y respiración con latidos perdidos; 25 (22/11): esfuerzo, FC media y calorías del día de sueño a sueño; 24 (21/11): suelo del giroscopio de cada pulsera; 23 (20/11): inicio con giros en la cama; 22 (19/11): modelo de fases con 30 noches y contexto ±7 min; 21 (18/11): VO₂ máx con K 16,45; 20 (12/11): inicio con tramo quieto de 9 min; 19 (11/11): paseos sin carga aparte en el día; 18 (11/11): esfuerzo del día sin el pulso casi en reposo fuera de las actividades; 17 (10/11): fin de la noche sin cortar al dormitar con el pulso alto ni con un despertar de 3 min; 16 (9/11 tarde): temperatura de la piel; 15 (9/11): fin antes del rato despierto tumbado e inquieto; 14 (7/11): inicio/fin de la noche despierto en la cama; 13 (5/11): fases con segunda pasada sobre la noche recortada; 12 (4/11): VFC sin los tramos de pulso alto; 11 (3/11): fin de la noche con 40 pasos y pesas con su carga; 10 (2/11): esfuerzo con la FCR de referencia; 9 (1/11): VFC por profundo + ligero; 8 (1/11): fin de la noche sin remolonear; 7 (30/10): esfuerzo sin el pulso bajo dormido; 6 (27/10): esfuerzo del día sin base fuera de actividades; 5: fases 11 noches
        let today = TimeUtil.dayKey(TimeUtil.nowMillis())
        let importUntil = WhoopImport.importedUntil()
        // 23/11: se apunta cada día ya rehecho; si iOS cierra la app a mitad (tarda minutos con el pulso de 40 días), la próxima vez
        // sigue donde iba en vez de empezar de cero (antes no terminaba nunca y la app se quedaba en "--" y se cerraba).
        let target = 27
        // 24/11: la 1.ª pasada guarda lo que da el modelo de fases en cada noche (stage_raw.csv); si con eso cambia la corrección personal
        // de las fases (StagePrior), una 2.ª pasada rehace las noches con ella (marca "27b" en el progreso)
        let before = StagePrior.refresh(store: store)
        let rows = store.lastDays(60).filter { $0.date < today && (importUntil.isEmpty || $0.date > importUntil) }
        func pass(_ tag: String) {
            var done = recalcProgress(tag)
            // De más reciente a más antiguo: el día siguiente ya está rehecho y su noche marca dónde acaba cada día (sin volver a buscarla)
            for row in rows {
                if done.contains(row.date) { continue }
                autoreleasepool {
                    if let d = computeDay(store: store, hrLog: hrLog, motionFile: motionFile, key: row.date,
                                          ageYears: ageYears, weightKg: weightKg, sex: sex) { store.saveDay(d) }
                }
                done.insert(row.date)
                UserDefaults.standard.set("\(tag)|" + done.sorted().joined(separator: ","), forKey: recalcProgressKey)
            }
        }
        let resumingSecond = UserDefaults.standard.string(forKey: recalcProgressKey)?.hasPrefix("\(target)b|") ?? false
        if !resumingSecond { pass("\(target)") }
        let after = StagePrior.refresh(store: store)
        if resumingSecond || (after != nil && (before == nil || (0..<3).contains { abs(after![$0] - before![$0]) > 0.01 })) { pass("\(target)b") }
        UserDefaults.standard.set(target, forKey: recalcKey)
        UserDefaults.standard.removeObject(forKey: recalcProgressKey)
    }

    static let recalcProgressKey = "pulseapp_night_recalc_progress"

    /// Días ya rehechos en el recálculo [target] que quedó a medias.
    private static func recalcProgress(_ tag: String) -> Set<String> {
        guard let v = UserDefaults.standard.string(forKey: recalcProgressKey) else { return [] }
        let parts = v.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == tag else { return [] }
        return Set(parts[1].split(separator: ",").map(String.init))
    }

    /// 17/11: tras importar el pulso de otro móvil (p. ej. de PulseApp a Pulse Beta), calcula los días que aún no están guardados
    /// (hasta 45 días atrás, sin tocar los importados de WHOOP ni hoy), de más antiguo a más reciente. Devuelve cuántos guardó.
    static func rebuildMissingDays(store: AppStore, hrLog: HrLog, motionFile: URL, ageYears: Int, weightKg: Double, sex: String) -> Int {
        let today = TimeUtil.dayKey(TimeUtil.nowMillis())
        let importUntil = WhoopImport.importedUntil()
        var saved = 0
        for back in stride(from: 45, through: 1, by: -1) {
            let key = Day.add(today, -back)
            if !importUntil.isEmpty && key <= importUntil { continue }
            if store.getDay(key) != nil { continue }
            if let d = computeDay(store: store, hrLog: hrLog, motionFile: motionFile, key: key,
                                  ageYears: ageYears, weightKg: weightKg, sex: sex) {
                store.saveDay(d)
                saved += 1
            }
        }
        return saved
    }

    /// 5/11: rehace UN día ya guardado (al registrar las series de un entreno de ese día). Hoy y los días de WHOOP no se tocan.
    static func recalcDay(store: AppStore, hrLog: HrLog, motionFile: URL, key: String, ageYears: Int, weightKg: Double, sex: String) {
        let today = TimeUtil.dayKey(TimeUtil.nowMillis())
        let importUntil = WhoopImport.importedUntil()
        if key >= today || (!importUntil.isEmpty && key <= importUntil) || store.getDay(key) == nil { return }
        if let d = computeDay(store: store, hrLog: hrLog, motionFile: motionFile, key: key, ageYears: ageYears, weightKg: weightKg, sex: sex) {
            store.saveDay(d)
        }
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
            if let st = staged {
                SleepStagesStore.save(yesterdayKey, st)   // para la gráfica de fases de días pasados
                StagePrior.record(yesterdayKey, st.rawFrac)   // 24/11: reparto del modelo sin corregir (StagePrior)
            }
        }
        let window: (Int64, Int64)? = staged.map { ($0.startMillis, $0.endMillis - 1) } ?? sleep.map { ($0.startMillis, $0.endMillis) }
        if let w = window { SkinTemp.ensure(yesterdayKey, fromMs: w.0, toMs: w.1) }   // 9/11: temperatura de la piel de esa noche
        var sleepWindowReadings = [HrReading]()
        if let w = window { sleepWindowReadings = nightReadings.filter { $0.timeMillis >= w.0 && $0.timeMillis <= w.1 } }

        let restingHr: Int? = sleepWindowReadings.isEmpty ? nil : MetricsCalculator.findRestingHr(sleepWindowReadings)
        let avgHrv: Double? = sleepWindowReadings.isEmpty ? nil : NightMetrics.hrv(sleepWindowReadings, staged: staged)
        var vo2: Double? = nil
        if let r = restingHr, r > 0 { vo2 = Formulas.vo2Max(hrMax: hrMax, restingHr: Double(r)) }
        // 22/11: el día va de sueño a sueño (DayCycle): desde que te dormiste esa noche hasta que te dormiste la siguiente
        // (sin noche, de 00:00 a 00:00). El esfuerzo, la FC media y las calorías salen de ese tramo, como el ciclo de WHOOP.
        let cycleStart = window?.0 ?? dayStart
        let nextKey = Day.add(yesterdayKey, 1)
        // 23/11: si el día siguiente ya está guardado (pasado), su noche sale de lo guardado: es el mismo cálculo y así no se repite
        // la búsqueda de la noche (que relee el archivo de pulso entero) para cada día del recálculo. Hoy no está guardado → se busca.
        var nextStart: Int64? = nil
        if nextKey < TimeUtil.dayKey(TimeUtil.nowMillis()), let nr = store.getDay(nextKey) {
            if let ns = nr.sleepStartMinuteOfDay, let ne = nr.sleepEndMinuteOfDay {
                let endMs = Day.start(nextKey) + Int64(ne) * 60_000
                if DayCycle.opensDay(asleepMinutes: nr.sleepMinutes, endMillis: endMs, date: nextKey) {
                    nextStart = DayCycle.startMillis(nextKey, ns, ne)
                }
            }
        } else {
            nextStart = detectNight(hrLog: hrLog, motionFile: motionFile, key: nextKey)
                .flatMap { DayCycle.opensDay(asleepMinutes: $0.asleep, endMillis: $0.window.1, date: nextKey) ? $0.window.0 : nil }
        }
        let cycleEnd = max(cycleStart + 3_600_000, nextStart ?? dayEnd)
        var cycleReadings = hrLog.readings(from: cycleStart, to: cycleEnd).filter { $0.timeMillis >= cycleStart && $0.timeMillis < cycleEnd }
        if cycleReadings.isEmpty { cycleReadings = dayReadings }
        var strain = Formulas.strainOf(readings: cycleReadings.map { ($0.timeMillis, $0.bpm) }, restingHr: Formulas.zoneRestingHr(),   // 2/11: FCR de referencia
                                       hrMax: hrMax, male: sex != "F", sleepWindow: window,
                                       activities: store.allSessions().filter { $0.type != Formulas.napType }.map { ($0.startMillis, $0.endMillis) })   // 11/11
        // Día con fuerza/funcional: + carga muscular, como WHOOP (22/10)
        let daySessions = store.allSessions().filter { $0.startMillis >= cycleStart && $0.startMillis < cycleEnd }
        let strengthMin = daySessions.reduce(0.0) { $0 + Formulas.dayMuscleMinutes($1.type, $1.startMillis, $1.endMillis) }
        // 27/10: la base por minuto solo en las actividades (el pulso del día va sin ella)
        let activityMin = daySessions.reduce(0.0) { $0 + Formulas.activityLoadMinutes($1.type, Double($1.endMillis - $1.startMillis) / 60000.0) }
        strain = Formulas.addStrength(strain, strengthMin, activityMin)
        let sleepMinutes = staged?.asleepMinutes ?? sleep?.asleepMinutes
        let efficiency = staged?.efficiencyPct ?? sleep?.efficiencyPct
        var startMinute: Int? = nil
        var endMinute: Int? = nil
        if let w = window {
            startMinute = TimeUtil.minuteOfDay(w.0)
            endMinute = TimeUtil.minuteOfDay(w.1)
        }
        let resp: Double? = sleepWindowReadings.isEmpty ? nil : RespiratoryRateCalculator.estimate(sleepWindowReadings)

        var sum = 0.0
        for r in cycleReadings { sum += Double(r.bpm) }
        let avgHr = sum / Double(cycleReadings.count)
        let durationMinutes = Double(cycleReadings.count) / 60.0
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
