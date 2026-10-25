import Foundation
import SwiftUI

/// Sueño con el aspecto de WHOOP (port de SleepDetailActivity de Android, 17/10): calificación con sus 4 componentes,
/// "El sueño de anoche" (pulso, fases, sueño reparador, latencia), horas vs lo necesario, regularidad, eficiencia,
/// estrés del sueño y tendencias semanales.
struct SleepDetailView: View {
    let dayOffset: Int
    var showBack: Bool = true
    @ObservedObject private var store = HomeStore.shared
    @State private var data: HomeData? = nil
    @State private var nightStress = [String: [StressPoint]]()
    /// Fase elegida (como WHOOP: se pinta en la gráfica de pulso y en su barra). nil = ninguna.
    @State private var selectedStage: Int? = nil
    @State private var showTypical = false

    var body: some View {
        WScreen {
            DetailHeader(title: WText.dateTitle(Day.add(Day.today(), dayOffset)), showBack: showBack)
            if let d = data {
                content(d)
            } else {
                ProgressView().tint(Theme.textSecondary).frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { load() }
        .onChange(of: store.version) { _ in load() }
    }

    private func load() {
        HomeStore.shared.load(dayOffset) { d in
            data = d
            HomeStore.shared.run({ SleepDetailView.nightStress(d) }, completion: { nightStress = $0 })
        }
    }

    /// Estrés de cada noche de la semana (para el estrés del sueño y su tendencia).
    static func nightStress(_ d: HomeData) -> [String: [StressPoint]] {
        var byDate = [String: DayRecord]()
        for r in d.records { byDate[r.date] = r }
        var nights = [String: ClosedRange<Int64>]()
        for i in 0...6 {
            let date = Day.add(d.date, -i)
            if date == d.date, let f = d.sleepFromMillis, let t = d.sleepToMillis, t > f { nights[date] = f...t; continue }
            guard let r = byDate[date], let s = r.sleepStartMinute, let e = r.sleepEndMinute else { continue }
            let dayStart = Day.start(date)
            let to = dayStart + Int64(e) * 60_000
            let from = s > e ? dayStart - Int64(1440 - s) * 60_000 : dayStart + Int64(s) * 60_000
            if to > from { nights[date] = from...to }
        }
        let others = nights.filter { !($0.key == d.date && !d.sleepStressSeries.isEmpty) }
        let samples = WhoopManager.shared.hrLog.readings(in: others.values.map { ($0.lowerBound - 15 * 60_000)...($0.upperBound + 15 * 60_000) })
        let baseline = BaselineProvider.compute(store: AppStore.shared)
        var out = [String: [StressPoint]]()
        for (date, r) in nights {
            if date == d.date && !d.sleepStressSeries.isEmpty { out[date] = d.sleepStressSeries }
            else { out[date] = StressCalculator.seriesBetween(samples, from: r.lowerBound, to: r.upperBound, baseline: baseline) }
        }
        return out
    }

    /// Minuto del día → minutos desde las 12:00 del día anterior (la noche queda continua en las gráficas).
    private func nightAxis(_ m: Int) -> Double { return Double(m >= 720 ? m - 720 : m + 720) }
    private func level(_ v: Int?, _ opt: Int, _ ok: Int) -> Int {
        guard let v = v else { return -1 }
        return v >= opt ? 2 : (v >= ok ? 1 : 0)
    }
    private func stressMins(_ date: String) -> StressBreakdown.Mins? {
        guard let s = nightStress[date], !s.isEmpty else { return nil }
        return StressBreakdown.of(s, sleep: [], activities: []).total
    }
    private func highPct(_ m: StressBreakdown.Mins?) -> Int? {
        guard let m = m, m.total > 0 else { return nil }
        return Int((Double(m.high) * 100 / Double(m.total)).rounded())
    }

    @ViewBuilder private func content(_ d: HomeData) -> some View {
        let day = d.day
        let monthAgo = Day.add(d.date, -30)
        let prev = d.records.filter { $0.date < d.date && $0.date >= monthAgo }
        let avg: ((DayRecord) -> Int?) -> Double? = { f in
            let v = prev.compactMap(f)
            return v.isEmpty ? nil : Double(v.reduce(0, +)) / Double(v.count)
        }
        let score = day.sleepScore
        let hvn = day.hoursVsNeedPct
        let high = highPct(stressMins(d.date))

        // ---------- Calificación ----------
        WRing(progress: Double(score ?? 0) / 100, value: score.map { "\($0)%" } ?? "--", label: "Calificación\ndel sueño",
              color: Theme.wRingSleep, size: 260, strokeRatio: 0.055, numberRatio: 0.26, suffixRatio: 0.5, labelRatio: 0.052, topText: "PULSE")
            .frame(maxWidth: .infinity).padding(.top, 14)

        WCard {
            componentRow("clock", "Horas vs. lo necesario", hvn.map { "\($0) %" } ?? "--", level(hvn, 85, 70))
            WDivider()
            componentRow("clock.arrow.circlepath", "Regularidad del sueño", day.consistency.map { "\($0) %" } ?? "--", level(day.consistency, 80, 65))
            WDivider()
            componentRow("chart.bar.fill", "Eficiencia del sueño", day.efficiency.map { "\($0) %" } ?? "--", level(day.efficiency, 90, 80))
            WDivider()
            componentRow("gauge", "Estrés del sueño alto", high.map { "\($0) %" } ?? "--",
                         high == nil ? -1 : (high! == 0 ? 2 : (high! <= 5 ? 1 : 0)))
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    let item: (String, Color) = [("Deficiente", Theme.wTrendAmber), ("Suficiente", Theme.textSecondary), ("Óptimo", Theme.wMint)][i]
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 14, height: 4).padding(.leading, 14)
                    Text(item.0).font(Theme.text(13.5)).foregroundColor(Theme.textSecondary).padding(.leading, 8)
                }
            }
            .frame(maxWidth: .infinity).padding(10)
            .background(Theme.background).cornerRadius(8)
            .padding(.top, 12)
        }
        .padding(.top, 18)

        // ---------- El sueño de anoche ----------
        WHeading(text: "El sueño de anoche").padding(.top, 34)
        WBody(text: "\(WText.dateShort(d.date)) vs. los 30 días anteriores", size: 14)
        sleepCard(d, prev, avg).padding(.top, 16)

        // ---------- Horas vs. lo necesario ----------
        needCard(d, avg).padding(.top, 14)

        // ---------- Regularidad ----------
        regularityCard(d, avg).padding(.top, 14)

        // ---------- Eficiencia ----------
        efficiencyCard(d, avg).padding(.top, 14)

        // ---------- Estrés del sueño ----------
        sleepStressCard(d, high).padding(.top, 14)

        // ---------- Tendencias semanales ----------
        WHeading(text: "Tendencias semanales").padding(.top, 34)
        weeklyCharts(d)
    }

    private func componentRow(_ icon: String, _ label: String, _ value: String, _ lvl: Int) -> some View {
        return HStack(spacing: 0) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(Theme.textSecondary).frame(width: 22)
            WTitle(text: label, size: 13).padding(.leading, 12)
            Spacer(minLength: 6)
            TriSegment(level: lvl)
            WNumber(text: value, size: 23).frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 16)
    }

    // MARK: Tarjeta de la noche

    private func sleepCard(_ d: HomeData, _ prev: [DayRecord], _ avg: ((DayRecord) -> Int?) -> Double?) -> some View {
        let day = d.day
        let sleepAvg = avg { $0.sleepMinutes }
        let pts = nightPoints(d)
        let hyp = d.stages
        let stageColors: [Color] = [Theme.wStageAwake, Theme.wStageLight, Theme.wStageDeep, Theme.wStageRem]
        let highlights: [(Int64, Int64)] = {
            guard let sel = selectedStage, let h = hyp else { return [] }
            return SleepDetailView.runs(h.stages, sel).map { (h.startMillis + Int64($0.0) * 60_000, h.startMillis + Int64($0.1) * 60_000) }
        }()
        return WCard {
            MetricHeader(title: "Horas de sueño", value: WText.hm(day.sleepMinutes),
                         trend: WTrend.of(day.sleepMinutes.map { Double($0) }, sleepAvg, tol: 5), goodWhenHigh: true,
                         avg: sleepAvg.map { Fmt.hm(Int($0.rounded())) }, info: "Tiempo dormido de verdad: la noche menos los ratos despierto.")
            if pts.count >= 2, let f = d.sleepFromMillis, let t = d.sleepToMillis {
                ActivityHrChart(points: pts, start: f, end: t, yStep: 20, filled: false, lineColor: Theme.wHrSleep,
                                highlights: highlights, highlightColor: selectedStage.map { stageColors[$0] } ?? .clear)
                    .frame(height: 220).padding(.top, 14)
            }
            HStack(spacing: 0) {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showTypical.toggle() } }) {
                    HStack(spacing: 0) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 3).stroke(Theme.textSecondary, lineWidth: 1.5).frame(width: 14, height: 14)
                            if showTypical || hyp == nil { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.textPrimary) }
                        }
                        WTitle(text: "Rango típico", size: 13, color: Theme.textSecondary).padding(.leading, 10)
                    }
                }
                .buttonStyle(.plain)
                .disabled(hyp == nil)
                Spacer()
                WTitle(text: "Duración", size: 13, color: Theme.textSecondary).padding(.trailing, 8)
                WNumber(text: WText.hm(day.inBed), size: 17)
            }
            .padding(.top, 18).padding(.bottom, 4)
            if let light = day.light, let deep = day.deep, let rem = day.rem, let inBed = day.inBed, inBed > 0 {
                let awake = day.awake ?? max(inBed - light - deep - rem, 0)
                let stages: [(String, Int, Color, (DayRecord) -> Int?)] = [
                    ("Despierto", awake, Theme.wStageAwake, { $0.awake }),
                    ("Ligero", light, Theme.wStageLight, { $0.light }),
                    ("Sueño profundo (SWS)", deep, Theme.wStageDeep, { $0.deep }),
                    ("REM", rem, Theme.wStageRem, { $0.rem })
                ]
                ForEach(0..<stages.count, id: \.self) { i in
                    let st = stages[i]
                    let frac = Double(st.1) / Double(inBed)
                    let typ = typical(prev, st.3)
                    let on = selectedStage == i
                    Button(action: {
                        guard hyp != nil else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        withAnimation(.easeInOut(duration: 0.15)) { selectedStage = on ? nil : i }
                    }) {
                        VStack(spacing: 4) {
                            HStack(spacing: 0) {
                                ZStack {
                                    Circle().stroke(Theme.textPrimary, lineWidth: 2).frame(width: 24, height: 24)
                                    if on { Circle().fill(Theme.textPrimary).frame(width: 24, height: 24)
                                            Circle().fill(Color.black).frame(width: 9, height: 9) }
                                }
                                WTitle(text: st.0, size: 14).padding(.leading, 12)
                                WNumber(text: "\(Int((frac * 100).rounded())) %", size: 14,
                                        color: (selectedStage == nil || on) ? st.2 : Theme.textSecondary).padding(.leading, 10)
                                Spacer()
                                WNumber(text: Fmt.hm(st.1), size: 19)
                            }
                            if let h = hyp, !showTypical {
                                StageTimelineBar(stages: h.stages, stage: i, color: st.2, active: on).frame(height: 30)
                            } else {
                                ZoneBar(fraction: frac, color: st.2, typicalLo: typ?.0, typicalHi: typ?.1).frame(height: 30)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                }
            } else {
                WBody(text: "Las fases (ligero, profundo y REM) aparecen las noches en que el movimiento estaba activado en Mi WHOOP.", size: 14)
                    .padding(.top, 10).padding(.bottom, 4)
            }
            Spacer().frame(height: 10)
            WDivider()
            let restAvg = avg { $0.restorative }
            ValueRow(label: "■  Sueño reparador", value: WText.hm(day.restorative),
                     trend: WTrend.of(day.restorative.map { Double($0) }, restAvg, tol: 5), goodWhenHigh: true,
                     avg: restAvg.map { Fmt.hm(Int($0.rounded())) })
            WDivider()
            ValueRow(label: "■  Latencia de inicio del sueño", value: WText.hm(day.latency))
        }
    }

    /// Tramos [inicio, fin) (en minutos desde el comienzo de la noche) en los que [stages] vale [stage].
    static func runs(_ stages: [Int], _ stage: Int) -> [(Int, Int)] {
        var out = [(Int, Int)]()
        var i = 0
        while i < stages.count {
            if stages[i] != stage { i += 1; continue }
            var j = i
            while j < stages.count && stages[j] == stage { j += 1 }
            out.append((i, j))
            i = j
        }
        return out
    }

    /// Pulso de la noche en medias de 30 s.
    private func nightPoints(_ d: HomeData) -> [(Int64, Int)] {
        var groups = [Int64: (Int, Int)]()
        for r in d.nightReadings {
            let k = r.timeMillis / 30_000
            let g = groups[k] ?? (0, 0)
            groups[k] = (g.0 + r.bpm, g.1 + 1)
        }
        return groups.keys.sorted().map { k in (k * 30_000, Int((Double(groups[k]!.0) / Double(groups[k]!.1)).rounded())) }
    }

    /// Rango típico (cuartiles) de la fracción de la noche en esa fase, de los 30 días anteriores.
    private func typical(_ prev: [DayRecord], _ f: (DayRecord) -> Int?) -> (Double, Double)? {
        let fr = prev.compactMap { r -> Double? in
            guard let v = f(r), let ib = r.inBed, ib > 0 else { return nil }
            return Double(v) / Double(ib)
        }.sorted()
        if fr.count >= 4 { return (fr[fr.count / 4], fr[(fr.count * 3) / 4]) }
        if fr.count >= 2 { return (fr.first!, fr.last!) }
        return nil
    }

    // MARK: Horas vs. lo necesario

    private func needCard(_ d: HomeData, _ avg: ((DayRecord) -> Int?) -> Double?) -> some View {
        let day = d.day
        let hvn = day.hoursVsNeedPct
        let a = avg { $0.hoursVsNeedPct }
        return WCard {
            MetricHeader(title: "Horas vs. lo necesario", value: hvn.map { "\($0) %" } ?? "--",
                         trend: WTrend.of(hvn.map { Double($0) }, a), goodWhenHigh: true, avg: a.map { String(format: "%.0f %%", $0) },
                         info: "Lo que dormiste frente a lo que necesitabas: un mínimo saludable para tu edad más lo que suman el esfuerzo de la víspera y la deuda de sueño.")
            if let need = day.needLastNight, need > 0 {
                let slept = day.sleepMinutes ?? 0
                HStack {
                    WTitle(text: "Horas de sueño", size: 13, color: Theme.textSecondary)
                    Spacer()
                    WNumber(text: Fmt.hm(slept), size: 17)
                }
                .padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 8)
                WProgress(fraction: Double(slept) / Double(need), color: Theme.wRingSleep, height: 14)
                WStackedBar(parts: [(Double(day.needBase ?? 0), Theme.wNeedBase), (Double(day.needStrainAdj ?? 0), Theme.strainBlue),
                                    (Double(day.needDebtAdj ?? 0), Theme.wNeedDebt)], height: 14)
                    .padding(.top, 14)
                HStack {
                    WTitle(text: "Sueño necesario", size: 13, color: Theme.textSecondary)
                    Spacer()
                    WNumber(text: Fmt.hm(need), size: 17)
                }
                .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 12)
                VStack(spacing: 0) {
                    needRow("Mínimo saludable", Fmt.hm(day.needBase ?? 0), Theme.wNeedBase)
                    needRow("Esfuerzo reciente", "+" + Fmt.hm(day.needStrainAdj ?? 0), Theme.strainBlue)
                    needRow("Deuda del sueño", "+" + Fmt.hm(day.needDebtAdj ?? 0), Theme.wNeedDebt)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Theme.background).cornerRadius(8)
            }
        }
    }

    private func needRow(_ name: String, _ value: String, _ color: Color) -> some View {
        return HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
            Text(name).font(Theme.text(14.5)).foregroundColor(Theme.textPrimary)
            Spacer()
            WNumber(text: value, size: 16)
        }
        .padding(.vertical, 8)
    }

    // MARK: Regularidad

    private func regularityCard(_ d: HomeData, _ avg: ((DayRecord) -> Int?) -> Double?) -> some View {
        let day = d.day
        var byDate = [String: DayRecord]()
        for r in d.records { byDate[r.date] = r }
        let wake = SleepPlanner.wakeMinute()
        let last5 = (0...4).reversed().map { Day.add(d.date, -$0) }
        let ranges: [WeekChart.Range?] = last5.map { date -> WeekChart.Range? in
            guard let r = byDate[date], let s = r.sleepStartMinute, let e = r.sleepEndMinute else { return nil }
            let mine = date == d.date
            return WeekChart.Range(start: nightAxis(s), end: nightAxis(e), startLabel: mine ? Fmt.clock(minuteOfDay: s) : nil,
                                   endLabel: mine ? String(format: "%d:%02d", e / 60, e % 60) : nil)
        }
        let optimal: [(Double, Double)?] = last5.map { date -> (Double, Double)? in
            guard let n = byDate[date]?.needLastNight else { return nil }
            let bed = ((wake - n) % 1440 + 1440) % 1440
            return (nightAxis(bed), nightAxis(wake))
        }
        let a = avg { $0.consistency }
        return WCard {
            MetricHeader(title: "Regularidad del sueño", value: day.consistency.map { "\($0) %" } ?? "--",
                         trend: WTrend.of(day.consistency.map { Double($0) }, a), goodWhenHigh: true, avg: a.map { String(format: "%.0f %%", $0) },
                         info: "Lo parecida que es tu hora de dormirte cada noche (últimas 7 noches).")
            WTitle(text: "- -  Hora óptima de acostarse/despertar", size: 12, color: Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 6)
            WeekChart(days: WeekChart.days(last5),
                      mode: .ranges(ranges: ranges, color: Theme.wRingSleep, dimPrevious: true,
                                    yLabels: [(nightAxis(19 * 60), "19:00"), (nightAxis(23 * 60), "23:00"), (nightAxis(3 * 60), "03:00"), (nightAxis(7 * 60), "07:00")],
                                    optimal: optimal))
                .frame(height: 230).padding(.top, 8)
        }
    }

    // MARK: Eficiencia

    private func efficiencyCard(_ d: HomeData, _ avg: ((DayRecord) -> Int?) -> Double?) -> some View {
        let day = d.day
        let a = avg { $0.efficiency }
        let we = avg { $0.wakeEpisodes }
        return WCard {
            MetricHeader(title: "Eficiencia del sueño", value: day.efficiency.map { "\($0) %" } ?? "--",
                         trend: WTrend.of(day.efficiency.map { Double($0) }, a), goodWhenHigh: true, avg: a.map { String(format: "%.0f %%", $0) },
                         info: "El porcentaje del tiempo en cama que estuviste dormido.")
            labelRow("Dormido", WText.hm(day.sleepMinutes))
            if let st = d.stages {
                SleepTimelineBar(stages: st.stages, awakeRow: false).frame(height: 16)
                SleepTimelineBar(stages: st.stages, awakeRow: true).frame(height: 16).padding(.top, 10)
            } else {
                WProgress(fraction: Double(day.efficiency ?? 0) / 100, color: Theme.wRingSleep, height: 16)
            }
            labelRow("Despierto", WText.hm(day.awake))
            WDivider()
            ValueRow(label: "■  Episodios de despertar", value: day.wakeEpisodes.map { "\($0)" } ?? "--",
                     trend: WTrend.of(day.wakeEpisodes.map { Double($0) }, we), goodWhenHigh: false, avg: we.map { String(format: "%.0f", $0) })
        }
    }

    private func labelRow(_ name: String, _ v: String) -> some View {
        return HStack {
            WTitle(text: name, size: 13, color: Theme.textSecondary)
            Spacer()
            WNumber(text: v, size: 17)
        }
        .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 8)
    }

    // MARK: Estrés del sueño

    private func sleepStressCard(_ d: HomeData, _ high: Int?) -> some View {
        let prevHigh = (1...6).compactMap { highPct(stressMins(Day.add(d.date, -$0))) }
        let avgHigh: Double? = prevHigh.isEmpty ? nil : Double(prevHigh.reduce(0, +)) / Double(prevHigh.count)
        let m = stressMins(d.date)
        return WCard {
            MetricHeader(title: "Estrés del sueño", value: high.map { "\($0) %" } ?? "--",
                         trend: WTrend.of(high.map { Double($0) }, avgHigh), goodWhenHigh: false, avg: avgHigh.map { String(format: "%.0f %%", $0) },
                         info: "Porcentaje de la noche con estrés alto (los demás niveles, debajo).")
            if let f = d.sleepFromMillis, let t = d.sleepToMillis, !d.sleepStressSeries.isEmpty {
                StressDayChart(points: d.sleepStressSeries, from: f, to: t, sleepFrom: f, sleepTo: t, showNow: true)
                    .frame(height: 230).padding(.top, 10)
            }
            if let m = m, m.total > 0 {
                let items: [(String, Int, Color)] = [("Alto", m.high, Theme.alertAmber), ("Medio", m.mid, Theme.wMint), ("Bajo", m.low, Theme.wLowBlue)]
                ForEach(0..<3, id: \.self) { i in
                    let f = Double(items[i].1) / Double(m.total)
                    HStack(spacing: 8) {
                        WTitle(text: items[i].0, size: 13.5)
                        WNumber(text: "\(Int((f * 100).rounded())) %", size: 13.5, color: items[i].2)
                        Spacer()
                        WNumber(text: Fmt.hm(items[i].1), size: 18)
                    }
                    .padding(.top, 16)
                    ZoneBar(fraction: f, color: items[i].2).frame(height: 28)
                }
            }
        }
    }

    // MARK: Tendencias semanales

    @ViewBuilder private func weeklyCharts(_ d: HomeData) -> some View {
        let week = (0...6).reversed().map { Day.add(d.date, -$0) }
        let days = WeekChart.days(week)
        let recs: [DayRecord?] = week.map { date -> DayRecord? in d.records.first { $0.date == date } }
        let blue = Theme.wRingSleep
        let mint = Theme.wMint
        let bars: ([Int?], (Int) -> String) -> WeekChart = { values, fmt in
            WeekChart(days: days, mode: .bars(values: values.map { v in v.map { [(Double($0), blue)] } },
                                              labels: values.map { v in v.map { WeekChart.BarLabel(text: fmt($0), color: blue) } }, max: nil))
        }
        VStack(spacing: 14) {
            ChartCard("Calificación del sueño") { bars(recs.map { $0?.sleepScore }) { "\($0) %" } }
            ChartCard("Horas vs. lo necesario (horas)", legend: [("Horas de sueño", blue), ("Sueño necesario", mint)]) {
                WeekChart(days: days, mode: .lines(series: [
                    WeekChart.Series(values: recs.map { $0?.sleepMinutes.map { Double($0) } }, color: blue,
                                     labels: recs.map { $0?.sleepMinutes.map { Fmt.hm($0) } }, labelsBelow: true),
                    WeekChart.Series(values: recs.map { $0?.needLastNight.map { Double($0) } }, color: mint,
                                     labels: recs.map { $0?.needLastNight.map { Fmt.hm($0) } }, labelsBelow: false)
                ]))
            }
            ChartCard("Horas vs. lo necesario (%)") { bars(recs.map { $0?.hoursVsNeedPct }) { "\($0) %" } }
            ChartCard("Sueño reparador (horas)", legend: [("Sueño profundo", Theme.wStageDeep), ("Sueño REM", Theme.wStageRem)]) {
                WeekChart(days: days, mode: .bars(
                    values: recs.map { r -> [(Double, Color)]? in
                        guard let deep = r?.deep, let rem = r?.rem else { return nil }
                        return [(Double(rem), Theme.wStageRem), (Double(deep), Theme.wStageDeep)]
                    },
                    labels: recs.map { r in r?.restorative.map { WeekChart.BarLabel(text: Fmt.hm($0), color: Theme.textPrimary) } }, max: nil))
            }
            ChartCard("Regularidad del sueño") { bars(recs.map { $0?.consistency }) { "\($0) %" } }
            ChartCard("Tiempo en cama") {
                WeekChart(days: days, mode: .ranges(ranges: recs.map { r -> WeekChart.Range? in
                    guard let s = r?.sleepStartMinute, let e = r?.sleepEndMinute else { return nil }
                    return WeekChart.Range(start: nightAxis(s), end: nightAxis(e), startLabel: Fmt.clock(minuteOfDay: s), endLabel: Fmt.clock(minuteOfDay: e))
                }, color: blue, dimPrevious: false, yLabels: [], optimal: []))
            }
            ChartCard("Eficiencia del sueño") {
                WeekChart(days: days, mode: .lines(series: [
                    WeekChart.Series(values: recs.map { $0?.efficiency.map { Double($0) } }, color: blue,
                                     labels: recs.map { $0?.efficiency.map { "\($0) %" } }, labelsBelow: false)
                ]))
            }
            ChartCard("Deuda de sueño") { bars(recs.map { $0?.debt }) { Fmt.hm($0) } }
            ChartCard("Estrés del sueño", legend: [("Alto", Theme.alertAmber), ("Medio", mint), ("Bajo", Theme.wLowBlue)]) {
                let ws = week.map { stressMins($0) }
                WeekChart(days: days, mode: .bars(
                    values: ws.map { m in m.map { [(Double($0.low), Theme.wLowBlue), (Double($0.mid), mint), (Double($0.high), Theme.alertAmber)] } },
                    labels: ws.map { m in m.map { WeekChart.BarLabel(text: Fmt.hm($0.high), color: Theme.alertAmber) } }, max: nil))
            }
        }
        .padding(.top, 2)
    }
}
