import Foundation
import SwiftUI

// MARK: - Salud

struct HealthView: View {
    @StateObject private var model = AppModel.shared

    var body: some View {
        let s = model.snap.summary
        let days = Array(model.snap.days.prefix(7).reversed())
        return NavigationStack {
            Screen("Salud") {
                Text("Salud").font(Theme.number(34)).foregroundColor(Theme.textPrimary)
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ListRow(title: "VFC (noche)", value: s.avgHrv.map { "\(Fmt.int($0)) ms" } ?? "–")
                        Hairline()
                        ListRow(title: "FC en reposo", value: s.restingHr.map { "\($0) lpm" } ?? "–")
                        Hairline()
                        ListRow(title: "Frecuencia respiratoria", value: s.respiratoryRate.map { "\(Fmt.comma($0)) rpm" } ?? "–")
                        Hairline()
                        ListRow(title: "VO₂ máx", value: model.snap.vo2Max.map { Fmt.comma($0) } ?? "–")
                        Hairline()
                        ListRow(title: "FC media del día", value: s.avgHr.map { "\($0) lpm" } ?? "–")
                    }
                }
                trendCard("VFC · últimos días", days, maxV: 150, color: Theme.recoveryGreen) { $0.avgHrv }
                trendCard("FC en reposo · últimos días", days, maxV: 90, color: Theme.alertRed) { $0.restingHr.map { Double($0) } }
                if let b = model.snap.baseline {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            CapsLabel(text: "Tu referencia personal")
                            Text("VFC \(Fmt.int(b.avgHrv)) ms · FC reposo \(Fmt.int(b.avgRestingHr)) lpm (\(b.daysUsed) días)")
                                .font(Theme.text(14)).foregroundColor(Theme.textPrimary)
                        }
                    }
                }
                NavigationLink(destination: StressView()) {
                    Card {
                        HStack {
                            Text("Estrés").font(Theme.text(16, .semibold)).foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text(model.snap.stress.level.capitalized).font(Theme.label(16))
                                .foregroundColor(Theme.stressColor(model.snap.stress.level))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Salud")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func trendCard(_ title: String, _ days: [DailyMetrics], maxV: Double, color: Color,
                           _ pick: (DailyMetrics) -> Double?) -> some View {
        var items = [WeekBars.Item]()
        for d in days { items.append(WeekBars.Item(label: Fmt.weekdayLetter(d.date), value: pick(d), color: color)) }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: title)
                if items.isEmpty {
                    EmptyNote(text: "Aún no hay días guardados.")
                } else {
                    WeekBars(items: items, maxValue: maxV, format: { Fmt.int($0) })
                }
            }
        }
    }
}

// MARK: - Sueño

struct SleepView: View {
    @StateObject private var model = AppModel.shared

    var body: some View {
        let s = model.snap.summary
        let days = Array(model.snap.days.prefix(7).reversed())
        return NavigationStack {
            Screen("Sueño") {
                Text(Fmt.nightTitle(TimeUtil.nowMillis())).font(Theme.number(28)).foregroundColor(Theme.textPrimary)
                Card {
                    HStack(spacing: 16) {
                        RingView(progress: Double(model.snap.sleepScore ?? 0) / 100.0,
                                 value: model.snap.sleepScore.map { "\($0)" } ?? "–", label: "Puntuación",
                                 color: Theme.sleepBlue, size: 120)
                        VStack(alignment: .leading, spacing: 8) {
                            kv("Dormido", s.sleepMinutes.map { Fmt.hm($0) } ?? "–")
                            kv("En cama", s.timeInBedMinutes.map { Fmt.hm($0) } ?? "–")
                            kv("Eficiencia", s.sleepEfficiencyPct.map { "\($0)%" } ?? "–")
                            kv("Necesidad", Fmt.hm(model.snap.lastNightNeed))
                        }
                        Spacer(minLength: 0)
                    }
                }
                hypnogramCard(s)
                if let st = s.stages { stagesCard(st) }
                timesCard(s)
                planCard
                weekCard(days)
            }
            .navigationTitle("Sueño")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            CapsLabel(text: k, size: 10)
            Text(v).font(Theme.number(22)).foregroundColor(Theme.textPrimary)
        }
    }

    private func hypnogramCard(_ s: DailySummary) -> some View {
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: "Hipnograma")
                if let st = s.stages, st.minutes > 0 {
                    HypnogramView(startMillis: st.startMillis, stages: st.stages)
                } else if s.sleepMinutes != nil {
                    EmptyNote(text: "Para ver las fases activa «Movimiento y pasos» en la pantalla de la pulsera: sin movimiento no se inventan fases.")
                } else {
                    EmptyNote(text: "Aún no hay una noche detectada. Sincroniza la pulsera por la mañana.")
                }
            }
        }
    }

    private func stagesCard(_ st: SleepStager.Result) -> some View {
        let total = max(Double(st.minutes), 1)
        let rows: [(String, Int, Color)] = [
            ("Despierto", st.awakeMinutes, Theme.stageAwake),
            ("REM", st.remMinutes, Theme.stageRem),
            ("Ligero", st.lightMinutes, Theme.stageLight),
            ("Profundo", st.deepMinutes, Theme.stageDeep)
        ]
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CapsLabel(text: "Fases")
                StackedBar(parts: rows.map { (Double($0.1), $0.2) }, height: 10)
                ForEach(0..<rows.count) { i in
                    VStack(spacing: 4) {
                        HStack {
                            Circle().fill(rows[i].2).frame(width: 10, height: 10)
                            Text(rows[i].0).font(Theme.text(14)).foregroundColor(Theme.textPrimary)
                            Spacer()
                            Text("\(Fmt.hm(rows[i].1)) · \(Int(Double(rows[i].1) * 100 / total))%")
                                .font(Theme.label(15)).foregroundColor(Theme.textSecondary)
                        }
                        ProgressBar(fraction: Double(rows[i].1) / total, color: rows[i].2, height: 5)
                    }
                }
            }
        }
    }

    private func timesCard(_ s: DailySummary) -> some View {
        return Card(padding: 0) {
            VStack(spacing: 0) {
                ListRow(title: "Me dormí", value: s.sleepStart ?? "–")
                Hairline()
                ListRow(title: "Me desperté", value: s.sleepEnd ?? "–")
                Hairline()
                ListRow(title: "Regularidad", value: model.snap.consistency.map { "\($0)%" } ?? "–")
                Hairline()
                ListRow(title: "Rendimiento del sueño", value: model.snap.sleepPerf.map { "\($0)%" } ?? "–")
            }
        }
    }

    private var planCard: some View {
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CapsLabel(text: "Esta noche")
                if let p = model.snap.plan {
                    Text(Fmt.hm(p.totalNeedMinutes)).font(Theme.number(34)).foregroundColor(Theme.textPrimary)
                    Text("Base \(Fmt.hm(p.baselineMinutes)) · esfuerzo +\(p.strainAdjustmentMinutes) min · deuda +\(p.debtAdjustmentMinutes) min")
                        .font(Theme.text(12)).foregroundColor(Theme.textSecondary)
                    if let b = p.suggestedBedtime {
                        Text("Acuéstate sobre las \(b) para despertar a las 7:30")
                            .font(Theme.text(13)).foregroundColor(Theme.sleepBlue)
                    }
                } else {
                    EmptyNote(text: "Sin datos todavía.")
                }
            }
        }
    }

    private func weekCard(_ days: [DailyMetrics]) -> some View {
        var items = [WeekBars.Item]()
        for d in days {
            let v: Double? = d.sleepMinutes.map { Double($0) / 60.0 }
            items.append(WeekBars.Item(label: Fmt.weekdayLetter(d.date), value: v, color: Theme.sleepBlue))
        }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: "Horas dormidas")
                if items.isEmpty { EmptyNote(text: "Aún no hay días guardados.") }
                else { WeekBars(items: items, maxValue: 10, format: { Fmt.comma($0) }) }
            }
        }
    }
}

// MARK: - Esfuerzo

struct StrainView: View {
    @StateObject private var model = AppModel.shared

    var body: some View {
        let strain = model.snap.summary.strain
        let days = Array(model.snap.days.prefix(7).reversed())
        let sessions = model.snap.allSessions
        return NavigationStack {
            Screen("Esfuerzo") {
                Text("Esfuerzo").font(Theme.number(34)).foregroundColor(Theme.textPrimary)
                Card {
                    HStack(spacing: 16) {
                        RingView(progress: strain / 21.0, value: Fmt.comma(strain), label: "de 21", color: Theme.strainBlue, size: 130)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(level(strain)).font(Theme.label(20)).foregroundColor(Theme.strainBlue)
                            Text("Calorías \(model.snap.kcal.map { Fmt.thousands(Int64($0)) } ?? "–") kcal")
                                .font(Theme.text(13)).foregroundColor(Theme.textSecondary)
                            Text("Pasos \(Fmt.thousands(Int64(model.snap.steps)))")
                                .font(Theme.text(13)).foregroundColor(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                zonesCard
                weekCard(days, strain)
                SectionTitle(text: "Actividades")
                if sessions.isEmpty {
                    Card { EmptyNote(text: "Todavía no hay actividades.") }
                } else {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<min(sessions.count, 30)) { i in
                                NavigationLink(destination: EditSessionView(sessionId: sessions[i].id)) {
                                    SessionRow(session: sessions[i])
                                }
                                .buttonStyle(.plain)
                                if i < min(sessions.count, 30) - 1 { Hairline() }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Esfuerzo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func level(_ s: Double) -> String {
        if s < 10 { return "Ligero" }
        if s < 14 { return "Moderado" }
        if s < 18 { return "Alto" }
        return "Muy alto"
    }

    private var zonesCard: some View {
        var z = [0, 0, 0, 0, 0, 0]
        for a in model.snap.todaySessions {
            z[0] += a.minutesZone0; z[1] += a.minutesZone1; z[2] += a.minutesZone2
            z[3] += a.minutesZone3; z[4] += a.minutesZone4; z[5] += a.minutesZone5
        }
        let colors = [Theme.track, Theme.zone1, Theme.zone2, Theme.zone3, Theme.zone4, Theme.zone5]
        let total = max(Double(z[1] + z[2] + z[3] + z[4] + z[5]), 1)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: "Zonas de hoy (actividades)")
                StackedBar(parts: (1...5).map { (Double(z[$0]), colors[$0]) }, height: 10)
                HStack {
                    ForEach(1..<6) { i in
                        VStack(spacing: 2) {
                            Text("Z\(i)").font(Theme.label(12)).foregroundColor(colors[i])
                            Text("\(z[i])′").font(Theme.number(16)).foregroundColor(Theme.textPrimary)
                        }
                        .frame(maxWidth: Double.infinity)
                    }
                }
                Text("\(Int(total)) min en zonas 1–5").font(Theme.text(11)).foregroundColor(Theme.textSecondary)
            }
        }
    }

    private func weekCard(_ days: [DailyMetrics], _ today: Double) -> some View {
        var items = [WeekBars.Item]()
        for d in days { items.append(WeekBars.Item(label: Fmt.weekdayLetter(d.date), value: d.strain, color: Theme.strainBlue)) }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: "Últimos días")
                if items.isEmpty { EmptyNote(text: "Aún no hay días guardados.") }
                else { WeekBars(items: items, maxValue: 21, format: { Fmt.comma($0) }) }
            }
        }
    }
}

// MARK: - Editar actividad

struct EditSessionView: View {
    let sessionId: Int64
    @State private var type = ""
    @State private var loaded = false
    @State private var session: ActivitySession? = nil
    @State private var saved = false

    private static let types = ["Sin clasificar", "Correr", "Ciclismo", "Caminar", "Gimnasio", "Fútbol", "Natación", "Yoga", "HIIT", "Otro"]

    var body: some View {
        Screen("Actividad") {
            if let s = session {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        CapsLabel(text: "\(Fmt.dateTime(s.startMillis)) · \(Fmt.hm(Int((s.endMillis - s.startMillis) / 60_000)))")
                        Text(Fmt.comma(s.strain)).font(Theme.number(44)).foregroundColor(Theme.strainBlue)
                        Text("Pulso medio \(s.avgHr) · máx \(s.maxHr) · \(Fmt.int(s.caloriesKcal)) kcal")
                            .font(Theme.text(13)).foregroundColor(Theme.textSecondary)
                        if s.autoDetected { Text("Detectada automáticamente").font(Theme.text(12)).foregroundColor(Theme.textSecondary) }
                    }
                }
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<EditSessionView.types.count) { i in
                            Button(action: { choose(EditSessionView.types[i]) }) {
                                HStack {
                                    Text(EditSessionView.types[i]).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
                                    Spacer()
                                    if type == EditSessionView.types[i] {
                                        Image(systemName: "checkmark").foregroundColor(Theme.recoveryGreen)
                                    }
                                }
                                .padding(.vertical, 13).padding(.horizontal, 16)
                            }
                            if i < EditSessionView.types.count - 1 { Hairline() }
                        }
                    }
                }
                if saved { Text("Guardado").font(Theme.text(12)).foregroundColor(Theme.recoveryGreen) }
            } else {
                Card { EmptyNote(text: "No se encontró la actividad.") }
            }
        }
        .navigationTitle("Actividad")
        .onAppear {
            if !loaded {
                loaded = true
                session = AppStore.shared.session(id: sessionId)
                type = session?.type ?? ""
            }
        }
    }

    private func choose(_ t: String) {
        guard var s = session else { return }
        s.type = t
        AppStore.shared.updateSession(s)
        session = s
        type = t
        saved = true
        AppModel.shared.refresh()
    }
}

// MARK: - Perfil

struct ProfileView: View {
    @State private var weight = ""
    @State private var height = ""
    @State private var birthday = Date()
    @State private var sex = "M"
    @State private var loaded = false
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Screen("Perfil") {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CapsLabel(text: "Tus datos")
                        TextField("Peso (kg)", text: $weight).keyboardType(.decimalPad)
                        Hairline()
                        TextField("Estatura (cm)", text: $height).keyboardType(.decimalPad)
                        Hairline()
                        DatePicker("Nacimiento", selection: $birthday, displayedComponents: [.date])
                        Hairline()
                        HStack(spacing: 10) {
                            sexButton("M", "Hombre")
                            sexButton("F", "Mujer")
                        }
                    }
                    .foregroundColor(Theme.textPrimary)
                }
                Button(action: { save() }) {
                    Text("Guardar").font(Theme.label(17)).foregroundColor(Theme.onAccent)
                        .frame(maxWidth: Double.infinity).padding(.vertical, 12)
                        .background(Theme.recoveryGreen).cornerRadius(12)
                }
                if !note.isEmpty { Text(note).font(Theme.text(12)).foregroundColor(Theme.textSecondary) }
                Text("Se usan para calorías, zonas de pulso (Tanaka) y VO₂ máx. Todo se queda en tu iPhone.")
                    .font(Theme.text(12)).foregroundColor(Theme.textSecondary)
            }
            .navigationTitle("Perfil")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { load() }
        }
    }

    private func sexButton(_ code: String, _ label: String) -> some View {
        let on = sex == code
        return Button(action: { sex = code }) {
            Text(label).font(Theme.label(16)).foregroundColor(on ? Theme.onAccent : Theme.textPrimary)
                .frame(maxWidth: Double.infinity).padding(.vertical, 9)
                .background(on ? Theme.recoveryGreen : Theme.track).cornerRadius(10)
        }
    }

    private func load() {
        if loaded { return }
        loaded = true
        if let p = AppStore.shared.getProfile() {
            weight = Fmt.comma(p.weightKg)
            height = Fmt.comma(p.heightCm)
            birthday = Date(timeIntervalSince1970: Double(p.birthdayMillis) / 1000.0)
            sex = p.sex
        }
    }

    private func save() {
        let w = Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0
        let h = Double(height.replacingOccurrences(of: ",", with: ".")) ?? 0
        if w < 30 || w > 250 || h < 120 || h > 230 {
            note = "Revisa peso (30–250 kg) y estatura (120–230 cm)."
            return
        }
        let old = AppStore.shared.getProfile()
        let ms = Int64(birthday.timeIntervalSince1970 * 1000.0)
        AppStore.shared.saveProfile(UserProfile(birthdayMillis: ms, weightKg: w, heightCm: h, sex: sex,
                                                vo2Max: old?.vo2Max, vo2MaxUpdatedDate: old?.vo2MaxUpdatedDate))
        WhoopManager.shared.refreshHrMax()
        AppModel.shared.refresh()
        note = "Guardado"
    }
}
