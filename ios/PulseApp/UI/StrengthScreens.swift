import Foundation
import SwiftUI

/* Entrenador de fuerza (5/11), como el de WHOOP — port de StrengthActivity / StrengthSessionActivity / ExercisePickerActivity /
   StrengthSummaryActivity de Android. */

// MARK: - Guardar

enum StrengthSave {
    static let type = "Entrenamiento de fuerza"

    /// Rehace la actividad [id] con su pulso y sus series (y el día guardado si es pasado).
    @discardableResult
    static func resummarize(_ id: Int64, newType: String? = nil) -> ActivitySession? {
        let st = AppStore.shared
        guard let s = st.session(id: id) else { return nil }
        let p = st.getProfile()
        let rhr = BaselineProvider.compute(store: st).map { Int($0.avgRestingHr) }
        guard var fresh = ActivityRecorder.summarize(hrLog: WhoopManager.shared.hrLog, startMillis: s.startMillis, endMillis: s.endMillis,
                                                     ageYears: p?.ageYears() ?? 30, weightKg: p?.weightKg ?? 70, sex: p?.sex ?? "M",
                                                     type: newType ?? s.type, autoDetected: s.autoDetected, restingHr: rhr) else { return nil }
        fresh.id = s.id
        st.updateSession(fresh)
        recalcDayOf(s.startMillis)
        return fresh
    }

    static func recalcDayOf(_ millis: Int64) {
        let st = AppStore.shared
        guard let p = st.getProfile() else { return }
        DailyMetricsUpdater.recalcDay(store: st, hrLog: WhoopManager.shared.hrLog, motionFile: AppPaths.file(MotionTracker.fileName),
                                      key: TimeUtil.dayKey(millis), ageYears: p.ageYears(), weightKg: p.weightKg, sex: p.sex)
    }

    /// Termina el entrenamiento en curso: guarda la actividad (inicio → ahora) con sus series; sustituye la automática del mismo rato.
    static func finishLive(_ w: Strength.Workout, endMs: Int64) -> Int64? {
        let st = AppStore.shared
        let start = w.startMs
        let end = max(endMs, start + 60_000)
        w.endMs = end
        w.id = -start
        Strength.saveLog(w)
        let p = st.getProfile()
        let rhr = BaselineProvider.compute(store: st).map { Int($0.avgRestingHr) }
        guard let s = ActivityRecorder.summarize(hrLog: WhoopManager.shared.hrLog, startMillis: start, endMillis: end,
                                                 ageYears: p?.ageYears() ?? 30, weightKg: p?.weightKg ?? 70, sex: p?.sex ?? "M",
                                                 type: type, autoDetected: false, restingHr: rhr) else {
            Strength.deleteLog(-start); return nil
        }
        for o in st.allSessions() where o.autoDetected {
            let ov = min(o.endMillis, end) - max(o.startMillis, start)
            if ov > 0 && ov * 2 >= min(o.endMillis - o.startMillis, end - start) { st.deleteSession(id: o.id) }
        }
        let id = st.saveSession(s)
        Strength.deleteLog(-start)
        w.id = id
        Strength.saveLog(w)
        recalcDayOf(start)
        return id
    }

    /// FC media de cada serie cronometrada: clave "ejercicio-serie" → lpm.
    static func setHeartRates(_ w: Strength.Workout) -> [String: Int] {
        var out = [String: Int]()
        let timed = w.exercises.enumerated().flatMap { (k, e) in e.sets.enumerated().compactMap { (si, s) -> (Int, Int, Int64, Int64)? in
            if let a = s.startMs, let b = s.endMs { return (k, si, a, b) }; return nil } }
        if timed.isEmpty { return out }
        let all = WhoopManager.shared.hrLog.readings(from: timed.map { $0.2 }.min()!, to: timed.map { $0.3 }.max()!)
        for (k, si, a, b) in timed {
            let v = all.filter { $0.timeMillis >= a && $0.timeMillis <= b }.map { $0.bpm }
            if !v.isEmpty { out["\(k)-\(si)"] = Int((Double(v.reduce(0, +)) / Double(v.count)).rounded()) }
        }
        return out
    }
}

// MARK: - Piezas

enum SFmt {
    static func kg(_ v: Double) -> String { return v == v.rounded() ? String(format: "%.0f", v) : Fmt.comma(v, 1) }
    static func dateUpper(_ ms: Int64) -> String {
        let key = TimeUtil.dayKey(ms)
        return "\(Day.dayOfMonth(key)) \(WText.monthUpper(key)) \(TimeUtil.parts(ms).year)"
    }
    static func hms(_ sec: Int64) -> String { return String(format: "%02d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60) }
    static func ms(_ sec: Int64) -> String { return String(format: "%d:%02d", sec / 60, sec % 60) }
    static func groupIcon(_ g: String?) -> String {
        switch g {
        case "Piernas", "Glúteos": return "figure.step.training"
        case "Core": return "figure.core.training"
        case "Cardio": return "heart"
        case "Cuerpo completo": return "figure.cross.training"
        default: return "dumbbell.fill"
        }
    }
    static func groupColor(_ g: String?) -> Color {
        switch g {
        case "Pecho": return Color(red: 0.12, green: 0.48, blue: 0.55)
        case "Espalda": return Color(red: 0.18, green: 0.44, blue: 0.62)
        case "Hombros": return Color(red: 0.25, green: 0.43, blue: 0.56)
        case "Bíceps", "Tríceps": return Color(red: 0.16, green: 0.50, blue: 0.48)
        case "Piernas", "Glúteos": return Color(red: 0.18, green: 0.50, blue: 0.37)
        case "Core": return Color(red: 0.33, green: 0.44, blue: 0.54)
        default: return Color(red: 0.23, green: 0.37, blue: 0.45)
        }
    }
}

let strengthGreen = Color(red: 0.17, green: 0.83, blue: 0.63)

struct ExerciseThumb: View {
    let group: String?
    var size: Double = 52
    var body: some View {
        let c = SFmt.groupColor(group)
        return RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: [c.opacity(0.75), c.opacity(0.3)], startPoint: .top, endPoint: .bottom))
            .frame(width: size * 1.15, height: size)
            .overlay(Image(systemName: SFmt.groupIcon(group)).font(.system(size: size * 0.38)).foregroundColor(.white.opacity(0.92)))
    }
}

struct PillButton: View {
    let title: String
    var primary = true
    var enabled = true
    var accent: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: { if enabled { action() } }) {
            WTitle(text: title, size: 14.5, color: accent ?? (primary ? Theme.background : Theme.textPrimary))
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(Capsule().fill(accent == nil && primary ? Color.white : Color.clear))
                .overlay(Capsule().stroke(accent ?? (primary ? Color.clear : Color.white.opacity(0.35)), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
    }
}

struct DashedAdd: View {
    let title: String
    var green = true
    let action: () -> Void
    var body: some View {
        let accent = green ? strengthGreen : Color.white.opacity(0.4)
        return Button(action: action) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.13)).frame(width: 64, height: 50)
                    .overlay(Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundColor(.white))
                if green { WTitle(text: title, size: 15) } else { Text(title).font(Theme.text(15.5)).foregroundColor(Theme.textPrimary) }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(green ? strengthGreen.opacity(0.1) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent, style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])))
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
    }
}

struct UnderlineTabs: View {
    let labels: [String]
    @Binding var selected: Int
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<labels.count, id: \.self) { i in
                Button(action: { selected = i }) {
                    VStack(spacing: 10) {
                        WTitle(text: labels[i], size: 13, color: i == selected ? Theme.textPrimary : Theme.textSecondary)
                        Rectangle().fill(i == selected ? Color.white : Color.clear).frame(height: 2).padding(.horizontal, 10)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 10)
    }
}

struct Segmented: View {
    let labels: [String]
    @Binding var selected: Int
    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<labels.count, id: \.self) { i in
                Button(action: { selected = i }) {
                    WTitle(text: labels[i], size: 13, color: i == selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(i == selected ? Color(red: 0.17, green: 0.2, blue: 0.22) : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.1, green: 0.125, blue: 0.145)))
        .padding(.top, 20)
    }
}

/// Tarjeta de hito: "9/10 · 1 más hasta tu próximo hito".
struct MilestoneCard: View {
    let count: Int
    var body: some View {
        let (done, next) = Strength.milestone(count)
        return HStack(spacing: 16) {
            Circle().fill(Color(red: 0.12, green: 0.16, blue: 0.29)).frame(width: 64, height: 64)
                .overlay(Circle().stroke(Theme.wInsightBorder, style: StrokeStyle(lineWidth: 1.4, dash: [3, 3])))
                .overlay(Image(systemName: "dumbbell.fill").font(.system(size: 24)).foregroundColor(.white))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    WNumber(text: "\(done)", size: 22, color: Theme.wInsightBorder)
                    WNumber(text: "/\(next)", size: 22)
                }
                Text("\(next - done) más hasta tu próximo hito").font(Theme.text(14.5)).foregroundColor(Theme.textPrimary)
                WProgress(fraction: Double(done) / Double(next), color: Theme.wInsightBorder, height: 6)
            }
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}

/// Tabla de un ejercicio (REPS / PESO / FC PROM. y total), para el resumen.
struct ExerciseTable: View {
    let w: Strength.Workout
    let k: Int
    let hr: [String: Int]
    let rec: [[Bool]]
    var body: some View {
        let e = w.exercises[k]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                ExerciseThumb(group: Strength.exercise(e.exId)?.group, size: 50)
                Text(e.name).font(Theme.text(15.5)).foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(4).background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.15, green: 0.18, blue: 0.2)))
            VStack(alignment: .leading, spacing: 10) {
                row(AnyView(WTitle(text: "Reps.", size: 12.5, color: Theme.textSecondary)), AnyView(WTitle(text: "Peso", size: 12.5, color: Theme.textSecondary)),
                    AnyView(WTitle(text: "FC prom.", size: 12.5, color: Theme.textSecondary)), false)
                ForEach(0..<e.sets.count, id: \.self) { si in
                    let s = e.sets[si]
                    row(AnyView(WNumber(text: "\(s.reps)", size: 19)), AnyView(unit(SFmt.kg(s.kg), "kg")),
                        AnyView(unit(hr["\(k)-\(si)"].map { "\($0)" } ?? "--", "lpm")), rec.count > k && rec[k].count > si && rec[k][si])
                }
                Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1).padding(.top, 6)
                WTitle(text: "Total", size: 12.5, color: Theme.textSecondary).padding(.top, 4)
                HStack(alignment: .lastTextBaseline) {
                    WNumber(text: "\(e.reps)", size: 22).frame(width: 70, alignment: .leading)
                    WNumber(text: SFmt.kg(e.volume), size: 22, color: Theme.strainBlue)
                    Text("kg").font(Theme.text(14)).foregroundColor(Theme.textSecondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18)
        }
        .background(Theme.wCard).cornerRadius(14)
        .padding(.top, 12)
    }
    private func unit(_ v: String, _ u: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) { WNumber(text: v, size: 19); Text(u).font(Theme.text(14)).foregroundColor(Theme.textSecondary) }
    }
    private func row(_ a: AnyView, _ b: AnyView, _ c: AnyView, _ medal: Bool) -> some View {
        HStack {
            a.frame(maxWidth: .infinity, alignment: .leading)
            b.frame(maxWidth: .infinity, alignment: .leading)
            c.frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if medal { Image(systemName: "medal.fill").foregroundColor(Color(red: 0.88, green: 0.69, blue: 0.29)) } else { Color.clear }
            }
            .frame(width: 24, height: 20)
        }
    }
}

/// Grupos de superserie (ejercicios seguidos con el mismo número).
func strengthGroups(_ w: Strength.Workout) -> [[Int]] {
    var out = [[Int]]()
    var i = 0
    while i < w.exercises.count {
        let g = w.exercises[i].superset
        var j = i + 1
        if g != 0 { while j < w.exercises.count && w.exercises[j].superset == g { j += 1 } }
        out.append(Array(i..<j))
        i = j
    }
    return out
}

struct SupersetBox<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "repeat").foregroundColor(Theme.textSecondary)
                WTitle(text: "Superserie", size: 13.5, color: Theme.textSecondary)
            }
            .padding(.leading, 6)
            content
        }
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 8)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])))
        .padding(.top, 16)
    }
}

// MARK: - Resumen del ejercicio

struct StrengthSummaryView: View {
    let sessionId: Int64
    @Binding var path: [Route]
    @State private var data: (Strength.Workout, [String: Int], [[Bool]])? = nil

    var body: some View {
        WScreen {
            DetailHeader(title: "Resumen del ejercicio", trailing: AnyView(
                Button(action: { path.append(.strengthSession("log", sessionId)) }) {
                    Image(systemName: "pencil").font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                }))
            if let d = data {
                let (w, hr, rec) = d
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            WNumber(text: SFmt.kg(w.volume), size: 40, color: Theme.strainBlue)
                            WNumber(text: "kg", size: 18, color: Theme.strainBlue)
                        }
                        WTitle(text: "Volumen de carga", size: 13, color: Theme.textSecondary)
                    }
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        WNumber(text: "\(w.reps)", size: 40)
                        WTitle(text: "Reps.", size: 13, color: Theme.textSecondary)
                    }
                }
                .padding(.top, 18)
                ForEach(strengthGroups(w), id: \.self) { g in
                    if g.count > 1 {
                        SupersetBox { ForEach(g, id: \.self) { k in ExerciseTable(w: w, k: k, hr: hr, rec: rec) } }
                    } else {
                        ExerciseTable(w: w, k: g[0], hr: hr, rec: rec)
                    }
                }
                WBody(text: "FC prom. = pulso medio de la serie entre \"Comenzar\" y \"Finalizar serie\" (\"--\" si no se cronometró). Medalla = récord personal en ese ejercicio: más peso que nunca (o más repeticiones si es sin peso), como WHOOP.", size: 13).padding(.top, 18)
            } else {
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            let id = sessionId
            HomeStore.shared.run({ () -> (Strength.Workout, [String: Int], [[Bool]])? in
                guard let w = Strength.logFor(id) else { return nil }
                return (w, StrengthSave.setHeartRates(w), Strength.records(w))
            }, completion: { data = $0 })
        }
    }
}

// MARK: - Entrenador de fuerza (inicio)

struct StrengthHomeView: View {
    @Binding var path: [Route]
    @State private var tab = 1
    @State private var version = 0
    @State private var showInfo = false
    @State private var showGenerate = false
    @State private var genText = ""
    @State private var preview: Strength.Workout? = nil
    @State private var previewSaved = false
    @State private var menuFor: Strength.Workout? = nil
    @State private var progress: [Strength.Workout]? = nil

    var body: some View {
        WScreen {
            DetailHeader(title: "Entrenador de fuerza", trailing: AnyView(
                Button(action: { showInfo = true }) {
                    Image(systemName: "info.circle").font(.system(size: 20)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                }))
            UnderlineTabs(labels: ["Progreso", "Mis entrenamientos", "Entrenamientos"], selected: $tab)
            if let live = Strength.live(), version >= 0 {
                VStack(alignment: .leading, spacing: 8) {
                    WTitle(text: "Entrenamiento en curso", size: 15, color: strengthGreen)
                    WBody(text: "Empezó a las \(Fmt.clock(live.startMs)) · \(live.exercises.count) ejercicios", size: 14.5)
                    PillButton(title: "Continuar") { path.append(.strengthSession("live", 0)) }.padding(.top, 6)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.wCard).cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(strengthGreen, lineWidth: 1.2))
                .padding(.top, 18)
            }
            switch tab {
            case 0: progressTab
            case 1: mineTab
            default: presetsTab
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { version += 1; loadProgress() }
        .alert("Entrenador de fuerza", isPresented: $showInfo, actions: { Button("OK", role: .cancel) {} }, message: {
            Text("Registra tus ejercicios, series, repeticiones y peso. Si pulsas \"Comenzar serie\" y \"Finalizar serie\" se guarda el pulso de cada serie.\n\nEl esfuerzo de la actividad suma tu pulso (cardio) y la carga muscular de tus series: repeticiones × (peso + la parte de tu peso corporal que mueve el ejercicio). Sin series registradas se estima por minutos.\n\nCalibrado con tu entreno del 4/11 (WHOOP 8,1). Cuantos más entrenos registres, mejor se podrá ajustar.")
        })
        .sheet(isPresented: $showGenerate) { generateSheet }
        .sheet(item: Binding(get: { preview.map { WorkoutBox(w: $0) } }, set: { if $0 == nil { preview = nil } })) { box in previewSheet(box.w) }
        .confirmationDialog(menuFor?.name ?? "", isPresented: Binding(get: { menuFor != nil }, set: { if !$0 { menuFor = nil } })) {
            if let t = menuFor {
                Button("Empezar") { startLive(t) }
                Button("Editar") { StrengthSessionView.pending = t.copy(); path.append(.strengthSession("template", t.id)) }
                Button("Eliminar", role: .destructive) { Strength.deleteTemplate(t.id); version += 1 }
            }
        }
    }

    private func startLive(_ from: Strength.Workout?) {
        StrengthSessionView.prepareLive(from)
        path.append(.strengthSession("live", 0))
    }

    private var mineTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Iniciar un entrenamiento").font(Theme.text(21)).foregroundColor(Theme.textPrimary).padding(.top, 24)
            WBody(text: "Empieza directamente con un entrenamiento y registra los ejercicios mientras avanzas.", size: 15).padding(.top, 6).padding(.bottom, 18)
            PillButton(title: "Inicio rápido") { startLive(nil) }
            Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1).padding(.top, 26)
            Text("Mis entrenamientos").font(Theme.text(21)).foregroundColor(Theme.textPrimary).padding(.top, 24).padding(.bottom, 14)
            Button(action: { genText = ""; showGenerate = true }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Genera a partir de un texto").font(Theme.text(17)).foregroundColor(Theme.textPrimary)
                    Text("Escribe o pega tu entrenamiento (\"press banca 4x8 40 kg, dominadas 4x8…\") y PulseApp lo creará.")
                        .font(Theme.text(15)).foregroundColor(Theme.textPrimary.opacity(0.85)).multilineTextAlignment(.leading)
                    WTitle(text: "Empezar  →", size: 14, color: Theme.wInsightBorder).padding(.top, 4)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Color(red: 0.16, green: 0.15, blue: 0.31), Color(red: 0.11, green: 0.23, blue: 0.29)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.wInsightBorder, lineWidth: 1.4))
            }
            .buttonStyle(.plain)
            PillButton(title: "Crear un entrenamiento", primary: false) {
                StrengthSessionView.pending = nil; path.append(.strengthSession("template", 0))
            }
            .padding(.top, 16)
            Rectangle().fill(Color.white.opacity(0.13)).frame(height: 1).padding(.top, 22)
            let list = version >= 0 ? Strength.templates() : []
            if list.isEmpty {
                WBody(text: "Aún no tienes entrenamientos guardados. Al finalizar uno puedes añadirlo aquí.", size: 14.5).padding(.top, 16)
            }
            ForEach(0..<list.count, id: \.self) { i in
                let t = list[i]
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        WTitle(text: t.name.isEmpty ? SFmt.dateUpper(t.startMs) : t.name, size: 16)
                        WBody(text: "\(t.exercises.count) ejercicios · \(t.setCount) series", size: 13.5)
                    }
                    Spacer()
                    Button(action: { menuFor = t }) {
                        Image(systemName: "ellipsis").font(.system(size: 18, weight: .bold)).foregroundColor(Theme.textPrimary).frame(width: 40, height: 40)
                    }
                }
                .padding(.leading, 16).padding(.vertical, 8)
                .background(Theme.wCard).cornerRadius(14)
                .padding(.top, 12)
                .contentShape(Rectangle())
                .onTapGesture { previewSaved = true; preview = t }
            }
        }
    }

    private var presetsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            WBody(text: "Entrenamientos de ejemplo para empezar. Al terminarlos se guardan tus pesos y la próxima vez se rellenan solos.", size: 14.5)
                .padding(.top, 20).padding(.bottom, 4)
            let ps = Strength.presets()
            ForEach(0..<ps.count, id: \.self) { i in
                let p = ps[i]
                HStack(spacing: 14) {
                    ExerciseThumb(group: Strength.exercise(p.exercises.first?.exId ?? "")?.group, size: 50)
                    VStack(alignment: .leading, spacing: 4) {
                        WTitle(text: p.name, size: 16)
                        WBody(text: p.exercises.map { $0.name.components(separatedBy: " - ").first ?? $0.name }.joined(separator: " · "), size: 13).lineLimit(2)
                    }
                    Spacer()
                }
                .padding(10).background(Theme.wCard).cornerRadius(14).padding(.top, 12)
                .contentShape(Rectangle())
                .onTapGesture { previewSaved = false; preview = p }
            }
        }
    }

    private var progressTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let logs = progress {
                MilestoneCard(count: logs.count).padding(.top, 20)
                if logs.isEmpty {
                    WBody(text: "Cuando registres entrenamientos aquí verás tu volumen por semana y tus mejores marcas.", size: 14.5).padding(.top, 18)
                } else {
                    WTitle(text: "Volumen de carga por semana", size: 15).padding(.top, 28).padding(.bottom, 12)
                    weekBars(logs)
                    WBody(text: "Toneladas (kg × repeticiones) por semana, de lunes a domingo.", size: 13).padding(.top, 8)
                    WTitle(text: "Tus ejercicios", size: 15).padding(.top, 28).padding(.bottom, 4)
                    exerciseList(logs)
                    WBody(text: "A la derecha, tu mejor serie: la de más peso (o más repeticiones si es sin peso).", size: 13).padding(.top, 10)
                }
            } else {
                ScreenLoading()
            }
        }
    }

    private func weekBars(_ logs: [Strength.Workout]) -> some View {
        let today = Day.today()
        let wd = Day.weekdayIndex(today)
        let monday = Day.add(today, -wd)
        let weeks = (0...7).reversed().map { Day.add(monday, -7 * $0) }
        let vols = weeks.map { wk -> Double in
            let a = Day.start(wk), b = Day.start(Day.add(wk, 7))
            return logs.filter { $0.startMs >= a && $0.startMs < b }.reduce(0) { $0 + $1.volume }
        }
        let maxV = max(vols.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(0..<weeks.count, id: \.self) { i in
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    if vols[i] > 0 { WNumber(text: Fmt.comma(vols[i] / 1000, 1), size: 11, color: Theme.textSecondary) }
                    RoundedRectangle(cornerRadius: 3).fill(Theme.strainBlue.opacity(i == weeks.count - 1 ? 1 : 0.7))
                        .frame(width: 18, height: max(2, 100 * vols[i] / maxV))
                    WNumber(text: "\(Day.dayOfMonth(weeks[i]))/\(Day.month(weeks[i]))", size: 11, color: Theme.textSecondary).padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 150)
    }

    private func exerciseList(_ logs: [Strength.Workout]) -> some View {
        var byEx = [String: [(Strength.ExerciseEntry, Strength.Workout)]]()
        for w in logs { for e in w.exercises { byEx[e.exId, default: []].append((e, w)) } }
        let keys = byEx.keys.sorted { (byEx[$0]!.map { $0.1.startMs }.max() ?? 0) > (byEx[$1]!.map { $0.1.startMs }.max() ?? 0) }
        return VStack(spacing: 8) {
            ForEach(keys, id: \.self) { k in
                let entries = byEx[k]!
                let best = entries.flatMap { $0.0.sets }.max { Strength.setScore($0) < Strength.setScore($1) }
                let last = entries.max { $0.1.startMs < $1.1.startMs }!
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Strength.exercise(k)?.name ?? entries[0].0.name).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                        Text("\(entries.count) \(entries.count == 1 ? "vez" : "veces") · última \(SFmt.dateUpper(last.1.startMs).lowercased())")
                            .font(Theme.text(12.5)).foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    if let b = best { WNumber(text: "\(b.reps) × \(SFmt.kg(b.kg)) kg", size: 16, color: Theme.textSecondary) }
                }
                .padding(14).background(Theme.wCard).cornerRadius(12)
            }
        }
    }

    private func loadProgress() {
        HomeStore.shared.run({ () -> [Strength.Workout] in
            let ids = Set(AppStore.shared.allSessions().map { $0.id })
            return Strength.logs().filter { $0.id > 0 && $0.setCount > 0 && ids.contains($0.id) }
        }, completion: { progress = $0 })
    }

    private var generateSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Escribe tu entrenamiento, un ejercicio por línea con series × repeticiones y el peso. Una línea que empieza por + va en superserie con la anterior.")
                    .font(Theme.text(14)).foregroundColor(.secondary)
                TextEditor(text: $genText).frame(minHeight: 220).padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                Text("Ej.: press de banca mancuerna 4x8 40 kg\ndominadas 4x8\nremo con polea 3x10 35 kg\n+ remo inclinado 3x10 35 kg").font(Theme.text(13)).foregroundColor(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("Describe tu entrenamiento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { showGenerate = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crear") {
                        let w = Strength.parse(genText)
                        showGenerate = false
                        if !w.exercises.isEmpty {
                            w.name = "Generado " + SFmt.dateUpper(TimeUtil.nowMillis())
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { previewSaved = false; preview = w }
                        }
                    }
                }
            }
        }
    }

    private func previewSheet(_ t: Strength.Workout) -> some View {
        NavigationStack {
            List {
                ForEach(0..<t.exercises.count, id: \.self) { i in
                    let e = t.exercises[i]
                    let s = e.sets.first
                    VStack(alignment: .leading, spacing: 2) {
                        Text((e.superset != 0 ? "⟳ " : "") + e.name)
                        Text("\(e.sets.count) × \(s?.reps ?? 0)" + ((s?.kg ?? 0) > 0 ? " · \(SFmt.kg(s!.kg)) kg" : "")).font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(t.name.isEmpty ? "Entrenamiento" : t.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { preview = nil } }
                ToolbarItem(placement: .confirmationAction) { Button("Empezar") { preview = nil; startLive(t) } }
                if !previewSaved {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Editar y guardar en Mis entrenamientos") {
                            let c = t.copy(); c.id = TimeUtil.nowMillis()
                            StrengthSessionView.pending = c
                            preview = nil
                            path.append(.strengthSession("template", 0))
                        }
                    }
                }
            }
        }
    }
}

struct WorkoutBox: Identifiable { let w: Strength.Workout; var id: ObjectIdentifier { ObjectIdentifier(w) } }

// MARK: - Sesión (en vivo / plantilla / series de una actividad)

struct StrengthSessionView: View {
    let mode: String          // "live" · "template" · "log"
    let refId: Int64          // id de plantilla o de actividad
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    static var pending: Strength.Workout? = nil

    @State private var w: Strength.Workout? = nil
    @State private var tab = 1
    @State private var version = 0
    @State private var now = TimeUtil.nowMillis()
    @State private var showPicker = false
    @State private var showMenu = false
    @State private var confirmFinish = false
    @State private var confirmDiscard = false
    @State private var exerciseMenu: Int? = nil
    @State private var setHr: [String: Int] = [:]
    @State private var message: String? = nil
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    static func prepareLive(_ from: Strength.Workout?) {
        if Strength.live() != nil { return }
        let w = Strength.Workout(0, TimeUtil.nowMillis(), 0, from?.name ?? "")
        for e in from?.exercises ?? [] { w.exercises.append(Strength.ExerciseEntry(e.exId, e.name, e.superset, e.sets.map { Strength.SetEntry($0.reps, $0.kg) })) }
        Strength.saveLive(w)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            WScreen {
                header
                if mode == "live" { UnderlineTabs(labels: ["Sesión en vivo", "Ejercicios"], selected: $tab) }
                if let w = w, version >= 0 {
                    if mode == "live" && tab == 0 { liveTab(w) } else { exercisesTab(w) }
                }
                Color.clear.frame(height: 90)
            }
            bottomBar.padding(.horizontal, 16).padding(.bottom, 18)
                .background(LinearGradient(colors: [Theme.wBgBottom.opacity(0), Theme.wBgBottom], startPoint: .top, endPoint: .center))
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: load)
        .onDisappear { persist() }
        .onReceive(timer) { _ in if mode == "live" { now = TimeUtil.nowMillis() } }
        .sheet(isPresented: $showPicker) {
            ExercisePickerView { ids, superset in addExercises(ids, superset) }
        }
        .confirmationDialog("Entrenamiento", isPresented: $showMenu) {
            Button("Finalizar entrenamiento") { prepareFinish() }
            Button("Guardar como entrenamiento") { if let w = w { saveAsTemplate(w); message = "Guardado en Mis entrenamientos" } }
            Button("Descartar entrenamiento", role: .destructive) { confirmDiscard = true }
            Button("Minimizar (sigue en curso)") { persist(); dismiss() }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog(exerciseMenu.flatMap { i in w.flatMap { i < $0.exercises.count ? $0.exercises[i].name : nil } } ?? "",
                            isPresented: Binding(get: { exerciseMenu != nil }, set: { if !$0 { exerciseMenu = nil } })) {
            if let k = exerciseMenu, let w = w, k < w.exercises.count { exerciseActions(w, k) }
        }
        .alert("¿Descartar el entrenamiento?", isPresented: $confirmDiscard, actions: {
            Button("Descartar", role: .destructive) { Strength.saveLive(nil); dismiss() }
            Button("Cancelar", role: .cancel) {}
        }, message: { Text("No se guardará la actividad ni las series. El pulso guardado no se toca.") })
        .alert("Finalizar entrenamiento", isPresented: $confirmFinish, actions: {
            Button("Guardar") { finish(addTemplate: false) }
            Button("Guardar y añadir a Mis entrenamientos") { finish(addTemplate: true) }
            Button("Seguir", role: .cancel) {}
        }, message: {
            if let w = w { Text("\(w.exercises.count) ejercicios, \(w.setCount) series, \(SFmt.kg(w.volume)) kg en \((TimeUtil.nowMillis() - w.startMs) / 60_000) min.\n\nSe guardará como actividad \"Entrenamiento de fuerza\" con el pulso de este rato.") }
        })
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK", role: .cancel) {} }
    }

    private var header: some View {
        HStack {
            Button(action: { if mode == "live" { showMenu = true } else { dismiss() } }) {
                Image(systemName: mode == "live" ? "ellipsis" : "chevron.left").font(.system(size: 20, weight: .bold))
                    .foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 3) {
                WTitle(text: title, size: 15.5)
                if mode == "live", let w = w { WNumber(text: SFmt.hms(max(0, now - w.startMs) / 1000), size: 14, color: Theme.textSecondary) }
            }
            Spacer()
            Button(action: { showPicker = true }) {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
            }
        }
        .padding(.top, 4)
    }

    private var title: String {
        switch mode {
        case "live": return SFmt.dateUpper(w?.startMs ?? TimeUtil.nowMillis())
        case "template": return (w?.name.isEmpty ?? true) ? "Nuevo entrenamiento" : w!.name
        default: return "Ejercicios de la actividad"
        }
    }

    private func load() {
        if w != nil { return }
        switch mode {
        case "live":
            w = Strength.live()
            if w == nil { dismiss(); return }
            if !(w!.exercises.isEmpty) { tab = 0 }
        case "template":
            if let p = StrengthSessionView.pending { w = p.copy(); StrengthSessionView.pending = nil; if w!.id <= 0 { w!.id = TimeUtil.nowMillis() } }
            else if let t = Strength.templates().first(where: { $0.id == refId }) { w = t.copy() }
            else { w = Strength.Workout(TimeUtil.nowMillis(), TimeUtil.nowMillis(), 0, "") }
        default:
            guard let s = AppStore.shared.session(id: refId) else { dismiss(); return }
            let lw = Strength.logFor(refId)?.copy() ?? Strength.Workout(refId, 0, 0, "")
            lw.startMs = s.startMillis; lw.endMs = s.endMillis
            w = lw
            refreshHr()
        }
    }

    private func persist() { if mode == "live", let w = w { Strength.saveLive(w) } }
    private func bump() { version += 1; persist() }

    private func refreshHr() {
        guard let w = w else { return }
        HomeStore.shared.run({ StrengthSave.setHeartRates(w) }, completion: { setHr = $0 })
    }

    // Orden de las series: en superserie se alternan (A1, B1, A2, B2…)
    private func order(_ w: Strength.Workout) -> [(Int, Int)] {
        var out = [(Int, Int)]()
        for g in strengthGroups(w) {
            if g.count == 1 { for s in 0..<w.exercises[g[0]].sets.count { out.append((g[0], s)) } }
            else {
                let maxSets = g.map { w.exercises[$0].sets.count }.max() ?? 0
                for s in 0..<maxSets { for k in g where s < w.exercises[k].sets.count { out.append((k, s)) } }
            }
        }
        return out
    }
    private func current(_ w: Strength.Workout) -> (Int, Int)? { return order(w).first { let s = w.exercises[$0.0].sets[$0.1]; return s.startMs != nil && s.endMs == nil } }
    private func next(_ w: Strength.Workout) -> (Int, Int)? { return order(w).first { let s = w.exercises[$0.0].sets[$0.1]; return !s.done && s.startMs == nil } }

    @ViewBuilder private func liveTab(_ w: Strength.Workout) -> some View {
        if w.exercises.isEmpty {
            DashedAdd(title: "Agregar ejercicio") { showPicker = true }
        } else {
            let cur = current(w)
            let nx = cur ?? next(w)
            let mgr = WhoopManager.shared
            let bpm = (mgr.lastBpm != nil && now - mgr.lastBpmTime < 15_000) ? mgr.lastBpm : nil
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                WNumber(text: bpm.map { "\($0)" } ?? "--", size: 64, color: Theme.strainBlue)
                WNumber(text: "lpm", size: 22, color: Theme.strainBlue)
            }
            .padding(.top, 22)
            let done = w.exercises.reduce(0) { $0 + $1.sets.filter { $0.done }.count }
            WTitle(text: "\(done) de \(w.setCount) series hechas", size: 13.5, color: Theme.textSecondary).padding(.top, 6)
            if let nx = nx {
                let e = w.exercises[nx.0], s = e.sets[nx.1]
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        ExerciseThumb(group: Strength.exercise(e.exId)?.group, size: 46)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(e.name).font(Theme.text(16.5)).foregroundColor(Theme.textPrimary)
                            WTitle(text: (cur != nil ? "Serie en curso · " : "Siguiente · ") + "serie \(nx.1 + 1) de \(e.sets.count)", size: 12.5,
                                   color: cur != nil ? strengthGreen : Theme.textSecondary)
                        }
                    }
                    HStack {
                        stat("\(s.reps)", "Reps.")
                        stat(SFmt.kg(s.kg) + " kg", "Peso")
                        stat(cur != nil ? SFmt.ms(max(0, now - (s.startMs ?? now)) / 1000) : restText(w), cur != nil ? "Tiempo de serie" : "Descanso")
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.wCard).cornerRadius(14).padding(.top, 22)
                let rest = order(w).filter { !w.exercises[$0.0].sets[$0.1].done && !($0.0 == nx.0 && $0.1 == nx.1) }.prefix(4)
                if !rest.isEmpty {
                    WTitle(text: "Después", size: 13.5, color: Theme.textSecondary).padding(.top, 24)
                    ForEach(Array(rest.enumerated()), id: \.offset) { _, p in
                        let ee = w.exercises[p.0], ss = ee.sets[p.1]
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ee.name).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                                Text("Serie \(p.1 + 1) de \(ee.sets.count)").font(Theme.text(12.5)).foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            WNumber(text: "\(ss.reps) × \(SFmt.kg(ss.kg)) kg", size: 16, color: Theme.textSecondary)
                        }
                        .padding(14).background(Theme.wCard).cornerRadius(12).padding(.top, 8)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    WTitle(text: "Todas las series hechas", size: 16)
                    WBody(text: "Pulsa \"Finalizar entrenamiento\" para guardar la actividad, o agrega otro ejercicio con +.", size: 14.5)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.wCard).cornerRadius(14).padding(.top, 22)
            }
            WBody(text: "Cambia repeticiones y peso en la pestaña Ejercicios (también después de cada serie).", size: 13.5).padding(.top, 18)
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { WNumber(text: v, size: 34); WTitle(text: l, size: 12, color: Theme.textSecondary) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func restText(_ w: Strength.Workout) -> String {
        guard let lastEnd = w.exercises.flatMap({ $0.sets }).compactMap({ $0.endMs }).max() else { return "--" }
        return SFmt.ms(max(0, now - lastEnd) / 1000)
    }

    @ViewBuilder private func exercisesTab(_ w: Strength.Workout) -> some View {
        if mode == "template" {
            TextField("Nombre del entrenamiento", text: Binding(get: { w.name }, set: { w.name = $0 }))
                .font(Theme.text(16)).foregroundColor(Theme.textPrimary)
                .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.12, green: 0.15, blue: 0.17)))
                .padding(.top, 10)
        }
        if mode == "log" {
            WBody(text: "Apunta las series que hiciste. Sin cronometrar cada serie no se puede sacar su pulso (sale \"--\"), pero la carga muscular sí cuenta para el esfuerzo.", size: 14).padding(.top, 8)
        }
        ForEach(strengthGroups(w), id: \.self) { g in
            if g.count > 1 {
                SupersetBox { ForEach(g, id: \.self) { k in exerciseCard(w, k) } }
            } else {
                exerciseCard(w, g[0])
            }
        }
        DashedAdd(title: "Agregar ejercicio") { showPicker = true }
    }

    private func exerciseCard(_ w: Strength.Workout, _ k: Int) -> some View {
        let e = w.exercises[k]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ExerciseThumb(group: Strength.exercise(e.exId)?.group, size: 46)
                Text(e.name).font(Theme.text(16)).foregroundColor(Theme.textPrimary)
                Spacer()
                Button(action: { exerciseMenu = k }) {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .bold)).foregroundColor(Theme.textPrimary).frame(width: 36, height: 36)
                }
            }
            HStack {
                WTitle(text: "Serie", size: 12, color: Theme.textSecondary).frame(width: 46, alignment: .leading)
                WTitle(text: "Reps.", size: 12, color: Theme.textSecondary).frame(maxWidth: .infinity)
                WTitle(text: "Peso (kg)", size: 12, color: Theme.textSecondary).frame(maxWidth: .infinity)
                WTitle(text: "FC prom.", size: 12, color: Theme.textSecondary).frame(width: 74, alignment: .trailing)
                Color.clear.frame(width: 26, height: 1)
            }
            ForEach(0..<e.sets.count, id: \.self) { si in setRow(w, k, si) }
            Button(action: {
                let last = e.sets.last
                e.sets.append(Strength.SetEntry(last?.reps ?? 10, last?.kg ?? 0)); bump()
            }) { WTitle(text: "+ Agregar serie", size: 13.5, color: strengthGreen).padding(.top, 6) }
            .buttonStyle(.plain)
        }
        .padding(12).background(Theme.wCard).cornerRadius(14).padding(.top, 12)
    }

    private func setRow(_ w: Strength.Workout, _ k: Int, _ si: Int) -> some View {
        let e = w.exercises[k]
        let s = e.sets[si]
        let active = s.startMs != nil && s.endMs == nil
        let right: String = active ? "en curso" : (setHr["\(k)-\(si)"].map { "\($0) lpm" } ?? (s.done ? "-- lpm" : ""))
        return HStack {
            WNumber(text: "\(si + 1)", size: 18, color: active ? strengthGreen : Theme.textPrimary).frame(width: 46, alignment: .leading)
            numField(Binding(get: { "\(s.reps)" }, set: { s.reps = Int($0) ?? 0; persist() }), decimal: false)
            numField(Binding(get: { SFmt.kg(s.kg) }, set: { s.kg = Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0; persist() }), decimal: true)
            WNumber(text: right, size: 15, color: active ? strengthGreen : Theme.textSecondary).frame(width: 74, alignment: .trailing)
            Button(action: {
                if e.sets.count <= 1 { w.exercises.remove(at: k); fixSupersets(w) } else { e.sets.remove(at: si) }
                bump()
            }) { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.textSecondary).frame(width: 26, height: 30) }
            .buttonStyle(.plain)
        }
    }

    private func numField(_ b: Binding<String>, decimal: Bool) -> some View {
        TextField("", text: b)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .font(Theme.number(18)).foregroundColor(Theme.textPrimary)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.13)))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
    }

    @ViewBuilder private func exerciseActions(_ w: Strength.Workout, _ k: Int) -> some View {
        if k > 0 { Button("Subir") { w.exercises.swapAt(k, k - 1); fixSupersets(w); bump() } }
        if k < w.exercises.count - 1 { Button("Bajar") { w.exercises.swapAt(k, k + 1); fixSupersets(w); bump() } }
        if w.exercises[k].superset == 0 && k < w.exercises.count - 1 {
            Button("Superserie con el siguiente") {
                let n = w.exercises[k + 1]
                let g = n.superset != 0 ? n.superset : (w.exercises.map { $0.superset }.max() ?? 0) + 1
                w.exercises[k].superset = g; n.superset = g; bump()
            }
        }
        if w.exercises[k].superset != 0 { Button("Sacar de la superserie") { w.exercises[k].superset = 0; fixSupersets(w); bump() } }
        Button("Eliminar ejercicio", role: .destructive) { w.exercises.remove(at: k); fixSupersets(w); bump() }
        Button("Cancelar", role: .cancel) {}
    }

    private func fixSupersets(_ w: Strength.Workout) {
        for g in strengthGroups(w) where g.count == 1 { w.exercises[g[0]].superset = 0 }
    }

    private var bottomBar: some View {
        Group {
            if let w = w, version >= 0 {
                if mode == "live" {
                    if w.exercises.isEmpty {
                        PillButton(title: "Comenzar la primera serie", primary: false, enabled: false) {}
                    } else if let c = current(w) {
                        PillButton(title: "Finalizar serie", accent: strengthGreen) {
                            let s = w.exercises[c.0].sets[c.1]; s.endMs = TimeUtil.nowMillis(); s.done = true
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(); bump(); refreshHr()
                        }
                    } else if let n = next(w) {
                        PillButton(title: w.exercises.allSatisfy({ $0.sets.allSatisfy { !$0.done } }) ? "Comenzar la primera serie" : "Comenzar serie") {
                            let s = w.exercises[n.0].sets[n.1]; s.startMs = TimeUtil.nowMillis(); s.endMs = nil; s.done = false
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(); bump()
                        }
                    } else {
                        PillButton(title: "Finalizar entrenamiento") { prepareFinish() }
                    }
                } else if mode == "template" {
                    PillButton(title: "Guardar entrenamiento", enabled: !w.exercises.isEmpty) {
                        if w.name.isEmpty { w.name = SFmt.dateUpper(TimeUtil.nowMillis()) }
                        w.startMs = TimeUtil.nowMillis()
                        Strength.saveTemplate(w); dismiss()
                    }
                } else {
                    PillButton(title: "Guardar") { saveLog(w) }
                }
            }
        }
    }

    private func prepareFinish() {
        guard let w = w else { return }
        if let c = current(w) { let s = w.exercises[c.0].sets[c.1]; s.endMs = TimeUtil.nowMillis(); s.done = true }
        for e in w.exercises { e.sets.removeAll { !$0.done } }
        w.exercises.removeAll { $0.sets.isEmpty }
        bump()
        confirmFinish = true
    }

    private func finish(addTemplate: Bool) {
        guard let w = w else { return }
        if addTemplate { saveAsTemplate(w) }
        HomeStore.shared.run({ StrengthSave.finishLive(w, endMs: TimeUtil.nowMillis()) }, completion: { id in
            guard let id = id else { message = "No hay pulso de este rato: ¿está conectada la pulsera?"; return }
            Strength.saveLive(nil)
            HomeStore.shared.invalidate(); AppModel.shared.refresh()
            if !path.isEmpty { path.removeLast() }
            path.append(.activity(id))
        })
    }

    private func saveAsTemplate(_ src: Strength.Workout) {
        let t = Strength.Workout(TimeUtil.nowMillis(), TimeUtil.nowMillis(), 0, src.name.isEmpty ? SFmt.dateUpper(src.startMs > 0 ? src.startMs : TimeUtil.nowMillis()) : src.name)
        for e in src.exercises { t.exercises.append(Strength.ExerciseEntry(e.exId, e.name, e.superset, e.sets.map { Strength.SetEntry($0.reps, $0.kg) })) }
        Strength.saveTemplate(t)
    }

    private func saveLog(_ w: Strength.Workout) {
        for e in w.exercises { for s in e.sets { s.done = true } }
        w.exercises.removeAll { $0.sets.isEmpty }
        w.id = refId
        Strength.saveLog(w)
        let id = refId
        let hasEx = !w.exercises.isEmpty
        HomeStore.shared.run({ () -> Bool in
            let s = AppStore.shared.session(id: id)
            let newType = (s != nil && hasEx && (s!.type == Formulas.unclassified || s!.type.isEmpty)) ? StrengthSave.type : nil
            StrengthSave.resummarize(id, newType: newType)
            return true
        }, completion: { _ in
            HomeStore.shared.invalidate(); AppModel.shared.refresh()
            dismiss()
        })
    }

    private func addExercises(_ ids: [String], _ superset: Bool) {
        if mode == "live", let fresh = Strength.live() { w = fresh }
        guard let w = w else { return }
        let g = superset && ids.count > 1 ? (w.exercises.map { $0.superset }.max() ?? 0) + 1 : 0
        for id in ids {
            guard let ex = Strength.exercise(id) else { continue }
            let sets = Strength.lastSetsOf(id).flatMap { $0.isEmpty ? nil : $0 } ?? (0..<3).map { _ in Strength.SetEntry(ex.group == "Core" ? 12 : 10, 0) }
            w.exercises.append(Strength.ExerciseEntry(ex.id, ex.name, g, sets))
        }
        if mode == "live" { tab = 1 }
        bump()
    }
}

// MARK: - Seleccionar ejercicios

struct ExercisePickerView: View {
    let onDone: ([String], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var group: String? = nil
    @State private var selected: [String] = []
    @State private var info: Strength.Exercise? = nil
    @State private var showCustom = false
    @State private var customName = ""
    @State private var customGroup = Strength.groups[0]
    @State private var customEq = Strength.equipment[0]
    @State private var version = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.wBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: { dismiss() }) { Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44) }
                    Spacer()
                    WTitle(text: "Seleccionar ejercicios", size: 15)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                HStack(spacing: 10) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(Theme.textSecondary)
                        TextField("Buscar un ejercicio…", text: $query).foregroundColor(Theme.textPrimary)
                    }
                    .padding(14).background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.12, green: 0.15, blue: 0.17)))
                    Menu {
                        Button("Todos") { group = nil }
                        ForEach(Strength.groups, id: \.self) { g in Button(g) { group = g } }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease").foregroundColor(.white).frame(width: 52, height: 50)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.12, green: 0.15, blue: 0.17)))
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        DashedAdd(title: "Agregar ejercicio personalizado", green: false) { customName = query; showCustom = true }
                        if let g = group {
                            Button(action: { group = nil }) { WTitle(text: "Filtro: \(g)  ✕", size: 13, color: strengthGreen) }.padding(.top, 14)
                        }
                        list
                        Color.clear.frame(height: 110)
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack(spacing: 10) {
                PillButton(title: "Súper conjunto", primary: false, enabled: selected.count >= 2) { onDone(selected, true); dismiss() }
                PillButton(title: selected.isEmpty ? "Añadir" : "Añadir (\(selected.count))", enabled: !selected.isEmpty) { onDone(selected, false); dismiss() }
            }
            .padding(.horizontal, 16).padding(.bottom, 18)
            .background(LinearGradient(colors: [Theme.wBgBottom.opacity(0), Theme.wBgBottom], startPoint: .top, endPoint: .center))
        }
        .alert(info?.name ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } }), actions: { Button("OK", role: .cancel) {} },
               message: { Text(info.map { infoText($0) } ?? "") })
        .sheet(isPresented: $showCustom) { customSheet }
    }

    private var list: some View {
        let words = Strength.norm(query.trimmingCharacters(in: .whitespaces)).split(separator: " ").map(String.init)
        let items = (version >= 0 ? Strength.library() : []).filter { e in
            (group == nil || e.group == group) && words.allSatisfy { Strength.norm(e.name).contains($0) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<items.count, id: \.self) { i in
                let e = items[i]
                let letter = String(Strength.norm(e.name).prefix(1)).uppercased()
                if i == 0 || String(Strength.norm(items[i - 1].name).prefix(1)).uppercased() != letter {
                    WTitle(text: letter, size: 14, color: Theme.textSecondary).padding(.top, 14).padding(.leading, 4)
                }
                row(e)
            }
            if items.isEmpty {
                WBody(text: "Ningún ejercicio con ese nombre. Puedes crearlo con \"Agregar ejercicio personalizado\".", size: 14.5).padding(.top, 18)
            }
        }
    }

    private func row(_ e: Strength.Exercise) -> some View {
        let on = selected.contains(e.id)
        return HStack(spacing: 14) {
            ExerciseThumb(group: e.group, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(Theme.text(15.5)).foregroundColor(Theme.textPrimary)
                Text("\(e.group) · \(e.equipment)").font(Theme.text(12.5)).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            if on { Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundColor(strengthGreen) }
            Button(action: { info = e }) { Image(systemName: "info.circle").foregroundColor(Theme.textSecondary).frame(width: 36, height: 36) }
                .buttonStyle(.plain)
        }
        .padding(4)
        .background(Theme.wCard).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? strengthGreen : Color.clear, lineWidth: 1.2))
        .contentShape(Rectangle())
        .onTapGesture { if let i = selected.firstIndex(of: e.id) { selected.remove(at: i) } else { selected.append(e.id) } }
    }

    private func infoText(_ e: Strength.Exercise) -> String {
        var s = "\(e.group) · \(e.equipment)"
        if e.bodyweight > 0 { s += "\nCuenta el \(Int((e.bodyweight * 100).rounded())) % de tu peso corporal." }
        let hist = Strength.logs().flatMap { w in w.exercises.filter { $0.exId == e.id }.map { (w, $0) } }
        if hist.isEmpty { return s + "\n\nAún no lo has registrado." }
        if let best = hist.flatMap({ $0.1.sets }).max(by: { Strength.setScore($0) < Strength.setScore($1) }),
           let last = hist.max(by: { $0.0.startMs < $1.0.startMs }) {
            s += "\n\nVeces registrado: \(hist.count)\nMejor serie: \(best.reps) × \(SFmt.kg(best.kg)) kg"
            s += "\nÚltima vez: \(SFmt.dateUpper(last.0.startMs).lowercased()) — " + last.1.sets.map { "\($0.reps)×\(SFmt.kg($0.kg))" }.joined(separator: ", ")
        }
        return s
    }

    private var customSheet: some View {
        NavigationStack {
            Form {
                TextField("Nombre del ejercicio", text: $customName)
                Picker("Grupo", selection: $customGroup) { ForEach(Strength.groups, id: \.self) { Text($0) } }
                Picker("Material", selection: $customEq) { ForEach(Strength.equipment, id: \.self) { Text($0) } }
            }
            .navigationTitle("Ejercicio personalizado")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { showCustom = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crear") {
                        let n = customName.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty {
                            let ex = Strength.addCustomExercise(n, group: customGroup, equipment: customEq, bodyweight: customEq == "Peso corporal" ? 0.6 : 0)
                            selected.append(ex.id); version += 1
                        }
                        showCustom = false
                    }
                }
            }
        }
    }
}
