import Foundation
import SwiftUI

/* 17/11 (rama de prueba "Pulse Beta"): piezas del rediseño aprobado en la maqueta "PulseApp rediseño 2".
   Solo interfaz: no cambian ningún cálculo. */

enum RD {
    static let card = Color(hex: 0x1F282E)
    static let cardOn = Color(hex: 0x2A353C)
    static let track = Color(hex: 0x2E3A41)
    static let typical = Color(hex: 0x46545C)
    static let band = Color(hex: 0x2A353C)
    static let text2 = Color(hex: 0xA9B4BA)
    static let ink = Color(hex: 0x101518)
}

// MARK: - Minigráfica de 7 días (se dibuja al aparecer)

struct Sparkline: View {
    let values: [Double?]
    var color: Color
    var width: Double = 76
    var height: Double = 30
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var points: [CGPoint] {
        let v: [(Int, Double)] = values.enumerated().compactMap { (i, x) in x.map { (i, $0) } }
        guard v.count >= 2 else { return [] }
        let lo = v.map { $0.1 }.min() ?? 0, hi = v.map { $0.1 }.max() ?? 1
        let r = max(hi - lo, 1e-9)
        let n = Double(max(values.count - 1, 1))
        return v.map { CGPoint(x: 3 + Double($0.0) / n * (width - 6), y: height - 3 - ($0.1 - lo) / r * (height - 6)) }
    }

    var body: some View {
        let p = points
        return ZStack(alignment: .topLeading) {
            if p.count >= 2 {
                Path { path in
                    path.move(to: p[0])
                    for q in p.dropFirst() { path.addLine(to: q) }
                }
                .trim(from: 0, to: drawn)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                Circle().fill(color).frame(width: 6, height: 6).position(p[p.count - 1]).opacity(Double(drawn))
            }
        }
        .frame(width: width, height: height)
        .onAppear {
            if reduceMotion { drawn = 1 } else { withAnimation(.easeOut(duration: 1.2)) { drawn = 1 } }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Barra con tu rango habitual (franja gris) y el valor de hoy (marca)

struct RangeBar: View {
    let value: Double?
    let lo: Double?
    let hi: Double?
    let scaleLo: Double
    let scaleHi: Double
    var color: Color

    var body: some View {
        GeometryReader { g in
            let w = Double(g.size.width)
            let span = max(scaleHi - scaleLo, 1e-9)
            let f: (Double) -> Double = { min(max(($0 - scaleLo) / span, 0), 1) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(RD.track).frame(height: 6)
                if let a = lo, let b = hi {
                    Capsule().fill(RD.typical).frame(width: max(f(b) - f(a), 4), height: 6).offset(x: f(a))
                }
                if let v = value {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 14).offset(x: f(v) - 2)
                }
            }
            .frame(height: 14)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

// MARK: - Pulso en directo (latido + electro con el degradado del logo)

struct LivePulseCard: View {
    @ObservedObject private var mgr = WhoopManager.shared
    @State private var beat = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: Bool { return mgr.lastBpm != nil && TimeUtil.nowMillis() - mgr.lastBpmTime < 15_000 }

    /// Forma de un latido (0…1 a lo largo del latido) → altura −1…1.
    static func ecg(_ u: Double) -> Double {
        func bump(_ c: Double, _ w: Double, _ a: Double) -> Double { let d = (u - c) / w; return a * exp(-d * d) }
        return bump(0.20, 0.035, 0.15) - bump(0.42, 0.012, 0.22) + bump(0.45, 0.013, 1.0) - bump(0.48, 0.012, 0.32) + bump(0.70, 0.05, 0.24)
    }

    var body: some View {
        let isLive = live
        let bpm = mgr.lastBpm ?? 60
        return HStack(spacing: 12) {
            Image(systemName: "heart.fill").font(.system(size: 18)).foregroundColor(isLive ? Theme.logoGreen : RD.text2)
                .scaleEffect(beat && isLive ? 1.22 : 1)
                .animation(isLive && !reduceMotion ? .easeInOut(duration: 30.0 / Double(max(bpm, 30))).repeatForever(autoreverses: true) : .default, value: beat)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    WNumber(text: isLive ? "\(bpm)" : "--", size: 24)
                    Text("lpm").font(Theme.number(13)).foregroundColor(RD.text2)
                }
                Text(isLive ? "En directo" : "Sin pulso en directo").font(Theme.text(12)).foregroundColor(RD.text2)
            }
            .frame(minWidth: 84, alignment: .leading)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !isLive)) { tl in
                Canvas { ctx, size in
                    let w = Double(size.width), h = Double(size.height)
                    let period = 60.0 / Double(max(bpm, 30))
                    let beatW = max(period * 70.0, 30)
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let shift = (t.truncatingRemainder(dividingBy: period)) / period * beatW
                    var p = Path()
                    var x = 0.0
                    while x <= w {
                        var u = (x + shift).truncatingRemainder(dividingBy: beatW) / beatW
                        if u < 0 { u += 1 }
                        let y = h / 2 - (isLive ? LivePulseCard.ecg(u) : 0) * (h / 2 - 3)
                        if x == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        x += 1.5
                    }
                    ctx.stroke(p, with: .linearGradient(Gradient(colors: [Theme.logoBlue, Theme.logoGreen]),
                                                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w, y: 0)),
                               style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 40)
            .opacity(isLive ? 1 : 0.4)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RD.card).cornerRadius(16)
        .onAppear { beat = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLive ? "Pulso en directo, \(bpm) latidos por minuto" : "Sin pulso en directo")
    }
}

// MARK: - Conmutador Semana / Mes

struct SegToggle: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                Button(action: { withAnimation(.easeOut(duration: 0.2)) { selection = i } }) {
                    Text(options[i]).font(Theme.text(13, .semibold))
                        .foregroundColor(selection == i ? RD.ink : RD.text2)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(Capsule().fill(selection == i ? Color.white : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == i ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(RD.track))
    }
}

// MARK: - Gráfica de tendencia: línea con el degradado del logo, tu rango sombreado y el dedo para ver cada día

struct TrendChart: View {
    let values: [Double?]
    let labels: [String]
    var band: ClosedRange<Double>? = nil
    var format: (Double) -> String
    var unit: String = ""
    var height: Double = 130
    @State private var sel: Int? = nil
    @State private var scrubbing = false
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let lastIdx = values.lastIndex { $0 != nil }
        let idx = sel ?? lastIdx
        let present = values.compactMap { $0 }
        var lo = present.min() ?? 0
        var hi = present.max() ?? 1
        if let b = band { lo = min(lo, b.lowerBound); hi = max(hi, b.upperBound) }
        let pad = max((hi - lo) * 0.12, 0.5)
        let lo0 = lo - pad, hi0 = hi + pad
        let h = height
        let shown: String = {
            guard let i = idx, let v = values[i] else { return "--" }
            return format(v) + (unit.isEmpty ? "" : " " + unit)
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WNumber(text: shown, size: 30)
                Text(idx.map { labels[$0] } ?? "").font(Theme.text(13)).foregroundColor(RD.text2)
            }
            GeometryReader { g in
                let w = Double(g.size.width)
                let n = Double(max(values.count - 1, 1))
                let X: (Int) -> Double = { 6 + Double($0) / n * (w - 12) }
                let Y: (Double) -> Double = { h - 8 - ($0 - lo0) / max(hi0 - lo0, 1e-9) * (h - 16) }
                let toIndex: (Double) -> Int = { x in min(max(Int(((x - 6) / max(w - 12, 1) * n).rounded()), 0), values.count - 1) }
                ZStack(alignment: .topLeading) {
                    if let b = band {
                        RoundedRectangle(cornerRadius: 4).fill(RD.band)
                            .frame(width: w, height: max(Y(b.lowerBound) - Y(b.upperBound), 2))
                            .offset(y: Y(b.upperBound))
                    }
                    Path { p in
                        var started = false
                        for (i, v) in values.enumerated() {
                            guard let v = v else { started = false; continue }
                            let pt = CGPoint(x: X(i), y: Y(v))
                            if started { p.addLine(to: pt) } else { p.move(to: pt); started = true }
                        }
                    }
                    .trim(from: 0, to: drawn)
                    .stroke(Theme.logoGradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    if values.count <= 10 {
                        ForEach(values.indices, id: \.self) { i in
                            if let v = values[i] {
                                Circle().fill(Color.white.opacity(0.85)).frame(width: 5, height: 5).position(x: X(i), y: Y(v))
                            }
                        }
                    }
                    if let i = idx, let v = values[i] {
                        Path { p in
                            p.move(to: CGPoint(x: X(i), y: 0))
                            p.addLine(to: CGPoint(x: X(i), y: h))
                        }
                        .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                        Circle().fill(Color.white).frame(width: 10, height: 10).position(x: X(i), y: Y(v))
                    }
                }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { loc in sel = toIndex(Double(loc.x)) }
                .simultaneousGesture(DragGesture(minimumDistance: 6)
                    .onChanged { v in
                        if !scrubbing && abs(v.translation.width) < abs(v.translation.height) { return }
                        scrubbing = true
                        sel = toIndex(Double(v.location.x))
                    }
                    .onEnded { _ in scrubbing = false })
            }
            .frame(height: h)
        }
        .onAppear {
            if reduceMotion { drawn = 1 } else { withAnimation(.easeOut(duration: 1.3)) { drawn = 1 } }
        }
    }
}

/// Tarjeta con título, Semana / Mes y la gráfica de tendencia de un dato de tus días.
struct RecordTrendCard: View {
    let title: String
    let records: [DayRecord]
    let endDate: String
    let pick: (DayRecord) -> Double?
    let format: (Double) -> String
    var unit: String = ""
    var band: ClosedRange<Double>? = nil
    @State private var range = 0

    var body: some View {
        let days = range == 0 ? 7 : 30
        let dates = (0..<days).reversed().map { Day.add(endDate, -$0) }
        var byDate = [String: DayRecord]()
        for r in records { byDate[r.date] = r }
        let vals: [Double?] = dates.map { d in byDate[d].flatMap(pick) }
        let labels = dates.map { WText.dateShort($0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                WTitle(text: title, size: 14, color: RD.text2)
                Spacer()
                SegToggle(options: ["Semana", "Mes"], selection: $range)
            }
            TrendChart(values: vals, labels: labels, band: band, format: format, unit: unit).id(range)
            Text(band != nil ? "Arrastra el dedo por la gráfica para ver cada día. La franja oscura es tu rango habitual."
                             : "Arrastra el dedo por la gráfica para ver cada día.")
                .font(Theme.text(12)).foregroundColor(RD.text2)
        }
        .padding(16)
        .background(RD.card).cornerRadius(16)
    }
}

// MARK: - Fila de Tendencias de Inicio: valor, minigráfica de 7 días y tu media

struct TrendRowView: View {
    let row: PanelRow
    let series: [Double?]
    let color: Color

    var body: some View {
        let trendColor = row.good == nil ? RD.text2 : (row.good! ? Theme.wMint : Theme.wTrendAmber)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: row.icon).font(.system(size: 12)).foregroundColor(RD.text2)
                    WTitle(text: row.label, size: 12, color: RD.text2).lineLimit(1).minimumScaleFactor(0.8)
                }
                WNumber(text: row.value, size: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if series.compactMap({ $0 }).count >= 2 {
                Sparkline(values: series, color: color)
            }
            VStack(alignment: .trailing, spacing: 3) {
                if row.trend != nil {
                    TrendIcon(trend: row.trend, color: trendColor, size: 11)
                } else {
                    Color.clear.frame(width: 11, height: 11)
                }
                Text(row.average.map { "media \($0)" } ?? " ").font(Theme.text(12)).foregroundColor(RD.text2).lineLimit(1)
            }
            .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RD.card).cornerRadius(16)
    }
}
