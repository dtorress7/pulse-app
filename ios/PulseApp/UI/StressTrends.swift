import Foundation
import SwiftUI

/* "Vista de tendencias" del Monitor de estrés (5/11, port de StressDays.kt / StressTrendsActivity.kt, copiada de las capturas de WHOOP). */

/// Reparto del estrés de cada día (bajo/medio/alto en minutos para Día total, Sin actividad y Sueño). Los días cerrados se guardan en
/// stress_days.csv (mismo formato que Android); hoy se calcula siempre.
enum StressDays {
    private static let file = "stress_days.csv"
    private static let header = "#pulseapp_stress_days v2"

    private static func readCache() -> [String: StressBreakdown.DayMins?] {
        var out = [String: StressBreakdown.DayMins?]()
        guard let t = try? String(contentsOf: AppPaths.file(file), encoding: .utf8) else { return out }
        let lines = t.components(separatedBy: "\n")
        if lines.first != header { return out }
        for l in lines.dropFirst() {
            let p = l.components(separatedBy: ",")
            if p.count == 2 && p[1] == "-" { out[p[0]] = .some(nil); continue }
            if p.count < 10 { continue }
            let v = p.dropFirst().map { Int($0) ?? 0 }
            out[p[0]] = StressBreakdown.DayMins(total: .init(low: v[0], mid: v[1], high: v[2]), noActivity: .init(low: v[3], mid: v[4], high: v[5]),
                                                sleep: .init(low: v[6], mid: v[7], high: v[8]))
        }
        return out
    }

    private static func writeCache(_ m: [String: StressBreakdown.DayMins?]) {
        var s = header + "\n"
        for k in m.keys.sorted() {
            guard let d = m[k]! else { s += "\(k),-\n"; continue }
            s += k
            for x in [d.total, d.noActivity, d.sleep] { s += ",\(x.low),\(x.mid),\(x.high)" }
            s += "\n"
        }
        try? s.data(using: .utf8)?.write(to: AppPaths.file(file), options: .atomic)
    }

    static func sleepOf(_ row: DailyMetrics?, _ dayStart: Int64) -> ClosedRange<Int64>? {
        guard let ss = row?.sleepStartMinuteOfDay, let se = row?.sleepEndMinuteOfDay else { return nil }
        let end = dayStart + Int64(se) * 60_000
        let start = ss > se ? dayStart - Int64(1440 - ss) * 60_000 : dayStart + Int64(ss) * 60_000
        return end > start ? start...end : nil
    }

    static func load(_ days: [String]) -> [String: StressBreakdown.DayMins?] {
        let store = AppStore.shared
        let today = Day.today()
        var stored = [String: DailyMetrics]()
        for d in store.lastDays(400) { stored[d.date] = d }
        let firstData = stored.keys.min()
        var cache = readCache()
        let toCompute = days.filter { $0 <= today && ($0 == today || cache[$0] == nil) }
            .filter { firstData == nil || $0 >= Day.add(firstData!, -1) || $0 == today }
        var res = [String: StressBreakdown.DayMins?]()
        let baseline = BaselineProvider.compute(store: store)
        let sessions = store.allSessions()
        let acts = sessions.filter { $0.type != Formulas.napType }.map { $0.startMillis...max($0.endMillis, $0.startMillis) }
        let naps = sessions.filter { $0.type == Formulas.napType }.map { $0.startMillis...max($0.endMillis, $0.startMillis) }
        let now = TimeUtil.nowMillis()
        var i = 0
        while i < toCompute.count {   // de 7 en 7 días para no llenar la memoria
            let chunk = Array(toCompute[i..<min(i + 7, toCompute.count)])
            let ranges = chunk.map { d in Day.start(d)...min(now, Day.start(Day.add(d, 1))) }
            let samples = WhoopManager.shared.hrLog.readings(in: ranges)
            for (k, d) in chunk.enumerated() {
                let r = ranges[k]
                let series = StressCalculator.seriesBetween(samples, from: r.lowerBound, to: r.upperBound, baseline: baseline)
                var day: StressBreakdown.DayMins? = nil
                if series.count >= 60 {
                    var sleep = [ClosedRange<Int64>]()
                    if let s = sleepOf(stored[d], r.lowerBound) { sleep.append(s) }
                    if let s = sleepOf(stored[Day.add(d, 1)], Day.start(Day.add(d, 1))) { sleep.append(s) }
                    day = StressBreakdown.of(series, sleep: sleep + naps, activities: acts)
                }
                res[d] = .some(day)
                if d != today { cache[d] = .some(day) }
            }
            i += 7
        }
        if !toCompute.isEmpty {
            let limit = Day.add(today, -2)
            writeCache(cache.filter { $0.key <= limit })
        }
        for d in days where res[d] == nil { res[d] = .some(cache[d] ?? nil) }
        return res
    }
}

struct StressTrendsView: View {
    let category: Int
    let dayOffset: Int
    @State private var cat = -1
    @State private var period = 1        // 0 = S, 1 = M, 2 = 6 M
    @State private var shift = 0
    @State private var data: [String: StressBreakdown.DayMins?]? = nil
    @State private var loadedKey = ""
    @State private var showPicker = false
    private let names = ["Estrés total diurno", "Estrés no relacionado con la actividad", "Estrés del sueño"]
    private let icons = ["gauge", "figure.stand", "moon"]
    private let months = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]
    private let wd = ["L", "M", "X", "J", "V", "S", "D"]

    private func range() -> (String, String) {
        let today = Day.today()
        switch period {
        case 0: return (Day.add(today, -6 - 7 * shift), Day.add(today, -7 * shift))
        case 1: return (Day.add(today, -29 - 30 * shift), Day.add(today, -30 * shift))
        default: return (Day.add(today, -182 * (shift + 1) + 1), Day.add(today, -182 * shift))
        }
    }
    private func dayList(_ a: String, _ b: String) -> [String] {
        var out = [String](); var d = a
        while d <= b { out.append(d); d = Day.add(d, 1) }
        return out
    }
    private func pick(_ d: StressBreakdown.DayMins??) -> StressBreakdown.Mins? {
        guard let dd = d, let x = dd else { return nil }
        let c = cat < 0 ? category : cat
        let m = c == 0 ? x.total : (c == 1 ? x.noActivity : x.sleep)
        return m.total > 0 ? m : nil
    }
    private func hm(_ m: Double) -> String { let v = Int(m.rounded()); return String(format: "%d:%02d", v / 60, v % 60) }
    private func label(_ d: String) -> String { return "\(Day.dayOfMonth(d)) \(months[Day.month(d) - 1])." }

    var body: some View {
        WScreen {
            DetailHeader(title: "Vista de tendencias")
            let c = cat < 0 ? category : cat
            Button(action: { showPicker = true }) {
                HStack(spacing: 16) {
                    Image(systemName: icons[c]).font(.system(size: 19)).foregroundColor(Theme.textSecondary)
                    WTitle(text: names[c], size: 15).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.textPrimary)
                }
                .padding(18).background(Theme.wCard).cornerRadius(14)
            }
            .buttonStyle(.plain).padding(.top, 16)
            if let data = data {
                content(data, c)
            } else {
                WBody(text: "Calculando… (la primera vez puede tardar un poco)", size: 14).padding(.top, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: load)
        .confirmationDialog("Apartado", isPresented: $showPicker) {
            ForEach(0..<3, id: \.self) { i in Button(names[i]) { cat = i } }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private func load() {
        let (a, b) = range()
        let len = dayList(a, b).count
        let need = dayList(Day.add(a, -len), b).filter { $0 <= Day.today() }
        let key = "\(period)-\(shift)"
        loadedKey = key
        data = nil
        HomeStore.shared.run({ StressDays.load(need) }, completion: { r in if loadedKey == key { data = r } })
    }

    @ViewBuilder private func content(_ data: [String: StressBreakdown.DayMins?], _ c: Int) -> some View {
        let today = Day.today()
        let (a, b) = range()
        let days = dayList(a, b)
        let prevDays = days.map { Day.add($0, -days.count) }
        let avg = avgHigh(days, data), prev = avgHigh(prevDays, data)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                WTitle(text: "Estrés alto prom.", size: 12.5, color: Theme.textSecondary)
                HStack(alignment: .lastTextBaseline, spacing: 3) { WNumber(text: avg.map { hm($0) } ?? "--", size: 38); WNumber(text: "hr", size: 17) }
                if let av = avg, let pv = prev, pv > 0 {
                    let down = av <= pv
                    let what = ["la semana anterior", "el mes anterior", "los 6 meses anteriores"][period]
                    WNumber(text: (down ? "▼ " : "▲ ") + "\(Int((abs(av - pv) * 100 / pv).rounded())) % vs. \(what)", size: 13,
                            color: down ? Theme.wMint : Theme.alertAmber)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background((down ? Theme.wMint : Theme.alertAmber).opacity(0.12)).cornerRadius(5)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Segmented(labels: ["S", "M", "6 M"], selected: Binding(get: { period }, set: { period = $0; shift = 0; load() }))
                    .frame(width: 190).padding(.top, -20)
                HStack(spacing: 4) {
                    Button(action: { shift += 1; load() }) { Image(systemName: "chevron.left").foregroundColor(Theme.textPrimary).frame(width: 32, height: 32) }
                    WTitle(text: "\(label(a)) - \(label(b)) \(TimeUtil.parts(Day.start(b)).year % 100)", size: 13)
                    Button(action: { if shift > 0 { shift -= 1; load() } }) {
                        Image(systemName: "chevron.right").foregroundColor(Theme.textPrimary.opacity(shift > 0 ? 1 : 0.3)).frame(width: 32, height: 32)
                    }
                }
            }
        }
        .padding(.top, 26)
        WBody(text: sentence(avg, prev, c), size: 16, color: Theme.textPrimary).padding(.top, 22)
        HStack(spacing: 6) {
            ForEach(Array([("Alto", Theme.alertAmber), ("Medio", Theme.wMint), ("Bajo", Theme.wLowBlue)].enumerated()), id: \.offset) { _, x in
                RoundedRectangle(cornerRadius: 1).fill(x.1).frame(width: 11, height: 11)
                WTitle(text: x.0, size: 12.5, color: Theme.textSecondary).padding(.trailing, 10)
            }
        }
        .padding(.top, 24)
        chart(days, data).frame(height: 290).padding(.top, 12)
        if b == today {
            WBody(text: "ⓘ  El promedio no incluye el día de hoy (\(label(today)))", size: 13).padding(.top, 10)
        }
        let what = [("¿Qué es el Estrés total diurno?", "El estrés es la respuesta natural del organismo a un desafío físico o mental. Es una medida del grado de alerta o activación de tu organismo en un momento dado. El Estrés total diurno incluye todo el día: también el sueño y las actividades."),
                    ("¿Qué es el Estrés no relacionado con la actividad?", "El estrés es la respuesta natural del organismo a un desafío físico o mental. Aquí solo cuenta el tiempo fuera del sueño y de las actividades de esfuerzo: el estrés del día a día (trabajo, emociones, cafeína, enfermedad…)."),
                    ("¿Qué es el Estrés del sueño?", "El estrés es la respuesta natural del organismo a un desafío físico o mental. El Estrés del sueño mide la activación mientras duermes: lo normal es que casi todo sea bajo; más medio o alto puede venir de entrenar tarde, alcohol, cenas copiosas o estar enfermo.")][c]
        VStack(alignment: .leading, spacing: 12) {
            Text(what.0).font(Theme.text(20)).foregroundColor(Theme.textPrimary)
            WBody(text: what.1, size: 15)
            WBody(text: "Bajo < 1 · Medio 1–2 · Alto ≥ 2 en la escala de 0 a 3, cada 5 minutos, frente a tu FC en reposo y tu VFC habituales.", size: 13.5)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.wCard).cornerRadius(14).padding(.top, 26)
    }

    private func avgHigh(_ ds: [String], _ data: [String: StressBreakdown.DayMins?]) -> Double? {
        let today = Day.today()
        let v = ds.filter { $0 != today }.compactMap { pick(data[$0]) }.map { Double($0.high) }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    private func sentence(_ avg: Double?, _ prev: Double?, _ c: Int) -> String {
        guard let av = avg else { return "Aún no hay días con datos en este periodo." }
        let esto = shift > 0 ? "En este periodo" : ["Esta semana", "Este mes", "En estos 6 meses"][period]
        let antes = ["los 7 días anteriores", "los 30 días anteriores", "los 6 meses anteriores"][period]
        let donde = ["", "", " mientras dormías"][c]
        let extra = [" Esto incluye el tiempo dedicado a actividades de sueño y esfuerzo.", " Esto excluye el tiempo dedicado a actividades de sueño y esfuerzo.", ""][c]
        var s = "\(esto) pasaste un promedio de \(hm(av)) horas en la zona de estrés alto\(donde)"
        if let pv = prev { s += ", lo cual es \(av <= pv ? "inferior" : "superior") a tu promedio de \(antes) (\(hm(pv)))." } else { s += "." }
        return s + extra
    }

    private func chart(_ days: [String], _ data: [String: StressBreakdown.DayMins?]) -> some View {
        var bars = [StressBreakdown.Mins?]()
        var labels = [(String, String)?]()
        if period == 2 {
            var i = 0
            var lastMonth = -1
            while i < days.count {
                let wk = Array(days[i..<min(i + 7, days.count)])
                let ms = wk.compactMap { pick(data[$0]) }
                bars.append(ms.isEmpty ? nil : StressBreakdown.Mins(low: ms.reduce(0) { $0 + $1.low }, mid: ms.reduce(0) { $0 + $1.mid },
                                                                     high: ms.reduce(0) { $0 + $1.high }))
                let m = Day.month(wk[0])
                labels.append(m != lastMonth ? (months[m - 1], "") : nil)
                lastMonth = m
                i += 7
            }
        } else {
            for (i, d) in days.enumerated() {
                bars.append(pick(data[d]))
                if period == 0 { labels.append((wd[Day.weekdayIndex(d)], "\(Day.dayOfMonth(d))")) }
                else { labels.append((days.count - 1 - i) % 7 == 0 ? (months[Day.month(d) - 1], "\(Day.dayOfMonth(d))") : nil) }
            }
        }
        return Canvas { ctx, size in
            let w = size.width, h = size.height
            let left = 44.0, right = w - 4, top = 8.0, bottom = h - 36
            for i in 0...4 {
                let y = bottom - (bottom - top) * Double(i) / 4
                var g = Path(); g.move(to: CGPoint(x: left, y: y)); g.addLine(to: CGPoint(x: right, y: y))
                ctx.stroke(g, with: .color(.white.opacity(0.12)), lineWidth: 1)
                ctx.draw(Text("\(i * 25) %").font(Theme.label(12)).foregroundColor(Theme.textSecondary), at: CGPoint(x: 0, y: y), anchor: .leading)
            }
            let n = max(bars.count, 1)
            let slot = (right - left) / Double(n)
            let bw = min(slot * 0.72, 26)
            for (i, b) in bars.enumerated() {
                let cx = left + slot * (Double(i) + 0.5)
                if let l = labels[i] {
                    ctx.draw(Text(l.0).font(Theme.label(12)).foregroundColor(Theme.textSecondary), at: CGPoint(x: cx, y: bottom + 12), anchor: .center)
                    ctx.draw(Text(l.1).font(Theme.label(12)).foregroundColor(Theme.textSecondary), at: CGPoint(x: cx, y: bottom + 27), anchor: .center)
                }
                guard let b = b, b.total > 0 else { continue }
                var y = bottom
                for (v, col) in [(b.low, Theme.wLowBlue), (b.mid, Theme.wMint), (b.high, Theme.alertAmber)] where v > 0 {
                    let hh = (bottom - top) * Double(v) / Double(b.total)
                    ctx.fill(Path(CGRect(x: cx - bw / 2, y: y - hh, width: bw, height: hh)), with: .color(col))
                    y -= hh
                }
            }
        }
    }
}
