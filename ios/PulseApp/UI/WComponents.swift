import Foundation
import SwiftUI

/* Piezas de interfaz con el aspecto de WHOOP (17/10): las mismas que WhoopUi.kt (objeto W) de Android. */

/// Título en mayúsculas, Barlow Condensed Bold con espaciado 0,14 ("MONITOR DE SALUD").
struct WTitle: View {
    let text: String
    var size: Double = 14.5
    var color: Color = Theme.textPrimary
    var body: some View {
        Text(text.uppercased())
            .font(Theme.number(size))
            .tracking(size * 0.14)
            .foregroundColor(color)
            .lineSpacing(3)
    }
}

/// Número en Barlow Condensed Bold.
struct WNumber: View {
    let text: String
    var size: Double
    var color: Color = Theme.textPrimary
    var body: some View {
        Text(text).font(Theme.number(size)).foregroundColor(color).monospacedDigit()
    }
}

/// Texto normal (fuente del sistema).
struct WBody: View {
    let text: String
    var size: Double = 15
    var color: Color = Theme.textSecondary
    var body: some View {
        Text(text).font(Theme.text(size)).foregroundColor(color).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }
}

/// Encabezado grande de sección ("Mi día", "Tendencias semanales").
struct WHeading: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.text(27, .medium)).foregroundColor(Theme.textPrimary)
    }
}

/// Tarjeta gris de WHOOP (radio 14).
struct WCard<Content: View>: View {
    var padding: Double = 16
    let content: Content
    init(padding: Double = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.wCard)
            .cornerRadius(14)
    }
}

struct WDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

/// Flecha de tendencia ▲ ▼ ●.
struct TrendIcon: View {
    let trend: Trend?
    var color: Color = Theme.textPrimary
    var size: Double = 11
    var body: some View {
        Group {
            if let t = trend {
                Image(systemName: t == .up ? "arrowtriangle.up.fill" : (t == .down ? "arrowtriangle.down.fill" : "circle.fill"))
                    .font(.system(size: t == .same ? size * 0.6 : size))
                    .foregroundColor(color)
            }
        }
    }
}

enum WTrend {
    static func of(_ value: Double?, _ avg: Double?, tol: Double = 0.5) -> Trend? {
        guard let v = value, let a = avg else { return nil }
        if abs(v - a) <= tol { return .same }
        return v > a ? .up : .down
    }

    /// Verde si va hacia lo bueno, naranja si va hacia lo malo, gris si no importa.
    static func color(_ trend: Trend?, _ goodWhenHigh: Bool?) -> Color {
        guard let t = trend, t != .same, let g = goodWhenHigh else { return Theme.textSecondary }
        return (t == .up) == g ? Theme.wMint : Theme.wTrendAmber
    }
}

/// Píldora con flecha de tendencia y texto, fondo gris: "▲ 7,4".
struct TrendChip: View {
    let trend: Trend?
    let text: String
    var arrowColor: Color = Theme.textPrimary
    var body: some View {
        HStack(spacing: 6) {
            if trend != nil { TrendIcon(trend: trend, color: arrowColor, size: 10) }
            WNumber(text: text, size: 15).opacity(0.92)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.wChip).cornerRadius(6)
    }
}

/// Fila de "Mi panel de control": icono, nombre, valor con tendencia y tu media debajo.
struct PanelRowView: View {
    let row: PanelRow
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: row.icon).font(.system(size: 19)).foregroundColor(Theme.textPrimary.opacity(0.85))
                .frame(width: 26)
            WTitle(text: row.label, size: 14.5).lineLimit(2).padding(.leading, 14).padding(.trailing, 8)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 8) {
                    WNumber(text: row.value, size: 27)
                    Group {
                        if row.trend != nil {
                            TrendIcon(trend: row.trend, color: row.good == nil ? Theme.textSecondary : (row.good! ? Theme.wMint : Theme.wTrendAmber), size: 12)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 13)
                }
                WNumber(text: row.average ?? "", size: 15.5, color: Theme.textSecondary).padding(.trailing, 21)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 68)
        .background(Theme.wCard).cornerRadius(14)
    }
}

/// Fila de "Actividades de hoy": píldora de color con icono y valor, nombre, horas y barra.
struct ActivityRowView: View {
    let color: Color
    let icon: String
    let value: String
    let name: String
    let start: String
    let end: String
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.textPrimary)
                WNumber(text: value, size: 23)
            }
            .frame(width: 112).frame(maxHeight: .infinity)
            .background(color).cornerRadius(10)
            WTitle(text: name, size: 16).lineLimit(1).padding(.leading, 18)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 8) {
                WNumber(text: start, size: 15, color: Theme.textSecondary)
                WNumber(text: end, size: 15, color: Theme.textSecondary)
            }
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 36).padding(.leading, 12)
        }
        .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 8)
        .frame(height: 66)
        .background(Theme.wRow).cornerRadius(12)
    }
}

/// Botón (i) que abre una explicación.
struct InfoButton: View {
    let title: String
    let message: String
    @State private var show = false
    var body: some View {
        Button(action: { show = true }) {
            Image(systemName: "info.circle").font(.system(size: 17)).foregroundColor(Theme.textSecondary)
        }
        .alert(title, isPresented: $show, actions: { Button("Cerrar", action: {}) }, message: { Text(message) })
    }
}

/// Cabecera de tarjeta con valor grande, flecha y la media debajo: "HORAS DE SUEÑO / 6:58 ▼ / 8:07".
struct MetricHeader: View {
    let title: String
    let value: String
    var trend: Trend? = nil
    var goodWhenHigh: Bool? = nil
    var avg: String? = nil
    var info: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WTitle(text: title)
                Spacer()
                if let i = info { InfoButton(title: title.prefix(1).uppercased() + title.dropFirst().lowercased(), message: i) }
            }
            HStack(spacing: 8) {
                WNumber(text: value, size: 26)
                TrendIcon(trend: trend, color: WTrend.color(trend, goodWhenHigh), size: 11)
            }
            .padding(.top, 12)
            if let a = avg { WNumber(text: a, size: 14, color: Theme.textSecondary).padding(.top, 3) }
        }
    }
}

/// Tarjeta de tendencia semanal: título con flecha, leyenda opcional y la gráfica.
struct ChartCard<Chart: View>: View {
    let title: String
    var legend: [(String, Color)] = []
    var height: Double = 250
    let chart: Chart
    init(_ title: String, legend: [(String, Color)] = [], height: Double = 250, @ViewBuilder chart: () -> Chart) {
        self.title = title
        self.legend = legend
        self.height = height
        self.chart = chart()
    }
    var body: some View {
        WCard {
            HStack {
                WTitle(text: title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textSecondary)
            }
            if !legend.isEmpty {
                HStack(spacing: 0) {
                    Spacer()
                    ForEach(0..<legend.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5).fill(legend[i].1).frame(width: 10, height: 10).padding(.leading, 14)
                        WTitle(text: legend[i].0, size: 12, color: Theme.textSecondary).padding(.leading, 7)
                    }
                }
                .padding(.top, 14)
            }
            chart.frame(height: height).padding(.top, 12)
        }
    }
}

/// Fila "nombre ............ valor" con flecha y media opcional (dentro de una tarjeta).
struct ValueRow: View {
    var icon: String? = nil
    let label: String
    let value: String
    var trend: Trend? = nil
    var goodWhenHigh: Bool? = nil
    var avg: String? = nil
    var body: some View {
        HStack(spacing: 0) {
            if let i = icon {
                Image(systemName: i).font(.system(size: 16)).foregroundColor(Theme.textSecondary).frame(width: 22).padding(.trailing, 12)
            }
            WTitle(text: label, size: 13.5)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 7) {
                    WNumber(text: value, size: 22)
                    TrendIcon(trend: trend, color: WTrend.color(trend, goodWhenHigh), size: 10)
                }
                if let a = avg { WNumber(text: a, size: 13, color: Theme.textSecondary).padding(.trailing, trend == nil ? 0 : 18) }
            }
        }
        .padding(.vertical, 12)
    }
}

/// Barra de zona de WHOOP: fondo rayado, relleno del color y el rango típico en un recuadro discontinuo.
struct ZoneBar: View {
    let fraction: Double
    let color: Color
    var typicalLo: Double? = nil
    var typicalHi: Double? = nil
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let top = h * 0.2, bottom = h * 0.8
            ctx.drawLayer { c in
                c.clip(to: Path(CGRect(x: 0, y: top, width: w, height: bottom - top)))
                var x = -h
                var p = Path()
                while x < w + h {
                    p.move(to: CGPoint(x: x, y: bottom))
                    p.addLine(to: CGPoint(x: x + (bottom - top), y: top))
                    x += 7
                }
                c.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 2)
            }
            let f = min(max(fraction, 0), 1)
            if f > 0 {
                let fw = max(w * f, bottom - top)
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: top, width: fw, height: bottom - top), cornerRadius: (bottom - top) / 2), with: .color(color))
            }
            if let lo = typicalLo, let hi = typicalHi {
                let x1 = w * lo, x2 = max(w * hi, x1 + 4)
                ctx.fill(Path(CGRect(x: x1, y: 0, width: x2 - x1, height: h)), with: .color(.black.opacity(0.18)))
                var d = Path()
                d.move(to: CGPoint(x: x1, y: 0)); d.addLine(to: CGPoint(x: x1, y: h))
                d.move(to: CGPoint(x: x2, y: 0)); d.addLine(to: CGPoint(x: x2, y: h))
                ctx.stroke(d, with: .color(.white.opacity(0.78)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
        }
    }
}

/// Indicador de 3 tramos (deficiente / suficiente / óptimo). level −1 = sin dato.
struct TriSegment: View {
    let level: Int
    private static let colors = [Color(hex: 0xF5A524), Color(hex: 0xB9BEC2), Color(hex: 0x2CE5A3)]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(i == level ? TriSegment.colors[i] : Color(hex: 0x3A4247))
            }
        }
        .frame(width: 54, height: 5)
    }
}

/// Barra apilada de segmentos proporcionales con separación (como Ui.fillStackedBar).
struct WStackedBar: View {
    let parts: [(Double, Color)]
    var height: Double = 14
    var body: some View {
        let visible = parts.filter { $0.0 > 0 }
        let total = max(visible.reduce(0.0) { $0 + $1.0 }, 0.0001)
        return GeometryReader { geo in
            HStack(spacing: 3) {
                if visible.isEmpty {
                    Capsule().fill(Theme.wTrack)
                } else {
                    ForEach(0..<visible.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: height / 2).fill(visible[i].1)
                            .frame(width: max((Double(geo.size.width) - 3 * Double(visible.count - 1)) * visible[i].0 / total, 2))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

/// Barra de progreso simple.
struct WProgress: View {
    let fraction: Double
    var color: Color = Theme.wRingSleep
    var height: Double = 14
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.wTrack)
                Capsule().fill(color).frame(width: max(Double(geo.size.width) * min(max(fraction, 0), 1), fraction > 0 ? height : 0))
            }
        }
        .frame(height: height)
    }
}

/// Anillo como los de WHOOP: trazo fino, número grande con "%" del mismo color, etiqueta y marca opcional.
struct WRing: View {
    let progress: Double
    let value: String
    var label: String = ""
    let color: Color
    var size: Double = 100
    var strokeRatio: Double = 0.075
    var numberRatio: Double = 0.30
    var suffixRatio: Double = 0.56
    var labelRatio: Double = 0.095
    var topText: String = ""
    var marker: Double? = nil
    var trackColor: Color = Theme.wTrack
    var labelColor: Color = Theme.textPrimary

    var body: some View {
        let stroke = size * strokeRatio
        let p = min(max(progress, 0), 1)
        let hasSuffix = value.hasSuffix("%")
        let number = hasSuffix ? String(value.dropLast()) : value
        let big = size * numberRatio
        return ZStack {
            Circle().stroke(trackColor, lineWidth: stroke).padding(stroke / 2)
            if p > 0 {
                Circle().trim(from: 0, to: p)
                    .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(stroke / 2)
            }
            if let m = marker {
                Capsule().fill(Color.white)
                    .frame(width: stroke * 0.32, height: stroke * 1.1)
                    .offset(y: -(size - stroke) / 2)
                    .rotationEffect(.degrees(360 * min(max(m, 0), 1)))
            }
            if !value.isEmpty {
                VStack(spacing: 0) {
                    if !topText.isEmpty {
                        Text(topText).font(Theme.medium(size * 0.075)).tracking(size * 0.075 * 0.3)
                            .foregroundColor(Theme.textSecondary).padding(.bottom, size * 0.02)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: size * 0.01) {
                        Text(number).font(Theme.number(big)).foregroundColor(Theme.textPrimary).monospacedDigit()
                        if hasSuffix { Text("%").font(Theme.number(big * suffixRatio)).foregroundColor(Theme.textPrimary) }
                    }
                    if !label.isEmpty {
                        Text(label.uppercased()).font(Theme.label(size * labelRatio)).tracking(size * labelRatio * 0.14)
                            .foregroundColor(labelColor).multilineTextAlignment(.center)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Fondo de las pantallas con aspecto WHOOP + desplazamiento (deja sitio a la barra inferior).
struct WScreen<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        ZStack {
            Theme.wBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 120)
            }
        }
    }
}

/// Cabecera de las pantallas de detalle: atrás · TÍTULO.
struct DetailHeader: View {
    let title: String
    var showBack: Bool = true
    var trailing: AnyView? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            WTitle(text: title, size: 15)
            HStack {
                if showBack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                    }
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
                Spacer()
                if let t = trailing { t } else { Color.clear.frame(width: 44, height: 44) }
            }
        }
        .padding(.top, 4)
    }
}

enum WText {
    private static let wd = ["LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM"]
    private static let wdLow = ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"]
    private static let mo = ["ENE", "FEB", "MAR", "ABR", "MAY", "JUN", "JUL", "AGO", "SEP", "OCT", "NOV", "DIC"]
    private static let moLow = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]

    /// "VIE., OCT. 16"
    static func dateTitle(_ d: String) -> String { return "\(wd[Day.weekdayIndex(d)])., \(mo[Day.month(d) - 1]). \(Day.dayOfMonth(d))" }
    /// "Vie., Oct. 16"
    static func dateShort(_ d: String) -> String {
        let a = wdLow[Day.weekdayIndex(d)], b = moLow[Day.month(d) - 1]
        return a.prefix(1).uppercased() + a.dropFirst() + "., " + b.prefix(1).uppercased() + b.dropFirst() + ". \(Day.dayOfMonth(d))"
    }
    static func weekday(_ d: String) -> String { return wdLow[Day.weekdayIndex(d)] }
    static func weekdayUpper(_ d: String) -> String { return wd[Day.weekdayIndex(d)] }
    static func monthUpper(_ d: String) -> String { return mo[Day.month(d) - 1] }
    static func monthLow(_ d: String) -> String { return moLow[Day.month(d) - 1] }

    /// Icono según el deporte.
    static func sportIcon(_ type: String) -> String {
        let t = type.lowercased()
        if t.contains("fútbol") || t.contains("futbol") { return "soccerball" }
        if t.contains("pádel") || t.contains("padel") || t.contains("pickle") || t.contains("tenis") { return "tennis.racket" }
        if t.contains("fuerza") || t.contains("gimnasio") { return "dumbbell.fill" }
        return "figure.run"
    }

    /// "17:35" (sin cero a la izquierda en la hora, como Android "H:mm").
    static func time(_ ms: Int64) -> String {
        let p = TimeUtil.parts(ms)
        return String(format: "%d:%02d", p.hour, p.minute)
    }

    static func hm(_ m: Int?) -> String { return m.map { Fmt.hm($0) } ?? "--" }
}
