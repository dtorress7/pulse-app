import Foundation
import SwiftUI

/* 17/11: pantalla Healthspan / WHOOP Age como la de WHOOP (vídeo del usuario): burbuja con la edad, ritmo de envejecimiento,
   apartados Sueño / Esfuerzo / Fitness con la media de 6 meses, la de 30 días y los años que suma cada dato, y la tendencia.
   Es una ESTIMACIÓN de PulseApp (ver Core/Healthspan.swift): se dice en la propia pantalla. */

/// Burbuja verde de WHOOP Age (también en pequeño en el Perfil).
struct AgeBlob: View {
    let text: String
    var size: Double = 230
    var subtitle: String? = nil
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x05140A), Color(hex: 0x0B3A17), Color(hex: 0x16EC06).opacity(0.9)],
                                     center: .center, startRadius: size * 0.18, endRadius: size * 0.52))
                .shadow(color: Color(hex: 0x16EC06).opacity(0.55), radius: size * 0.09)
                .scaleEffect(pulse ? 1.03 : 0.98)
            Circle().stroke(Color(hex: 0x6CFF7A).opacity(0.35), lineWidth: max(1, size * 0.008)).padding(size * 0.04)
            VStack(spacing: size * 0.01) {
                WNumber(text: text, size: size * 0.2)
                WTitle(text: "WHOOP Age", size: max(9, size * 0.055), color: Theme.textPrimary.opacity(0.8))
                if let s = subtitle {
                    Text(s).font(Theme.number(max(10, size * 0.06))).foregroundColor(Theme.wRecoveryHigh).padding(.top, size * 0.02)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            if !reduceMotion { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { pulse = true } }
        }
        .accessibilityElement(children: .combine)
    }

    /// "<18,0" por debajo de 18 (como WHOOP) o la edad con un decimal.
    static func text(_ age: Double?) -> String {
        guard let a = age else { return "--" }
        return a < Healthspan.minAge ? "<18,0" : Fmt.comma(a)
    }
}

struct HealthspanView: View {
    @Binding var path: [Route]
    @State private var result: Healthspan.Result? = nil
    @State private var open: Set<String> = ["regularity", "sleep_hours"]
    @State private var showInfo = false
    private let monthsUp = ["ENE", "FEB", "MAR", "ABR", "MAY", "JUN", "JUL", "AGO", "SEPT", "OCT", "NOV", "DIC"]

    var body: some View {
        WScreen {
            ZStack {
                VStack(spacing: 2) {
                    WTitle(text: "Healthspan", size: 15)
                    if let r = result {
                        WTitle(text: "Próxima actualización en \(r.nextUpdateDays) \(r.nextUpdateDays == 1 ? "día" : "días")", size: 11,
                               color: Theme.textSecondary)
                    }
                }
                HStack {
                    BackButton()
                    Spacer()
                    Button(action: { showInfo = true }) {
                        Image(systemName: "info.circle").font(.system(size: 20)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Cómo se calcula")
                }
            }
            .padding(.top, 4)
            if let r = result {
                content(r)
            } else {
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if result == nil {
                HomeStore.shared.run({ () -> Healthspan.Result in
                    let d = HomeDataLoader.load(dayOffset: 0, historyDays: 400)
                    return Healthspan.compute(records: d.records, sessions: AppStore.shared.allSessions(),
                                              profile: AppStore.shared.getProfile(), today: Day.today())
                }, completion: { result = $0 })
            }
        }
        .alert("WHOOP Age en PulseApp", isPresented: $showInfo, actions: { Button("Cerrar", action: {}) }, message: {
            Text("WHOOP no publica su fórmula (pesos, curvas ni límites de cada dato). PulseApp la estima con los mismos 8 datos que usa WHOOP (medias de 6 meses de sueño, actividad y forma física; la masa magra solo si la hay): cada uno suma o resta años según lo lejos que esté de un valor de referencia. Está ajustada para que con tus medias del 15/11 salgan los mismos años que daba WHOOP, pero puede no coincidir con la suya. Se desbloquea con 21 recuperaciones en 31 días y se actualiza cada domingo. Por debajo de 18 se muestra \"<18,0\", como WHOOP.")
        })
    }

    private func weekLabel(_ a: String, _ b: String) -> String {
        return "\(monthsUp[Day.month(a) - 1]). \(Day.dayOfMonth(a)) - \(monthsUp[Day.month(b) - 1]). \(Day.dayOfMonth(b))"
    }

    @ViewBuilder private func content(_ r: Healthspan.Result) -> some View {
        WTitle(text: weekLabel(r.weekStart, r.weekEnd), size: 13).frame(maxWidth: .infinity).padding(.top, 10)
        let younger: String = {
            guard let a = r.whoopAge, let c = r.chronoAge else { return "-- años" }
            if a < Healthspan.minAge { return "-- años más joven" }
            let d = c - a
            return Fmt.comma(abs(d)) + (d >= 0 ? " años más joven" : " años mayor")
        }()
        AgeBlob(text: AgeBlob.text(r.whoopAge), size: 240, subtitle: younger).frame(maxWidth: .infinity).padding(.top, 20)
        if r.whoopAge == nil {
            WBody(text: "Aún no está disponible: como en WHOOP, hacen falta 21 recuperaciones en los últimos 31 días (y al menos 4 de los 8 datos).", size: 13)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 10)
        }

        paceCard(r.pace).padding(.top, 26)

        ForEach(["Sueño", "Esfuerzo", "Fitness"], id: \.self) { g in
            HStack(alignment: .center) {
                Text(g).font(Theme.text(22)).foregroundColor(Theme.textPrimary)
                Spacer()
                legend("arrowtriangle.down.fill", "Prom. de\n6 meses")
                legend("arrowtriangle.up.fill", "Promedio de\n30 días").padding(.leading, 12)
            }
            .padding(.top, 30)
            VStack(spacing: 0) {
                ForEach(r.factors.filter { $0.group == g }, id: \.key) { f in
                    factorRow(f)
                    if f.key != r.factors.filter({ $0.group == g }).last?.key { WDivider() }
                }
            }
            .background(Theme.wCard).cornerRadius(14).padding(.top, 12)
        }

        WHeading(text: "Vista de tendencias").padding(.top, 34)
        historyCard(r).padding(.top, 14)

        VStack(alignment: .leading, spacing: 12) {
            Text("¿Qué es WHOOP Age?").font(Theme.text(20)).foregroundColor(Theme.textPrimary)
            WBody(text: "WHOOP Age es una edad fisiológica: cómo de joven o mayor se comporta tu cuerpo según tus hábitos de sueño, actividad y forma física de los últimos 6 meses, frente a tu edad real. El ritmo de envejecimiento dice cuántos años de WHOOP Age ganas por cada año de calendario: 1,0x es al ritmo normal, por debajo envejeces más despacio.", size: 15)
            WBody(text: "En PulseApp es una estimación propia: WHOOP no publica su fórmula.", size: 13)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.wCard).cornerRadius(14).padding(.top, 26)
    }

    private func legend(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(Theme.textSecondary)
            Text(text).font(Theme.text(11)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
        }
    }

    // MARK: Ritmo de envejecimiento (-1,0x … 3,0x)

    private func paceCard(_ pace: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WTitle(text: "Ritmo de envejecimiento", size: 13)
            HStack {
                Label("Lento", systemImage: "tortoise").font(Theme.text(12)).foregroundColor(Theme.textSecondary)
                WNumber(text: pace.map { Fmt.comma($0) + "x" } ?? "--", size: 22).padding(.leading, 12)
                Spacer()
                Label("Rápido", systemImage: "hare").font(Theme.text(12)).foregroundColor(Theme.textSecondary)
            }
            GeometryReader { g in
                let w = Double(g.size.width)
                let n = 60
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<n, id: \.self) { i in
                            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1.5, height: i % 15 == 0 ? 22 : 14)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if let p = pace {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.white).frame(width: 3, height: 30)
                            .offset(x: (p + 1) / 4 * w - 1.5)
                    }
                }
                .frame(height: 30)
            }
            .frame(height: 30)
            HStack {
                Text("-1,0x").font(Theme.label(11)).foregroundColor(Theme.textSecondary)
                Spacer()
                Text("1,0x").font(Theme.label(11)).foregroundColor(Theme.textSecondary)
                Spacer()
                Text("3,0x").font(Theme.label(11)).foregroundColor(Theme.textSecondary)
            }
        }
        .padding(16).background(Theme.wCard).cornerRadius(14)
    }

    // MARK: Cada dato

    private func fmt(_ f: Healthspan.Factor, _ v: Double) -> String {
        switch f.unit {
        case "%": return String(format: "%.0f %%", v)
        case "h": return Fmt.hm(Int((v * 60).rounded())) + " h"
        case "pasos": return Fmt.thousands(Int64(v.rounded())) + " pasos"
        default: return Fmt.int(v) + " " + f.unit
        }
    }

    private func ends(_ f: Healthspan.Factor) -> (String, String) {
        switch f.unit {
        case "%": return ("\(Int(f.lo)) %", "\(Int(f.hi)) %")
        case "h": return ("\(Int(f.lo))h", "\(Int(f.hi))h")
        case "pasos": return ("\(Int(f.lo / 1000))K", "\(Int(f.hi / 1000))K")
        case "lpm": return ("\(Int(f.lo)) lpm", "\(Int(f.hi)) lpm")
        default: return ("\(Int(f.lo))", "\(Int(f.hi))")
        }
    }

    private func status(_ f: Healthspan.Factor) -> (String, String) {
        let name = f.name.lowercased()
        guard let y = f.years else { return ("Sin datos suficientes", "Hacen falta al menos 5 días con este dato en los últimos 6 meses.") }
        if let a6 = f.avg6m, let a30 = f.avg30, (a30 > a6) == f.goodHigh, abs(a30 - a6) / max(abs(a6), 1e-9) > 0.05 {
            return ("Gran mejora", "Has hecho grandes progresos con tu \(name) este mes. Continúa por este camino para ver cómo tu WHOOP Age disminuye con el tiempo.")
        }
        if y <= -0.3 { return ("Superando", "Estás mejorando significativamente tu salud a largo plazo con tu \(name). Sigue así para mantener los beneficios duraderos.") }
        if y >= 0.3 { return ("Margen de mejora", "Tu \(name) te está sumando años. Pequeños cambios mantenidos en el tiempo la harán bajar.") }
        return ("En la media", "Tu \(name) no suma ni resta casi nada a tu WHOOP Age.")
    }

    private func factorRow(_ f: Healthspan.Factor) -> some View {
        let isOpen = open.contains(f.key)
        let (lo, hi) = ends(f)
        let yColor: Color = f.years == nil ? Theme.textSecondary : (f.years! <= 0 ? Theme.wRecoveryHigh : Theme.alertAmber)
        return VStack(alignment: .leading, spacing: 10) {
            Button(action: { withAnimation(.easeOut(duration: 0.2)) { if isOpen { open.remove(f.key) } else { open.insert(f.key) } } }) {
                HStack {
                    WTitle(text: f.name, size: 13).multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                }
                .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            HStack(alignment: .center, spacing: 10) {
                FactorBar(f: f, text6: f.avg6m.map { fmt(f, $0) }, text30: f.avg30.map { fmt(f, $0) }, loText: lo, hiText: hi,
                          showLabels: isOpen)
                VStack(spacing: 0) {
                    WNumber(text: f.years.map { ($0 > 0 ? "+" : ($0 < 0 ? "−" : "")) + Fmt.comma(abs($0)) } ?? "--", size: 19, color: yColor)
                    Text("años").font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                }
                .frame(width: 52)
            }
            if isOpen {
                let st = status(f)
                Text(st.0).font(Theme.text(15, .semibold)).foregroundColor(Theme.textPrimary).padding(.top, 4)
                WBody(text: st.1, size: 14)
                Button(action: { path.append(.trends(f.trendKey)) }) {
                    HStack(spacing: 6) {
                        WTitle(text: "Ver tendencia", size: 12.5, color: Theme.strainBlue)
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.strainBlue)
                    }
                    .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Tendencia de la edad (26 semanas)

    private func historyCard(_ r: Healthspan.Result) -> some View {
        let h = r.history
        return VStack(alignment: .leading, spacing: 12) {
            WTitle(text: "Tendencia de la edad de WHOOP", size: 13)
            HStack(spacing: 14) {
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(Theme.wRecoveryHigh).frame(width: 10, height: 10); WTitle(text: "Tu WHOOP Age", size: 11, color: Theme.textSecondary) }
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10); WTitle(text: "Edad cronológica", size: 11, color: Theme.textSecondary) }
            }
            if h.count < 2 {
                WBody(text: "Aún no hay semanas suficientes para la tendencia.", size: 13).padding(.vertical, 20)
            } else {
                Canvas { ctx, size in
                    let w = Double(size.width), hh = Double(size.height)
                    let left = 34.0, right = w - 30, top = 10.0, bottom = hh - 22
                    let vals = h.flatMap { [max($0.1, Healthspan.minAge), $0.2] }
                    let lo = floor((vals.min() ?? 17) - 1), hi = ceil((vals.max() ?? 25) + 1)
                    func X(_ i: Int) -> Double { return left + (right - left) * Double(i) / Double(max(h.count - 1, 1)) }
                    func Y(_ v: Double) -> Double { return bottom - (bottom - top) * (v - lo) / max(hi - lo, 1e-9) }
                    for k in 0...3 {
                        let v = lo + (hi - lo) * Double(k) / 3
                        ctx.draw(Text(Fmt.comma(v)).font(Theme.label(10)).foregroundColor(Theme.textSecondary), at: CGPoint(x: 0, y: Y(v)), anchor: .leading)
                    }
                    var c = Path(), a = Path()
                    for (i, p) in h.enumerated() {
                        let pc = CGPoint(x: X(i), y: Y(p.2)), pa = CGPoint(x: X(i), y: Y(max(p.1, Healthspan.minAge)))
                        if i == 0 { c.move(to: pc); a.move(to: pa) } else { c.addLine(to: pc); a.addLine(to: pa) }
                    }
                    ctx.stroke(c, with: .color(.white), lineWidth: 1.5)
                    ctx.stroke(a, with: .color(Theme.wRecoveryHigh), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let last = h.last {
                        ctx.draw(Text(Fmt.comma(last.2)).font(Theme.label(11)).foregroundColor(.white), at: CGPoint(x: right + 4, y: Y(last.2)), anchor: .leading)
                        ctx.draw(Text(AgeBlob.text(last.1)).font(Theme.label(11)).foregroundColor(Theme.wRecoveryHigh),
                                 at: CGPoint(x: right + 4, y: Y(max(last.1, Healthspan.minAge))), anchor: .leading)
                    }
                    var lastMonth = -1
                    for (i, p) in h.enumerated() {
                        let m = Day.month(p.0)
                        if m != lastMonth {
                            ctx.draw(Text(["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"][m - 1])
                                .font(Theme.label(10)).foregroundColor(Theme.textSecondary), at: CGPoint(x: X(i), y: bottom + 12), anchor: .center)
                            lastMonth = m
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding(16).background(Theme.wCard).cornerRadius(14)
    }
}

/// Barra de un dato de Healthspan: tramos de naranja (malo) a verde (bueno), ▼ media de 6 meses y ▲ media de 30 días.
struct FactorBar: View {
    let f: Healthspan.Factor
    let text6: String?
    let text30: String?
    let loText: String
    let hiText: String
    let showLabels: Bool

    private func frac(_ v: Double) -> Double { return min(max((v - f.lo) / max(f.hi - f.lo, 1e-9), 0), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                let w = Double(g.size.width)
                ZStack(alignment: .topLeading) {
                    if let t = text6, let v = f.avg6m {
                        VStack(spacing: 0) {
                            if showLabels { Text("Prom. de 6 meses").font(Theme.text(11)).foregroundColor(Theme.textSecondary) }
                            WNumber(text: t, size: 14)
                        }
                        .fixedSize()
                        .position(x: min(max(frac(v) * w, 50), w - 50), y: showLabels ? 14 : 8)
                    }
                    HStack(spacing: 2) {
                        ForEach(0..<14, id: \.self) { i in
                            let t = Double(i) / 13
                            let good = f.goodHigh ? t : 1 - t
                            Capsule().fill(good < 0.4 ? Theme.alertAmber.opacity(0.85) : (good < 0.6 ? Color.white.opacity(0.3) : Theme.wRecoveryHigh.opacity(0.85)))
                                .frame(height: 4)
                        }
                    }
                    .offset(y: showLabels ? 36 : 24)
                    if let v = f.avg6m {
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundColor(.white)
                            .position(x: frac(v) * w, y: showLabels ? 31 : 19)
                    }
                    if let v = f.avg30 {
                        Image(systemName: "arrowtriangle.up.fill").font(.system(size: 8)).foregroundColor(Theme.textSecondary)
                            .position(x: frac(v) * w, y: showLabels ? 47 : 35)
                    }
                }
            }
            .frame(height: showLabels ? 52 : 40)
            HStack {
                Text(loText).font(Theme.label(10)).foregroundColor(Theme.textSecondary)
                Spacer()
                if showLabels, let t = text30 {
                    VStack(spacing: 0) {
                        WNumber(text: t, size: 13, color: Theme.textSecondary)
                        Text("Promedio de 30 días").font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                }
                Text(hiText).font(Theme.label(10)).foregroundColor(Theme.textSecondary)
            }
        }
    }
}

/// Botón de volver de las pantallas de detalle.
struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.textPrimary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Volver")
    }
}
