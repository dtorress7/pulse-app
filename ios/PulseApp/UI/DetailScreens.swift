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
        let base = data?.vitals ?? []
        let tiles = base.contains { $0.key == "temp" } ? base : base + [temp]
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
                WNumber(text: v.value.map { (v.key == "temp" && $0 > 0 ? "+" : "") + fmt($0, v.decimals) } ?? "--", size: 46)
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
        if v.key == "temp" { return ("cerca de \(lo > 0 ? "+" : "")\(loS) a \(hi > 0 ? "+" : "")\(hiS)", v.ok) }
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

/// Medidor del Monitor de estrés como WHOOP (5/11): arco 0,0–3,0 (azul → verde → ámbar), marca en el valor, número, nivel y hora.
struct StressGauge: View {
    let value: Double?
    let level: String
    let time: String
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let r = min(w * 0.36, h * 0.48)
            let c = CGPoint(x: w / 2, y: r + 16)
            let start = 150.0, sweep = 240.0
            func pt(_ deg: Double, _ rr: Double) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
            }
            var track = Path()
            track.addArc(center: c, radius: r, startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
            ctx.stroke(track, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            // Degradado a lo largo del arco: tramos cortos con su color
            let n = 60
            for i in 0..<n {
                let f0 = Double(i) / Double(n), f1 = Double(i + 1) / Double(n)
                var seg = Path()
                seg.addArc(center: c, radius: r, startAngle: .degrees(start + sweep * f0), endAngle: .degrees(start + sweep * f1 + 0.6), clockwise: false)
                let col: Color = f0 < 0.5 ? mix(Theme.wLowBlue, Theme.wMint, f0 / 0.5) : mix(Theme.wMint, Theme.alertAmber, (f0 - 0.5) / 0.5)
                ctx.stroke(seg, with: .color(col), style: StrokeStyle(lineWidth: 7, lineCap: i == 0 || i == n - 1 ? .round : .butt))
            }
            if let v = value {
                let deg = start + sweep * min(max(v, 0), 3) / 3
                var t = Path(); t.move(to: pt(deg, r - 10)); t.addLine(to: pt(deg, r + 10))
                ctx.stroke(t, with: .color(.white), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            ctx.draw(Text(value.map { Fmt.comma($0, 1) } ?? "--").font(Theme.number(r * 0.62)).foregroundColor(Theme.textPrimary),
                     at: CGPoint(x: c.x, y: c.y - r * 0.08), anchor: .center)
            let lc: Color = level == "ALTO" ? Theme.alertAmber : (level == "MEDIO" ? Theme.wMint : Theme.wLowBlue)
            ctx.draw(Text(level).font(Theme.number(17)).tracking(2).foregroundColor(lc), at: CGPoint(x: c.x, y: c.y + r * 0.34), anchor: .center)
            ctx.draw(Text(time).font(Theme.label(13)).foregroundColor(Theme.textSecondary), at: CGPoint(x: c.x, y: c.y + r * 0.56), anchor: .center)
            let ey = pt(start, r).y + 22
            ctx.draw(Text("0,0").font(Theme.label(13)).foregroundColor(Theme.textSecondary), at: CGPoint(x: pt(start, r).x, y: ey), anchor: .center)
            ctx.draw(Text("3,0").font(Theme.label(13)).foregroundColor(Theme.textSecondary), at: CGPoint(x: pt(start + sweep, r).x, y: ey), anchor: .center)
        }
    }
    private func mix(_ a: Color, _ b: Color, _ f: Double) -> Color {
        let ua = UIColor(a), ub = UIColor(b)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0, r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(min(max(f, 0), 1))
        return Color(red: Double(r1 + (r2 - r1) * t), green: Double(g1 + (g2 - g1) * t), blue: Double(b1 + (b2 - b1) * t))
    }
}

/// Monitor de estrés (port de StressDetailActivity; 5/11 como la app de WHOOP): "< HOY >", medidor con el valor de ahora,
/// gráfica de las 24 h anteriores con el sueño y las actividades, y Día total / Sin actividad / Sueño frente a tu día
/// habitual a la misma hora (mismos días de la semana de las 4 semanas anteriores; si no hay, los últimos 7 días).
struct StressDetailView: View {
    let initialOffset: Int
    @Binding var path: [Route]
    struct Result {
        let today: StressBreakdown.DayMins
        let habitual: StressBreakdown.DayMins?
        let sameWeekday: Bool
        let chart: [StressPoint]
        let chartFrom: Int64
        let chartTo: Int64
        let sleeps: [(Int64, Int64)]
        let activities: [(Int64, Int64)]
        let offset: Int
    }
    @State private var offset: Int? = nil
    @State private var result: Result? = nil
    @State private var showInfo = false
    private static let weekdayNames = ["LUNES", "MARTES", "MIÉRCOLES", "JUEVES", "VIERNES", "SÁBADO", "DOMINGO"]

    var body: some View {
        WScreen {
            DetailHeader(title: "Monitor de estrés", trailing: AnyView(
                Button(action: { showInfo = true }) {
                    Image(systemName: "info.circle").font(.system(size: 20)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                }))
            let off = offset ?? initialOffset
            let day = Day.add(Day.today(), off)
            HStack(spacing: 6) {
                Button(action: { offset = off - 1; load() }) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 40, height: 40)
                }
                WTitle(text: off == 0 ? "Hoy" : (off == -1 ? "Ayer" : "\(WText.weekdayUpper(day))., \(WText.monthUpper(day)). \(Day.dayOfMonth(day))"), size: 15)
                    .frame(minWidth: 110)
                Button(action: { if off < 0 { offset = off + 1; load() } }) {
                    Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.textPrimary.opacity(off < 0 ? 1 : 0.3))
                        .frame(width: 40, height: 40)
                }
            }
            .frame(maxWidth: .infinity)
            if let r = result, r.offset == off {
                let last = r.chart.last
                let level = last == nil ? "" : (last!.score < 1 ? "BAJO" : (last!.score < 2 ? "MEDIO" : "ALTO"))
                StressGauge(value: last.map { Double($0.score) }, level: level, time: last.map { Fmt.clock($0.timeMillis) } ?? "")
                    .frame(height: 230)
                    .onTapGesture { showInfo = true }
                StressDayChart(points: r.chart, from: r.chartFrom, to: r.chartTo, showNow: off == 0, whoopStyle: true,
                               activities: r.activities, sleeps: r.sleeps)
                    .frame(height: 230).padding(.top, 8)
                let dateText = "\(WText.weekdayUpper(day))., \(WText.monthUpper(day)). \(Day.dayOfMonth(day)) ESTRÉS "
                let vsText = r.sameWeekday ? "VS. UN \(StressDetailView.weekdayNames[Day.weekdayIndex(day)]) HABITUAL" : "VS. UN DÍA HABITUAL"
                card("gauge", "Día total", dateText, vsText, r.today.total, r.habitual?.total,
                     "El estrés experimentado a lo largo del día, incluso durante el sueño y las actividades.", 0)
                card("figure.stand", "Sin actividad", dateText, vsText, r.today.noActivity, r.habitual?.noActivity,
                     "El estrés experimentado fuera de las actividades de esfuerzo y el sueño.", 1)
                card("moon", "Sueño", dateText, vsText, r.today.sleep, r.habitual?.sleep, "El estrés experimentado durante el sueño.", 2)
                if r.habitual == nil {
                    WBody(text: "Aún no hay días anteriores con datos a esta hora para comparar. La barra de abajo aparecerá cuando los haya.", size: 14)
                        .padding(.top, 12)
                }
            } else {
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if offset == nil { offset = initialOffset }; load() }
        .alert("Monitor de estrés", isPresented: $showInfo, actions: { Button("OK", role: .cancel) {} }, message: {
            Text("El estrés (0 a 3) sale de tu pulso y tu VFC cada 5 minutos frente a tu línea base: pulso por encima de tu FC en reposo y VFC por debajo de tu media lo suben.\n\nBajo < 1 · Medio 1–2 · Alto ≥ 2.\n\nLas tarjetas comparan el día con tu día habitual a la misma hora: la barra de arriba es el día elegido y la de abajo (más apagada) tu media.")
        })
    }

    private func load() {
        let off = offset ?? initialOffset
        HomeStore.shared.load(off) { home in
            HomeStore.shared.run({ StressDetailView.compute(home, off) }, completion: { result = $0 })
        }
    }

    static func compute(_ home: HomeData, _ off: Int) -> Result {
        let store = AppStore.shared
        let baseline = BaselineProvider.compute(store: store)
        let day = Day.add(Day.today(), off)
        let dayStart = Day.start(day)
        let now = TimeUtil.nowMillis()
        let end = off == 0 ? now : Day.start(Day.add(day, 1))
        let elapsed = end - dayStart
        let all = store.allSessions()
        let sessions = all.map { $0.startMillis...max($0.endMillis, $0.startMillis) }
        var stored = [String: DailyMetrics]()
        for d in store.lastDays(60) { stored[d.date] = d }

        var sleepDay = [ClosedRange<Int64>]()
        if let f = home.sleepFromMillis, let t = home.sleepToMillis, t > f { sleepDay.append(f...t) }
        let todayDay = StressBreakdown.of(home.stressSeries, sleep: sleepDay, activities: sessions)

        func sleepOf(_ d: String) -> ClosedRange<Int64>? {
            guard let row = stored[d], let ss = row.sleepStartMinuteOfDay, let se = row.sleepEndMinuteOfDay else { return nil }
            let s = Day.start(d)
            let e = s + Int64(se) * 60_000
            let st = ss > se ? s - Int64(1440 - ss) * 60_000 : s + Int64(ss) * 60_000
            return e > st ? st...e : nil
        }
        // Gráfica: 24 h hasta ahora (o hasta el final del día elegido)
        let chartFrom = end - 86_400_000
        let chartSamples = WhoopManager.shared.hrLog.readings(from: chartFrom, to: end)
        let chart = StressCalculator.seriesBetween(chartSamples, from: chartFrom, to: end, baseline: baseline)
        var sleeps = [(Int64, Int64)]()
        if let f = home.sleepFromMillis, let t = home.sleepToMillis, t > f { sleeps.append((f, t)) }
        if let p = sleepOf(Day.add(day, -1)) { sleeps.append((p.lowerBound, p.upperBound)) }
        for s in all where s.type == Formulas.napType { sleeps.append((s.startMillis, s.endMillis)) }
        var seen = Set<Int64>()
        sleeps = sleeps.filter { $0.1 > chartFrom && $0.0 < end && seen.insert($0.0 / 60_000).inserted }
        let acts = all.filter { $0.type != Formulas.napType && $0.endMillis > chartFrom && $0.startMillis < end }.map { ($0.startMillis, $0.endMillis) }

        func dayFor(_ d: String, _ samples: [HrReading]) -> StressBreakdown.DayMins? {
            let s = Day.start(d)
            let series = StressCalculator.seriesBetween(samples, from: s, to: s + elapsed, baseline: baseline)
            if series.isEmpty || series.count < todayDay.total.total / 2 { return nil }
            return StressBreakdown.of(series, sleep: sleepOf(d).map { [$0] } ?? [], activities: sessions)
        }
        let weekDays = (1...4).map { Day.add(day, -7 * $0) }
        var samples = WhoopManager.shared.hrLog.readings(in: weekDays.map { Day.start($0)...(Day.start($0) + elapsed) })
        let same = weekDays.compactMap { dayFor($0, samples) }
        var habitual = StressBreakdown.average(same)
        var sameWeekday = !same.isEmpty
        if same.isEmpty {
            let lastWeek = (1...7).map { Day.add(day, -$0) }
            samples = WhoopManager.shared.hrLog.readings(in: lastWeek.map { Day.start($0)...(Day.start($0) + elapsed) })
            habitual = StressBreakdown.average(lastWeek.compactMap { dayFor($0, samples) })
            sameWeekday = false
        }
        return Result(today: todayDay, habitual: habitual, sameWeekday: sameWeekday, chart: chart, chartFrom: chartFrom, chartTo: end,
                      sleeps: sleeps, activities: acts, offset: off)
    }

    private func card(_ icon: String, _ title: String, _ dateText: String, _ vsText: String, _ today: StressBreakdown.Mins,
                      _ habitual: StressBreakdown.Mins?, _ description: String, _ category: Int) -> some View {
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
            Button(action: { path.append(.stressTrends(category, offset ?? initialOffset)) }) {
                HStack(spacing: 10) {
                    WTitle(text: "Ver tendencias", size: 14)
                    Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.textPrimary)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
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
    @State private var selectedZone: Int? = nil
    @State private var selectedStage: Int? = nil
    @State private var strengthTab = 0
    @State private var strengthPage = 0
    @State private var scrub: (Int64, Int)? = nil

    struct Stats { let strain: Double; let steps: Int?; let kcal: Double; let avgHr: Int; let maxHr: Int; let seconds: Int64 }
    struct Model {
        let session: ActivitySession
        let me: Stats
        let avg: [Stats]
        let chart: [(Int64, Int)]
        let zoneSec: [Int]
        let typical: [(Double, Double)?]
        let hrMax: Double
        /// 29/10: tramos [desde, hasta) en ms de cada zona y zona de cada tramo de 10 s (−1 = sin pulso), para marcar una zona
        let zoneRuns: [[(Int64, Int64)]]
        let bucketZone: [Int]
        /// 2/11: fases de la siesta (nil si no es siesta o no se pudieron calcular)
        var nap: SleepStager.Result? = nil
        /// 5/11: series del entrenador de fuerza, reparto cardio/muscular y nº de entrenos registrados hasta este
        var log: Strength.Workout? = nil
        var cardioPct = 100
        var strengthCount = 0
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
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { load() }
        .onChange(of: store.version) { _ in load() }
        .confirmationDialog("Actividad", isPresented: $showMenu) {
            Button("Editar actividad") { path.append(.editActivity(sessionId)) }
            Button(Strength.logFor(sessionId) != nil ? "Editar ejercicios (entrenador de fuerza)" : "Registrar ejercicios (entrenador de fuerza)") {
                path.append(.strengthSession("log", sessionId))
            }
            Button("Eliminar actividad", role: .destructive) { confirmDelete = true }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("¿Eliminar esta actividad?", isPresented: $confirmDelete, actions: {
            Button("Eliminar", role: .destructive) {
                AppStore.shared.deleteSession(id: sessionId)
                Strength.deleteLog(sessionId)
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
        let band = BandSteps.read()
        func stepsIn(_ a: ActivitySession) -> Int? {
            // 30/10: pasos de la pulsera (también sin el móvil cerca) + PulseApp donde la pulsera no llega
            if BandSteps.hasData(band, fromMs: a.startMillis, toMs: a.endMillis) {
                return BandSteps.merged(band, motion, fromMs: a.startMillis, toMs: a.endMillis)
            }
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
        var inside = [(Int64, Int)]()
        for r in samples where r.timeMillis >= s.startMillis && r.timeMillis <= s.endMillis {
            let sec = r.timeMillis / 1000
            if sec == lastSec { continue }
            lastSec = sec
            zoneSec[zoneOf(r.bpm, hrMax)] += 1
            inside.append((r.timeMillis, r.bpm))
        }
        // Tramos de cada zona (segundos seguidos; huecos ≤ 5 s se unen), igual que Android
        var zoneRuns = [[(Int64, Int64)]](repeating: [], count: 6)
        var curZ = -1, a: Int64 = 0, last: Int64 = 0
        for (t, b) in inside.sorted(by: { $0.0 < $1.0 }) {
            let z = zoneOf(b, hrMax)
            if z == curZ && t - last <= 5_000 { last = t; continue }
            if curZ >= 0 { zoneRuns[curZ].append((a, last + 1_000)) }
            curZ = z; a = t; last = t
        }
        if curZ >= 0 { zoneRuns[curZ].append((a, last + 1_000)) }
        let nBuckets = Int(min(max((s.endMillis - s.startMillis) / 10_000 + 1, 1), 5000))
        var bSum = [Int](repeating: 0, count: nBuckets), bCnt = [Int](repeating: 0, count: nBuckets)
        for (t, b) in inside { let k = Int((t - s.startMillis) / 10_000); if k >= 0 && k < nBuckets { bSum[k] += b; bCnt[k] += 1 } }
        let bucketZone = (0..<nBuckets).map { k in bCnt[k] > 0 ? zoneOf(Int((Double(bSum[k]) / Double(bCnt[k])).rounded()), hrMax) : -1 }
        let typical: [(Double, Double)?] = (0...5).map { z -> (Double, Double)? in
            let fr = sameType.compactMap { a -> Double? in
                let mins = [a.minutesZone0, a.minutesZone1, a.minutesZone2, a.minutesZone3, a.minutesZone4, a.minutesZone5]
                let tot = mins.reduce(0, +)
                return tot <= 0 ? nil : Double(mins[z]) / Double(tot)
            }
            return fr.count >= 2 ? (fr.min()!, fr.max()!) : nil
        }
        let nap = s.type == Formulas.napType ? NapStages.get(s, hrLog: WhoopManager.shared.hrLog) : nil
        var m = Model(session: s, me: stats(s), avg: pool.map { stats($0) }, chart: chart, zoneSec: zoneSec, typical: typical, hrMax: hrMax,
                      zoneRuns: zoneRuns, bucketZone: bucketZone, nap: nap)
        if let log = Strength.logFor(s.id), log.setCount > 0 {
            var cardio = 0.0
            if inside.count > 1 {
                for i in 1..<inside.count {
                    let dt = Double(inside[i].0 - inside[i - 1].0) / 60000
                    if dt <= 0 || dt > 8 { continue }
                    cardio += Formulas.trimp(minutes: dt, hr: inside[i].1, restingHr: Formulas.zoneRestingHr(), hrMax: hrMax)
                }
            }
            m.log = log
            m.cardioPct = Strength.cardioMuscleSplit(cardio, Strength.muscleLoad(log, bodyKg: Formulas.bodyKg())).0
            let ids = Set(all.map { $0.id })
            m.strengthCount = Strength.logs().filter { ids.contains($0.id) && $0.setCount > 0 && $0.startMs <= log.startMs }.count
        }
        return m
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
        VStack(spacing: 10) {
            Image(systemName: WText.sportIcon(s.type)).font(.system(size: 34)).foregroundColor(Theme.textPrimary)
            WTitle(text: s.type, size: 22)
            Text(whenText(s)).font(Theme.text(15)).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        if s.type == Formulas.napType { napContent(m) } else { activityContent(m) }
    }

    // 2/11: la siesta se muestra como en WHOOP (horas de sueño, sueño reparador y fases), no como una actividad
    @ViewBuilder private func napContent(_ m: Model) -> some View {
        let s = m.session
        let st = m.nap
        let asleep = NapStages.asleepMinutes(s)
        HStack(alignment: .top, spacing: 12) {
            bigStat(Fmt.hm(asleep), Theme.wRingSleep, nil, nil, "Horas de sueño")
            bigStat(st.map { Fmt.hm($0.deepMinutes + $0.remMinutes) } ?? "--", Theme.textPrimary, nil, nil, "Sueño reparador")
        }
        .padding(.top, 26)
        Text("Esta siesta redujo tu sueño requerido por \(asleep) minutos.")
            .font(Theme.text(17)).foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.wRingSleep.opacity(0.7), lineWidth: 1.5))
            .padding(.top, 22)
        let start = st?.startMillis ?? s.startMillis, end = st?.endMillis ?? s.endMillis
        let names = ["Despierto", "Ligero", "Sueño profundo (SWS)", "REM"]
        let colors = [Theme.wStageAwake, Theme.wStageLight, Theme.wStageDeep, Theme.wStageRem]
        let order = [SleepStager.awake, SleepStager.light, SleepStager.deep, SleepStager.rem]
        let runs: [[(Int64, Int64)]] = {
            var r = [[(Int64, Int64)]](repeating: [], count: 4)
            guard let st = st else { return r }
            var i = 0
            while i < st.stages.count {
                var j = i
                while j < st.stages.count && st.stages[j] == st.stages[i] { j += 1 }
                r[st.stages[i]].append(((st.startMinute + Int64(i)) * 60_000, (st.startMinute + Int64(j)) * 60_000))
                i = j
            }
            return r
        }()
        if m.chart.count >= 2 {
            ActivityHrChart(points: m.chart, start: start, end: end,
                            highlights: selectedStage.map { runs[$0] } ?? [],
                            highlightColor: selectedStage.map { colors[order.firstIndex(of: $0) ?? 0] } ?? .clear).frame(height: 300).padding(.top, 22)
        }
        HStack(spacing: 0) {
            WTitle(text: "Fases de la siesta", size: 14.5, color: Theme.textSecondary)
            Spacer()
            WTitle(text: "Duración", size: 14.5, color: Theme.textSecondary).padding(.trailing, 8)
            WNumber(text: Fmt.hm(Int((end - start) / 60_000)), size: 18)
        }
        .padding(.top, 22)
        if let st = st {
            ForEach(0..<4, id: \.self) { k in
                let stage = order[k]
                let mins = st.count(stage)
                let on = selectedStage == stage
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        WTitle(text: names[k], size: 15.5)
                        WNumber(text: "\(mins * 100 / max(st.stages.count, 1)) %", size: 15, color: colors[k])
                        Spacer()
                        WNumber(text: Fmt.hm(mins), size: 22)
                    }
                    if mins > 0 {
                        StageTimelineBar(stages: st.stages, stage: stage, color: colors[k], active: true).frame(height: 30).padding(.top, 4)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 12)
                .background(Theme.wCard).cornerRadius(14)
                .opacity(mins == 0 || (selectedStage != nil && !on) ? 0.55 : 1)
                .padding(.top, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    if mins > 0 { selectedStage = on ? nil : stage; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            }
            WTitle(text: "Métricas de la siesta", size: 15.5).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 30)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    statCard("bell", "Despertares", "\(st.awakenings)", "", nil, nil)
                    statCard("bed.double", "Eficiencia", "\(st.efficiencyPct)", "%", nil, nil)
                    statCard("heart", "FC prom.", "\(s.avgHr)", "lpm", nil, nil)
                }
            }
            .padding(.top, 16)
        } else {
            WBody(text: "Sin movimiento grabado en la siesta no se pueden calcular las fases.", size: 14.5).padding(.top, 12)
        }
        WBody(text: "Fases calculadas con tu pulso y movimiento (el mismo método que la noche). Las siestas restan su tiempo dormido de lo que necesitas dormir esa noche, como en WHOOP.", size: 14).padding(.top, 18)
    }

    @ViewBuilder private func activityContent(_ m: Model) -> some View {
        let s = m.session
        let me = m.me

        let avgStrain = average(m.avg.map { $0.strain })
        let avgSteps = average(m.avg.compactMap { $0.steps.map { Double($0) } })
        HStack(alignment: .top, spacing: 12) {
            bigStat(Fmt.comma(me.strain), Theme.strainBlue, avgStrain.map { trendOf(me.strain, $0) }, avgStrain.map { Fmt.comma($0) }, "Esfuerzo\nde actividad")
            if m.log != nil {
                cardioMuscle(m.cardioPct)
            } else {
                bigStat(me.steps.map { Fmt.thousands(Int64($0)) } ?? "--", Theme.textPrimary,
                        (me.steps != nil && avgSteps != nil) ? trendOf(Double(me.steps!), avgSteps!) : nil,
                        avgSteps.map { Fmt.thousands(Int64($0.rounded())) }, "Pasos de la actividad")
            }
        }
        .padding(.top, 26)

        if m.log != nil { Segmented(labels: ["Ejercicios", "Zonas de FC"], selected: $strengthTab) }
        let exMode = m.log != nil && strengthTab == 0
        if m.chart.count >= 2 {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                WNumber(text: scrub.map { "\($0.1)" } ?? " ", size: 34, color: Theme.strainBlue)
                if let sc = scrub {
                    WNumber(text: "lpm", size: 16, color: Theme.strainBlue)
                    WNumber(text: Fmt.clock(sc.0), size: 16, color: Theme.textSecondary).padding(.leading, 8)
                }
            }
            .padding(.top, 16).opacity(scrub == nil ? 0 : 1)
            ActivityHrChart(points: m.chart, start: s.startMillis, end: s.endMillis,
                            highlights: exMode ? exerciseRuns(m.log!) : (selectedZone.map { m.zoneRuns[$0] } ?? []),
                            highlightColor: exMode ? strengthGreen : (selectedZone.map { Theme.wZone[$0] } ?? .clear),
                            onScrub: { t, b in if let t = t, let b = b { scrub = (t, b) } else { scrub = nil } })
                .frame(height: 360).padding(.top, 6)
        } else {
            WBody(text: "No hay pulso guardado de esta actividad.", size: 14).padding(.top, 22)
        }
        if exMode { exercisePager(m.log!) }
        if !exMode { zonesSection(m) }
        keyStats(m)
    }

    private func exerciseRuns(_ log: Strength.Workout) -> [(Int64, Int64)] {
        if strengthPage == 0 || strengthPage > log.exercises.count { return [] }
        return log.exercises[strengthPage - 1].sets.compactMap { st in
            if let a = st.startMs, let b = st.endMs { return (a, b) }; return nil
        }
    }

    private func cardioMuscle(_ cardioPct: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { WTitle(text: "Cardio", size: 13); Spacer(); WTitle(text: "Muscular", size: 13) }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Color(red: 0.04, green: 0.5, blue: 0.82), Theme.strainBlue],
                                                                          startPoint: .leading, endPoint: .trailing))
                    Rectangle().fill(Color.white).frame(width: 3, height: 22).offset(x: Double(geo.size.width) * Double(cardioPct) / 100 - 1.5)
                }
            }
            .frame(height: 16)
            HStack { WNumber(text: "\(cardioPct) %", size: 17); Spacer(); WNumber(text: "\(100 - cardioPct) %", size: 17) }
        }
        .padding(.leading, 12).padding(.top, 6)
        .frame(maxWidth: .infinity)
    }

    /// Tarjetas que se deslizan: total y una por ejercicio (sus series se marcan en la gráfica); "Ver todo" abre el resumen.
    private func exercisePager(_ log: Strength.Workout) -> some View {
        let pages = log.exercises.count + 1
        let p = min(strengthPage, pages - 1)
        let vol = p == 0 ? log.volume : log.exercises[p - 1].volume
        let reps = p == 0 ? log.reps : log.exercises[p - 1].reps
        return VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    if p == 0 {
                        RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.2, green: 0.22, blue: 0.24)).frame(width: 64, height: 56)
                            .overlay(Image(systemName: "dumbbell.fill").font(.system(size: 22)).foregroundColor(.white))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(log.exercises.count) ejercicios").font(Theme.text(15.5)).foregroundColor(Theme.textPrimary)
                            Text("\(log.setCount) series").font(Theme.text(13.5)).foregroundColor(Theme.strainBlue)
                        }
                    } else {
                        let e = log.exercises[p - 1]
                        ExerciseThumb(group: Strength.exercise(e.exId)?.group, size: 50)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                            Text("\(e.sets.count) series").font(Theme.text(13.5)).foregroundColor(Theme.wMint)
                        }
                    }
                    Spacer()
                    if p > 0 { Image(systemName: "chevron.right").foregroundColor(Theme.textSecondary) }
                }
                .padding(4).background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.15, green: 0.18, blue: 0.2)))
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .lastTextBaseline, spacing: 3) { WNumber(text: SFmt.kg(vol), size: 30); WNumber(text: "kg", size: 16) }
                        WTitle(text: "Volumen de carga", size: 12, color: Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        WNumber(text: "\(reps)", size: 30)
                        WTitle(text: "Repeticiones totales", size: 12, color: Theme.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20).padding(.vertical, 18)
            }
            .background(Theme.wCard).cornerRadius(14)
            .contentShape(Rectangle())
            .onTapGesture { if p > 0 { path.append(.strengthSummary(sessionId)) } }
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if abs(v.translation.width) > abs(v.translation.height) {
                    strengthPage = v.translation.width < 0 ? min(p + 1, pages - 1) : max(p - 1, 0)
                }
            })
            HStack {
                Spacer().frame(maxWidth: .infinity)
                HStack(spacing: 7) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle().fill(i == p ? Color.white : Color.white.opacity(0.33)).frame(width: 7, height: 7)
                            .onTapGesture { strengthPage = i }
                    }
                }
                Button(action: { path.append(.strengthSummary(sessionId)) }) {
                    HStack(spacing: 8) { WTitle(text: "Ver todo", size: 14); Image(systemName: "arrow.right").foregroundColor(Theme.textPrimary) }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.top, 18)
    }

    @ViewBuilder private func zonesSection(_ m: Model) -> some View {
        let s = m.session
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
            let on = selectedZone == z
            zoneRow(z, range, m.zoneSec[z], Double(m.zoneSec[z]) / Double(total), Theme.wZone[z], m.typical[z],
                    timeline: on ? m.bucketZone : nil, dimmed: selectedZone != nil && !on)
                .contentShape(Rectangle())
                .onTapGesture {
                    // 29/10: tocar una zona la marca, como las fases del sueño
                    if m.zoneSec[z] > 0 { selectedZone = on ? nil : z; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
        }
        WBody(text: "Las zonas salen de tu reserva de FC, como en WHOOP: entre tu FC en reposo (\(Formulas.zoneRestingHr()) lpm) y tu FC máxima (\(Int(m.hrMax.rounded())) lpm), que puedes cambiar en Sobre mí.", size: 14.5).padding(.top, 12)
    }

    @ViewBuilder private func keyStats(_ m: Model) -> some View {
        let s = m.session
        let me = m.me
        let durSec = (s.endMillis - s.startMillis) / 1000

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
        if m.log != nil {
            MilestoneCard(count: m.strengthCount).padding(.top, 26)
        } else if Formulas.isStrength(s.type) {
            VStack(alignment: .leading, spacing: 10) {
                WTitle(text: "Entrenador de fuerza", size: 15)
                WBody(text: "Registra los ejercicios, series y pesos de este entreno: la carga muscular entra en el esfuerzo y verás el resumen como en WHOOP.", size: 14.5)
                PillButton(title: "Registrar ejercicios") { path.append(.strengthSession("log", sessionId)) }.padding(.top, 4)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.wCard).cornerRadius(14).padding(.top, 26)
        }
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

    private func zoneRow(_ z: Int, _ range: String, _ seconds: Int, _ fraction: Double, _ color: Color, _ typical: (Double, Double)?,
                         timeline: [Int]? = nil, dimmed: Bool = false) -> some View {
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
            if !empty, let tl = timeline {
                StageTimelineBar(stages: tl, stage: z, color: color, active: true).frame(height: 30).padding(.top, 4)
            } else if !empty {
                ZoneBar(fraction: fraction, color: color, typicalLo: typical?.0, typicalHi: typical?.1).frame(height: 44)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, empty ? 14 : 12)
        .background(Theme.wCard).cornerRadius(14)
        .opacity(empty || dimmed ? 0.55 : 1)
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
