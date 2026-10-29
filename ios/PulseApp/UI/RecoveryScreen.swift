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

    var body: some View {
        WScreen {
            DetailHeader(title: dayOffset == 0 ? "Hoy" : WText.dateTitle(Day.add(Day.today(), dayOffset)), showBack: showBack)
            if let d = data {
                content(d)
            } else {
                ProgressView().tint(Theme.textSecondary).frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { HomeStore.shared.load(dayOffset) { data = $0 } }
        .onChange(of: store.version) { _ in HomeStore.shared.load(dayOffset) { data = $0 } }
    }

    @ViewBuilder private func content(_ d: HomeData) -> some View {
        let day = d.day
        let rec = day.recovery
        let monthAgo = Day.add(d.date, -30)
        let prev = d.records.filter { $0.date < d.date && $0.date >= monthAgo }
        func avgD(_ f: (DayRecord) -> Double?) -> Double? {
            let v = prev.compactMap(f); return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        let hrvAvg = avgD { $0.hrv }
        let rhrAvg = avgD { $0.rhr.map { Double($0) } }
        let respAvg = avgD { $0.resp }
        let scoreAvg = avgD { $0.sleepScore.map { Double($0) } }

        WRing(progress: Double(rec ?? 0) / 100, value: rec.map { "\($0)%" } ?? "--", label: "Recuperación",
              color: rec.map { Theme.wRecoveryColor($0) } ?? Theme.wRecoveryHigh, size: 260,
              strokeRatio: 0.055, numberRatio: 0.26, suffixRatio: 0.5, labelRatio: 0.052, topText: "PULSE")
            .frame(maxWidth: .infinity).padding(.top, 14)

        WCard {
            metricRow("waveform.path.ecg", "Variabilidad de la\nfrecuencia cardíaca", day.hrv.map { Fmt.int($0) }, hrvAvg.map { Fmt.int($0) },
                      WTrend.of(day.hrv, hrvAvg, tol: 1), good: true)
            WDivider()
            metricRow("heart", "Frecuencia cardíaca\nen reposo", day.rhr.map { "\($0)" }, rhrAvg.map { Fmt.int($0) },
                      WTrend.of(day.rhr.map { Double($0) }, rhrAvg, tol: 0.5), good: false)
            WDivider()
            metricRow("lungs", "Frecuencia\nrespiratoria", day.resp.map { Fmt.comma($0) }, respAvg.map { Fmt.comma($0) },
                      WTrend.of(day.resp, respAvg, tol: 0.05), good: false)
            WDivider()
            metricRow("moon", "Calificación\ndel sueño", day.sleepScore.map { "\($0) %" }, scoreAvg.map { String(format: "%.0f %%", $0) },
                      WTrend.of(day.sleepScore.map { Double($0) }, scoreAvg, tol: 0.5), good: true)
            HStack(spacing: 8) {
                HStack(spacing: 1) {
                    Image(systemName: "arrowtriangle.up.fill").font(.system(size: 9)).foregroundColor(Theme.wMint)
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundColor(Theme.wTrendAmber)
                }
                Text(dayOffset == 0 ? "Hoy vs. los últimos 30 días" : "Este día vs. los 30 días anteriores")
                    .font(Theme.text(14.5)).foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Theme.background).cornerRadius(8)
            .padding(.top, 12)
        }
        .padding(.top, 18)

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
