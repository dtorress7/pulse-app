import Foundation
import Combine

/// Todo lo que muestran las pantallas, calculado en segundo plano (equivale a showSummary de Android).
struct Snapshot {
    var loaded = false
    var profile: UserProfile? = nil
    var baseline: PersonalBaseline? = nil
    var summary = DailySummary.empty()
    var vo2Max: Double? = nil
    var stress = StressSummary(currentScore: nil, level: "BAJO", lastUpdateMinute: nil, series: [])
    var plan: SleepPlan? = nil               // para esta noche
    var lastNightNeed = SleepPlanner.baselineMinutes
    var recovery = RecoveryBreakdown(total: 0, hrvDeltaPct: nil, rhrDelta: nil, respPenalty: false, personalBaseline: false)
    var consistency: Int? = nil
    var sleepPerf: Int? = nil
    var sleepScore: Int? = nil
    var todaySessions = [ActivitySession]()
    var allSessions = [ActivitySession]()
    var days = [DailyMetrics]()              // últimos 14 días, más reciente primero
    var steps = 0
    var kcal: Double? = nil
    var age = 30
}

enum Steps {
    /// Pasos de hoy: en directo si el acelerómetro está activo; si no, sumados de motion_minutes.csv.
    static func today(live: Int) -> Int {
        if live > 0 { return live }
        let day = TimeUtil.dayKey(TimeUtil.nowMillis())
        return MotionTracker.stepsFor(day: day, file: AppPaths.file(MotionTracker.fileName))
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var snap = Snapshot()
    private var computing = false
    private var pendingAgain = false
    private let lock = NSLock()

    /// Recalcula todo (puede tardar unos cientos de ms con muchos días de datos). No bloquea la pantalla.
    func refresh() {
        lock.lock()
        if computing { pendingAgain = true; lock.unlock(); return }
        computing = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let s = AppModel.compute()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.snap = s
                self.lock.lock()
                self.computing = false
                let again = self.pendingAgain
                self.pendingAgain = false
                self.lock.unlock()
                if again { self.refresh() }
            }
        }
    }

    static func compute() -> Snapshot {
        let store = AppStore.shared
        let hrLog = WhoopManager.shared.hrLog
        var s = Snapshot()
        let profile = store.getProfile()
        s.profile = profile
        s.age = profile?.ageYears() ?? 30
        let baseline = BaselineProvider.compute(store: store)
        s.baseline = baseline

        let summary = MetricsCalculator(ageYears: s.age, male: profile?.sex != "F").analyze(hrLog: hrLog)
        s.summary = summary

        // VO2máx: fijo, solo se recalcula los martes (o si nunca se ha calculado)
        let now = TimeUtil.nowMillis()
        let isTuesday = TimeUtil.parts(now).weekday == 2
        let todayKey = TimeUtil.dayKey(now)
        if var p = profile, (isTuesday || p.vo2Max == nil), let v = summary.vo2Max {
            p.vo2Max = v
            p.vo2MaxUpdatedDate = todayKey
            store.saveProfile(p)
            s.profile = p
            s.vo2Max = v
        } else {
            s.vo2Max = profile?.vo2Max ?? summary.vo2Max
        }

        let todayStart = TimeUtil.startOfDay(now)
        let all = store.allSessions()
        s.allSessions = all
        s.todaySessions = all.filter { $0.startMillis >= todayStart }
        if let p = profile {
            let elapsed = Double(TimeUtil.minuteOfDay(now))
            s.kcal = CalorieCalculator.estimateDailyTotal(
                elapsedMinutesToday: elapsed, activityKcalToday: s.todaySessions.reduce(0) { $0 + $1.caloriesKcal },
                ageYears: s.age, weightKg: p.weightKg, heightCm: p.heightCm, sex: p.sex)
        }
        s.steps = Steps.today(live: WhoopManager.shared.stepsToday)
        s.stress = StressCalculator.analyze(hrLog: hrLog, restingHr: summary.restingHr, baseline: baseline)
        s.plan = SleepPlanner.computeTonightPlan(store: store, todayStrain: summary.strain)
        s.lastNightNeed = SleepPlanner.planForLastNight(store: store, summary: summary).totalNeedMinutes
        s.recovery = RecoveryCalculator.breakdown(nightlyHrv: summary.avgHrv, restingHr: summary.restingHr,
                                                  baseline: baseline, respiratoryRate: summary.respiratoryRate)
        s.days = store.lastDays(14)
        var nights = HomeDataLoader.nights(Array(store.lastDays(3).reversed()))
        if let a = summary.sleepStartMinuteOfDay, let b = summary.sleepEndMinuteOfDay { nights.append((a, b)) }
        s.consistency = Formulas.sleepConsistency(nights)
        if let slept = summary.sleepMinutes {
            let pct = min(slept * 100 / max(s.lastNightNeed, 1), 100)
            s.sleepPerf = pct
            s.sleepScore = Formulas.sleepScore(hoursVsNeedPct: pct, efficiencyPct: summary.sleepEfficiencyPct, consistencyPct: s.consistency)
        }
        s.loaded = true
        return s
    }
}
