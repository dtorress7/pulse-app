import Foundation
import SwiftUI

// MARK: - Tarjeta y textos

struct Card<Content: View>: View {
    let content: Content
    var padding: Double = 16
    init(padding: Double = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: Double.infinity, alignment: .leading)
            .background(Theme.card)
            .cornerRadius(16)
    }
}

/// Etiqueta pequeña en mayúsculas con espaciado (estilo WHOOP).
struct CapsLabel: View {
    let text: String
    var color: Color = Theme.textSecondary
    var size: Double = 12
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label(size))
            .tracking(size * 0.14)
            .foregroundColor(color)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.text(20, .semibold))
            .foregroundColor(Theme.textPrimary)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

/// Fila de lista agrupada: texto a la izquierda, valor a la derecha.
struct ListRow: View {
    let title: String
    let value: String
    var valueColor: Color = Theme.textSecondary
    var subtitle: String? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                if let sub = subtitle {
                    Text(sub).font(Theme.text(12)).foregroundColor(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            Text(value).font(Theme.number(18)).foregroundColor(valueColor)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 16)
    }
}

struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.text(13))
            .foregroundColor(Theme.textSecondary)
            .padding(16)
    }
}

// MARK: - Barras

struct ProgressBar: View {
    let fraction: Double
    var color: Color = Theme.sleepBlue
    var height: Double = 8
    var body: some View {
        let f = min(max(fraction, 0.0), 1.0)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: Double(geo.size.width) * f)
            }
        }
        .frame(height: height)
    }
}

/// Barra apilada de segmentos proporcionales.
struct StackedBar: View {
    let parts: [(Double, Color)]
    var height: Double = 8
    var body: some View {
        let visible = parts.filter { $0.0 > 0 }
        let total = max(visible.reduce(0.0) { $0 + $1.0 }, 0.0001)
        return GeometryReader { geo in
            let width = Double(geo.size.width)
            HStack(spacing: 2) {
                if visible.isEmpty {
                    Rectangle().fill(Theme.track)
                } else {
                    ForEach(0..<visible.count) { i in
                        Rectangle()
                            .fill(visible[i].1)
                            .frame(width: max(width * visible[i].0 / total - 2, 1))
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// Gráfica de barras de los últimos días: valor arriba, barra, letra del día abajo. La última es "HOY".
struct WeekBars: View {
    struct Item { let label: String; let value: Double?; let color: Color }
    let items: [Item]
    let maxValue: Double
    let format: (Double) -> String

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(0..<items.count) { i in
                column(i)
            }
        }
        .frame(height: 150)
    }

    private func column(_ i: Int) -> some View {
        let item = items[i]
        let isLast = i == items.count - 1
        var h = 4.0
        if let v = item.value, maxValue > 0 { h = 96.0 * min(max(v / maxValue, 0.04), 1.0) }
        let barColor: Color = item.value == nil ? Theme.track : item.color
        let barOpacity: Double = (isLast || item.value == nil) ? 1.0 : 0.55
        let top: String = item.value.map { format($0) } ?? "–"
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(top).font(Theme.number(13)).foregroundColor(isLast ? Theme.textPrimary : Theme.textSecondary)
            RoundedRectangle(cornerRadius: 6).fill(barColor).opacity(barOpacity).frame(height: h)
            CapsLabel(text: isLast ? "HOY" : item.label, color: isLast ? Theme.textPrimary : Theme.textSecondary, size: 10)
        }
        .frame(maxWidth: Double.infinity)
    }
}

// MARK: - Anillo

/// Anillo de progreso: trazo grueso con extremos redondeados, número grande condensado en el centro.
/// "72%" se dibuja como "72" grande + "%" pequeño. Si [label] está vacío no se dibuja etiqueta.
struct RingView: View {
    let progress: Double
    let value: String
    var label: String = ""
    let color: Color
    var size: Double = 110

    var body: some View {
        let stroke = size * 0.105
        let p = min(max(progress, 0.0), 1.0)
        return ZStack {
            Circle().stroke(Theme.track, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: p)
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: size * 0.01) {
                numberText
                if !label.isEmpty { CapsLabel(text: label, size: size * 0.095) }
            }
        }
        .frame(width: size, height: size)
        .padding(stroke / 2)
    }

    private var numberText: some View {
        let hasSuffix = value.hasSuffix("%")
        let number = hasSuffix ? String(value.dropLast()) : value
        let big = size * (label.isEmpty ? 0.31 : 0.27)
        return HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(number).font(Theme.number(big)).foregroundColor(Theme.textPrimary)
            if hasSuffix { Text("%").font(Theme.number(big * 0.46)).foregroundColor(Theme.textSecondary) }
        }
    }
}

// MARK: - Medidor semicircular del estrés (0–3)

struct GaugeView: View {
    let value: Double          // 0…3

    var body: some View {
        GeometryReader { geo in
            let w = Double(geo.size.width)
            let h = Double(geo.size.height)
            let stroke = 12.0
            let labelSpace = 22.0
            let radius = min(w / 2 - stroke, h - stroke / 2 - labelSpace)
            let cx = w / 2
            let cy = h - labelSpace
            let v = min(max(value, 0.0), 3.0)
            let angle = Double.pi * (1.0 - v / 3.0)
            let inner = radius - stroke * 1.6
            let outer = radius + stroke / 2
            ZStack {
                Path { p in
                    p.addArc(center: CGPoint(x: cx, y: cy), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                }
                .stroke(LinearGradient(colors: [Theme.strainBlue, Theme.recoveryGreen, Theme.alertAmber], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                Path { p in
                    p.move(to: CGPoint(x: cx + inner * cos(angle), y: cy - inner * sin(angle)))
                    p.addLine(to: CGPoint(x: cx + outer * cos(angle), y: cy - outer * sin(angle)))
                }
                .stroke(Theme.textPrimary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                Text("0,0").font(Theme.label(13)).foregroundColor(Theme.textSecondary)
                    .offset(x: cx - radius - w / 2, y: cy + 11 - h / 2)
                Text("3,0").font(Theme.label(13)).foregroundColor(Theme.textSecondary)
                    .offset(x: cx + radius - w / 2, y: cy + 11 - h / 2)
            }
        }
    }
}

// MARK: - Gráfica de estrés (últimas 24 h)

struct StressChart: View {
    let points: [StressPoint]
    var sleepStartMinute: Int? = nil
    var sleepEndMinute: Int? = nil
    var activities: [ActivityPeriod] = []

    var body: some View {
        GeometryReader { geo in
            chart(Double(geo.size.width), Double(geo.size.height))
        }
    }

    private func chart(_ w: Double, _ h: Double) -> some View {
        let top = 4.0
        let bottom = h - 4.0
        let now = TimeUtil.nowMillis()
        let from = now - 24 * 3_600_000
        let span = Double(now - from)
        func xFor(_ t: Int64) -> Double { return min(max(w * Double(t - from) / span, 0.0), w) }
        func yFor(_ s: Double) -> Double { return bottom - (min(max(s, 0.0), 3.0) / 3.0) * (bottom - top) }
        // Un minuto del día → su aparición más reciente que no sea futura
        func timeOfMinute(_ minute: Int) -> Int64 {
            var t = TimeUtil.setTime(now, hour: minute / 60, minute: minute % 60)
            if t > now { t = TimeUtil.addDays(t, -1) }
            return t
        }

        // Tramos separados: si faltan datos más de 15 min, la línea se corta
        let pts = points.filter { $0.timeMillis >= from }.sorted { $0.timeMillis < $1.timeMillis }
        var segments = [[StressPoint]]()
        for p in pts {
            if let lastSeg = segments.last, let last = lastSeg.last, p.timeMillis - last.timeMillis <= 15 * 60_000 {
                segments[segments.count - 1].append(p)
            } else {
                segments.append([p])
            }
        }

        var sleepRect: (Double, Double)? = nil
        if let s = sleepStartMinute, let e = sleepEndMinute {
            let te = timeOfMinute(e)
            var ts = timeOfMinute(s)
            if ts > te { ts = ts - 24 * 3_600_000 }
            sleepRect = (xFor(ts), xFor(te))
        }

        return ZStack(alignment: .topLeading) {
            if let sr = sleepRect {
                Rectangle().fill(Theme.sleepBlue.opacity(0.10))
                    .frame(width: max(sr.1 - sr.0, 1), height: bottom - top)
                    .offset(x: sr.0, y: top)
                Rectangle().fill(Theme.sleepBlue)
                    .frame(width: max(sr.1 - sr.0, 1), height: 2)
                    .offset(x: sr.0, y: top)
            }
            ForEach(0..<4) { i in
                Rectangle().fill(Theme.track.opacity(0.6)).frame(width: w, height: 1)
                    .offset(x: 0, y: yFor(Double(i)))
            }
            ForEach(0..<activities.count) { i in
                let a = activities[i]
                let te = timeOfMinute(a.endMinute)
                let ts0 = timeOfMinute(a.startMinute)
                let ts = ts0 > te ? ts0 - 24 * 3_600_000 : ts0
                let x1 = xFor(ts)
                let x2 = max(xFor(te), x1 + 4)
                RoundedRectangle(cornerRadius: 2).fill(Theme.strainBlue)
                    .frame(width: x2 - x1, height: 4)
                    .offset(x: x1, y: bottom - 3)
            }
            ForEach(0..<segments.count) { i in
                segmentView(segments[i], xFor: xFor, yFor: yFor, w: w, bottom: bottom, top: top)
            }
            // Marcador de "ahora"
            Rectangle().fill(Theme.textPrimary.opacity(0.7)).frame(width: 1, height: bottom - top)
                .offset(x: w - 1.5, y: top)
            Circle().fill(Theme.textPrimary).frame(width: 6, height: 6).offset(x: w - 6, y: bottom - 3)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    private func segmentView(_ seg: [StressPoint], xFor: (Int64) -> Double, yFor: (Double) -> Double,
                             w: Double, bottom: Double, top: Double) -> some View {
        var line = Path()
        var fill = Path()
        for (i, p) in seg.enumerated() {
            let x = xFor(p.timeMillis)
            let y = yFor(Double(p.score))
            if i == 0 {
                line.move(to: CGPoint(x: x, y: y))
                fill.move(to: CGPoint(x: x, y: bottom))
                fill.addLine(to: CGPoint(x: x, y: y))
            } else {
                line.addLine(to: CGPoint(x: x, y: y))
                fill.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if seg.count == 1, let p = seg.first {
            line.addLine(to: CGPoint(x: xFor(p.timeMillis) + 2, y: yFor(Double(p.score))))
        }
        if let last = seg.last {
            fill.addLine(to: CGPoint(x: xFor(last.timeMillis), y: bottom))
        }
        fill.closeSubpath()
        return ZStack {
            fill.fill(Theme.recoveryGreen.opacity(0.18))
            line.stroke(LinearGradient(colors: [Theme.strainBlue, Theme.sleepBlue, Theme.recoveryGreen], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Hipnograma

/// 4 carriles (arriba Despierto, luego REM, Ligero y abajo Profundo), un bloque por tramo, línea que une tramos y horas abajo.
struct HypnogramView: View {
    let startMillis: Int64
    let stages: [Int]

    private static let laneOf = [0, 2, 3, 1]   // Despierto, Ligero, Profundo, REM → carril (0 = arriba)

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                chart(Double(geo.size.width), Double(geo.size.height))
            }
            .frame(height: 128)
            HStack {
                Text(Fmt.clock(startMillis)).font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                Spacer()
                Text(Fmt.clock(startMillis + Int64(stages.count / 2) * 60_000)).font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                Spacer()
                Text(Fmt.clock(startMillis + Int64(stages.count) * 60_000)).font(Theme.text(11)).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private func chart(_ w: Double, _ h: Double) -> some View {
        let n = stages.count
        let laneH = h / 4.0
        let blockH = laneH * 0.62
        // Tramos seguidos de la misma fase
        var runs = [(Int, Int, Int)]()   // (inicio, fin, fase)
        var i = 0
        while i < n {
            var j = i
            while j < n && stages[j] == stages[i] { j += 1 }
            runs.append((i, j, stages[i]))
            i = j
        }
        func laneTop(_ stage: Int) -> Double { return Double(HypnogramView.laneOf[stage]) * laneH + (laneH - blockH) / 2 }
        func x(_ k: Int) -> Double { return n > 0 ? Double(k) / Double(n) * w : 0 }

        return ZStack(alignment: .topLeading) {
            ForEach(0..<4) { l in
                Rectangle().fill(Theme.track.opacity(0.5)).frame(width: w, height: 1)
                    .offset(x: 0, y: Double(l) * laneH + laneH / 2)
            }
            ForEach(0..<runs.count) { k in
                let r = runs[k]
                let left = x(r.0)
                let width = max(x(r.1) - left, 2)
                if k > 0 {
                    let prev = runs[k - 1]
                    let y1 = laneTop(prev.2) + blockH / 2
                    let y2 = laneTop(r.2) + blockH / 2
                    Rectangle().fill(Theme.stageColor(r.2).opacity(0.5))
                        .frame(width: 1.2, height: abs(y2 - y1))
                        .offset(x: left, y: min(y1, y2))
                }
                RoundedRectangle(cornerRadius: 3).fill(Theme.stageColor(r.2))
                    .frame(width: width, height: blockH)
                    .offset(x: left, y: laneTop(r.2))
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }
}
