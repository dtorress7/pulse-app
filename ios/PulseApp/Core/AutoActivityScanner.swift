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
        // Una vez (25/10, igual que Android): se repasan 7 días con la detección nueva (fútbol del 24/10 cortado, paseos, siesta falsa)
        let rescan = UserDefaults.standard.integer(forKey: "pulseapp_act_rescan") < 1
        let windowMs: Int64 = rescan ? 7 * 86_400_000 : 36 * 3_600_000

        let readings = hrLog.readings(from: now - windowMs, to: now)
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
        let minuteSet = Set(minutes.map { $0.0 })
        let rhr0 = BaselineProvider.compute(store: store).map { Int($0.avgRestingHr) } ?? Formulas.zoneRestingHr()
        let motionList = MotionTracker.readMinutes(AppPaths.file(MotionTracker.fileName)).filter { $0.minuteStartUnix * 1000 >= now - windowMs }
        var motion = [Int64: MotionMinute](minimumCapacity: motionList.count)
        for mm in motionList { motion[mm.minuteStartUnix / 60] = mm }
        let naps = Formulas.detectNaps(minutes, motion: motionList, rhr: rhr0)
        let acts = Formulas.detectActivities(minutes, hrMax: hrMax, motion: motion.isEmpty ? nil : motion)
        let walks = Formulas.detectWalks(minutes, motion: motion, hrMax: hrMax)
            .filter { w in !acts.contains { $0.0 <= w.1 && $0.1 >= w.0 } }
        let found: [(Int64, Int64, String)] = acts.map { ($0.0, $0.1, "Sin clasificar") }
            + walks.map { ($0.0, $0.1, Formulas.walkType) } + naps.map { ($0.0, $0.1, Formulas.napType) }

        let manual = ActivityState.manualStart()
        var existing = store.allSessions()
        let rhr = BaselineProvider.compute(store: store).map { Int($0.avgRestingHr) }
        var saved = 0
        if rescan {
            for old in existing where old.autoDetected && old.type == Formulas.napType && old.startMillis >= now - windowMs {
                if !naps.contains(where: { $0.0 * 60_000 <= old.endMillis && $0.1 * 60_000 + 59_999 >= old.startMillis }) {
                    store.deleteSession(id: old.id)
                    existing.removeAll { $0.id == old.id }
                }
            }
        }
        for (m0, m1, type) in found {
            let start = m0 * 60_000, end = m1 * 60_000 + 59_999
            if now - end < 10 * 60_000 { continue }                       // aún puede seguir
            // Un hueco de datos no es el final: ≥ 5 min de pulso en los 10 min siguientes, o que haya pasado ≥ 1 h
            if now - end < 60 * 60_000 && ((m1 + 1)...(m1 + 10)).filter({ minuteSet.contains($0) }).count < 5 { continue }
            if let m = manual, m <= end { continue }                       // la manual manda
            let overlap = existing.filter { $0.startMillis < end && $0.endMillis > start }
            if !overlap.isEmpty {
                // Una automática guardada antes de tener todo el pulso se alarga (no si la has editado tú)
                if type == Formulas.napType || overlap.contains(where: { !$0.autoDetected || $0.type == Formulas.napType }) { continue }
                let oStart = overlap.map { $0.startMillis }.min()!, oEnd = overlap.map { $0.endMillis }.max()!
                let ns = min(start, oStart), ne = max(end, oEnd)
                if ns >= oStart - 60_000 && ne <= oEnd + 60_000 { continue }
                let keep = overlap[0]
                guard var fresh = ActivityRecorder.summarize(
                    hrLog: hrLog, startMillis: ns, endMillis: ne,
                    ageYears: profile.ageYears(), weightKg: profile.weightKg, sex: profile.sex,
                    type: keep.type, autoDetected: true, restingHr: rhr) else { continue }
                fresh.id = keep.id
                store.updateSession(fresh)
                for o in overlap.dropFirst() { store.deleteSession(id: o.id) }
                existing.removeAll { e in overlap.contains { $0.id == e.id } }
                existing.append(fresh)
                Formulas.updateObservedHrMax(fresh.maxHr)
                saved += 1
                continue
            }
            let nap = type == Formulas.napType
            guard let session = ActivityRecorder.summarize(
                hrLog: hrLog, startMillis: start, endMillis: end,
                ageYears: profile.ageYears(), weightKg: profile.weightKg, sex: profile.sex,
                type: type, autoDetected: true, restingHr: rhr) else { continue }
            var s = session
            if nap { s.strain = 0; s.caloriesKcal = 0 } else { Formulas.updateObservedHrMax(session.maxHr) }
            s.id = store.saveSession(s)
            existing.append(s)
            saved += 1
        }
        if rescan { UserDefaults.standard.set(1, forKey: "pulseapp_act_rescan") }
        return saved
    }

    /// Una sola vez tras actualizar (20/10): rehace zonas, calorías y esfuerzo de las actividades guardadas
    /// con las fórmulas nuevas. Mismo inicio, fin y deporte; si no hay pulso, se deja como estaba.
    private static func recalcAllOnce(store: AppStore, hrLog: HrLog, profile: UserProfile) {
        if UserDefaults.standard.integer(forKey: keyRecalc) >= 5 { return }
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
        UserDefaults.standard.set(5, forKey: keyRecalc)   // 5 = esfuerzo v4 del 25/10 (paseos)
    }
}
