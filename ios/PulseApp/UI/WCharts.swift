import Foundation
import SwiftUI

/* Gráficas dibujadas a mano con el aspecto de WHOOP (port de WhoopViews.kt y WeekChartView.kt de Android). */

private func label(_ ctx: GraphicsContext, _ s: String, _ font: Font, _ color: Color, _ p: CGPoint, _ anchor: UnitPoint) {
    ctx.draw(Text(s).font(font).foregroundColor(color), at: p, anchor: anchor)
}

/// Gráfica del Monitor de estrés: escala 0–3 a la izquierda, el día desde las 00:00 hasta ahora, franja de sueño con la luna,
/// línea que pasa de turquesa (bajo) a verde (alto) y marca de "ahora".
struct StressDayChart: View {
    let points: [StressPoint]
    let from: Int64
    let to: Int64
    var sleepFrom: Int64? = nil
    var sleepTo: Int64? = nil
    var showNow: Bool = true

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let to = max(self.to, from + 60_000)
            let left = 34.0, right = w - 8, top = 30.0, bottom = h - 28
            func x(_ t: Int64) -> Double { return left + (right - left) * min(max(Double(t - from) / Double(to - from), 0), 1) }
            func y(_ v: Double) -> Double { return bottom - (bottom - top) * (min(max(v, 0), 3) / 3) }
            let lf = Theme.label(13)

            if let sf = sleepFrom, let st = sleepTo, st > from, sf < to {
                let x1 = x(max(sf, from)), x2 = x(min(st, to))
                ctx.fill(Path(CGRect(x: x1, y: y(3), width: x2 - x1, height: bottom - y(3))), with: .color(.white.opacity(0.06)))
                var l = Path(); l.move(to: CGPoint(x: x1, y: y(3))); l.addLine(to: CGPoint(x: x2, y: y(3)))
                ctx.stroke(l, with: .color(Theme.wRingSleep), lineWidth: 2.5)
                var moon = ctx.resolve(Image(systemName: "moon.fill"))
                moon.shading = .color(Theme.textPrimary)
                ctx.draw(moon, in: CGRect(x: (x1 + x2) / 2 - 8, y: y(3) - 24, width: 16, height: 16))
            }
            for i in 0...3 {
                let yy = y(Double(i))
                var g = Path(); g.move(to: CGPoint(x: left, y: yy)); g.addLine(to: CGPoint(x: right, y: yy))
                ctx.stroke(g, with: .color(.white.opacity(0.11)), lineWidth: 1)
                label(ctx, "\(i),0", lf, Theme.textSecondary, CGPoint(x: 0, y: yy), .leading)
            }
            // Horas cada 4 h
            label(ctx, Fmt.clock(from + 60_000), lf, Theme.textSecondary, CGPoint(x: left - 4, y: h - 10), .leading)
            var t = TimeUtil.setTime(from, hour: TimeUtil.parts(from).hour, minute: 0)
            while true {
                t += 3_600_000
                if t >= to { break }
                if TimeUtil.parts(t).hour % 4 != 0 { continue }
                let xx = x(t)
                if xx - left < 40 || right - xx < 46 { continue }
                var g = Path(); g.move(to: CGPoint(x: xx, y: top)); g.addLine(to: CGPoint(x: xx, y: bottom))
                ctx.stroke(g, with: .color(.white.opacity(0.11)), lineWidth: 1)
                label(ctx, Fmt.clock(t), lf, Theme.textSecondary, CGPoint(x: xx, y: h - 10), .center)
            }
            // Línea con degradado vertical según el nivel
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [.init(color: Theme.wStressLineLow, location: 0), .init(color: Theme.wStressLineLow, location: 0.25),
                                 .init(color: Theme.wStressLineHigh, location: 0.75)]),
                startPoint: CGPoint(x: 0, y: y(0)), endPoint: CGPoint(x: 0, y: y(3)))
            let pts = points.filter { $0.timeMillis >= from && $0.timeMillis <= to }.sorted { $0.timeMillis < $1.timeMillis }
            var path = Path()
            var last: Int64 = 0
            var started = false
            for p in pts {
                let pt = CGPoint(x: x(p.timeMillis), y: y(Double(p.score)))
                if !started || p.timeMillis - last > 15 * 60_000 {
                    if started { ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)) }
                    path = Path(); path.move(to: pt); started = true
                } else {
                    path.addLine(to: pt)
                }
                last = p.timeMillis
            }
            if started { ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)) }
            if showNow {
                let xx = right - 2
                var d = Path(); d.move(to: CGPoint(x: xx, y: top - 14)); d.addLine(to: CGPoint(x: xx, y: bottom))
                ctx.stroke(d, with: .color(Theme.textPrimary), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                ctx.fill(Path(ellipseIn: CGRect(x: xx - 3.5, y: bottom - 3.5, width: 7, height: 7)), with: .color(Theme.textPrimary))
                label(ctx, Fmt.clock(to), Theme.number(14), Theme.textPrimary, CGPoint(x: right, y: h - 10), .trailing)
            }
        }
    }
}

/// "Esfuerzo y recuperación": 7 días, esfuerzo (azul, 0–21 a la izquierda) y recuperación (círculos de su color, 0–100 % a la derecha).
struct StrainRecoveryChart: View {
    struct Item { let weekday: String; let dayOfMonth: String; let strain: Double?; let recovery: Int? }
    let days: [Item]

    var body: some View {
        Canvas { ctx, size in
            if days.isEmpty { return }
            let w = size.width, h = size.height
            let left = 30.0, right = w - 46, top = 22.0, bottom = h - 58
            let n = days.count
            let step = (right - left) / Double(n)
            func cx(_ i: Int) -> Double { return left + step * (Double(i) + 0.5) }
            func yS(_ s: Double) -> Double { return bottom - (bottom - top) * min(max(s / 21, 0), 1) }
            func yR(_ r: Int) -> Double { return bottom - (bottom - top) * min(max(Double(r) / 100, 0), 1) }
            func rc(_ r: Int) -> Color { return Theme.wRecoveryColor(r) }
            let blue = Theme.strainBlue

            ctx.fill(Path(roundedRect: CGRect(x: cx(n - 1) - step * 0.42, y: top - 16, width: step * 0.84, height: h - 4 - (top - 16)), cornerRadius: 6),
                     with: .color(.white.opacity(0.086)))
            let lefts = ["0", "7", "14", "21"]
            let rights: [(String, Color)] = [("0%", Theme.alertRed), ("33%", Theme.alertRed), ("66%", Theme.alertAmber), ("100%", Theme.wRecoveryHigh)]
            for i in 0...3 {
                let yy = bottom - (bottom - top) * Double(i) / 3
                var g = Path(); g.move(to: CGPoint(x: left, y: yy)); g.addLine(to: CGPoint(x: right, y: yy))
                ctx.stroke(g, with: .color(.white.opacity(0.094)), lineWidth: 1)
                label(ctx, lefts[i], Theme.label(13), blue, CGPoint(x: 0, y: yy), .leading)
                label(ctx, rights[i].0, Theme.label(13), rights[i].1, CGPoint(x: w, y: yy), .trailing)
            }
            func poly(_ pts: [(Int, Double)], _ c: Color) {
                if pts.count < 2 { return }
                var p = Path()
                for (k, v) in pts.enumerated() {
                    if k == 0 { p.move(to: CGPoint(x: cx(v.0), y: v.1)) } else { p.addLine(to: CGPoint(x: cx(v.0), y: v.1)) }
                }
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
            }
            var recPts = [(Int, Double)](), strPts = [(Int, Double)]()
            for (i, d) in days.enumerated() {
                if let r = d.recovery { recPts.append((i, yR(r))) }
                if let s = d.strain { strPts.append((i, yS(s))) }
            }
            poly(recPts, Color(hex: 0x8A9096))
            poly(strPts, blue)
            let r = 6.5
            for (i, d) in days.enumerated() {
                let x = cx(i)
                let ys = d.strain.map { yS($0) }
                let yr = d.recovery.map { yR($0) }
                if let yy = yr, let rv = d.recovery {
                    let c = CGRect(x: x - r, y: yy - r, width: 2 * r, height: 2 * r)
                    ctx.fill(Path(ellipseIn: c), with: .color(Theme.wCard))
                    ctx.stroke(Path(ellipseIn: c), with: .color(rc(rv)), lineWidth: 2.6)
                    let above = ys == nil || yy <= ys!
                    label(ctx, "\(rv) %", Theme.number(17), rc(rv), CGPoint(x: x, y: above ? yy - r - 11 : yy + r + 11), .center)
                }
                if let yy = ys, let sv = d.strain {
                    let c = CGRect(x: x - r, y: yy - r, width: 2 * r, height: 2 * r)
                    ctx.fill(Path(ellipseIn: c), with: .color(Theme.wCard))
                    ctx.stroke(Path(ellipseIn: c), with: .color(blue), lineWidth: 2.6)
                    let below = (yr == nil || yy >= yr!) && yy + r + 17 <= bottom + 4
                    label(ctx, Fmt.comma(sv), Theme.number(17), blue, CGPoint(x: x, y: below ? yy + r + 11 : yy - r - 11), .center)
                }
                let lastDay = i == n - 1
                let c = lastDay ? Theme.textPrimary : Theme.textSecondary
                label(ctx, d.weekday, Theme.label(13.5), c, CGPoint(x: x, y: h - 35), .center)
                label(ctx, d.dayOfMonth, Theme.label(13.5), c, CGPoint(x: x, y: h - 16), .center)
            }
        }
    }
}

/// Línea de pulso en directo del Monitor de salud: últimos 10 min sobre cuadrícula, punto en el último valor.
struct LiveHrLine: View {
    let points: [(Int64, Int)]
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var grid = Path()
            var gx = 0.0
            while gx <= w { grid.move(to: CGPoint(x: gx, y: 0)); grid.addLine(to: CGPoint(x: gx, y: h)); gx += 14 }
            var gy = 0.0
            while gy <= h { grid.move(to: CGPoint(x: 0, y: gy)); grid.addLine(to: CGPoint(x: w, y: gy)); gy += 14 }
            ctx.stroke(grid, with: .color(.white.opacity(0.055)), lineWidth: 1)
            let endX = w - 16
            var d = Path(); d.move(to: CGPoint(x: endX, y: 4)); d.addLine(to: CGPoint(x: endX, y: h - 4))
            ctx.stroke(d, with: .color(.white.opacity(0.67)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            guard let lastT = points.last?.0 else { return }
            let window: Int64 = 10 * 60_000
            let from = lastT - window
            // Medias de 5 s: el pulso segundo a segundo hace una línea demasiado nerviosa
            var groups = [Int64: [Int]]()
            for (t, b) in points where t >= from { groups[t / 5000, default: []].append(b) }
            let keys = groups.keys.sorted()
            if keys.isEmpty { return }
            let vis: [(Int64, Double)] = keys.map { k in
                let v = groups[k]!
                return (k == lastT / 5000 ? lastT : k * 5000 + 2500, Double(v.reduce(0, +)) / Double(v.count))
            }
            let minB = vis.map { $0.1 }.min()! - 10
            let maxB = vis.map { $0.1 }.max()! + 10
            func x(_ t: Int64) -> Double { return endX * Double(t - from) / Double(window) }
            func y(_ b: Double) -> Double { return h - 10 - (h - 20) * ((b - minB) / max(1, maxB - minB)) }
            var p = Path()
            for (i, v) in vis.enumerated() {
                let pt = CGPoint(x: x(v.0), y: y(v.1))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .linearGradient(Gradient(colors: [Theme.strainBlue.opacity(0), Theme.strainBlue]),
                                                 startPoint: .zero, endPoint: CGPoint(x: endX, y: 0)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            let ly = y(vis.last!.1)
            ctx.fill(Path(ellipseIn: CGRect(x: endX - 7, y: ly - 7, width: 14, height: 14)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: endX - 3.5, y: ly - 3.5, width: 7, height: 7)), with: .color(Theme.strainBlue))
        }
    }
}

/// Pulso de una actividad (o de la noche): área azul, escala a la izquierda, líneas discontinuas al inicio y al final.
struct ActivityHrChart: View {
    let points: [(Int64, Int)]
    let start: Int64
    let end: Int64
    var yStep: Double = 25
    var filled: Bool = true
    var lineColor: Color = Theme.strainBlue

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            if points.count < 2 { return }
            let top = 10.0, bottom = h - 30
            let t0 = points.first!.0, t1 = points.last!.0
            let lo = floor(Double(points.map { $0.1 }.min()! - 5) / yStep) * yStep
            let hi = ceil(Double(points.map { $0.1 }.max()! + 5) / yStep) * yStep
            func x(_ t: Int64) -> Double { return w * Double(t - t0) / Double(max(1, t1 - t0)) }
            func y(_ b: Double) -> Double { return bottom - (bottom - top) * ((b - lo) / max(1, hi - lo)) }
            var v = lo
            while v <= hi + 0.1 {
                let yy = y(v)
                var g = Path(); g.move(to: CGPoint(x: 28, y: yy)); g.addLine(to: CGPoint(x: w, y: yy))
                ctx.stroke(g, with: .color(.white.opacity(0.086)), lineWidth: 1)
                label(ctx, String(format: "%.0f", v), Theme.label(13), Theme.textSecondary, CGPoint(x: 2, y: yy), .leading)
                v += yStep
            }
            var line = Path(), fill = Path()
            for (i, p) in points.enumerated() {
                let pt = CGPoint(x: x(p.0), y: y(Double(p.1)))
                if i == 0 { line.move(to: pt); fill.move(to: CGPoint(x: pt.x, y: bottom)); fill.addLine(to: pt) }
                else { line.addLine(to: pt); fill.addLine(to: pt) }
            }
            fill.addLine(to: CGPoint(x: x(t1), y: bottom)); fill.closeSubpath()
            if filled {
                ctx.fill(fill, with: .linearGradient(Gradient(colors: [lineColor.opacity(0.43), lineColor.opacity(0.03)]),
                                                     startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bottom)))
            }
            ctx.stroke(line, with: .color(lineColor), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            for (t, alignLeft) in [(start, true), (end, false)] {
                let xx = x(t)
                var d = Path(); d.move(to: CGPoint(x: xx, y: top - 6)); d.addLine(to: CGPoint(x: xx, y: bottom))
                ctx.stroke(d, with: .color(.white.opacity(0.78)), style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                ctx.fill(Path(ellipseIn: CGRect(x: xx - 3.5, y: bottom - 3.5, width: 7, height: 7)), with: .color(.white))
                label(ctx, Fmt.clock(t), Theme.number(14), Theme.textPrimary,
                      CGPoint(x: alignLeft ? xx + 4 : xx - 4, y: h - 12), alignLeft ? .leading : .trailing)
            }
        }
    }
}

/// Gráfica de "Tendencias semanales" (7 días, el último resaltado): barras (apiladas o no), barras flotantes
/// (tiempo en cama / regularidad) o líneas con puntos.
struct WeekChart: View {
    struct DayLabel { let weekday: String; let dayOfMonth: String }
    struct BarLabel { let text: String; let color: Color }
    /// Barra flotante en minutos (para la noche: minutos desde las 12:00 del día anterior, así la noche es continua).
    struct Range { let start: Double; let end: Double; let startLabel: String?; let endLabel: String? }
    struct Series { let values: [Double?]; let color: Color; let labels: [String?]; let labelsBelow: Bool }

    enum Mode {
        case bars(values: [[(Double, Color)]?], labels: [BarLabel?], max: Double?)
        case ranges(ranges: [Range?], color: Color, dimPrevious: Bool, yLabels: [(Double, String)], optimal: [(Double, Double)?])
        case lines(series: [Series])
    }

    let days: [DayLabel]
    let mode: Mode

    static func days(_ dates: [String]) -> [DayLabel] {
        return dates.map { DayLabel(weekday: WText.weekday($0), dayOfMonth: "\(Day.dayOfMonth($0))") }
    }

    var body: some View {
        Canvas { ctx, size in
            let n = days.count
            if n == 0 { return }
            let w = size.width, h = size.height
            var hasYLabels = false
            if case .ranges(_, _, _, let yl, _) = mode, !yl.isEmpty { hasYLabels = true }
            let left = hasYLabels ? 40.0 : 0
            let right = w, top = 26.0, bottom = h - 46
            let step = (right - left) / Double(n)
            func cx(_ i: Int) -> Double { return left + step * (Double(i) + 0.5) }

            ctx.fill(Path(roundedRect: CGRect(x: cx(n - 1) - step * 0.42, y: 4, width: step * 0.84, height: h - 6), cornerRadius: 5),
                     with: .color(.white.opacity(0.086)))
            if !hasYLabels {
                var g = Path()
                for k in 0...4 {
                    let yy = bottom - (bottom - top) * Double(k) / 4
                    g.move(to: CGPoint(x: left, y: yy)); g.addLine(to: CGPoint(x: right, y: yy))
                }
                ctx.stroke(g, with: .color(.white.opacity(0.094)), lineWidth: 1)
            }
            for (i, d) in days.enumerated() {
                let c = i == n - 1 ? Theme.textPrimary : Theme.textSecondary
                label(ctx, d.weekday, Theme.label(12.5), c, CGPoint(x: cx(i), y: h - 30), .center)
                label(ctx, d.dayOfMonth, Theme.label(12.5), c, CGPoint(x: cx(i), y: h - 13), .center)
            }
            let valueFont = Theme.number(14.5)
            switch mode {
            case .bars(let values, let labels, let mx0):
                let totals = values.map { b in (b ?? []).reduce(0.0) { $0 + $1.0 } }
                var mx = max(mx0 ?? 0, totals.max() ?? 0)
                if mx <= 0 { mx = 1 }
                let bw = step * 0.38
                for i in 0..<n {
                    let b = i < values.count ? values[i] : nil
                    var yy = bottom
                    for (v, c) in b ?? [] where v > 0 {
                        let hgt = (bottom - top - 18) * (v / mx)
                        ctx.fill(Path(CGRect(x: cx(i) - bw / 2, y: yy - hgt, width: bw, height: hgt)), with: .color(c))
                        yy -= hgt
                    }
                    if b != nil && totals[i] <= 0 {
                        ctx.fill(Path(CGRect(x: cx(i) - bw / 2, y: bottom - 2, width: bw, height: 2)), with: .color(.white.opacity(0.24)))
                    }
                    if i < labels.count, let l = labels[i] {
                        label(ctx, l.text, valueFont, l.color, CGPoint(x: cx(i), y: yy - 6), .bottom)
                    }
                }
            case .ranges(let ranges, let color, let dimPrevious, let yLabels, let optimal):
                var all = [Double]()
                for r in ranges { if let r = r { all.append(r.start); all.append(r.end) } }
                for o in optimal { if let o = o { all.append(o.0); all.append(o.1) } }
                all.append(contentsOf: yLabels.map { $0.0 })
                if all.isEmpty { return }
                let lo = all.min()! - 25, hi = all.max()! + 25
                func y(_ m: Double) -> Double { return top + 14 + (bottom - top - 28) * ((m - lo) / max(1, hi - lo)) }
                for (m, s) in yLabels {
                    let yy = y(m)
                    var g = Path(); g.move(to: CGPoint(x: left, y: yy)); g.addLine(to: CGPoint(x: right, y: yy))
                    ctx.stroke(g, with: .color(.white.opacity(0.094)), lineWidth: 1)
                    label(ctx, s, Theme.label(12), Theme.textSecondary, CGPoint(x: 0, y: yy), .leading)
                }
                for which in 0...1 {
                    var p = Path()
                    var started = false
                    for (i, o) in optimal.enumerated() {
                        guard let o = o else { continue }
                        let yy = y(which == 0 ? o.0 : o.1)
                        let x1 = cx(i) - step * 0.42, x2 = cx(i) + step * 0.42
                        if !started { p.move(to: CGPoint(x: x1, y: yy)); started = true } else { p.addLine(to: CGPoint(x: x1, y: yy)) }
                        p.addLine(to: CGPoint(x: x2, y: yy))
                    }
                    if started { ctx.stroke(p, with: .color(.white.opacity(0.78)), style: StrokeStyle(lineWidth: 1.3, dash: [4, 4])) }
                }
                let bw = step * 0.3
                for (i, r) in ranges.enumerated() {
                    guard let r = r else { continue }
                    let dim = dimPrevious && i != n - 1
                    let c = dim ? Color(hex: 0x6E757A) : color
                    ctx.fill(Path(roundedRect: CGRect(x: cx(i) - bw / 2, y: y(r.start), width: bw, height: max(y(r.end) - y(r.start), 2)), cornerRadius: 3),
                             with: .color(c))
                    let tc = dim ? Theme.textSecondary : color
                    if let s = r.startLabel { label(ctx, s, Theme.number(13.5), tc, CGPoint(x: cx(i), y: y(r.start) - 4), .bottom) }
                    if let s = r.endLabel { label(ctx, s, Theme.number(13.5), tc, CGPoint(x: cx(i), y: y(r.end) + 4), .top) }
                }
            case .lines(let series):
                let vals = series.flatMap { $0.values.compactMap { $0 } }
                if vals.isEmpty { return }
                let lo = vals.min()!, hi = vals.max()!
                let pad = max(1, (hi - lo) * 0.25)
                func y(_ v: Double) -> Double { return bottom - 20 - (bottom - top - 50) * ((v - (lo - pad)) / max(1, (hi + pad) - (lo - pad))) }
                for s in series {
                    var p = Path()
                    var started = false
                    for (i, v) in s.values.enumerated() {
                        guard let v = v else { continue }
                        let pt = CGPoint(x: cx(i), y: y(v))
                        if !started { p.move(to: pt); started = true } else { p.addLine(to: pt) }
                    }
                    ctx.stroke(p, with: .color(s.color), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
                }
                for s in series {
                    for (i, v) in s.values.enumerated() {
                        guard let v = v else { continue }
                        let c = CGRect(x: cx(i) - 5, y: y(v) - 5, width: 10, height: 10)
                        ctx.fill(Path(ellipseIn: c), with: .color(Theme.wCard))
                        ctx.stroke(Path(ellipseIn: c), with: .color(s.color), lineWidth: 2.2)
                        if i < s.labels.count, let t = s.labels[i] {
                            label(ctx, t, valueFont, s.color, CGPoint(x: cx(i), y: s.labelsBelow ? y(v) + 9 : y(v) - 9), s.labelsBelow ? .top : .bottom)
                        }
                    }
                }
            }
        }
    }
}

/// Barra de la noche minuto a minuto: awakeRow = false dibuja lo dormido (azul con huecos donde estuviste despierto);
/// true dibuja la pista rayada con una marca blanca en cada despertar.
struct SleepTimelineBar: View {
    let stages: [Int]
    let awakeRow: Bool
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let n = stages.count
            if n == 0 { return }
            func x(_ i: Int) -> Double { return w * Double(i) / Double(n) }
            var i = 0
            if !awakeRow {
                while i < n {
                    if stages[i] == SleepStager.awake { i += 1; continue }
                    var j = i
                    while j < n && stages[j] != SleepStager.awake { j += 1 }
                    ctx.fill(Path(roundedRect: CGRect(x: x(i) + 1, y: 0, width: max(x(j) - x(i) - 2, 2), height: h), cornerRadius: 3),
                             with: .color(Theme.wRingSleep))
                    i = j
                }
            } else {
                ctx.drawLayer { c in
                    c.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: h)))
                    var p = Path()
                    var xx = -h
                    while xx < w + h { p.move(to: CGPoint(x: xx, y: h)); p.addLine(to: CGPoint(x: xx + h, y: 0)); xx += 7 }
                    c.stroke(p, with: .color(.white.opacity(0.13)), lineWidth: 2)
                }
                while i < n {
                    if stages[i] != SleepStager.awake { i += 1; continue }
                    var j = i
                    while j < n && stages[j] == SleepStager.awake { j += 1 }
                    ctx.fill(Path(CGRect(x: x(i), y: 0, width: max(x(j) - x(i), 2.5), height: h)), with: .color(.white))
                    i = j
                }
            }
        }
    }
}
