import Foundation

/// Todo lo que enseña Inicio con el aspecto de WHOOP (port de HomeData.kt de Android, 17/10), para HOY (en directo)
/// o para un día pasado (con lo guardado). Las fórmulas son las de siempre: aquí solo se reúnen y se comparan
/// con tu media de los 30 días anteriores.
struct DayRecord {
    let date: String                     // yyyy-MM-dd
    var hrv: Double? = nil
    var rhr: Int? = nil
    var resp: Double? = nil
    var sleepMinutes: Int? = nil
    var efficiency: Int? = nil
    var sleepStartMinute: Int? = nil
    var sleepEndMinute: Int? = nil
    var strain: Double? = nil
    var recovery: Int? = nil
    var sleepScore: Int? = nil
    /// Lo que necesitas dormir la noche que empieza ese día.
    var needTonight: Int? = nil
    /// Deuda de sueño tras la noche que termina ese día.
    var debt: Int? = nil
    var consistency: Int? = nil
    var steps: Int? = nil
    var kcal: Double? = nil
    var vo2: Double? = nil
    // Sueño de esa noche: fases (si hubo movimiento), despertares, latencia, tiempo en cama
    var light: Int? = nil
    var deep: Int? = nil
    var rem: Int? = nil
    var awake: Int? = nil
    var wakeEpisodes: Int? = nil
    var latency: Int? = nil
    var inBed: Int? = nil
    /// Lo que necesitabas la noche que termina ese día y de dónde sale (base + esfuerzo de la víspera + deuda).
    var needLastNight: Int? = nil
    var needBase: Int? = nil
    var needStrainAdj: Int? = nil
    var needDebtAdj: Int? = nil
    // Esfuerzo de ese día
    var strengthMinutes: Int = 0
    var zones: ZoneDay? = nil

    init(date: String) { self.date = date }

    /// Sueño reparador = profundo + REM.
    var restorative: Int? {
        if let d = deep, let r = rem { return d + r }
        return nil
    }
    var hoursVsNeedPct: Int? {
        guard let s = sleepMinutes, let n = needLastNight else { return nil }
        return min(s * 100 / max(n, 1), 100)
    }
}

enum Trend { case up, down, same }

/// Fila de "Mi panel de control": good true = verde, false = naranja, nil = gris.
struct PanelRow {
    let key: String
    let label: String
    let icon: String
    let value: String
    let average: String?
    let trend: Trend?
    let good: Bool?
}

/// Señal del Monitor de salud con su rango habitual. ok nil = aún sin rango (menos de 3 noches).
struct VitalStatus {
    let key: String
    let label: String
    let icon: String
    let value: Double?
    let unit: String
    let decimals: Int
    let lo: Double?
    let hi: Double?
    let goodWhenHigh: Bool
    let ok: Bool?
}

struct WeekPoint {
    let date: String
    let strain: Double?
    let recovery: Int?
}

struct HomeData {
    var date: String
    var isToday: Bool
    var summary: DailySummary?
    var day: DayRecord
    var vitals: [VitalStatus]
    var healthOk: Int
    var healthTotal: Int
    var stressScore: Float?
    var stressLevel: String
    var stressMinute: Int?
    var stressSeries: [StressPoint]
    var stressFrom: Int64
    var stressTo: Int64
    var sleepFromMillis: Int64?
    var sleepToMillis: Int64?
    var sessions: [ActivitySession]
    var bedtime: String?
    var wakeMinute: Int
    var panel: [PanelRow]
    var week: [WeekPoint]
    var streak: Int
    var insight: String
    var baselineReady: Bool
    var profileMissing: Bool
    /// Todos los días con datos (hasta 40 antes + el elegido), de más antiguo a más reciente.
    var records: [DayRecord]
    /// Estrés durante la noche que termina ese día.
    var sleepStressSeries: [StressPoint]
    /// Fases minuto a minuto de esa noche (solo hoy, si hubo movimiento).
    var stages: SleepStager.Result?
    /// Pulso de la noche (lecturas de la ventana de sueño ± 10 min), para la gráfica de Sueño.
    var nightReadings: [HrReading]
}

enum PanelKeys {
    static let hrv = "hrv", rhr = "rhr", steps = "steps", z13 = "z13", z45 = "z45"
    static let strength = "strength", vo2 = "vo2", kcal = "kcal", stress = "stress_card"
    static let strainRecovery = "strain_recovery_card", regularity = "regularity", need = "need"
    static let strain = "strain", efficiency = "efficiency", sleepScore = "sleep_score", debt = "debt"

    /// Orden y nombres tal como salen en WHOOP.
    static let all: [(String, String)] = [
        (hrv, "Variabilidad de la frecuencia cardíaca"), (rhr, "Frecuencia cardíaca en reposo"), (steps, "Pasos"),
        (z13, "Zonas de FC 1-3 (semanal)"), (z45, "Zonas de FC 4-5 (semanal)"), (strength, "Tiempo de actividad de fuerza"),
        (vo2, "VO₂ máx"), (kcal, "Calorías"), (stress, "Monitor de estrés"), (strainRecovery, "Esfuerzo y recuperación"),
        (regularity, "Regularidad del sueño"), (need, "Sueño necesario"), (strain, "Esfuerzo del día"),
        (efficiency, "Eficiencia del sueño"), (sleepScore, "Calificación del sueño"), (debt, "Deuda de sueño")
    ]

    private static let hiddenKey = "pulseapp_panel_hidden"
    static func hidden() -> Set<String> {
        return Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }
    static func setHidden(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys), forKey: hiddenKey)
    }
}

/// Días como "yyyy-MM-dd" (hora local).
enum Day {
    static func start(_ key: String) -> Int64 { return TimeUtil.parseDayKey(key) ?? 0 }
    static func add(_ key: String, _ days: Int) -> String { return TimeUtil.dayKey(TimeUtil.addDays(start(key) + 12 * 3_600_000, days)) }
    static func today() -> String { return TimeUtil.dayKey(TimeUtil.nowMillis()) }
    static func weekdayIndex(_ key: String) -> Int { return TimeUtil.parts(start(key) + 12 * 3_600_000).weekday - 1 }   // 0 = lunes
    static func dayOfMonth(_ key: String) -> Int { return TimeUtil.parts(start(key) + 12 * 3_600_000).day }
    static func month(_ key: String) -> Int { return TimeUtil.parts(start(key) + 12 * 3_600_000).month }
}

enum HomeDataLoader {

    /// Calcula Inicio para hoy + [dayOffset] (0 = hoy, −1 = ayer…). Puede tardar: llamar fuera del hilo principal.
    static func load(dayOffset: Int) -> HomeData {
        let store = AppStore.shared
        let hrLog = WhoopManager.shared.hrLog
        let profile = store.getProfile()
        let age = profile?.ageYears() ?? 30
        let male = profile?.sex != "F"
        // Para las zonas (reserva de FC) y las calorías de las actividades: FC en reposo de tus noches y metabolismo basal
        if let p = profile {
            Formulas.setBmr(CalorieCalculator.basalMetabolicRate(ageYears: p.ageYears(), weightKg: p.weightKg, heightCm: p.heightCm, sex: p.sex))
        }
        if let b = BaselineProvider.compute(store: store) { Formulas.setZoneRestingHr(Int(b.avgRestingHr.rounded())) }
        let hrMax = Formulas.hrMax(ageYears: age)
        let motionFile = AppPaths.file(MotionTracker.fileName)

        let now = TimeUtil.nowMillis()
        let today = Day.today()
        let date = Day.add(today, min(dayOffset, 0))
        let isToday = date == today
        let dayStart = Day.start(date)
        let dayEnd = Day.start(Day.add(date, 1))

        let summary: DailySummary? = isToday ? MetricsCalculator(ageYears: age, male: male).analyze(hrLog: hrLog) : nil

        // Tras actualizar (23/10): rehace una vez las noches guardadas con la VFC y la recuperación nuevas
        if isToday {
            DailyMetricsUpdater.recalcPastNightsOnce(store: store, hrLog: hrLog, motionFile: motionFile, ageYears: age,
                                                     weightKg: profile?.weightKg ?? 75, sex: profile?.sex ?? "M")
        }
        // Días guardados (la fila D = noche que termina D + esfuerzo de D), de más antiguo a más reciente
        let stored = store.lastDays(80).sorted { $0.date < $1.date }
        var byDate = [String: DailyMetrics]()
        for d in stored { byDate[d.date] = d }
        if isToday { AutoActivityScanner.scan(store: store, hrLog: hrLog) }
        let allSessions = store.allSessions()
        let stepsByDay = stepsPerDay(motionFile)
        let zoneDays = ZoneDayCache.load(hrUrl: hrLog.url, hrMax: hrMax, today: today, days: 40)
        let base = SleepPlanner.baselineForAge(profile?.ageYears())
        let wake = SleepPlanner.wakeMinute()

        func rowsBefore(_ d: String) -> [DailyMetrics] { return stored.filter { $0.date < d } }
        func kcalFor(_ d: String, _ elapsed: Double) -> Double? {
            guard let p = profile else { return nil }
            let s = Day.start(d), e = Day.start(Day.add(d, 1))
            let act = allSessions.filter { $0.startMillis >= s && $0.startMillis < e }.reduce(0.0) { $0 + $1.caloriesKcal }
            return CalorieCalculator.estimateDailyTotal(elapsedMinutesToday: elapsed, activityKcalToday: act,
                                                        ageYears: p.ageYears(), weightKg: p.weightKg, heightCm: p.heightCm, sex: p.sex)
        }
        func strengthOf(_ d: String) -> Int {
            let s = Day.start(d), e = Day.start(Day.add(d, 1))
            return allSessions.filter { $0.type.lowercased().contains("fuerza") && $0.startMillis >= s && $0.startMillis < e }
                .reduce(0) { $0 + Int(($1.endMillis - $1.startMillis) / 60_000) }
        }

        /// Día guardado → el mismo cálculo que hizo Inicio ese día (línea base, necesidad y regularidad de los días anteriores).
        func recordFromStored(_ d: String, _ row: DailyMetrics) -> DayRecord {
            let before = rowsBefore(d)
            let last7 = Array(before.suffix(7))
            let baseline = BaselineProvider.computeFrom(Array(before.reversed()))
            var r = DayRecord(date: d)
            // Días importados de WHOOP (23/10): se muestran las notas oficiales de WHOOP; si no, las calcula PulseApp
            if let w = row.whoopRecovery {
                r.recovery = w
            } else if row.avgHrv != nil || row.restingHr != nil {
                r.recovery = Formulas.recovery(hrv: row.avgHrv, restingHr: row.restingHr, respiratoryRate: row.respiratoryRate, baseline: baseline).total
            }
            let prevStrain = byDate[Day.add(d, -1)]?.strain
            let debtBefore = SleepPlanner.debtFrom(Array(before.suffix(14)), base: base)
            let strainAdj = Formulas.sleepNeedFromStrain(prevStrain ?? 0)
            let needLastNight = row.whoopSleepNeed ?? (base + strainAdj + debtBefore)
            // Regularidad de esa noche: ella y las 3 anteriores
            let consistency = row.whoopConsistency ?? Formulas.sleepConsistency(HomeDataLoader.nights(last7 + [row]))
            if let w = row.whoopSleepScore {
                r.sleepScore = w
            } else if let m = row.sleepMinutes {
                r.sleepScore = Formulas.sleepScore(hoursVsNeedPct: min(m * 100 / max(needLastNight, 1), 100),
                                                   efficiencyPct: row.sleepEfficiencyPct, consistencyPct: consistency)
            }
            r.hrv = row.avgHrv; r.rhr = row.restingHr; r.resp = row.respiratoryRate
            r.sleepMinutes = row.sleepMinutes; r.efficiency = row.sleepEfficiencyPct
            r.sleepStartMinute = row.sleepStartMinuteOfDay; r.sleepEndMinute = row.sleepEndMinuteOfDay
            r.strain = row.strain
            let debtAfter = SleepPlanner.nextDebt(debtBefore, base: base, prevDayStrain: prevStrain, slept: row.sleepMinutes)
            r.needTonight = base + Formulas.sleepNeedFromStrain(row.strain ?? 0) + debtAfter
            r.debt = debtAfter
            r.consistency = consistency
            if let st = stepsByDay[d], st > 0 { r.steps = st }
            r.kcal = kcalFor(d, 1440)
            r.vo2 = row.vo2Max
            r.light = row.lightMinutes; r.deep = row.deepMinutes; r.rem = row.remMinutes; r.awake = row.awakeMinutes
            r.wakeEpisodes = row.wakeEpisodes; r.latency = row.latencyMinutes
            if let s = row.sleepStartMinuteOfDay, let e = row.sleepEndMinuteOfDay { r.inBed = (e - s + 1440) % 1440 }
            r.needLastNight = needLastNight; r.needBase = base; r.needStrainAdj = strainAdj; r.needDebtAdj = debtBefore
            r.strengthMinutes = strengthOf(d)
            r.zones = zoneDays[d]
            return r
        }

        // ---------- Hoy en directo ----------
        var todayRecord: DayRecord? = nil
        var bedtime: String? = nil
        if isToday, let s = summary {
            let baseline = BaselineProvider.compute(store: store)
            var r = DayRecord(date: date)
            if s.avgHrv != nil || s.restingHr != nil {
                r.recovery = RecoveryCalculator.breakdown(nightlyHrv: s.avgHrv, restingHr: s.restingHr, baseline: baseline,
                                                          respiratoryRate: s.respiratoryRate).total
            }
            let lastPlan = SleepPlanner.planForLastNight(store: store, summary: s)
            // Deuda tras la noche de hoy: la mitad de lo que faltó para la necesidad de esa noche
            var debtAfter = lastPlan.debtAdjustmentMinutes
            if let m = s.sleepMinutes { debtAfter = max(Int((Double(lastPlan.totalNeedMinutes - m) / 2).rounded()), 0) }
            // Día con fuerza/funcional: WHOOP suma carga muscular al esfuerzo del día (22/10)
            let strengthMin = allSessions.filter { $0.startMillis >= dayStart && $0.startMillis < dayEnd && Formulas.isStrength($0.type) }
                .reduce(0.0) { $0 + Double($1.endMillis - $1.startMillis) / 60000.0 }
            let dayStrain = Formulas.addStrength(s.strain, strengthMin)
            let plan = SleepPlanner.computeTonightPlan(store: store, todayStrain: dayStrain, wakeHour: wake / 60, wakeMinute: wake % 60,
                                                       debtOverride: debtAfter)
            bedtime = plan.suggestedBedtime
            var consistency: Int? = nil
            if let a = s.sleepStartMinuteOfDay, let b = s.sleepEndMinuteOfDay {
                consistency = Formulas.sleepConsistency(HomeDataLoader.nights(Array(stored.filter { $0.date < date }.suffix(3))) + [(a, b)])
            }
            if let m = s.sleepMinutes {
                r.sleepScore = Formulas.sleepScore(hoursVsNeedPct: min(m * 100 / max(lastPlan.totalNeedMinutes, 1), 100),
                                                   efficiencyPct: s.sleepEfficiencyPct, consistencyPct: consistency)
            }
            r.debt = debtAfter
            // VO2 máx estable: se recalcula solo los martes (o si nunca se ha calculado)
            let isTuesday = TimeUtil.parts(now).weekday == 2
            if var p = profile, (isTuesday || p.vo2Max == nil), let v = s.vo2Max {
                p.vo2Max = v
                p.vo2MaxUpdatedDate = date
                store.saveProfile(p)
                r.vo2 = v
            } else {
                r.vo2 = profile?.vo2Max ?? s.vo2Max
            }
            r.hrv = s.avgHrv; r.rhr = s.restingHr; r.resp = s.respiratoryRate
            r.sleepMinutes = s.sleepMinutes; r.efficiency = s.sleepEfficiencyPct
            r.sleepStartMinute = s.sleepStartMinuteOfDay; r.sleepEndMinute = s.sleepEndMinuteOfDay
            r.strain = dayStrain
            r.needTonight = plan.totalNeedMinutes
            r.consistency = consistency
            let live = Steps.today(live: WhoopManager.shared.stepsToday)
            if live > 0 { r.steps = live }
            r.kcal = kcalFor(date, Double(TimeUtil.minuteOfDay(now)))
            if let st = s.stages {
                r.light = st.lightMinutes; r.deep = st.deepMinutes; r.rem = st.remMinutes; r.awake = st.awakeMinutes
                r.wakeEpisodes = st.awakenings
                if let rs = s.restStartMillis { r.latency = max(Int((st.startMillis - rs) / 60_000), 0) }
                r.inBed = st.minutes
            } else {
                r.awake = s.awakeMinutes
                r.inBed = s.timeInBedMinutes
            }
            r.needLastNight = lastPlan.totalNeedMinutes; r.needBase = lastPlan.baselineMinutes
            r.needStrainAdj = lastPlan.strainAdjustmentMinutes; r.needDebtAdj = lastPlan.debtAdjustmentMinutes
            r.strengthMinutes = strengthOf(date)
            r.zones = zoneDays[date]
            todayRecord = r
        }

        // Registros de los 40 días anteriores + el día elegido
        var records = [String: DayRecord]()
        for i in stride(from: 40, through: 1, by: -1) {
            let d = Day.add(date, -i)
            if let row = byDate[d] { records[d] = recordFromStored(d, row) }
        }
        var day: DayRecord
        if let t = todayRecord {
            day = t
        } else if let row = byDate[date] {
            day = recordFromStored(date, row)
        } else {
            day = DayRecord(date: date)
            if let st = stepsByDay[date], st > 0 { day.steps = st }
            day.strengthMinutes = strengthOf(date)
            day.zones = zoneDays[date]
        }
        records[date] = day
        let monthAgo = Day.add(date, -30)
        let previous = records.values.filter { $0.date < date && $0.date >= monthAgo }.sorted { $0.date < $1.date }

        // Ventana de sueño de la noche que termina ese día
        var sleepFrom: Int64? = nil
        var sleepTo: Int64? = nil
        if isToday, let s = summary, let ss = s.sleepStartMillis, let se = s.sleepEndMillis {
            sleepFrom = s.stages?.startMillis ?? ss
            sleepTo = s.stages?.endMillis ?? se
        } else if let s = day.sleepStartMinute, let e = day.sleepEndMinute {
            sleepTo = dayStart + Int64(e) * 60_000
            sleepFrom = s > e ? dayStart - Int64(1440 - s) * 60_000 : dayStart + Int64(s) * 60_000
        }

        // ---------- Estrés del día (00:00 → ahora, como WHOOP) ----------
        let baselineNow = BaselineProvider.compute(store: store)
        var loadFrom = dayStart
        if let f = sleepFrom { loadFrom = min(loadFrom, f - 15 * 60_000) }
        if isToday { loadFrom = min(loadFrom, now - 86_400_000) }
        let loadTo = isToday ? now + 60_000 : max(dayEnd, (sleepTo ?? dayEnd) + 15 * 60_000)
        let samples = hrLog.readings(from: loadFrom, to: loadTo)
        var sleepStress = [StressPoint]()
        var nightReadings = [HrReading]()
        if let f = sleepFrom, let t = sleepTo {
            sleepStress = StressCalculator.seriesBetween(samples, from: f, to: t, baseline: baselineNow)
            nightReadings = samples.filter { $0.timeMillis >= f - 10 * 60_000 && $0.timeMillis <= t + 10 * 60_000 }
        }
        let stressTo = isToday ? now : dayEnd
        let series = StressCalculator.seriesBetween(samples, from: dayStart, to: stressTo, baseline: baselineNow)
        let current: StressPoint? = isToday ? StressCalculator.seriesBetween(samples, from: now - 86_400_000, to: now, baseline: baselineNow).last : nil
        let lastPoint = (current ?? series.last)?.score
        let lastMinute = (current ?? series.last)?.minuteOfDay
        var level = "ALTO"
        if lastPoint == nil || lastPoint! < 1 { level = "BAJO" } else if lastPoint! < 2 { level = "MEDIO" }

        // ---------- Monitor de salud ----------
        let twoWeeks = Day.add(date, -14)
        let hist = records.values.filter { $0.date < date && $0.date >= twoWeeks }
        let vitals = [
            vital("resp", "Frecuencia respiratoria", "lungs.fill", day.resp, "rpm", 1,
                  hist.filter { BaselineProvider.sameScale($0.date) }.compactMap { $0.resp }, goodWhenHigh: false),
            vital("rhr", "FCR", "heart.fill", day.rhr.map { Double($0) }, "lpm", 0,
                  hist.compactMap { $0.rhr.map { Double($0) } }, goodWhenHigh: false),
            vital("hrv", "VFC", "waveform.path.ecg", day.hrv, "ms", 0,
                  hist.filter { BaselineProvider.sameScale($0.date) }.compactMap { $0.hrv }, goodWhenHigh: true)
        ]
        let withRange = vitals.filter { $0.ok != nil }
        let healthOk = withRange.filter { $0.ok == true }.count

        // ---------- Mi panel de control ----------
        var panel = [PanelRow]()
        func avgOf(_ v: [Double]) -> Double? { return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        func add(_ key: String, _ icon: String, _ value: Double?, _ avg: Double?, _ goodWhenHigh: Bool?, _ fmt: (Double) -> String, _ tol: Double) {
            let label = (PanelKeys.all.first { $0.0 == key }?.1 ?? key).uppercased()
            var trend: Trend? = nil
            if let v = value, let a = avg { trend = abs(v - a) <= tol ? .same : (v > a ? .up : .down) }
            var good: Bool? = nil
            if let t = trend, t != .same, let g = goodWhenHigh { good = (t == .up) == g }
            panel.append(PanelRow(key: key, label: label, icon: icon, value: value.map(fmt) ?? "--", average: avg.map(fmt), trend: trend, good: good))
        }
        let hm: (Double) -> String = { Fmt.hm(Int($0.rounded())) }
        let int0: (Double) -> String = { String(format: "%.0f", $0) }
        let pct: (Double) -> String = { String(format: "%.0f %%", $0) }
        let thousands: (Double) -> String = { Fmt.thousands(Int64($0.rounded())) }
        add(PanelKeys.hrv, "waveform.path.ecg", day.hrv, avgOf(previous.filter { BaselineProvider.sameScale($0.date) }.compactMap { $0.hrv }), true, int0, 0.5)
        add(PanelKeys.rhr, "heart.fill", day.rhr.map { Double($0) }, avgOf(previous.compactMap { $0.rhr.map { Double($0) } }), false, int0, 0.5)
        add(PanelKeys.steps, "figure.walk", day.steps.map { Double($0) }, avgOf(previous.compactMap { $0.steps.map { Double($0) } }), true, thousands, 0.5)

        // Zonas de FC semanales (7 días hasta ese día) frente a la media semanal de las 4 semanas anteriores
        func zoneWeek(_ end: String, _ pick: (ZoneDay) -> Int) -> Double? {
            let days = (0...6).compactMap { zoneDays[Day.add(end, -$0)] }
            return days.isEmpty ? nil : Double(days.reduce(0) { $0 + pick($1) }) / 60.0
        }
        func zoneAvgWeek(_ end: String, _ pick: (ZoneDay) -> Int) -> Double? {
            let days = (7...34).compactMap { zoneDays[Day.add(end, -$0)] }.filter { $0.totalSeconds >= 3600 }
            return days.count < 3 ? nil : Double(days.reduce(0) { $0 + pick($1) }) / 60.0 / Double(days.count) * 7
        }
        add(PanelKeys.z13, "heart.circle", zoneWeek(date) { $0.z13Seconds }, zoneAvgWeek(date) { $0.z13Seconds }, true, hm, 0.5)
        add(PanelKeys.z45, "bolt.heart.fill", zoneWeek(date) { $0.z45Seconds }, zoneAvgWeek(date) { $0.z45Seconds }, true, hm, 0.5)

        // Fuerza: actividades de tipo "fuerza" de los últimos 7 días frente a la media semanal de las 4 anteriores
        let strength = allSessions.filter { $0.type.lowercased().contains("fuerza") }
        func strengthMinutes(_ from: String, _ toExclusive: String) -> Double {
            let s = Day.start(from), e = Day.start(toExclusive)
            return strength.filter { $0.startMillis >= s && $0.startMillis < e }.reduce(0.0) { $0 + Double($1.endMillis - $1.startMillis) / 60000.0 }
        }
        let hasHistory = previous.count >= 7
        add(PanelKeys.strength, "dumbbell.fill", strengthMinutes(Day.add(date, -6), Day.add(date, 1)),
            hasHistory ? strengthMinutes(Day.add(date, -34), Day.add(date, -6)) / 4.0 : nil, true, hm, 0.5)
        add(PanelKeys.vo2, "lungs.fill", day.vo2, avgOf(previous.compactMap { $0.vo2 }), true, int0, 0.5)
        add(PanelKeys.kcal, "flame", day.kcal, avgOf(previous.compactMap { $0.kcal }), nil, thousands, 0.5)
        add(PanelKeys.regularity, "clock.arrow.circlepath", day.consistency.map { Double($0) },
            avgOf(previous.compactMap { $0.consistency.map { Double($0) } }), true, pct, 0.5)
        add(PanelKeys.need, "bed.double.fill", day.needTonight.map { Double($0) },
            avgOf(previous.compactMap { $0.needTonight.map { Double($0) } }), false, hm, 0.5)
        add(PanelKeys.strain, "flame.fill", day.strain, avgOf(previous.compactMap { $0.strain }), true, { Fmt.comma($0) }, 0.05)
        add(PanelKeys.efficiency, "chart.bar.fill", day.efficiency.map { Double($0) },
            avgOf(previous.compactMap { $0.efficiency.map { Double($0) } }), true, pct, 0.5)
        add(PanelKeys.sleepScore, "moon", day.sleepScore.map { Double($0) },
            avgOf(previous.compactMap { $0.sleepScore.map { Double($0) } }), true, pct, 0.5)
        add(PanelKeys.debt, "hourglass", day.debt.map { Double($0) }, avgOf(previous.compactMap { $0.debt.map { Double($0) } }), false, hm, 0.5)

        // ---------- Esfuerzo y recuperación: 7 días ----------
        let week = stride(from: 6, through: 0, by: -1).map { i -> WeekPoint in
            let d = Day.add(date, -i)
            let r = records[d]
            return WeekPoint(date: d, strain: r?.strain, recovery: r?.recovery)
        }

        // ---------- Racha: días seguidos llevando la pulsera (≥ 1 h de pulso) ----------
        var streak = 0
        var cursor = ((zoneDays[date]?.totalSeconds ?? 0) >= 3600 || !isToday) ? date : Day.add(date, -1)
        while (zoneDays[cursor]?.totalSeconds ?? 0) >= 3600 { streak += 1; cursor = Day.add(cursor, -1) }

        let sessionsOfDay = allSessions.filter { $0.startMillis >= dayStart && $0.startMillis < dayEnd }.sorted { $0.startMillis < $1.startMillis }

        return HomeData(
            date: date, isToday: isToday, summary: summary, day: day,
            vitals: vitals, healthOk: healthOk, healthTotal: withRange.count,
            stressScore: lastPoint, stressLevel: level, stressMinute: lastMinute, stressSeries: series,
            stressFrom: dayStart, stressTo: stressTo, sleepFromMillis: sleepFrom, sleepToMillis: sleepTo,
            sessions: sessionsOfDay, bedtime: bedtime, wakeMinute: wake, panel: panel, week: week, streak: streak,
            insight: Insight.build(day: day, previous: previous, isToday: isToday, baselineReady: baselineNow != nil),
            baselineReady: baselineNow != nil, profileMissing: profile == nil,
            records: records.values.sorted { $0.date < $1.date }, sleepStressSeries: sleepStress,
            stages: isToday ? summary?.stages : nil, nightReadings: nightReadings)
    }

    /// (inicio, fin) de las noches guardadas que tienen las dos horas.
    static func nights(_ rows: [DailyMetrics]) -> [(Int, Int)] {
        return rows.compactMap { r -> (Int, Int)? in
            guard let a = r.sleepStartMinuteOfDay, let b = r.sleepEndMinuteOfDay else { return nil }
            return (a, b)
        }
    }

    /// Rango habitual = media ± 1 desviación (mínimo ±5 % de la media). nil con menos de 3 noches.
    private static func vital(_ key: String, _ label: String, _ icon: String, _ value: Double?, _ unit: String, _ decimals: Int,
                              _ history: [Double], goodWhenHigh: Bool) -> VitalStatus {
        guard history.count >= BaselineProvider.minDaysRequired, let v = value else {
            return VitalStatus(key: key, label: label, icon: icon, value: value, unit: unit, decimals: decimals,
                               lo: nil, hi: nil, goodWhenHigh: goodWhenHigh, ok: nil)
        }
        let mean = history.reduce(0, +) / Double(history.count)
        var sq = 0.0
        for h in history { sq += (h - mean) * (h - mean) }
        let sd = (sq / Double(history.count)).squareRoot()
        let half = max(sd, mean * 0.05)
        let lo = mean - half, hi = mean + half
        // Como WHOOP: fuera del rango hacia el lado bueno (VFC alta, FCR o respiración baja) sigue contando como bien
        let ok = (v >= lo && v <= hi) || (goodWhenHigh && v > hi) || (!goodWhenHigh && v < lo)
        return VitalStatus(key: key, label: label, icon: icon, value: v, unit: unit, decimals: decimals,
                           lo: lo, hi: hi, goodWhenHigh: goodWhenHigh, ok: ok)
    }

    private static func stepsPerDay(_ file: URL) -> [String: Int] {
        var out = [String: Int]()
        for m in MotionTracker.readMinutes(file) {
            out[TimeUtil.dayKey(m.minuteStartUnix * 1000), default: 0] += m.steps
        }
        return out
    }
}

/// Segundos con pulso de un día y segundos en zonas 1–5 (por % de la FC máx, como las zonas de la app).
struct ZoneDay {
    let totalSeconds: Int, z1: Int, z2: Int, z3: Int, z4: Int, z5: Int
    var z13Seconds: Int { return z1 + z2 + z3 }
    var z45Seconds: Int { return z4 + z5 }
}

/// Tiempo por zonas de cada día sacado de hr_log.csv en UNA pasada (sin cargar las lecturas en memoria), con caché de los
/// días cerrados (zone_days.csv). Hoy y los 2 días anteriores siempre se recalculan. Si cambia la FC máx se rehace todo.
enum ZoneDayCache {
    private static let lock = NSLock()

    static func load(hrUrl: URL, hrMax: Double, today: String, days: Int) -> [String: ZoneDay] {
        lock.lock(); defer { lock.unlock() }
        let cacheUrl = AppPaths.file("zone_days.csv")
        var result = [String: ZoneDay]()
        let zb = Formulas.zoneBounds(hrMax: hrMax)
        let header = "v3,zonas=" + zb.map { String($0) }.joined(separator: "/")
        if let text = try? String(contentsOf: cacheUrl, encoding: .utf8) {
            let lines = text.split(separator: "\n")
            if lines.first.map(String.init) == header {
                for l in lines.dropFirst() {
                    let p = l.split(separator: ",")
                    if p.count == 7, let a = Int(p[1]), let b = Int(p[2]), let c = Int(p[3]), let d = Int(p[4]), let e = Int(p[5]), let f = Int(p[6]) {
                        result[String(p[0])] = ZoneDay(totalSeconds: a, z1: b, z2: c, z3: d, z4: e, z5: f)
                    }
                }
            }
        }
        let recent = Day.add(today, -3)
        var wanted = Set<String>()
        for i in 0...days {
            let d = Day.add(today, -i)
            if d > recent || result[d] == nil { wanted.insert(d) }
        }
        if wanted.isEmpty || !FileManager.default.fileExists(atPath: hrUrl.path) { return result }

        // Por día: zona+1 de cada segundo (0 = sin dato), 86 400 bytes por día
        var secs = [String: [UInt8]]()
        let wantedBytes = Dictionary(uniqueKeysWithValues: wanted.map { (Array($0.utf8), $0) })
        WhoopManager.shared.hrLog.flush()
        guard let handle = try? FileHandle(forReadingFrom: hrUrl) else { return result }
        defer { try? handle.close() }
        var carry = [UInt8]()
        while true {
            guard let data = try? handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            var bytes = carry
            bytes.append(contentsOf: data)
            var lineStart = 0
            let n = bytes.count
            var i = 0
            while i < n {
                if bytes[i] == 10 {
                    parse(bytes, lineStart, i, wantedBytes, zb, &secs)
                    lineStart = i + 1
                }
                i += 1
            }
            carry = lineStart < n ? Array(bytes[lineStart..<n]) : []
        }
        for d in wanted {
            if let arr = secs[d] {
                var c = [Int](repeating: 0, count: 7)
                for v in arr { c[Int(v)] += 1 }
                let total = 86400 - c[0]
                result[d] = ZoneDay(totalSeconds: total, z1: c[2], z2: c[3], z3: c[4], z4: c[5], z5: c[6])
            } else {
                result[d] = ZoneDay(totalSeconds: 0, z1: 0, z2: 0, z3: 0, z4: 0, z5: 0)
            }
        }
        // Guarda solo días cerrados hace ≥ 3 días y con datos: el historial de la pulsera puede llegar tarde
        var out = header + "\n"
        let oldest = Day.add(today, -days)
        for d in result.keys.sorted() {
            guard let z = result[d], d <= recent, d >= oldest, z.totalSeconds > 0 else { continue }
            out += "\(d),\(z.totalSeconds),\(z.z1),\(z.z2),\(z.z3),\(z.z4),\(z.z5)\n"
        }
        try? out.write(to: cacheUrl, atomically: true, encoding: .utf8)
        return result
    }

    private static func parse(_ b: [UInt8], _ s: Int, _ e: Int, _ wanted: [[UInt8]: String], _ zb: [Int], _ secs: inout [String: [UInt8]]) {
        if e - s < 21 || b[s + 10] != 84 { return }          // 'T'
        guard let day = wanted[Array(b[s..<(s + 10)])] else { return }
        func d2(_ o: Int) -> Int { return Int(b[o] &- 48) * 10 + Int(b[o + 1] &- 48) }
        let h = d2(s + 11), m = d2(s + 14), sec = d2(s + 17)
        if h > 23 || m > 59 || sec > 59 || b[s + 19] != 44 { return }
        var i = s + 20
        var bpm = 0
        var digits = 0
        while i < e && b[i] >= 48 && b[i] <= 57 { bpm = bpm * 10 + Int(b[i] - 48); i += 1; digits += 1 }
        if digits == 0 || bpm <= 0 || bpm > 250 { return }
        let z = UInt8(Formulas.zoneOf(bpm, zb) + 1)
        let idx = h * 3600 + m * 60 + sec
        if secs[day] == nil { secs[day] = [UInt8](repeating: 0, count: 86400) }
        secs[day]![idx] = z
    }
}

/// "Perspectiva diaria": texto corto con lo más importante del día, hecho con tus propios datos.
enum Insight {
    static func build(day: DayRecord, previous: [DayRecord], isToday: Bool, baselineReady: Bool) -> String {
        var parts = [String]()
        if let rec = day.recovery {
            if rec >= 67 { parts.append("Recuperación en verde (\(rec) %): tu cuerpo está preparado para un día exigente.") }
            else if rec >= 34 { parts.append("Recuperación en amarillo (\(rec) %): puedes entrenar, pero sin pasarte.") }
            else { parts.append("Recuperación en rojo (\(rec) %): hoy toca priorizar el descanso.") }
            let target = rec >= 67 ? "14 y 18" : rec >= 34 ? "10 y 14" : "0 y 10"
            parts.append("Esfuerzo recomendado para \(isToday ? "hoy" : "ese día"): entre \(target).")
        }
        let hrvs = previous.compactMap { $0.hrv }
        if let h = day.hrv, hrvs.count >= 3 {
            let avg = hrvs.reduce(0, +) / Double(hrvs.count)
            let diff = (h / avg - 1) * 100
            if diff >= 5 { parts.append(String(format: "Tu VFC (%.0f ms) está un %.0f %% por encima de tu media.", h, diff)) }
            else if diff <= -5 { parts.append(String(format: "Tu VFC (%.0f ms) está un %.0f %% por debajo de tu media.", h, -diff)) }
            else { parts.append(String(format: "Tu VFC (%.0f ms) está en tu media.", h)) }
        }
        let rhrs = previous.compactMap { $0.rhr }
        if let r = day.rhr, rhrs.count >= 3 {
            let d = Double(r) - Double(rhrs.reduce(0, +)) / Double(rhrs.count)
            if d >= 2 { parts.append(String(format: "La FC en reposo (%d lpm) sube %.0f lpm sobre lo normal.", r, d)) }
            else if d <= -2 { parts.append(String(format: "La FC en reposo (%d lpm) baja %.0f lpm respecto a lo normal.", r, -d)) }
        }
        if let m = day.sleepMinutes {
            parts.append("Dormiste \(Fmt.hm(m))" + (day.sleepScore.map { " (calificación \($0) %)" } ?? "") + ".")
        }
        if let debt = day.debt, debt >= 30 { parts.append("Arrastras \(Fmt.hm(debt)) de deuda de sueño.") }
        if !baselineReady { parts.append("Aún estoy aprendiendo tu línea base: con 3 noches más los números serán más tuyos.") }
        if parts.isEmpty { return "Todavía no hay datos suficientes de este día. Lleva la pulsera puesta y vuelve más tarde." }
        return parts.joined(separator: " ")
    }
}

/// Reparto del estrés en minutos (bajo < 1, medio 1–2, alto ≥ 2) como el Monitor de estrés de WHOOP:
/// DÍA TOTAL, SIN ACTIVIDAD (fuera del sueño y de las actividades) y SUEÑO. Cada punto de la serie son 5 min.
enum StressBreakdown {
    struct Mins {
        let low: Int, mid: Int, high: Int
        var total: Int { return low + mid + high }
    }
    struct DayMins { let total: Mins, noActivity: Mins, sleep: Mins }

    static func of(_ points: [StressPoint], sleep: [ClosedRange<Int64>], activities: [ClosedRange<Int64>]) -> DayMins {
        var t = [0, 0, 0], n = [0, 0, 0], s = [0, 0, 0]
        for p in points {
            let center = p.timeMillis + 5 * 30_000
            let level = p.score < 1 ? 0 : (p.score < 2 ? 1 : 2)
            t[level] += 5
            if sleep.contains(where: { $0.contains(center) }) { s[level] += 5 }
            else if !activities.contains(where: { $0.contains(center) }) { n[level] += 5 }
        }
        return DayMins(total: Mins(low: t[0], mid: t[1], high: t[2]), noActivity: Mins(low: n[0], mid: n[1], high: n[2]),
                       sleep: Mins(low: s[0], mid: s[1], high: s[2]))
    }

    static func average(_ days: [DayMins]) -> DayMins? {
        if days.isEmpty { return nil }
        func avg(_ pick: (DayMins) -> Mins) -> Mins {
            let c = Double(days.count)
            return Mins(low: Int((Double(days.reduce(0) { $0 + pick($1).low }) / c).rounded()),
                        mid: Int((Double(days.reduce(0) { $0 + pick($1).mid }) / c).rounded()),
                        high: Int((Double(days.reduce(0) { $0 + pick($1).high }) / c).rounded()))
        }
        return DayMins(total: avg { $0.total }, noActivity: avg { $0.noActivity }, sleep: avg { $0.sleep })
    }

    /// Diferencia como la enseña WHOOP: flecha y porcentaje frente al día habitual.
    static func delta(_ today: Int, _ habitual: Int) -> (Trend, String) {
        if today == 0 && habitual == 0 { return (.same, "0:00") }
        if habitual == 0 { return (.up, "—") }
        if today == habitual { return (.same, "0 %") }
        let pct = Int((Double(abs(today - habitual)) * 100.0 / Double(habitual)).rounded())
        return (today > habitual ? .up : .down, "\(pct) %")
    }
}

extension HrLog {
    /// Lecturas que caen dentro de alguno de los tramos (p. ej. 7 noches), en una sola pasada por el archivo.
    func readings(in ranges: [ClosedRange<Int64>]) -> [HrReading] {
        if ranges.isEmpty { return [] }
        let lo = ranges.map { $0.lowerBound }.min()!
        // Lo reciente sale de la caché de HrLog; si no, una pasada por el archivo guardando solo lo que cae en los tramos
        if lo >= TimeUtil.nowMillis() - 2 * 86_400_000 {
            let hi = ranges.map { $0.upperBound }.max()!
            return readings(from: lo, to: hi).filter { r in ranges.contains { $0.contains(r.timeMillis) } }
        }
        flush()
        let r = HrLog.scan(url: url, fromOffset: 0, accept: { t in ranges.contains { $0.contains(t) } }).readings
        return HrLog.sortedUnique(r)
    }
}
