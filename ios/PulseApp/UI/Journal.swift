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

/// Círculo de estado de un día del diario, como WHOOP: verde con ✓ = todo respondido, aro verde = parte, gris = nada.
struct JournalStatusDot: View {
    let status: Int
    var size: Double = 24
    var body: some View {
        Group {
            if status == 2 {
                Image(systemName: "checkmark").font(.system(size: size * 0.46, weight: .heavy)).foregroundColor(Theme.wBgBottom)
                    .frame(width: size, height: size).background(Circle().fill(Theme.wMint))
            } else if status == 1 {
                Circle().stroke(Theme.wMint, lineWidth: 2).frame(width: size - 2, height: size - 2).frame(width: size, height: size)
            } else {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 2).frame(width: size - 2, height: size - 2).frame(width: size, height: size)
            }
        }
        .accessibilityLabel(status == 2 ? "Completado" : (status == 1 ? "A medias" : "Sin registrar"))
    }
}

struct JournalCard: View {
    let onOpen: (String) -> Void
    let onInsights: () -> Void
    private let wd = ["LUN.", "MAR.", "MIÉ.", "JUE.", "VIE.", "SÁB.", "DOM."]

    var body: some View {
        let today = Day.today()
        let days = (0..<7).reversed().map { Day.add(today, -$0) }
        let all = JournalStore.all()
        let qs = JournalStore.questions()
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
                            JournalStatusDot(status: JournalStore.status(d, answers: all[d] ?? [:], questions: qs), size: 26)
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

// MARK: - Piezas comunes del diario

private let journalBlue = Color(hex: 0x3D8BFD)

/// Recuadro "Registro inteligente" / "Crear comportamientos personalizados" con TEXTO y HABLAR (como WHOOP).
struct JournalSmartBox: View {
    let title: String
    let onText: () -> Void
    let onSpeak: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: 0x8FA3FF))
                Text(title).font(Theme.text(15, .medium)).foregroundColor(Theme.textPrimary)
            }
            HStack(spacing: 10) {
                boxButton("keyboard", "Texto", Color.white.opacity(0.08), onText)
                boxButton("mic.fill", "Hablar", Color(hex: 0x24346E), onSpeak)
            }
        }
        .padding(14)
        .background(LinearGradient(colors: [Color(hex: 0x252A4A), Color(hex: 0x1C2138)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x4A55A0).opacity(0.55), lineWidth: 1))
        .cornerRadius(16)
    }

    private func boxButton(_ icon: String, _ text: String, _ bg: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13))
                WTitle(text: text, size: 12)
            }
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(bg).cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

/// Botón blanco de abajo ("FINALIZADO", "GUARDAR COMPORTAMIENTOS").
struct JournalBottomButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            WTitle(text: title, size: 13, color: Theme.wBgBottom)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(Color.white).cornerRadius(12)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(LinearGradient(colors: [Theme.wBgBottom.opacity(0), Theme.wBgBottom], startPoint: .top, endPoint: .center))
    }
}

// MARK: - Diario de un día

struct JournalView: View {
    let initialDate: String
    @Environment(\.dismiss) private var dismiss
    @State private var date = ""
    @State private var answers = [String: Bool]()
    @State private var questions = [String]()
    @State private var showPicker = false
    @State private var smart: SmartMode? = nil
    @State private var lastLog: [(String, Bool)] = []
    private let monthNames = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]
    private let wd = ["Lun.", "Mar.", "Mié.", "Jue.", "Vie.", "Sáb.", "Dom."]

    enum SmartMode: String, Identifiable { case text, speak; var id: String { rawValue } }

    var body: some View {
        let today = Day.today()
        let d = date.isEmpty ? initialDate : date
        let sorted = questions.sorted { JournalCatalog.fold($0).trimmingCharacters(in: CharacterSet(charactersIn: "¿")) <
                                        JournalCatalog.fold($1).trimmingCharacters(in: CharacterSet(charactersIn: "¿")) }
        return ZStack(alignment: .bottom) {
            Theme.wBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar(d, today)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        weekChips(d, today)
                        Text(d == today ? "¿Qué pasa hoy, \(Day.dayOfMonth(d)) de \(monthNames[Day.month(d) - 1])?"
                                        : "¿Qué pasó el \(Day.dayOfMonth(d)) de \(monthNames[Day.month(d) - 1])?")
                            .font(Theme.text(23, .semibold)).foregroundColor(Theme.textPrimary).padding(.top, 20)
                        JournalSmartBox(title: "Registro inteligente", onText: { smart = .text }, onSpeak: { smart = .speak })
                            .padding(.top, 16)
                        if !lastLog.isEmpty {
                            WBody(text: "Registrado: " + lastLog.map { ($0.1 ? "✓ " : "✕ ") + $0.0 }.joined(separator: " · "), size: 13)
                                .padding(.top, 8)
                        }
                        WTitle(text: "Comportamientos", size: 11, color: Theme.textSecondary).padding(.top, 22).padding(.bottom, 8)
                        VStack(spacing: 8) {
                            ForEach(sorted, id: \.self) { q in
                                HStack(spacing: 8) {
                                    Text(q).font(Theme.text(15.5, .medium)).foregroundColor(Theme.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                                    answerButton(q, false)
                                    answerButton(q, true)
                                }
                                .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 14)
                                .background(Theme.wCard).cornerRadius(12)
                            }
                        }
                        Button(action: { showPicker = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                                WTitle(text: "Añadir comportamientos", size: 12)
                            }
                            .foregroundColor(Theme.textPrimary).frame(maxWidth: .infinity).frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.plain).padding(.top, 10)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 110)
                }
            }
            JournalBottomButton(title: "Finalizado", action: finish)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if date.isEmpty { date = initialDate }
            questions = JournalStore.questions()
            answers = JournalStore.day(date)
        }
        .sheet(isPresented: $showPicker, onDismiss: { questions = JournalStore.questions() }) { BehaviorPickerView() }
        .sheet(item: $smart) { m in
            SmartTextSheet(title: "Registro inteligente",
                           hint: "Cuéntame tu día: \"desayuné, tomé dos cafés, cené tarde y no bebí alcohol\".",
                           speak: m == .speak, actionTitle: "Registrar") { text in
                let r = SmartLog.parse(text, questions: questions)
                withAnimation(.easeOut(duration: 0.2)) { for (q, v) in r { answers[q] = v } }
                lastLog = r.map { (JournalCatalog.name($0.key), $0.value) }.sorted { $0.0 < $1.0 }
                JournalStore.save(date, answers)
            }
        }
    }

    private func topBar(_ d: String, _ today: String) -> some View {
        HStack {
            Button(action: finish) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Cerrar")
            Spacer()
            HStack(spacing: 14) {
                Button(action: { select(Day.add(d, -1)) }) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.textPrimary).frame(width: 30, height: 36)
                }
                .accessibilityLabel("Día anterior")
                WTitle(text: d == today ? "Hoy" : (d == Day.add(today, -1) ? "Ayer" : WText.dateShort(d)), size: 12.5)
                Button(action: { if d < today { select(Day.add(d, 1)) } }) {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                        .foregroundColor(d < today ? Theme.textPrimary : Theme.textSecondary.opacity(0.4)).frame(width: 30, height: 36)
                }
                .disabled(d >= today)
                .accessibilityLabel("Día siguiente")
            }
            Spacer()
            Button(action: { showPicker = true }) {
                Image(systemName: "pencil").font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Elegir comportamientos")
        }
        .padding(.horizontal, 6)
    }

    private func weekChips(_ d: String, _ today: String) -> some View {
        // La semana que acaba en el día elegido (o hoy si es de esta semana)
        let end = d > Day.add(today, -7) ? today : min(Day.add(d, 3), today)
        return HStack(spacing: 6) {
            ForEach((0..<7).reversed().map { Day.add(end, -$0) }, id: \.self) { x in
                let st = x == d ? JournalStore.status(x, answers: answers, questions: questions) : JournalStore.status(x, questions: questions)
                Button(action: { select(x) }) {
                    VStack(spacing: 5) {
                        Text(wd[Day.weekdayIndex(x)]).font(Theme.text(10.5)).foregroundColor(Theme.textSecondary)
                        WNumber(text: "\(Day.dayOfMonth(x))", size: 17)
                        JournalStatusDot(status: st, size: 18)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(x == d ? Color.white.opacity(0.07) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(x == d ? Color.white.opacity(0.85) : Color.clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private func select(_ x: String) {
        JournalStore.save(date, answers)
        date = x
        answers = JournalStore.day(x)
        lastLog = []
    }

    private func answerButton(_ q: String, _ yes: Bool) -> some View {
        let on = answers[q] == yes
        return Button(action: {
            withAnimation(.easeOut(duration: 0.15)) { if on { answers.removeValue(forKey: q) } else { answers[q] = yes } }
        }) {
            Image(systemName: yes ? "checkmark" : "xmark").font(.system(size: 12, weight: .bold))
                .foregroundColor(on ? Theme.wBgBottom : Theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? (yes ? Theme.wMint : Color.white) : Color.white.opacity(0.1)))
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

// MARK: - Seleccionar comportamientos (como WHOOP)

struct BehaviorPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<String>()
    @State private var initial = Set<String>()
    @State private var cat = ""
    @State private var search = ""
    @State private var create: JournalView.SmartMode? = nil
    @State private var items = JournalCatalog.all()

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.wBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Cerrar sin guardar")
                    WTitle(text: "Seleccionar comportamientos", size: 13)
                    Spacer()
                }
                .padding(.horizontal, 6).padding(.top, 8)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                    TextField("", text: $search, prompt: Text("Buscar comportamientos").foregroundColor(Theme.textSecondary))
                        .font(Theme.text(15)).foregroundColor(Theme.textPrimary).autocorrectionDisabled()
                    if !search.isEmpty {
                        Button(action: { search = "" }) { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textSecondary) }
                    }
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Color.white.opacity(0.07)).cornerRadius(10)
                .padding(.horizontal, 16).padding(.top, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(JournalCatalog.categories.indices, id: \.self) { i in
                            let c = JournalCatalog.categories[i]
                            Button(action: { withAnimation(.easeOut(duration: 0.15)) { cat = c.key } }) {
                                Text(c.title).font(Theme.text(14, .medium))
                                    .foregroundColor(cat == c.key ? Theme.wBgBottom : Theme.textPrimary)
                                    .padding(.horizontal, 12).frame(height: 34)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(cat == c.key ? Color.white : Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) { list }
                        .padding(.horizontal, 16).padding(.bottom, 110)
                }
            }
            JournalBottomButton(title: "Guardar comportamientos") {
                let order = items.map { $0.q }
                var qs = order.filter { chosen.contains($0) }
                // Preguntas elegidas que no están en el catálogo (p. ej. importadas de WHOOP con otro texto) se conservan
                qs += chosen.filter { !order.contains($0) }.sorted()
                JournalStore.setQuestions(qs)
                dismiss()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            chosen = Set(JournalStore.questions())
            initial = chosen
        }
        .sheet(item: $create) { m in
            CustomBehaviorSheet(speak: m == .speak) { item in
                items = JournalCatalog.all()
                chosen.insert(item.q)
                initial.insert(item.q)
                cat = JournalCatalog.customCat
            }
        }
    }

    @ViewBuilder private var list: some View {
        let f = JournalCatalog.fold(search.trimmingCharacters(in: .whitespaces))
        let shown = items.filter { (cat.isEmpty || $0.cat == cat) && (f.isEmpty || JournalCatalog.fold($0.name).contains(f) || JournalCatalog.fold($0.q).contains(f)) }
        let sel = shown.filter { initial.contains($0.q) }
        let rest = shown.filter { !initial.contains($0.q) }
        if search.isEmpty {
            JournalSmartBox(title: "Crear comportamientos personalizados", onText: { create = .text }, onSpeak: { create = .speak })
                .padding(.bottom, 18)
        }
        if cat == JournalCatalog.customCat && shown.isEmpty && search.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "book.closed.fill").font(.system(size: 34)).foregroundColor(Color(hex: 0x8FA3FF)).padding(.bottom, 4)
                Text("Aún no hay comportamientos personalizados").font(Theme.text(18, .semibold)).foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                WBody(text: "Crea comportamientos personalizados para hacer seguimiento de cómo tus rutinas influyen en tu Recuperación con el tiempo. Tus resultados aparecerán aquí.", size: 13.5)
                    .multilineTextAlignment(.center)
            }
            .padding(22).frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        if shown.isEmpty && !search.isEmpty {
            WBody(text: "No hay ningún comportamiento con \"\(search)\". Puedes crearlo tú en Comportamientos personalizados.", size: 14).padding(.top, 8)
        }
        if !sel.isEmpty {
            WTitle(text: "Actualmente seleccionado", size: 10.5, color: Theme.textSecondary).padding(.bottom, 4)
            ForEach(sel, id: \.self) { row($0) }
        }
        if !rest.isEmpty {
            WTitle(text: "No seleccionado", size: 10.5, color: Theme.textSecondary).padding(.top, sel.isEmpty ? 0 : 14).padding(.bottom, 4)
            ForEach(rest, id: \.self) { row($0) }
        }
    }

    private func row(_ it: JournalCatalog.Item) -> some View {
        let on = chosen.contains(it.q)
        return Button(action: { if on { chosen.remove(it.q) } else { chosen.insert(it.q) } }) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.name).font(Theme.text(15.5, .semibold)).foregroundColor(Theme.textPrimary)
                    Text(it.q).font(Theme.text(12.5)).foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(on ? journalBlue : Color.clear)
                    RoundedRectangle(cornerRadius: 6).stroke(on ? journalBlue : Color.white.opacity(0.7), lineWidth: 1.6)
                    if on { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(.white) }
                }
                .frame(width: 26, height: 26)
            }
            .padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Crear un comportamiento propio: nombre y pregunta (escrito o hablado).
struct CustomBehaviorSheet: View {
    let speak: Bool
    let onCreate: (JournalCatalog.Item) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var question = ""
    @StateObject private var mic = SpeechInput()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.wBackground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    WBody(text: "Ponle un nombre corto y la pregunta que responderás cada día con sí o no.", size: 14)
                    field("Nombre (p. ej. Siesta corta)", $name)
                    field("Pregunta (p. ej. ¿Dormiste una siesta corta?)", $question)
                    MicButton(mic: mic)
                    if let e = mic.error { WBody(text: e, size: 13, color: Theme.alertAmber) }
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("Comportamiento personalizado")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { mic.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crear") {
                        mic.stop()
                        if let it = JournalCatalog.addCustom(name: name, question: question) { onCreate(it) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if speak { mic.start() } }
        .onChange(of: mic.text) { t in
            // Lo dicho: "nombre" o "nombre, pregunta"
            let parts = t.components(separatedBy: CharacterSet(charactersIn: ",.?¿")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let n = parts.first { name = n.prefix(1).uppercased() + n.dropFirst() }
            if parts.count > 1 { question = "¿" + parts.dropFirst().joined(separator: " ") + "?" }
        }
    }

    private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Theme.textSecondary))
            .font(Theme.text(16)).foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 12).frame(height: 46)
            .background(Color.white.opacity(0.07)).cornerRadius(10)
    }
}

/// Escribir o dictar el día y marcar solo las respuestas.
struct SmartTextSheet: View {
    let title: String
    let hint: String
    let speak: Bool
    let actionTitle: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @StateObject private var mic = SpeechInput()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.wBackground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    WBody(text: hint, size: 14)
                    TextEditor(text: $text)
                        .font(Theme.text(16)).foregroundColor(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(8).frame(height: 160)
                        .background(Color.white.opacity(0.07)).cornerRadius(12)
                    MicButton(mic: mic)
                    if let e = mic.error { WBody(text: e, size: 13, color: Theme.alertAmber) }
                    WBody(text: "PulseApp busca en lo que escribas los comportamientos que tienes en el diario (\"no\", \"sin\" o \"nada\" en la misma frase lo marcan como no). Todo se queda en el móvil.", size: 12)
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { mic.stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) { mic.stop(); onDone(text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if speak { mic.start() } }
        .onChange(of: mic.text) { t in text = t }
    }
}

struct MicButton: View {
    @ObservedObject var mic: SpeechInput
    var body: some View {
        Button(action: { mic.listening ? mic.stop() : mic.start() }) {
            HStack(spacing: 8) {
                Image(systemName: mic.listening ? "stop.fill" : "mic.fill").font(.system(size: 14))
                WTitle(text: mic.listening ? "Escuchando… toca para parar" : "Hablar", size: 12)
            }
            .foregroundColor(Theme.textPrimary).frame(maxWidth: .infinity).frame(height: 44)
            .background(mic.listening ? Theme.alertRed.opacity(0.35) : Color(hex: 0x24346E)).cornerRadius(10)
        }
        .buttonStyle(.plain)
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
