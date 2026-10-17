import Foundation
import SwiftUI

/// Esfuerzo con el aspecto de WHOOP (port de ActivitiesListActivity de Android, 17/10): anillo grande con la marca del
/// esfuerzo recomendado, zonas de FC, fuerza y pasos frente a tus últimos 30 días, explicación del nivel, actividades del día,
/// tendencias semanales y el historial.
struct StrainDetailView: View {
    let dayOffset: Int
    var showBack: Bool = true
    @Binding var path: [Route]
    @ObservedObject private var store = HomeStore.shared
    @State private var data: HomeData? = nil

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
        HomeStore.shared.load(dayOffset) { data = $0 }
    }

    @ViewBuilder private func content(_ d: HomeData) -> some View {
        let day = d.day
        let monthAgo = Day.add(d.date, -30)
        let prev = d.records.filter { $0.date < d.date && $0.date >= monthAgo }
        let strain = day.strain ?? 0
        // Esfuerzo recomendado según la recuperación (como WHOOP)
        let target: Double? = day.recovery.map { $0 >= 67 ? 16 : ($0 >= 34 ? 12 : 8) }

        WRing(progress: strain / 21, value: day.strain.map { Fmt.comma($0) } ?? "--", label: "Esfuerzo", color: Theme.strainBlue,
              size: 260, strokeRatio: 0.055, numberRatio: 0.28, labelRatio: 0.055, topText: "PULSE", marker: target.map { $0 / 21 })
            .frame(maxWidth: .infinity).padding(.top, 14)

        comparisonCard(d, prev).padding(.top, 18)

        WBody(text: levelText(d, prev, target), size: 15.5, color: Theme.textPrimary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.wBgMid)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.wInsightBorder, lineWidth: 1.5))
            .cornerRadius(14)
            .padding(.top, 16)

        WHeading(text: d.isToday ? "Actividades de hoy" : "Actividades del día").padding(.top, 30).padding(.bottom, 14)
        if d.sessions.isEmpty {
            WBody(text: "No hay actividades este día. Añádelas con el + de Inicio.", size: 14)
        }
        VStack(spacing: 10) {
            ForEach(d.sessions) { s in
                Button(action: { path.append(.activity(s.id)) }) {
                    ActivityRowView(color: Theme.strainBlue, icon: WText.sportIcon(s.type), value: Fmt.comma(s.strain), name: s.type,
                                    start: WText.time(s.startMillis), end: WText.time(s.endMillis))
                }
                .buttonStyle(.plain)
            }
        }

        WHeading(text: "Tendencias semanales").padding(.top, 28)
        weeklyCharts(d)

        let all = Array(AppStore.shared.allSessions().prefix(30))
        if !all.isEmpty {
            WHeading(text: "Todas las actividades").padding(.top, 28).padding(.bottom, 14)
            VStack(spacing: 10) {
                ForEach(all) { s in
                    Button(action: { path.append(.activity(s.id)) }) {
                        ActivityRowView(color: Theme.strainBlue, icon: WText.sportIcon(s.type), value: Fmt.comma(s.strain), name: s.type,
                                        start: "\(TimeUtil.parts(s.startMillis).day) \(WText.monthLow(TimeUtil.dayKey(s.startMillis)))",
                                        end: WText.time(s.startMillis))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func comparisonCard(_ d: HomeData, _ prev: [DayRecord]) -> some View {
        let day = d.day
        func zoneMin(_ r: DayRecord, _ pick: (ZoneDay) -> Int) -> Int? { return r.zones.map { pick($0) / 60 } }
        func avgOf(_ f: (DayRecord) -> Int?) -> Double? {
            let v = prev.compactMap(f)
            return v.isEmpty ? nil : Double(v.reduce(0, +)) / Double(v.count)
        }
        let z13 = zoneMin(day) { $0.z13Seconds }, z13a = avgOf { r in zoneMin(r) { $0.z13Seconds } }
        let z45 = zoneMin(day) { $0.z45Seconds }, z45a = avgOf { r in zoneMin(r) { $0.z45Seconds } }
        let str = day.strengthMinutes, stra = avgOf { $0.strengthMinutes }
        let steps = day.steps, stepsa = avgOf { $0.steps }
        func row(_ icon: String, _ label: String, _ v: Int?, _ a: Double?, _ fmt: (Int) -> String) -> ValueRow {
            return ValueRow(icon: icon, label: label, value: v.map(fmt) ?? "--", trend: WTrend.of(v.map { Double($0) }, a), goodWhenHigh: true,
                            avg: a.map { fmt(Int($0.rounded())) })
        }
        return WCard {
            row("heart.circle", "Zonas de frecuencia cardíaca 1-3", z13, z13a) { Fmt.hm($0) }
            WDivider()
            row("bolt.heart.fill", "Zonas de frecuencia cardíaca 4-5", z45, z45a) { Fmt.hm($0) }
            WDivider()
            row("dumbbell.fill", "Tiempo de actividad de fuerza", str, stra) { Fmt.hm($0) }
            WDivider()
            row("figure.walk", "Pasos", steps, stepsa) { Fmt.thousands(Int64($0)) }
            HStack(spacing: 2) {
                Image(systemName: "arrowtriangle.up.fill").font(.system(size: 9)).foregroundColor(Theme.wMint)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundColor(Theme.wTrendAmber)
                Text("\(WText.dateShort(d.date)) vs. los últimos 30 días").font(Theme.text(14)).foregroundColor(Theme.textPrimary).padding(.leading, 8)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.background).cornerRadius(8)
            .padding(.top, 10)
        }
    }

    private func levelText(_ d: HomeData, _ prev: [DayRecord], _ target: Double?) -> String {
        let day = d.day
        let strain = day.strain ?? 0
        var byDate = [String: DayRecord]()
        for r in d.records { byDate[r.date] = r }
        let weekLoad = (0...6).compactMap { byDate[Day.add(d.date, -$0)]?.strain }.reduce(0, +)
        let ps = prev.compactMap { $0.strain }
        let prevWeeks: Double? = ps.count >= 7 ? ps.reduce(0, +) / Double(ps.count) * 7 : nil
        var text: String
        if day.strain == nil { text = "Todavía no hay esfuerzo calculado para este día." }
        else if strain < 10 { text = "Se considera que el esfuerzo por debajo de 10 es ligero." }
        else if strain < 14 { text = "Se considera que el esfuerzo entre 10 y 13,9 es moderado." }
        else if strain < 18 { text = "Se considera que el esfuerzo entre 14 y 17,9 es alto." }
        else { text = "Un esfuerzo de 18 o más es máximo: tu cuerpo necesitará recuperarse bien." }
        if let pw = prevWeeks {
            if weekLoad < pw * 0.8 { text += " Tu carga cardiovascular acumulada es baja." }
            else if weekLoad > pw * 1.2 { text += " Tu carga cardiovascular acumulada es alta." }
            else { text += " Tu carga cardiovascular acumulada está en tu media." }
        }
        if let t = target {
            text += " Para tu recuperación de hoy, el esfuerzo recomendado ronda \(Fmt.comma(t, 0)) (la marca blanca del anillo)."
        }
        return text
    }

    @ViewBuilder private func weeklyCharts(_ d: HomeData) -> some View {
        let week = (0...6).reversed().map { Day.add(d.date, -$0) }
        let days = WeekChart.days(week)
        let recs: [DayRecord?] = week.map { date -> DayRecord? in d.records.first { $0.date == date } }
        let blue = Theme.strainBlue
        let white = Theme.textPrimary
        let z = Theme.wZoneBar
        VStack(spacing: 14) {
            ChartCard("Esfuerzo") {
                WeekChart(days: days, mode: .bars(values: recs.map { r in r?.strain.map { [($0, blue)] } },
                                                  labels: recs.map { r in r?.strain.map { WeekChart.BarLabel(text: Fmt.comma($0), color: blue) } }, max: 21))
            }
            ChartCard("Zonas de FC 1-3", legend: [("Zona 1", z[0]), ("Zona 2", z[1]), ("Zona 3", z[2])]) {
                WeekChart(days: days, mode: .bars(
                    values: recs.map { r in r?.zones.map { [(Double($0.z1) / 60, z[0]), (Double($0.z2) / 60, z[1]), (Double($0.z3) / 60, z[2])] } },
                    labels: recs.map { r in r?.zones.map { WeekChart.BarLabel(text: Fmt.hm($0.z13Seconds / 60), color: white) } }, max: nil))
            }
            ChartCard("Zonas de FC 4-5", legend: [("Zona 4", z[3]), ("Zona 5", z[4])]) {
                WeekChart(days: days, mode: .bars(
                    values: recs.map { r in r?.zones.map { [(Double($0.z4) / 60, z[3]), (Double($0.z5) / 60, z[4])] } },
                    labels: recs.map { r in r?.zones.map { WeekChart.BarLabel(text: Fmt.hm($0.z45Seconds / 60), color: white) } }, max: 30))
            }
            ChartCard("Pasos") {
                WeekChart(days: days, mode: .bars(values: recs.map { r in r?.steps.map { [(Double($0), blue)] } },
                                                  labels: recs.map { r in r?.steps.map { WeekChart.BarLabel(text: Fmt.thousands(Int64($0)), color: blue) } }, max: nil))
            }
            ChartCard("Calorías") {
                WeekChart(days: days, mode: .bars(values: recs.map { r in r?.kcal.map { [($0, blue)] } },
                                                  labels: recs.map { r in r?.kcal.map { WeekChart.BarLabel(text: Fmt.thousands(Int64($0.rounded())), color: blue) } }, max: nil))
            }
            ChartCard("Tiempo de actividad de fuerza") {
                WeekChart(days: days, mode: .bars(values: recs.map { r in [(Double(r?.strengthMinutes ?? 0), blue)] },
                                                  labels: recs.map { r in WeekChart.BarLabel(text: Fmt.hm(r?.strengthMinutes ?? 0), color: white) }, max: 30))
            }
        }
        .padding(.top, 2)
    }
}
