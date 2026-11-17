import Foundation
import SwiftUI

/// Recuperación con el aspecto de WHOOP (29/10, copiado de su pantalla "Hoy → Recuperación"): anillo grande, tarjeta con VFC,
/// FC en reposo, frecuencia respiratoria y calificación del sueño (valor, flecha y tu media de 30 días debajo) y la leyenda
/// "Hoy vs. los últimos 30 días". Debajo, cómo se calcula y la recuperación de la semana.
struct RecoveryDetailView: View {
    let dayOffset: Int
    var showBack: Bool = true
    @ObservedObject private var store = HomeStore.shared
    @ObservedObject private var app = AppModel.shared
    @State private var data: HomeData? = nil
    @State private var metric = "hrv"

    var body: some View {
        WScreen {
            DetailHeader(title: dayOffset == 0 ? "Hoy" : WText.dateTitle(Day.add(Day.today(), dayOffset)), showBack: showBack)
            if let d = data {
                content(d)
            } else {
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { HomeStore.shared.load(dayOffset) { data = $0 } }
        .onChange(of: store.version) { _ in HomeStore.shared.load(dayOffset) { data = $0 } }
    }

    @ViewBuilder private func content(_ d: HomeData) -> some View {
        let day = d.day
        let rec = day.recovery
        let hrvAvg = RecoveryDetailView.avg30(d) { $0.hrv }
        let rhrAvg = RecoveryDetailView.avg30(d) { $0.rhr.map { Double($0) } }
        let respAvg = RecoveryDetailView.avg30(d) { $0.resp }
        let scoreAvg = RecoveryDetailView.avg30(d) { $0.sleepScore.map { Double($0) } }

        WRing(progress: Double(rec ?? 0) / 100, value: rec.map { "\($0)%" } ?? "--", label: "Recuperación",
              color: rec.map { Theme.wRecoveryColor($0) } ?? Theme.wRecoveryHigh, size: 260,
              strokeRatio: 0.055, numberRatio: 0.26, suffixRatio: 0.5, labelRatio: 0.052, topText: "PULSE")
            .frame(maxWidth: .infinity).padding(.top, 14)

        // 17/11 rediseño: qué dice tu recuperación y el esfuerzo que te sienta bien hoy
        if let r = rec {
            Text(RecoveryDetailView.advice(r)).font(Theme.text(15)).foregroundColor(Color(hex: 0xD5DDE2))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 14)
        }

        // ---------- Qué la explica: hoy frente a tu rango habitual de 30 días; tocar una fila cambia la gráfica ----------
        WHeading(text: "Qué la explica").padding(.top, 30)
        Text(dayOffset == 0 ? "Hoy frente a tus últimos 30 días. Toca una fila para ver su tendencia."
                            : "Este día frente a los 30 días anteriores. Toca una fila para ver su tendencia.")
            .font(Theme.text(13)).foregroundColor(RD.text2).padding(.top, 4)
        VStack(spacing: 8) {
            ForEach(RecoveryDetailView.order, id: \.self) { key in
                if let v = d.vitals.first(where: { $0.key == key }) {
                    vitalRow(v, avg: key == "hrv" ? hrvAvg : (key == "rhr" ? rhrAvg : (key == "resp" ? respAvg : nil)))
                }
            }
        }
        .padding(.top, 12)

        trendCard(d).padding(.top, 12)

        // ---------- Cómo se calcula ----------
        WHeading(text: "Cómo se calcula").padding(.top, 34)
        WCard {
            if dayOffset == 0 {
                let r = app.snap.recovery
                valueLine("VFC frente a tu media", r.hrvDeltaPct.map { signed($0) + " %" })
                WDivider()
                valueLine("FC en reposo frente a tu media", r.rhrDelta.map { signed($0) + " lpm" })
                WDivider()
            }
            WBody(text: "Como en WHOOP, la recuperación sale de tu VFC y tu FC en reposo de esta noche comparadas con tu propia media "
                  + "de las últimas semanas (más VFC y menos pulso que de costumbre = más recuperación). Si la respiración se dispara, baja. "
                  + "La calificación del sueño se muestra como en WHOOP pero no cambia la nota: en tus 199 noches de WHOOP no mejoraba el cálculo.",
                  size: 14)
                .padding(.vertical, 12)
            if dayOffset == 0 && !app.snap.recovery.personalBaseline {
                WBody(text: "Aún no hay 3 días de datos: se usa una referencia genérica.", size: 13).padding(.bottom, 8)
            }
        }
        .padding(.top, 14)

        // ---------- Semana ----------
        let week = (0...6).reversed().map { Day.add(d.date, -$0) }
        let recs: [Int?] = week.map { date in d.records.first { $0.date == date }?.recovery }
        WHeading(text: "Tendencias semanales").padding(.top, 34)
        ChartCard("Recuperación") {
            WeekChart(days: WeekChart.days(week), mode: .bars(
                values: recs.map { v in v.map { [(Double($0), Theme.wRecoveryColor($0))] } },
                labels: recs.map { v in v.map { WeekChart.BarLabel(text: "\($0) %", color: Theme.wRecoveryColor($0)) } }, max: 100))
        }
        .padding(.top, 14).padding(.bottom, 30)
    }

    static let order = ["hrv", "rhr", "resp", "temp"]

    static func advice(_ r: Int) -> String {
        if r >= 67 { return "Recuperación alta: tu cuerpo está listo. Hoy te sienta bien un esfuerzo de unos 16." }
        if r >= 34 { return "Recuperación media: un esfuerzo moderado, de unos 12, es buena idea." }
        return "Recuperación baja: prioriza descansar. Un esfuerzo de unos 8 como mucho."
    }

    private func fmtVital(_ v: VitalStatus, _ x: Double) -> String {
        return v.decimals > 0 ? Fmt.comma(x, v.decimals) : Fmt.int(x)
    }

    /// Fila como la maqueta: nombre, diferencia con tu media, valor, barra con tu rango habitual y una frase.
    private func vitalRow(_ v: VitalStatus, avg: Double?) -> some View {
        let selectable = v.key != "temp"
        let on = selectable && metric == v.key
        let name: String = v.key == "hrv" ? "VFC" : (v.key == "rhr" ? "FC en reposo" : (v.key == "resp" ? "Respiración" : "Temperatura de la piel"))
        let unit = v.key == "resp" ? "rpm" : v.unit
        var delta = ""
        if let x = v.value, let a = avg {
            let dd = x - a
            delta = (dd >= 0 ? "+" : "−") + fmtVital(v, abs(dd))
        }
        let markColor: Color = v.ok == nil ? RD.text2 : (v.ok! ? Theme.wMint : Theme.wTrendAmber)
        var note = "Aún sin rango: hacen falta más noches."
        if let lo = v.lo, let hi = v.hi, let x = v.value {
            let range = fmtVital(v, lo) + " a " + fmtVital(v, hi) + " " + unit
            if x < lo { note = "Por debajo de tu rango habitual, " + range }
            else if x > hi { note = "Por encima de tu rango habitual, " + range }
            else { note = "Dentro de tu rango habitual, " + range }
        }
        var sLo = (v.lo ?? (v.value ?? 0) - 1), sHi = (v.hi ?? (v.value ?? 0) + 1)
        let span = max(sHi - sLo, 0.2)
        sLo -= span * 0.8; sHi += span * 0.8
        if let x = v.value { sLo = min(sLo, x - span * 0.1); sHi = max(sHi, x + span * 0.1) }
        let scaleLo = sLo, scaleHi = sHi
        return Button(action: { if selectable { withAnimation(.easeOut(duration: 0.2)) { metric = v.key } } }) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(Theme.text(15, .semibold)).foregroundColor(Theme.textPrimary)
                    Spacer()
                    if !delta.isEmpty {
                        WNumber(text: delta + (v.key == "temp" ? "" : " frente a tu media"), size: 14, color: markColor)
                    }
                    WNumber(text: v.value.map { fmtVital(v, $0) + (v.key == "temp" ? " °C" : "") } ?? "--", size: 24)
                    if v.key != "temp" { Text(unit).font(Theme.number(13)).foregroundColor(RD.text2) }
                }
                RangeBar(value: v.value, lo: v.lo, hi: v.hi, scaleLo: scaleLo, scaleHi: scaleHi, color: markColor)
                Text(note).font(Theme.text(12)).foregroundColor(RD.text2)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(on ? RD.cardOn : RD.card)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? Theme.logoBlue : Color.clear, lineWidth: 2))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Tendencia de la métrica elegida (Semana / Mes) con tu rango habitual sombreado.
    @ViewBuilder private func trendCard(_ d: HomeData) -> some View {
        let v = d.vitals.first { $0.key == metric }
        let band: ClosedRange<Double>? = {
            guard let lo = v?.lo, let hi = v?.hi, hi > lo else { return nil }
            return lo...hi
        }()
        switch metric {
        case "rhr":
            RecordTrendCard(title: "Tendencia de FC en reposo", records: d.records, endDate: d.date, pick: { $0.rhr.map { Double($0) } },
                            format: { Fmt.int($0) }, unit: "lpm", band: band).id("rhr")
        case "resp":
            RecordTrendCard(title: "Tendencia de respiración", records: d.records, endDate: d.date, pick: { $0.resp },
                            format: { Fmt.comma($0) }, unit: "rpm", band: band).id("resp")
        default:
            RecordTrendCard(title: "Tendencia de VFC", records: d.records, endDate: d.date, pick: { $0.hrv },
                            format: { Fmt.int($0) }, unit: "ms", band: band).id("hrv")
        }
    }

    /// Media de los 30 días anteriores al día mostrado.
    static func avg30(_ d: HomeData, _ f: (DayRecord) -> Double?) -> Double? {
        let monthAgo = Day.add(d.date, -30)
        let v = d.records.filter { $0.date < d.date && $0.date >= monthAgo }.compactMap(f)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    /// Fila como WHOOP: icono, nombre en mayúsculas, valor grande con flecha y tu media de 30 días debajo.
    private func metricRow(_ icon: String, _ label: String, _ value: String?, _ avg: String?, _ trend: Trend?, good: Bool) -> some View {
        HStack(spacing: 0) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(Theme.textSecondary).frame(width: 26)
            WTitle(text: label, size: 13.5).lineLimit(2).padding(.leading, 12)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    WNumber(text: value ?? "--", size: 32)
                    TrendIcon(trend: trend, color: WTrend.color(trend, good), size: 11).frame(width: 12)
                }
                if let a = avg { WNumber(text: a, size: 16, color: Theme.textSecondary).padding(.trailing, 20) }
            }
        }
        .padding(.vertical, 16)
    }

    private func valueLine(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
            Spacer()
            WNumber(text: value ?? "--", size: 19)
        }
        .padding(.vertical, 12)
    }

    private func signed(_ v: Double) -> String { return (v >= 0 ? "+" : "") + Fmt.comma(v) }
}
