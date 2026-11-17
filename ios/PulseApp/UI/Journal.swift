import Foundation
import SwiftUI

/* 17/11: Diario e "Información sobre comportamientos" como WHOOP (vídeo del usuario).
   Impacto de un comportamiento = recuperación media de los días con él − la de los días sin él, en los últimos 90 días; hace
   falta haberlo registrado ≥ 5 días con y ≥ 5 sin (como WHOOP: "5 en los que hayas realizado este comportamiento y 5 en los que
   no"). Con el export del usuario este cálculo sigue a los números de WHOOP (correlación 0,85). Además, 4 comportamientos que
   PulseApp saca solo de tus datos: esfuerzo 11+ la víspera, calificación del sueño 84 %+, entrenamiento tardío y hora de
   despertar consistente. Solo informativo: no cambia la recuperación. */

struct Behavior: Identifiable {
    let id: String
    let name: String
    let impact: Double?
    let yes: Int
    let no: Int
    let avgYes: Double?
    let avgNo: Double?
    let auto: Bool
    /// Respuesta de cada día (todo el historial).
    let history: [String: Bool]
}

enum BehaviorAnalysis {
    static let window = 90
    static let minEach = 5

    private static let autos: [(id: String, name: String)] = [
        ("auto:strain11", "Esfuerzo 11+"), ("auto:sleep84", "Calificación del sueño 84 %+"),
        ("auto:latework", "Entrenamiento tardío"), ("auto:wake", "Hora de despertar consistente")
    ]

    /// Valor de cada comportamiento automático por día.
    static func autoHistory(_ id: String, _ recs: [String: DayRecord], _ sessions: [ActivitySession]) -> [String: Bool] {
        var out = [String: Bool]()
        var sessByDay = [String: [ActivitySession]]()
        for s in sessions where s.type != Formulas.napType { sessByDay[TimeUtil.dayKey(s.startMillis), default: []].append(s) }
        for (d, r) in recs {
            let prev = Day.add(d, -1)
            switch id {
            case "auto:strain11":
                if let s = recs[prev]?.strain { out[d] = s >= 11 }
            case "auto:sleep84":
                if let s = r.sleepScore { out[d] = s >= 84 }
            case "auto:latework":
                if recs[prev] != nil {
                    out[d] = (sessByDay[prev] ?? []).contains { TimeUtil.parts($0.endMillis).hour >= 20 }
                }
            default:
                guard let e = r.sleepEndMinute else { continue }
                let past = (1...7).compactMap { recs[Day.add(d, -$0)]?.sleepEndMinute }
                if past.count >= 3 {
                    let med = past.sorted()[past.count / 2]
                    out[d] = abs(e - med) <= 30
                }
            }
        }
        return out
    }

    static func compute(records: [DayRecord], sessions: [ActivitySession], journal: [String: [String: Bool]], today: String) -> [Behavior] {
        var recs = [String: DayRecord]()
        for r in records { recs[r.date] = r }
        let from = Day.add(today, -(window - 1))
        func build(_ id: String, _ name: String, _ hist: [String: Bool], _ auto: Bool) -> Behavior {
            var y = [Double](), n = [Double]()
            for (d, v) in hist where d >= from && d <= today {
                guard let rc = recs[d]?.recovery else { continue }
                if v { y.append(Double(rc)) } else { n.append(Double(rc)) }
            }
            let ay = y.isEmpty ? nil : y.reduce(0, +) / Double(y.count)
            let an = n.isEmpty ? nil : n.reduce(0, +) / Double(n.count)
            var impact: Double? = nil
            if y.count >= minEach && n.count >= minEach, let a = ay, let b = an { impact = a - b }
            return Behavior(id: id, name: name, impact: impact, yes: y.count, no: n.count, avgYes: ay, avgNo: an, auto: auto, history: hist)
        }
        var qs = Set<String>()
        for (_, a) in journal { for q in a.keys { qs.insert(q) } }
        // Dos preguntas pueden tener el mismo comportamiento (p. ej. magnesio): se juntan
        var byName = [String: [String: Bool]]()
        for q in qs {
            let name = JournalStore.behaviorName(q)
            for (d, a) in journal { if let v = a[q] { byName[name, default: [:]][d] = v } }
        }
        var out = byName.map { build("q:" + $0.key, $0.key, $0.value, false) }
        for a in autos { out.append(build(a.id, a.name, autoHistory(a.id, recs, sessions), true)) }
        return out
    }

    static func load() -> [Behavior] {
        let d = HomeDataLoader.load(dayOffset: 0, historyDays: 130)
        return compute(records: d.records, sessions: AppStore.shared.allSessions(), journal: JournalStore.all(), today: Day.today())
    }
}

// MARK: - Tarjeta "Mi diario" de Inicio

struct JournalCard: View {
    let onOpen: (String) -> Void
    let onInsights: () -> Void
    private let wd = ["LUN.", "MAR.", "MIÉ.", "JUE.", "VIE.", "SÁB.", "DOM."]

    var body: some View {
        let today = Day.today()
        let days = (0..<7).reversed().map { Day.add(today, -$0) }
        let all = JournalStore.all()
        return VStack(alignment: .leading, spacing: 14) {
            Button(action: { onOpen(today) }) {
                HStack {
                    WTitle(text: "Mi diario", size: 14)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { d in
                    Button(action: { onOpen(d) }) {
                        VStack(spacing: 8) {
                            WTitle(text: wd[Day.weekdayIndex(d)], size: 10.5, color: d == today ? Theme.textPrimary : Theme.textSecondary)
                            if all[d]?.isEmpty == false {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(Theme.wBgBottom)
                                    .frame(width: 26, height: 26).background(Circle().fill(Theme.wMint))
                            } else {
                                Circle().stroke(d == today ? Theme.wMint : Color.white.opacity(0.25), lineWidth: 2).frame(width: 26, height: 26)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Diario del \(WText.dateShort(d))")
                }
            }
            Button(action: onInsights) {
                HStack(spacing: 8) {
                    Image(systemName: "sun.max").font(.system(size: 14))
                    WTitle(text: "Información sobre comportamientos", size: 12.5)
                }
                .foregroundColor(Theme.textPrimary)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Color.white.opacity(0.08)).cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(16).background(Theme.wCard).cornerRadius(14)
    }
}

// MARK: - Diario de un día

struct JournalView: View {
    let initialDate: String
    @Environment(\.dismiss) private var dismiss
    @State private var date = ""
    @State private var answers = [String: Bool]()
    @State private var questions = [String]()
    @State private var showEdit = false
    private let monthNames = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
    private let wd = ["Lun.", "Mar.", "Mié.", "Jue.", "Vie.", "Sáb.", "Dom."]

    var body: some View {
        let today = Day.today()
        let d = date.isEmpty ? initialDate : date
        return WScreen {
            DetailHeader(title: "Diario", trailing: AnyView(
                Button(action: { showEdit = true }) {
                    Image(systemName: "pencil").font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Elegir preguntas")))
            HStack(spacing: 6) {
                ForEach((0..<7).reversed().map { Day.add(today, -$0) }, id: \.self) { x in
                    Button(action: { select(x) }) {
                        VStack(spacing: 6) {
                            Text(wd[Day.weekdayIndex(x)]).font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                            WNumber(text: "\(Day.dayOfMonth(x))", size: 17, color: x == d ? Theme.wBgBottom : Theme.textPrimary)
                            Image(systemName: JournalStore.day(x).isEmpty ? "circle" : "checkmark.circle.fill").font(.system(size: 13))
                                .foregroundColor(x == d ? Theme.wBgBottom : (JournalStore.day(x).isEmpty ? Theme.textSecondary : Theme.wMint))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(x == d ? Color.white : Theme.wCard))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)
            Text(d == today ? "¿Qué pasa hoy, \(Day.dayOfMonth(d)) de \(monthNames[Day.month(d) - 1])?"
                            : "¿Qué pasó el \(Day.dayOfMonth(d)) de \(monthNames[Day.month(d) - 1])?")
                .font(Theme.text(24, .semibold)).foregroundColor(Theme.textPrimary).padding(.top, 22)
            WBody(text: "Responde por lo de ayer y anoche: cuenta para tu recuperación de este día.", size: 14).padding(.top, 6)
            WTitle(text: "Comportamientos", size: 12, color: Theme.textSecondary).padding(.top, 22).padding(.bottom, 8)
            VStack(spacing: 8) {
                ForEach(questions, id: \.self) { q in
                    HStack(spacing: 10) {
                        Text(q).font(Theme.text(15)).foregroundColor(Theme.textPrimary).frame(maxWidth: .infinity, alignment: .leading)
                        answerButton(q, false)
                        answerButton(q, true)
                    }
                    .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 6)
                    .background(Theme.wCard).cornerRadius(12)
                }
            }
            Button(action: finish) {
                WTitle(text: "Finalizado", size: 14, color: Theme.wBgBottom)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.white).cornerRadius(14)
            }
            .buttonStyle(.plain).padding(.top, 24)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if date.isEmpty { date = initialDate }
            questions = JournalStore.questions()
            answers = JournalStore.day(date)
        }
        .sheet(isPresented: $showEdit, onDismiss: { questions = JournalStore.questions() }) { JournalQuestionsSheet() }
    }

    private func select(_ x: String) {
        JournalStore.save(date, answers)
        date = x
        answers = JournalStore.day(x)
    }

    private func answerButton(_ q: String, _ yes: Bool) -> some View {
        let on = answers[q] == yes
        return Button(action: {
            withAnimation(.easeOut(duration: 0.15)) { if on { answers.removeValue(forKey: q) } else { answers[q] = yes } }
        }) {
            Image(systemName: yes ? "checkmark" : "xmark").font(.system(size: 14, weight: .bold))
                .foregroundColor(on ? Theme.wBgBottom : Theme.textPrimary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? (yes ? Theme.wMint : Color.white) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(yes ? "Sí" : "No")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func finish() {
        JournalStore.save(date, answers)
        dismiss()
    }
}

/// Elegir las preguntas del diario.
struct JournalQuestionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<String>()

    var body: some View {
        let all = JournalStore.catalog.map { $0.q }.filter { $0 != "¿Consumiste magnesio?" }
        return NavigationStack {
            List {
                ForEach(all, id: \.self) { q in
                    Button(action: { if chosen.contains(q) { chosen.remove(q) } else { chosen.insert(q) } }) {
                        HStack {
                            Text(q).foregroundColor(Theme.textPrimary)
                            Spacer()
                            if chosen.contains(q) { Image(systemName: "checkmark").foregroundColor(Theme.wMint) }
                        }
                    }
                }
            }
            .navigationTitle("Preguntas del diario")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        JournalStore.setQuestions(all.filter { chosen.contains($0) })
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { chosen = Set(JournalStore.questions()) }
    }
}

// MARK: - Información sobre comportamientos

struct BehaviorInsightsView: View {
    @Binding var path: [Route]
    @State private var list: [Behavior]? = nil

    var body: some View {
        WScreen {
            DetailHeader(title: "Información sobre comportamientos")
            if let l = list {
                content(l)
            } else {
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { HomeStore.shared.run({ BehaviorAnalysis.load() }, completion: { list = $0 }) }
    }

    @ViewBuilder private func content(_ l: [Behavior]) -> some View {
        let unlocked = l.filter { $0.impact != nil }.sorted { ($0.impact ?? 0) > ($1.impact ?? 0) }
        let locked = l.filter { $0.impact == nil && $0.yes + $0.no > 0 }.sorted { $0.yes + $0.no > $1.yes + $1.no }
        let maxAbs = max(unlocked.map { abs($0.impact ?? 0) }.max() ?? 1, 1)
        Text("Análisis del impacto de la recuperación").font(Theme.text(24, .semibold)).foregroundColor(Theme.textPrimary).padding(.top, 14)
        WBody(text: "Ve cómo los comportamientos se relacionan con tu recuperación en los últimos 90 días. Pulsa un comportamiento para ver más detalles.", size: 14)
            .padding(.top, 6)
        if unlocked.isEmpty {
            WBody(text: "Aún no hay ningún comportamiento con datos suficientes. Rellena el diario cada día: cada comportamiento se desbloquea con 5 días con él y 5 sin él.", size: 14)
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.wCard).cornerRadius(14).padding(.top, 18)
        } else {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)).foregroundColor(Theme.alertAmber)
                    WTitle(text: "Afecta", size: 11, color: Theme.alertAmber)
                }
                Spacer()
                WTitle(text: "% del impacto", size: 11, color: Theme.textSecondary)
                Spacer()
                HStack(spacing: 4) {
                    WTitle(text: "Ayuda", size: 11, color: Theme.wMint)
                    Image(systemName: "arrowtriangle.up.fill").font(.system(size: 8)).foregroundColor(Theme.wMint)
                }
            }
            .padding(.top, 22).padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(unlocked) { b in
                    Button(action: { path.append(.behavior(b.id)) }) { impactRow(b, maxAbs) }.buttonStyle(.plain)
                    WDivider()
                }
            }
            .padding(.horizontal, 14).background(Theme.wCard).cornerRadius(14).padding(.top, 8)
        }
        if !locked.isEmpty {
            WTitle(text: "Sigue registrando para desbloquear", size: 13).padding(.top, 30)
            WBody(text: "Los análisis se desbloquean cuando has registrado un comportamiento al menos 10 días: 5 en los que lo hiciste y 5 en los que no.", size: 13)
                .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(locked) { b in
                    HStack {
                        Text(b.name).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                        Spacer()
                        counter("xmark", b.no)
                        counter("checkmark", b.yes)
                    }
                    .padding(.vertical, 12)
                    WDivider()
                }
            }
            .padding(.horizontal, 14).background(Theme.wCard).cornerRadius(14).padding(.top, 10)
        }
    }

    private func counter(_ icon: String, _ n: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            WNumber(text: "\(min(n, BehaviorAnalysis.minEach))/\(BehaviorAnalysis.minEach)", size: 13,
                    color: n >= BehaviorAnalysis.minEach ? Theme.wMint : Theme.textSecondary)
        }
        .foregroundColor(n >= BehaviorAnalysis.minEach ? Theme.wMint : Theme.textSecondary)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.2), lineWidth: 1))
    }

    private func impactRow(_ b: Behavior, _ maxAbs: Double) -> some View {
        let v = b.impact ?? 0
        let c = v >= 0 ? Theme.wMint : Theme.alertAmber
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(b.name).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                if b.auto { Image(systemName: "sparkles").font(.system(size: 11)).foregroundColor(Theme.textSecondary) }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                GeometryReader { g in
                    let w = Double(g.size.width), mid = w / 2
                    let len = abs(v) / maxAbs * (w / 2 - 4)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                        Capsule().fill(c).frame(width: max(len, 3), height: 6).offset(x: v >= 0 ? mid : mid - len)
                        Circle().fill(Color.white).frame(width: 7, height: 7).offset(x: mid - 3.5)
                    }
                    .frame(height: 8)
                }
                .frame(height: 8)
                WNumber(text: (v >= 0 ? "+" : "−") + "\(Int(abs(v).rounded())) %", size: 15, color: c).frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Detalle de un comportamiento

struct BehaviorDetailView: View {
    let id: String
    @State private var b: Behavior? = nil
    private let monthsUp = ["ENE.", "FEB.", "MAR.", "ABR.", "MAY.", "JUN.", "JUL.", "AGO.", "SEPT.", "OCT.", "NOV.", "DIC."]

    var body: some View {
        WScreen {
            DetailHeader(title: "Detalles de comportamiento")
            if let b = b {
                content(b)
            } else {
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { HomeStore.shared.run({ BehaviorAnalysis.load().first { $0.id == id } }, completion: { b = $0 }) }
    }

    @ViewBuilder private func content(_ b: Behavior) -> some View {
        let v = b.impact
        let c = (v ?? 0) >= 0 ? Theme.wMint : Theme.alertAmber
        Text(b.name).font(Theme.text(28, .semibold)).foregroundColor(Theme.textPrimary).padding(.top, 14)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WTitle(text: "Impacto en la recuperación", size: 12, color: Theme.textSecondary)
                Spacer()
                if let x = v {
                    Text(x >= 0 ? "Positivo" : "Negativo").font(Theme.text(11, .semibold)).foregroundColor(c)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(c.opacity(0.15)).cornerRadius(5)
                }
            }
            WNumber(text: v.map { ($0 >= 0 ? "+" : "−") + "\(Int(abs($0).rounded())) %" } ?? "--", size: 34, color: v == nil ? Theme.textSecondary : c)
            HStack(spacing: 18) {
                avgStat("Con \(b.name.lowercased())", b.avgYes, b.yes)
                avgStat("Sin \(b.name.lowercased())", b.avgNo, b.no)
            }
            if v == nil {
                WBody(text: "Necesitas al menos \(BehaviorAnalysis.minEach) días con y \(BehaviorAnalysis.minEach) sin en los últimos 90 días (ahora \(b.yes) y \(b.no)).", size: 13)
            }
        }
        .padding(16).background(Theme.wCard).cornerRadius(14).padding(.top, 16)

        Text("Historial de registro").font(Theme.text(22)).foregroundColor(Theme.textPrimary).padding(.top, 30)
        calendar(b).padding(.top, 12)

        VStack(alignment: .leading, spacing: 10) {
            Text("Impacto de \(b.name.lowercased())").font(Theme.text(20)).foregroundColor(Theme.textPrimary)
            WBody(text: explanation(b), size: 15)
            if b.auto {
                WBody(text: "Este comportamiento lo calcula PulseApp con tus datos; no hace falta registrarlo.", size: 13)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.wCard).cornerRadius(14).padding(.top, 24)
    }

    private func avgStat(_ label: String, _ avg: Double?, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            WNumber(text: avg.map { "\(Int($0.rounded())) %" } ?? "--", size: 20)
            Text("\(label) (\(n) días)").font(Theme.text(12)).foregroundColor(Theme.textSecondary)
        }
    }

    private func explanation(_ b: Behavior) -> String {
        guard let y = b.avgYes, let n = b.avgNo, b.impact != nil else {
            return "Cuando tengas suficientes días registrados verás aquí cómo cambia tu recuperación los días con \(b.name.lowercased()) frente a los días sin."
        }
        return "En los últimos 90 días, tu recuperación fue de media \(Int(y.rounded())) % los días con \(b.name.lowercased()) y \(Int(n.rounded())) % los días sin. Es una relación observada en tus datos: no tiene por qué ser la causa, pero te ayuda a ver qué hábitos te sientan mejor."
    }

    /// 3 meses de puntos: sí (verde), no (hueco), sin registrar (gris tenue).
    private func calendar(_ b: Behavior) -> some View {
        let today = Day.today()
        let start = Day.add(today, -90)
        let firstMonday = Day.add(start, -Day.weekdayIndex(start))
        let weeks = Int(ceil(Double(Day.weekdayIndex(start) + 91) / 7.0))
        let yes = b.history.filter { $0.key >= start && $0.value }.count
        let no = b.history.filter { $0.key >= start && !$0.value }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(["L", "M", "X", "J", "V", "S", "D"], id: \.self) { l in
                    Text(l).font(Theme.label(11)).foregroundColor(Theme.textSecondary).frame(width: 16)
                }
                Spacer()
                WTitle(text: "\(monthsUp[Day.month(start) - 1]) - \(monthsUp[Day.month(today) - 1])", size: 11, color: Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<weeks, id: \.self) { w in
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { i in
                            let d = Day.add(firstMonday, w * 7 + i)
                            dot(d < start || d > today ? nil : b.history[d], inRange: d >= start && d <= today)
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                legendDot(true, "Sí (\(yes))")
                legendDot(false, "No (\(no))")
                legendDot(nil, "Faltante (\(91 - yes - no))")
            }
            .padding(.top, 6)
        }
        .padding(16).background(Theme.wCard).cornerRadius(14)
    }

    @ViewBuilder private func dot(_ v: Bool?, inRange: Bool) -> some View {
        if !inRange {
            Color.clear.frame(width: 16, height: 16)
        } else if let x = v {
            Circle().fill(x ? Theme.wMint : Color.clear).overlay(Circle().stroke(x ? Theme.wMint : Color.white.opacity(0.7), lineWidth: 1.5))
                .frame(width: 12, height: 12).frame(width: 16, height: 16)
        } else {
            Circle().fill(Color.white.opacity(0.12)).frame(width: 8, height: 8).frame(width: 16, height: 16)
        }
    }

    private func legendDot(_ v: Bool?, _ text: String) -> some View {
        HStack(spacing: 6) {
            dot(v, inRange: true)
            Text(text).font(Theme.text(12)).foregroundColor(Theme.textSecondary)
        }
    }
}

// MARK: - Tarjeta de Recuperación: comportamientos de ese día

struct BehaviorChipsCard: View {
    let date: String
    @Binding var path: [Route]
    @State private var chips: [(String, Double?)]? = nil

    var body: some View {
        Button(action: { path.append(.behaviors) }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "sun.max").font(.system(size: 15)).foregroundColor(Theme.textPrimary)
                    WTitle(text: "Información sobre comportamientos", size: 13)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                }
                WBody(text: "Algunos de tus comportamientos de ayer pueden haber afectado tu puntuación de recuperación de este día.", size: 13.5)
                if let c = chips, !c.isEmpty {
                    FlowChips(items: c)
                } else if chips != nil {
                    WBody(text: "Rellena el diario para ver aquí qué hiciste ayer.", size: 13)
                }
            }
            .padding(16).background(Theme.wCard).cornerRadius(14)
        }
        .buttonStyle(.plain)
        .onAppear {
            let d = date
            HomeStore.shared.run({ () -> [(String, Double?)] in
                let l = BehaviorAnalysis.load()
                return l.filter { $0.history[d] == true }.sorted { abs($0.impact ?? 0) > abs($1.impact ?? 0) }.prefix(6).map { ($0.name, $0.impact) }
            }, completion: { chips = $0 })
        }
    }
}

/// Píldoras en filas (se parten solas en varias líneas).
struct FlowChips: View {
    let items: [(String, Double?)]
    var body: some View {
        var rows = [[(String, Double?)]]()
        var cur = [(String, Double?)]()
        var width = 0.0
        for it in items {
            let w = Double(it.0.count) * 7.5 + 40
            if width + w > 330 && !cur.isEmpty { rows.append(cur); cur = []; width = 0 }
            cur.append(it); width += w + 8
        }
        if !cur.isEmpty { rows.append(cur) }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r].indices, id: \.self) { i in
                        let it = rows[r][i]
                        let c = it.1 == nil ? Theme.textSecondary : ((it.1 ?? 0) >= 0 ? Theme.wMint : Theme.alertAmber)
                        HStack(spacing: 6) {
                            Image(systemName: it.1 == nil ? "circle.fill" : ((it.1 ?? 0) >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill"))
                                .font(.system(size: 8)).foregroundColor(c)
                            Text(it.0).font(Theme.text(13, .medium)).foregroundColor(Theme.textPrimary).lineLimit(1)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.white.opacity(0.08)).cornerRadius(8)
                    }
                }
            }
        }
    }
}
