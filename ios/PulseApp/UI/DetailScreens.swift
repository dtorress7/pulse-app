import Foundation
import SwiftUI

// MARK: - Monitor de salud

/// Monitor de salud con el aspecto de WHOOP (port de HealthActivity, 17/10): pulso en directo con su zona, y la respiración,
/// la FCR y la VFC de la noche frente a tu rango habitual (media ± 1 desviación de los 14 días anteriores). Es también la pestaña Salud.
struct HealthMonitorView: View {
    var showBack: Bool = true
    @Binding var path: [Route]
    @StateObject private var mgr = WhoopManager.shared
    @ObservedObject private var store = HomeStore.shared
    @State private var data: HomeData? = nil
    @State private var live = [(Int64, Int)]()
    @State private var hrMax = 190.0
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        WScreen {
            DetailHeader(title: "Monitor de salud", showBack: showBack)
            liveCard.padding(.top, 10)
            vitals.padding(.top, 12)
            WBody(text: vitalsNote, size: 14).padding(.top, 12)
            stressCard.padding(.top, 14)
            extras.padding(.top, 14)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { load() }
        .onChange(of: store.version) { _ in load() }
        .onReceive(ticker) { _ in addLive() }
    }

    private func load() {
        hrMax = Formulas.hrMax(ageYears: AppStore.shared.getProfile()?.ageYears() ?? 30)
        HomeStore.shared.run({ () -> [(Int64, Int)] in
            let now = TimeUtil.nowMillis()
            return WhoopManager.shared.hrLog.readings(from: now - 10 * 60_000, to: now + 60_000).map { ($0.timeMillis, $0.bpm) }
        }, completion: { recent in
            var merged = recent
            for p in live where !recent.contains(where: { $0.0 / 1000 == p.0 / 1000 }) { merged.append(p) }
            live = merged.sorted { $0.0 < $1.0 }
        })
        HomeStore.shared.load(0) { data = $0 }
    }

    /// Cada 2 s añade el último pulso recibido de la pulsera.
    private func addLive() {
        guard let b = mgr.lastBpm else { return }
        let t = mgr.lastBpmTime
        if t > TimeUtil.nowMillis() - 15_000 && (live.last.map { $0.0 < t } ?? true) {
            live.append((t, b))
            if live.count > 900 { live.removeFirst(live.count - 900) }
        }
    }

    private func zoneOf(_ bpm: Int) -> Int { return Formulas.zoneOf(bpm, Formulas.zoneBounds(hrMax: hrMax)) }

    private var liveCard: some View {
        let last = live.last
        let fresh = last != nil && last!.0 > TimeUtil.nowMillis() - 15_000
        let zone = fresh ? zoneOf(last!.1) : -1
        var status = ""
        if !fresh {
            if WhoopSettings.deviceId == nil && !mgr.isRunning { status = "Vincula tu WHOOP en Inicio → Más → Mi WHOOP" }
            else if !mgr.isRunning { status = "WHOOP desconectada" }
            else { status = "Esperando pulso de la WHOOP…" }
        }
        return WCard {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    WTitle(text: "Frecuencia cardíaca en directo", size: 13.5, color: Theme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        WNumber(text: fresh ? "\(last!.1)" : "--", size: 52)
                        Text("lpm").font(Theme.text(18)).foregroundColor(Theme.textPrimary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    WTitle(text: zone >= 0 ? "Zona \(zone)" : "", size: 14)
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { z in
                            RoundedRectangle(cornerRadius: 2).fill(zone >= z ? Theme.wZone[z] : Theme.wTrack).frame(width: 26, height: 8)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            LiveHrLine(points: live).frame(height: 150).padding(.top, 12)
            if !status.isEmpty { WBody(text: status, size: 13).padding(.top, 8) }
        }
    }

    private var vitals: some View {
        let temp = VitalStatus(key: "temp", label: "Temp. cutánea (dif. valor inicial)", icon: "thermometer", value: nil, unit: "°C",
                               decimals: 1, lo: nil, hi: nil, goodWhenHigh: true, ok: nil)
        let tiles = (data?.vitals ?? []) + [temp]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(0..<tiles.count, id: \.self) { i in tile(tiles[i]) }
        }
    }

    private func fmt(_ v: Double, _ decimals: Int) -> String { return decimals == 0 ? String(format: "%.0f", v) : Fmt.comma(v, decimals) }

    private func tile(_ v: VitalStatus) -> some View {
        let (text, ok) = chipText(v)
        let bg: Color = ok == nil ? Theme.wChip : (ok! ? Theme.wMintBg : Theme.wStressHighDim)
        let fg: Color = ok == nil ? Theme.textSecondary : (ok! ? Theme.wMint : Theme.alertAmber)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: v.icon).font(.system(size: 17)).foregroundColor(Theme.textSecondary).frame(width: 22)
                WTitle(text: v.label, size: 13.5, color: Theme.textSecondary)
            }
            Spacer(minLength: 18)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                WNumber(text: v.value.map { fmt($0, v.decimals) } ?? "--", size: 46)
                Text(v.unit).font(Theme.text(18)).foregroundColor(Theme.textPrimary)
            }
            HStack(spacing: 6) {
                if let o = ok { Image(systemName: o ? "checkmark" : "info.circle").font(.system(size: 12, weight: .bold)).foregroundColor(fg) }
                WNumber(text: text, size: 15.5, color: fg)
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 5)
            .background(bg).cornerRadius(6)
            .padding(.top, 16)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(Theme.wCard).cornerRadius(14)
    }

    /// Texto de la etiqueta como WHOOP: "dentro de 54 - 61", "elevado > 107", "baja < 13,4".
    private func chipText(_ v: VitalStatus) -> (String, Bool?) {
        guard let value = v.value else { return (v.key == "temp" ? "sin datos de la pulsera" : "sin datos esta noche", nil) }
        guard let lo = v.lo, let hi = v.hi, v.ok != nil else { return ("calibrando", nil) }
        let loS = fmt(lo, v.decimals), hiS = fmt(hi, v.decimals)
        if value > hi { return (v.key == "hrv" ? "elevado > \(hiS)" : "alta > \(hiS)", v.ok) }
        if value < lo { return (v.key == "hrv" ? "bajo < \(loS)" : "baja < \(loS)", v.ok) }
        return ("dentro de \(loS) - \(hiS)", true)
    }

    private var vitalsNote: String {
        guard let d = data else { return "" }
        if d.healthTotal == 0 { return "Tu rango habitual aparece con \(BaselineProvider.minDaysRequired) noches guardadas." }
        return "\(d.healthOk)/\(d.healthTotal) métricas dentro de tu rango. El oxígeno en sangre no se puede medir sin la nube de WHOOP."
    }

    private var stressCard: some View {
        let d = data
        let level = d?.stressLevel ?? "BAJO"
        return Button(action: { path.append(.stress) }) {
            WCard {
                HStack {
                    WTitle(text: "Monitor de estrés")
                    Spacer()
                    WTitle(text: d?.stressScore != nil ? level : "", size: 16, color: Theme.wStressColor(level))
                    WNumber(text: d?.stressScore.map { Fmt.comma(Double($0)) } ?? "--", size: 24)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                }
                if let dd = d {
                    StressDayChart(points: dd.stressSeries, from: dd.stressFrom, to: dd.stressTo,
                                   sleepFrom: dd.sleepFromMillis, sleepTo: dd.sleepToMillis, showNow: true)
                        .frame(height: 230).padding(.top, 12)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var extras: some View {
        var rows = [String: PanelRow]()
        for r in data?.panel ?? [] { rows[r.key] = r }
        let list = [PanelKeys.steps, PanelKeys.kcal, PanelKeys.vo2].compactMap { rows[$0] } +
            [PanelRow(key: "avg_hr", label: "FC MEDIA DE HOY", icon: "heart", value: data?.summary?.avgHr.map { "\($0)" } ?? "--",
                      average: nil, trend: nil, good: nil)]
        return VStack(spacing: 12) {
            ForEach(0..<list.count, id: \.self) { i in PanelRowView(row: list[i]) }
        }
    }
}

// MARK: - Monitor de estrés

/// Monitor de estrés (port de StressDetailActivity, 17/10): Día total, Sin actividad y Sueño de hoy (00:00 → ahora)
/// frente a tu día habitual a la misma hora: la media de los mismos días de la semana de las últimas 4 semanas
/// (si no hay, los últimos 7 días).
struct StressDetailView: View {
    struct Result {
        let today: StressBreakdown.DayMins
        let habitual: StressBreakdown.DayMins?
        let sameWeekday: Bool
    }
    @State private var result: Result? = nil
    private static let weekdayNames = ["LUNES", "MARTES", "MIÉRCOLES", "JUEVES", "VIERNES", "SÁBADO", "DOMINGO"]

    var body: some View {
        WScreen {
            DetailHeader(title: "Monitor de estrés")
            if let r = result {
                let today = Day.today()
                let dateText = "\(WText.weekdayUpper(today))., \(WText.monthUpper(today)). \(Day.dayOfMonth(today)) ESTRÉS "
                let vsText = r.sameWeekday ? "VS. UN \(StressDetailView.weekdayNames[Day.weekdayIndex(today)]) HABITUAL" : "VS. UN DÍA HABITUAL"
                card("gauge", "Día total", dateText, vsText, r.today.total, r.habitual?.total,
                     "El estrés experimentado a lo largo del día, incluso durante el sueño y las actividades.")
                card("figure.stand", "Sin actividad", dateText, vsText, r.today.noActivity, r.habitual?.noActivity,
                     "El estrés experimentado fuera de las actividades de esfuerzo y el sueño.")
                card("moon", "Sueño", dateText, vsText, r.today.sleep, r.habitual?.sleep, "El estrés experimentado durante el sueño.")
                if r.habitual == nil {
                    WBody(text: "Aún no hay días anteriores con datos a esta hora para comparar. La barra de abajo aparecerá cuando los haya.", size: 14)
                        .padding(.top, 4)
                }
            } else {
                ProgressView().tint(Theme.textSecondary).frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            HomeStore.shared.load(0) { home in
                HomeStore.shared.run({ StressDetailView.compute(home) }, completion: { result = $0 })
            }
        }
    }

    static func compute(_ home: HomeData) -> Result {
        let store = AppStore.shared
        let baseline = BaselineProvider.compute(store: store)
        let today = Day.today()
        let todayStart = Day.start(today)
        let now = TimeUtil.nowMillis()
        let elapsed = now - todayStart
        let sessions = store.allSessions().map { $0.startMillis...max($0.endMillis, $0.startMillis) }
        var stored = [String: DailyMetrics]()
        for d in store.lastDays(40) { stored[d.date] = d }

        var sleepToday = [ClosedRange<Int64>]()
        if let f = home.sleepFromMillis, let t = home.sleepToMillis, t > f { sleepToday.append(f...t) }
        let todayDay = StressBreakdown.of(home.stressSeries, sleep: sleepToday, activities: sessions)

        func dayFor(_ d: String, _ samples: [HrReading]) -> StressBreakdown.DayMins? {
            let s = Day.start(d)
            let series = StressCalculator.seriesBetween(samples, from: s, to: s + elapsed, baseline: baseline)
            if series.isEmpty || series.count * 5 < todayDay.total.total / 2 { return nil }
            var sleep = [ClosedRange<Int64>]()
            if let row = stored[d], let ss = row.sleepStartMinuteOfDay, let se = row.sleepEndMinuteOfDay {
                let end = s + Int64(se) * 60_000
                let start = ss > se ? s - Int64(1440 - ss) * 60_000 : s + Int64(ss) * 60_000
                if end > start { sleep.append(start...end) }
            }
            return StressBreakdown.of(series, sleep: sleep, activities: sessions)
        }
        // Primero los mismos días de la semana de las 4 semanas anteriores; si no hay, la última semana
        let weekDays = (1...4).map { Day.add(today, -7 * $0) }
        var samples = WhoopManager.shared.hrLog.readings(in: weekDays.map { Day.start($0)...(Day.start($0) + elapsed) })
        let same = weekDays.compactMap { dayFor($0, samples) }
        if !same.isEmpty { return Result(today: todayDay, habitual: StressBreakdown.average(same), sameWeekday: true) }
        let lastWeek = (1...7).map { Day.add(today, -$0) }
        samples = WhoopManager.shared.hrLog.readings(in: lastWeek.map { Day.start($0)...(Day.start($0) + elapsed) })
        let recent = lastWeek.compactMap { dayFor($0, samples) }
        return Result(today: todayDay, habitual: StressBreakdown.average(recent), sameWeekday: false)
    }

    private func card(_ icon: String, _ title: String, _ dateText: String, _ vsText: String, _ today: StressBreakdown.Mins,
                      _ habitual: StressBreakdown.Mins?, _ description: String) -> some View {
        let cols: [(String, Int, Int?, Color)] = [("BAJO", today.low, habitual?.low, Theme.wLowBlue), ("MEDIO", today.mid, habitual?.mid, Theme.wMint),
                                                  ("ALTO", today.high, habitual?.high, Theme.alertAmber)]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(Theme.textSecondary)
                WTitle(text: title, size: 15)
            }
            (Text(dateText).foregroundColor(Theme.textPrimary) + Text(vsText).foregroundColor(Theme.textSecondary))
                .font(Theme.number(13.5)).tracking(13.5 * 0.14)
                .padding(.top, 22)
            WStackedBar(parts: [(Double(today.low), Theme.wLowBlue), (Double(today.mid), Theme.wMint), (Double(today.high), Theme.alertAmber)], height: 14)
                .padding(.top, 20)
            if let h = habitual {
                WStackedBar(parts: [(Double(h.low), Theme.wStressLowDim), (Double(h.mid), Theme.wStressMidDim), (Double(h.high), Theme.wStressHighDim)], height: 8)
                    .padding(.top, 8)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    let c = cols[i]
                    VStack(alignment: .leading, spacing: 0) {
                        WNumber(text: Fmt.hm(c.1), size: 27)
                        if let h = c.2 {
                            let dl = StressBreakdown.delta(c.1, h)
                            TrendChip(trend: dl.0, text: dl.1).padding(.top, 8)
                        } else {
                            TrendChip(trend: nil, text: "—").padding(.top, 8)
                        }
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 1).fill(c.3).frame(width: 11, height: 11)
                            WTitle(text: c.0, size: 14, color: Theme.textSecondary)
                        }
                        .padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 22)
            WBody(text: description, size: 16).padding(.top, 22)
        }
        .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.wCard).cornerRadius(14)
        .padding(.top, 16)
    }
}

// MARK: - Detalle de una actividad

/// Detalle de una actividad (port de ActivityDetailActivity, 17/10): esfuerzo y pasos frente a tu media, pulso de la actividad,
/// tiempo en cada zona (con tu rango típico en ese deporte) y estadísticas clave frente a los últimos 30 días.
struct ActivityDetailView: View {
    let sessionId: Int64
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = HomeStore.shared
    @State private var model: Model? = nil
    @State private var showMenu = false
    @State private var confirmDelete = false

    struct Stats { let strain: Double; let steps: Int?; let kcal: Double; let avgHr: Int; let maxHr: Int; let seconds: Int64 }
    struct Model {
        let session: ActivitySession
        let me: Stats
        let avg: [Stats]
        let chart: [(Int64, Int)]
        let zoneSec: [Int]
        let typical: [(Double, Double)?]
        let hrMax: Double
    }

    var body: some View {
        WScreen {
            DetailHeader(title: "", trailing: AnyView(
                Button(action: { showMenu = true }) {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .bold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                }))
            if let m = model {
                content(m)
            } else {
                ProgressView().tint(Theme.textSecondary).frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { load() }
        .onChange(of: store.version) { _ in load() }
        .confirmationDialog("Actividad", isPresented: $showMenu) {
            Button("Editar actividad") { path.append(.editActivity(sessionId)) }
            Button("Eliminar actividad", role: .destructive) { confirmDelete = true }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("¿Eliminar esta actividad?", isPresented: $confirmDelete, actions: {
            Button("Eliminar", role: .destructive) {
                AppStore.shared.deleteSession(id: sessionId)
                HomeStore.shared.invalidate()
                AppModel.shared.refresh()
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        }, message: { Text("Se borra el registro de la actividad. El pulso guardado no se toca.") })
    }

    private func load() {
        let id = sessionId
        HomeStore.shared.run({ ActivityDetailView.compute(id) }, completion: { m in
            if let m = m { model = m } else { dismiss() }
        })
    }

    static func zoneOf(_ bpm: Int, _ hrMax: Double) -> Int { return Formulas.zoneOf(bpm, Formulas.zoneBounds(hrMax: hrMax)) }

    static func compute(_ id: Int64) -> Model? {
        let store = AppStore.shared
        guard let s = store.session(id: id) else { return nil }
        let all = store.allSessions()
        let hrMax = Formulas.hrMax(ageYears: store.getProfile()?.ageYears() ?? 30)
        let motion = MotionTracker.readMinutes(AppPaths.file(MotionTracker.fileName))
        func stepsIn(_ a: ActivitySession) -> Int? {
            let m = motion.filter { $0.minuteStartUnix * 1000 >= a.startMillis && $0.minuteStartUnix * 1000 < a.endMillis }
            return m.isEmpty ? nil : m.reduce(0) { $0 + $1.steps }
        }
        let pad: Int64 = 10 * 60_000
        let samples = WhoopManager.shared.hrLog.readings(from: s.startMillis - pad, to: s.endMillis + pad)
        let monthAgo = s.startMillis - 30 * 86_400_000
        let others = all.filter { $0.id != s.id && $0.startMillis >= monthAgo && $0.startMillis < s.startMillis + 86_400_000 }
        let sameType = others.filter { $0.type == s.type }
        let pool = sameType.isEmpty ? others : sameType
        func stats(_ a: ActivitySession) -> Stats {
            return Stats(strain: a.strain, steps: stepsIn(a), kcal: a.caloriesKcal, avgHr: a.avgHr, maxHr: a.maxHr, seconds: (a.endMillis - a.startMillis) / 1000)
        }
        // Pulso en medias de 10 s
        var groups = [Int64: (Int, Int)]()
        for r in samples {
            let k = r.timeMillis / 10_000
            let g = groups[k] ?? (0, 0)
            groups[k] = (g.0 + r.bpm, g.1 + 1)
        }
        let chart = groups.keys.sorted().map { k in (k * 10_000, Int((Double(groups[k]!.0) / Double(groups[k]!.1)).rounded())) }
        var zoneSec = [Int](repeating: 0, count: 6)
        var lastSec: Int64 = -1
        for r in samples where r.timeMillis >= s.startMillis && r.timeMillis <= s.endMillis {
            let sec = r.timeMillis / 1000
            if sec == lastSec { continue }
            lastSec = sec
            zoneSec[zoneOf(r.bpm, hrMax)] += 1
        }
        let typical: [(Double, Double)?] = (0...5).map { z -> (Double, Double)? in
            let fr = sameType.compactMap { a -> Double? in
                let mins = [a.minutesZone0, a.minutesZone1, a.minutesZone2, a.minutesZone3, a.minutesZone4, a.minutesZone5]
                let tot = mins.reduce(0, +)
                return tot <= 0 ? nil : Double(mins[z]) / Double(tot)
            }
            return fr.count >= 2 ? (fr.min()!, fr.max()!) : nil
        }
        return Model(session: s, me: stats(s), avg: pool.map { stats($0) }, chart: chart, zoneSec: zoneSec, typical: typical, hrMax: hrMax)
    }

    private func trendOf(_ value: Double, _ avg: Double) -> Trend {
        if abs(value - avg) < 0.005 * max(1, abs(avg)) { return .same }
        return value > avg ? .up : .down
    }
    private func hm(_ sec: Int64) -> String { return String(format: "%d:%02d", sec / 3600, (sec % 3600) / 60) }
    private func hms(_ sec: Int64) -> String { return String(format: "%d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60) }

    /// "Hoy de las 17:35 a las 19:26", "Ayer de las …" o "16 oct. de las …".
    private func whenText(_ s: ActivitySession) -> String {
        let key = TimeUtil.dayKey(s.startMillis)
        let today = Day.today()
        let day: String
        if key == today { day = "Hoy" }
        else if key == Day.add(today, -1) { day = "Ayer" }
        else {
            let p = TimeUtil.parts(s.startMillis)
            day = "\(p.day) \(WText.monthLow(key))." + (p.year == TimeUtil.parts(TimeUtil.nowMillis()).year ? "" : " \(p.year)")
        }
        return "\(day) de las \(Fmt.clock(s.startMillis)) a las \(Fmt.clock(s.endMillis))"
    }

    private func average(_ v: [Double]) -> Double? { return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    @ViewBuilder private func content(_ m: Model) -> some View {
        let s = m.session
        let me = m.me
        VStack(spacing: 10) {
            Image(systemName: WText.sportIcon(s.type)).font(.system(size: 34)).foregroundColor(Theme.textPrimary)
            WTitle(text: s.type, size: 22)
            Text(whenText(s)).font(Theme.text(15)).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)

        let avgStrain = average(m.avg.map { $0.strain })
        let avgSteps = average(m.avg.compactMap { $0.steps.map { Double($0) } })
        HStack(alignment: .top, spacing: 12) {
            bigStat(Fmt.comma(me.strain), Theme.strainBlue, avgStrain.map { trendOf(me.strain, $0) }, avgStrain.map { Fmt.comma($0) }, "Esfuerzo\nde actividad")
            bigStat(me.steps.map { Fmt.thousands(Int64($0)) } ?? "--", Theme.textPrimary,
                    (me.steps != nil && avgSteps != nil) ? trendOf(Double(me.steps!), avgSteps!) : nil,
                    avgSteps.map { Fmt.thousands(Int64($0.rounded())) }, "Pasos de la actividad")
        }
        .padding(.top, 26)

        if m.chart.count >= 2 {
            ActivityHrChart(points: m.chart, start: s.startMillis, end: s.endMillis).frame(height: 360).padding(.top, 22)
        } else {
            WBody(text: "No hay pulso guardado de esta actividad.", size: 14).padding(.top, 22)
        }

        let durSec = (s.endMillis - s.startMillis) / 1000
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4).stroke(Theme.textSecondary, lineWidth: 1.5).frame(width: 26, height: 26)
            WTitle(text: "Rango típico", size: 14.5, color: Theme.textSecondary).padding(.leading, 14)
            Spacer()
            WTitle(text: "Duración", size: 14.5, color: Theme.textSecondary).padding(.trailing, 8)
            WNumber(text: hms(durSec), size: 18)
        }
        .padding(.top, 22)

        let total = max(m.zoneSec.reduce(0, +), 1)
        let bounds = Formulas.zoneBounds(hrMax: m.hrMax)
        ForEach((0...5).reversed(), id: \.self) { z in
            let range = z == 0 ? "<\(bounds[0]) BPM" : (z == 5 ? "\(bounds[4])+ BPM" : "\(bounds[z - 1])-\(bounds[z] - 1) BPM")
            zoneRow(z, range, m.zoneSec[z], Double(m.zoneSec[z]) / Double(total), Theme.wZone[z], m.typical[z])
        }
        WBody(text: "Las zonas salen de tu reserva de FC, como en WHOOP: entre tu FC en reposo (\(Formulas.zoneRestingHr()) lpm) y tu FC máxima (\(Int(m.hrMax.rounded())) lpm), que puedes cambiar en Sobre mí.", size: 14.5).padding(.top, 12)

        HStack {
            WTitle(text: "Estadísticas clave", size: 15.5)
            Spacer()
            WTitle(text: "vs. promedio de 30 días", size: 13, color: Theme.textSecondary)
        }
        .padding(.top, 34)
        let kcalAvg = average(m.avg.map { $0.kcal })
        let hrAvg = average(m.avg.map { Double($0.avgHr) })
        let maxAvg = average(m.avg.map { Double($0.maxHr) })
        let durAvg = average(m.avg.map { Double($0.seconds) })
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                statCard("flame", "Calorías", String(format: "%.0f", me.kcal), "cal.", kcalAvg.map { trendOf(me.kcal, $0) }, kcalAvg.map { String(format: "%.0f cal.", $0) })
                statCard("heart", "FC prom.", "\(me.avgHr)", "lpm", hrAvg.map { trendOf(Double(me.avgHr), $0) }, hrAvg.map { String(format: "%.0f lpm", $0) })
                statCard("bolt.heart", "FC máxima", "\(me.maxHr)", "lpm", maxAvg.map { trendOf(Double(me.maxHr), $0) }, maxAvg.map { String(format: "%.0f lpm", $0) })
                statCard("stopwatch", "Duración", hm(durSec), String(format: ":%02d", durSec % 60), durAvg.map { trendOf(Double(durSec), $0) },
                         durAvg.map { hms(Int64($0.rounded())) })
            }
        }
        .padding(.top, 16)
        if s.autoDetected {
            WBody(text: "Actividad detectada automáticamente. Puedes cambiar el deporte o la hora desde ···", size: 14).padding(.top, 18)
        }
    }

    private func bigStat(_ value: String, _ color: Color, _ trend: Trend?, _ avgText: String?, _ label: String) -> some View {
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                WNumber(text: value, size: 56, color: color)
                if let a = avgText { TrendChip(trend: trend, text: a) }
            }
            WTitle(text: label, size: 16, color: Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func zoneRow(_ z: Int, _ range: String, _ seconds: Int, _ fraction: Double, _ color: Color, _ typical: (Double, Double)?) -> some View {
        let empty = seconds == 0
        return VStack(spacing: 6) {
            HStack(spacing: 14) {
                WTitle(text: "Zona \(z)", size: 15.5)
                WTitle(text: range, size: 15.5, color: Theme.textSecondary)
                WNumber(text: String(format: "%.0f %%", fraction * 100), size: 16, color: color)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    WNumber(text: String(format: "%d:%02d", seconds / 3600, (seconds % 3600) / 60), size: 22)
                    WNumber(text: String(format: ":%02d", seconds % 60), size: 15, color: Theme.textSecondary)
                }
            }
            if !empty {
                ZoneBar(fraction: fraction, color: color, typicalLo: typical?.0, typicalHi: typical?.1).frame(height: 44)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, empty ? 14 : 12)
        .background(Theme.wCard).cornerRadius(14)
        .opacity(empty ? 0.55 : 1)
        .padding(.top, 12)
    }

    private func statCard(_ icon: String, _ label: String, _ value: String, _ unit: String, _ trend: Trend?, _ avgText: String?) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17)).foregroundColor(Theme.textSecondary)
                WTitle(text: label, size: 14, color: Theme.textSecondary)
            }
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                WNumber(text: value, size: 48)
                Text(unit).font(Theme.text(20)).foregroundColor(Theme.textPrimary)
            }
            .padding(.top, 22)
            TrendChip(trend: trend, text: avgText ?? "sin media").padding(.top, 14)
        }
        .padding(18)
        .frame(width: 176, alignment: .leading)
        .background(Theme.wCard).cornerRadius(14)
    }
}
