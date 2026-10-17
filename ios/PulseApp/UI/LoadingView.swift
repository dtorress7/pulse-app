import Foundation
import SwiftUI

/// Pantalla de carga animada (fondo negro) con el logo de PulseApp, igual que en Android:
/// el anillo gira con su degradado azul → verde, el latido recorre la línea como en un monitor y, al pasar por el pico,
/// el anillo "late" y suelta una onda. Debajo, las letras de CARGANDO saltan una detrás de otra.
struct LoadingView: View {
    var text: String = "CARGANDO"
    @State private var start = Date()

    // Latido del logo (coordenadas del logo de 120 × 120 con el anillo de radio 44 centrado en 60,60)
    private static let pulse: [CGPoint] = [CGPoint(x: 8, y: 62), CGPoint(x: 38, y: 62), CGPoint(x: 45, y: 48), CGPoint(x: 54, y: 82),
                                           CGPoint(x: 64, y: 30), CGPoint(x: 72, y: 70), CGPoint(x: 77, y: 62), CGPoint(x: 112, y: 62)]
    /// Puntos cada poco a lo largo del latido: (x, y, distancia acumulada 0..1).
    private static let samples: [(Double, Double, Double)] = {
        var lens = [Double]()
        for i in 0..<(pulse.count - 1) {
            lens.append(hypot(Double(pulse[i + 1].x - pulse[i].x), Double(pulse[i + 1].y - pulse[i].y)))
        }
        let total = lens.reduce(0, +)
        var out = [(Double, Double, Double)]()
        var acc = 0.0
        for i in 0..<lens.count {
            let steps = max(2, Int(lens[i] / 1.2))
            for s in 0..<steps {
                let f = Double(s) / Double(steps)
                out.append((Double(pulse[i].x) + Double(pulse[i + 1].x - pulse[i].x) * f,
                            Double(pulse[i].y) + Double(pulse[i + 1].y - pulse[i].y) * f, (acc + lens[i] * f) / total))
            }
            acc += lens[i]
        }
        out.append((Double(pulse.last!.x), Double(pulse.last!.y), 1))
        return out
    }()
    private static let spikeAt: Double = samples.min { $0.1 < $1.1 }!.2

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSince(start) * 1000
                LoadingView.draw(&ctx, size, t, text)
            }
        }
        .background(Color.black)
    }

    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ text: String) {
        let w = size.width, h = size.height
        let cx = w / 2, cy = h / 2 - 34
        let r = min(58, w * 0.17)
        let unit = r / 44
        func lx(_ x: Double) -> Double { return cx + (x - 60) * unit }
        func ly(_ y: Double) -> Double { return cy + (y - 60) * unit }

        // Ritmo: un latido cada 1,1 s; la cabeza recorre el trazo en 0,8 s
        let beat = 1100.0
        let phase = t.truncatingRemainder(dividingBy: beat) / beat
        let headPos = min(phase / 0.8, 1.15)
        let sinceSpike = ((phase - spikeAt * 0.8 + 1).truncatingRemainder(dividingBy: 1)) * beat
        let bump = 1 + 0.055 * exp(-(sinceSpike / 90) * (sinceSpike / 90))
        let rr = r * bump
        let green = Color(hex: 0x16EC06), blue = Color(hex: 0x02A9F7)

        // Onda que sale del anillo en cada latido
        if sinceSpike < 700 {
            let k = sinceSpike / 700
            let rad = rr + 26 * k
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - rad, y: cy - rad, width: 2 * rad, height: 2 * rad)),
                       with: .color(green.opacity(0.47 * (1 - k))), lineWidth: 3 * (1 - k))
        }
        // Anillo: pista + arco de 300° que gira
        let stroke = 10 * unit
        ctx.stroke(Path(ellipseIn: CGRect(x: cx - rr, y: cy - rr, width: 2 * rr, height: 2 * rr)), with: .color(Color(hex: 0x1E262B)), lineWidth: stroke)
        let rot = t.truncatingRemainder(dividingBy: 1600) / 1600 * 360
        var arc = Path()
        arc.addArc(center: CGPoint(x: cx, y: cy), radius: rr, startAngle: .degrees(-90 + rot), endAngle: .degrees(-90 + rot + 300), clockwise: false)
        ctx.stroke(arc, with: .linearGradient(Gradient(colors: [blue, green]), startPoint: CGPoint(x: cx - rr, y: cy + rr),
                                              endPoint: CGPoint(x: cx + rr, y: cy - rr)),
                   style: StrokeStyle(lineWidth: stroke, lineCap: .round))

        // Latido: hueco negro sobre el anillo + silueta tenue + trazo que se va dibujando con estela
        var line = Path()
        for (k, p) in pulse.enumerated() {
            let pt = CGPoint(x: lx(Double(p.x)), y: ly(Double(p.y)))
            if k == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
        }
        ctx.stroke(line, with: .color(.black), style: StrokeStyle(lineWidth: 11 * unit, lineCap: .round, lineJoin: .round))
        ctx.stroke(line, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 5.5 * unit, lineCap: .round, lineJoin: .round))
        let tail = 0.45
        for i in 1..<samples.count {
            let p = samples[i].2
            if p > headPos || p < headPos - tail { continue }
            let a = min(max((p - (headPos - tail)) / tail, 0), 1)
            var seg = Path()
            seg.move(to: CGPoint(x: lx(samples[i - 1].0), y: ly(samples[i - 1].1)))
            seg.addLine(to: CGPoint(x: lx(samples[i].0), y: ly(samples[i].1)))
            ctx.stroke(seg, with: .color(.white.opacity(a)), style: StrokeStyle(lineWidth: 5.5 * unit, lineCap: .round))
        }
        if headPos <= 1 {
            let hp = samples.min { abs($0.2 - headPos) < abs($1.2 - headPos) }!
            let hr = 4.2 * unit
            ctx.fill(Path(ellipseIn: CGRect(x: lx(hp.0) - hr, y: ly(hp.1) - hr, width: 2 * hr, height: 2 * hr)), with: .color(.white))
        }

        // CARGANDO: cada letra salta por turnos (ola)
        let chars = Array(text)
        let font = Theme.number(17)
        let widths = chars.map { ch -> Double in Double(ctx.resolve(Text(String(ch)).font(font)).measure(in: CGSize(width: 100, height: 100)).width) }
        let spacing = 5.0
        let totalW = widths.reduce(0, +) + spacing * Double(max(chars.count - 1, 0))
        var x = cx - totalW / 2
        let baseY = cy + r + 70
        let cycle = 1500.0
        for (i, ch) in chars.enumerated() {
            var lt = (t - Double(i) * 85).truncatingRemainder(dividingBy: cycle)
            if lt < 0 { lt += cycle }
            let jump = lt < 320 ? sin(Double.pi * lt / 320) : 0
            ctx.draw(Text(String(ch)).font(font).foregroundColor(.white.opacity((150 + 105 * jump) / 255)),
                     at: CGPoint(x: x, y: baseY - jump * 9), anchor: .bottomLeading)
            x += widths[i] + spacing
        }
    }
}
