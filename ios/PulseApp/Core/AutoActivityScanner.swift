import Foundation

/// Detección automática de actividades como WHOOP (20/10), igual que Android (AutoActivityScanner.kt):
/// repasa el pulso de las últimas 36 h con Formulas.detectActivities y guarda como "Sin clasificar" las actividades
/// terminadas (fin hace ≥ 10 min) que no se solapen con otra ni con una actividad manual en curso.
/// Se llama desde el procesador de la pulsera y al abrir Inicio, como mucho cada 5 min.
enum AutoActivityScanner {
    private static let lock = NSLock()
    private static var lastRun: Int64 = 0
    private static let keyRecalc = "pulseapp_act_recalc"

    @discardableResult
    static func scan(store: AppStore, hrLog: HrLog, force: Bool = false) -> Int {
        let now = TimeUtil.nowMillis()
        lock.lock()
        if !force && now - lastRun < 5 * 60_000 { lock.unlock(); return 0 }
        lastRun = now
        defer { lock.unlock() }
        guard let profile = store.getProfile() else { return 0 }
        recalcAllOnce(store: store, hrLog: hrLog, profile: profile)
        let hrMax = Formulas.hrMax(ageYears: profile.ageYears())

        let readings = hrLog.readings(from: now - 36 * 3_600_000, to: now)
        var per = [Int64: (Int, Int)]()
        for r in readings {
            let k = r.timeMillis / 60_000
            let g = per[k] ?? (0, 0)
            per[k] = (g.0 + r.bpm, g.1 + 1)
        }
        let minutes: [(Int64, Double)] = per.keys.sorted().compactMap { k in
            let g = per[k]!
            return g.1 >= 20 ? (k, Double(g.0) / Double(g.1)) : nil
        }
        let rhr0 = BaselineProvider.compute(store: store).map { Int($0.avgRestingHr) } ?? Formulas.zoneRestingHr()
        let motion = MotionTracker.readMinutes(AppPaths.file(MotionTracker.fileName)).filter { $0.minuteStartUnix * 1000 >= now - 36 * 3_600_000 }
        let naps = Formulas.detectNaps(minutes, motion: motion, rhr: rhr0)
        let found: [(Int64, Int64, Bool)] = Formulas.detectActivities(minutes, hrMax: hrMax).map { ($0.0, $0.1, false) }
            + naps.map { ($0.0, $0.1, true) }
        if found.isEmpty { return 0 }

        let manual = ActivityState.manualStart()
        let existing = store.allSessions()
        let rhr = BaselineProvider.compute(store: store).map { Int($0.avgRestingHr) }
        var saved = 0
        for (m0, m1, nap) in found {
            let start = m0 * 60_000, end = m1 * 60_000 + 59_999
            if now - end < 10 * 60_000 { continue }                       // aún puede seguir
            if let m = manual, m <= end { continue }                       // la manual manda
            if existing.contains(where: { $0.startMillis < end && $0.endMillis > start }) { continue }
            guard let session = ActivityRecorder.summarize(
                hrLog: hrLog, startMillis: start, endMillis: end,
                ageYears: profile.ageYears(), weightKg: profile.weightKg, sex: profile.sex,
                type: nap ? Formulas.napType : "Sin clasificar", autoDetected: true, restingHr: rhr) else { continue }
            var s = session
            if nap { s.strain = 0; s.caloriesKcal = 0 } else { Formulas.updateObservedHrMax(session.maxHr) }
            _ = store.saveSession(s)
            saved += 1
        }
        return saved
    }

    /// Una sola vez tras actualizar (20/10): rehace zonas, calorías y esfuerzo de las actividades guardadas
    /// con las fórmulas nuevas. Mismo inicio, fin y deporte; si no hay pulso, se deja como estaba.
    private static func recalcAllOnce(store: AppStore, hrLog: HrLog, profile: UserProfile) {
        if UserDefaults.standard.integer(forKey: keyRecalc) >= 3 { return }
        if Formulas.bmr() <= 0 {
            Formulas.setBmr(CalorieCalculator.basalMetabolicRate(ageYears: profile.ageYears(), weightKg: profile.weightKg,
                                                                 heightCm: profile.heightCm, sex: profile.sex))
        }
        let rhr = BaselineProvider.compute(store: store).map { Int($0.avgRestingHr) }
        if let r = rhr { Formulas.setZoneRestingHr(r) }
        let importUntil = WhoopImport.importedUntil()
        for old in store.allSessions() {
            // Las importadas de WHOOP se quedan con los números de WHOOP
            if !importUntil.isEmpty && TimeUtil.dayKey(old.startMillis) <= importUntil { continue }
            guard var fresh = ActivityRecorder.summarize(
                hrLog: hrLog, startMillis: old.startMillis, endMillis: old.endMillis,
                ageYears: profile.ageYears(), weightKg: profile.weightKg, sex: profile.sex,
                type: old.type, autoDetected: old.autoDetected, restingHr: rhr) else { continue }
            fresh.id = old.id
            if old.type == Formulas.napType { fresh.strain = 0; fresh.caloriesKcal = 0 }
            store.updateSession(fresh)
        }
        UserDefaults.standard.set(3, forKey: keyRecalc)   // 3 = curva de esfuerzo v2 del 22/10
    }
}
