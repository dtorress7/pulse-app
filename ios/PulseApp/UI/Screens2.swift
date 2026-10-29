import Foundation
import SwiftUI

// MARK: - Editar actividad

struct EditSessionView: View {
    let sessionId: Int64
    @State private var type = ""
    @State private var loaded = false
    @State private var session: ActivitySession? = nil
    @State private var start = Date()
    @State private var end = Date()
    @State private var message = ""

    private static let types = ["Sin clasificar", "Fútbol", "Pádel", "Pickleball", "Entrenamiento funcional", "Entrenamiento de fuerza", "Correr", "Ciclismo", "Caminar", "Otro"]

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
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        CapsLabel(text: "Horas")
                        DatePicker("Inicio", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        Hairline()
                        DatePicker("Fin", selection: $end, displayedComponents: [.date, .hourAndMinute])
                    }
                    .foregroundColor(Theme.textPrimary)
                }
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<EditSessionView.types.count) { i in
                            Button(action: { type = EditSessionView.types[i] }) {
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
                Button(action: { save() }) {
                    Text("Guardar").font(Theme.label(17)).foregroundColor(Theme.onAccent)
                        .frame(maxWidth: Double.infinity).padding(.vertical, 12)
                        .background(Theme.recoveryGreen).cornerRadius(12)
                }
                if !message.isEmpty { Text(message).font(Theme.text(12)).foregroundColor(Theme.textSecondary) }
                Text("Al guardar se recalculan esfuerzo, zonas y calorías con el pulso de esas horas y el deporte elegido.")
                    .font(Theme.text(12)).foregroundColor(Theme.textSecondary)
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
                if let s = session {
                    start = Date(timeIntervalSince1970: Double(s.startMillis) / 1000)
                    end = Date(timeIntervalSince1970: Double(s.endMillis) / 1000)
                }
            }
        }
    }

    private func save() {
        guard let old = session else { return }
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.timeIntervalSince1970 * 1000)
        if endMs <= startMs { message = "La hora de fin debe ser posterior al inicio"; return }
        let st = AppStore.shared
        let p = st.getProfile()
        let rhr = BaselineProvider.compute(store: st).map { Int($0.avgRestingHr) }
        guard var fresh = ActivityRecorder.summarize(
            hrLog: WhoopManager.shared.hrLog, startMillis: startMs, endMillis: endMs,
            ageYears: p?.ageYears() ?? 30, weightKg: p?.weightKg ?? 75, sex: p?.sex ?? "M",
            // Si cambias las horas, ya no se toca sola (la detección automática solo alarga las que no has editado)
            type: type, autoDetected: old.autoDetected && startMs == old.startMillis && endMs == old.endMillis, restingHr: rhr) else {
            message = "No hay datos de pulso en ese rango horario"
            return
        }
        fresh.id = old.id
        if type == Formulas.napType { fresh.strain = 0; fresh.caloriesKcal = 0 } else { Formulas.updateObservedHrMax(fresh.maxHr) }
        st.updateSession(fresh)
        session = fresh
        message = "Actividad actualizada"
        AppModel.shared.refresh()
        HomeStore.shared.invalidate()
    }
}

// MARK: - Perfil

struct ProfileView: View {
    @State private var weight = ""
    @State private var height = ""
    @State private var birthday = Date()
    @State private var sex = "M"
    @State private var hrMax = ""
    @State private var zoneRhr = ""
    @State private var loaded = false
    @State private var note = ""

    var body: some View {
        WScreen {
            DetailHeader(title: "Sobre mí")
            // Avatar y resumen
            VStack(spacing: 14) {
                Image(systemName: "person.fill").font(.system(size: 34)).foregroundColor(Theme.textSecondary)
                    .frame(width: 80, height: 80).background(Circle().fill(Theme.wCard))
                HStack(spacing: 0) {
                    stat(ageText, "Años")
                    stat(bmiText, "IMC")
                    stat(AppStore.shared.getProfile()?.vo2Max.map { Fmt.int($0) } ?? "--", "VO₂ máx")
                }
            }
            .frame(maxWidth: .infinity).padding(.top, 10)

            WTitle(text: "Tus datos").padding(.top, 26).padding(.bottom, 10)
            WCard(padding: 0) {
                row("Peso (kg)") { input($weight, "--") }
                WDivider()
                row("Estatura (cm)") { input($height, "--") }
                WDivider()
                row("Nacimiento") { DatePicker("", selection: $birthday, displayedComponents: [.date]).labelsHidden().colorScheme(.dark) }
                WDivider()
                row("Sexo") {
                    HStack(spacing: 8) { sexButton("M", "Hombre"); sexButton("F", "Mujer") }.frame(width: 190)
                }
            }

            HStack {
                WTitle(text: "Ajustes de FC")
                Spacer()
                WBody(text: "Como WHOOP: reserva de FC", size: 12.5)
            }
            .padding(.top, 26).padding(.bottom, 10)
            WCard(padding: 0) {
                row("FC máxima") { input($hrMax, "auto") }
                WDivider()
                row("FC en reposo para zonas") { input($zoneRhr, "auto (\(Formulas.zoneRestingHr()))") }
                WDivider()
                zonesList.padding(.horizontal, 16).padding(.vertical, 10)
            }

            Button(action: { save() }) {
                WTitle(text: "Guardar", size: 16, color: Theme.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Theme.wMint).cornerRadius(12)
            }
            .padding(.top, 22)
            if !note.isEmpty { WBody(text: note, size: 13).padding(.top, 8) }
            WBody(text: "Se usan para calorías, zonas de pulso, esfuerzo y VO₂ máx. FC máxima y FC en reposo para zonas: pon las mismas que en WHOOP (Ajustes de FC: la tuya 195 y 59); vacías = automáticas. Todo se queda en tu iPhone.", size: 12.5)
                .padding(.top, 10).padding(.bottom, 30)
        }
        .onAppear { load() }
    }

    private var ageText: String {
        let years = Calendar.current.dateComponents([.year], from: birthday, to: Date()).year ?? 0
        return years > 0 ? "\(years)" : "--"
    }

    private var bmiText: String {
        let w = Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0
        let h = Double(height.replacingOccurrences(of: ",", with: ".")) ?? 0
        return w > 0 && h > 0 ? Fmt.comma(w / ((h / 100) * (h / 100))) : "--"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            WNumber(text: value, size: 26)
            WTitle(text: label, size: 11, color: Theme.textSecondary)
        }
        .frame(width: 84)
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ trailing: () -> V) -> some View {
        HStack {
            WTitle(text: label, size: 13.5)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func input(_ value: Binding<String>, _ placeholder: String) -> some View {
        TextField(placeholder, text: value).keyboardType(.decimalPad)
            .font(Theme.number(20)).foregroundColor(Theme.textPrimary)
            .multilineTextAlignment(.trailing).frame(maxWidth: 140)
    }

    /// Rangos de las zonas 1–5 (reserva de FC, como en las actividades y en WHOOP).
    private var zonesList: some View {
        let age = Calendar.current.dateComponents([.year], from: birthday, to: Date()).year ?? 30
        let hm = Int(hrMax.trimmingCharacters(in: .whitespaces)) ?? 0
        let zr = Int(zoneRhr.trimmingCharacters(in: .whitespaces)) ?? 0
        let maxHr = hm > 0 ? Double(hm) : Formulas.hrMax(ageYears: age)
        let b = Formulas.zoneBounds(hrMax: maxHr, rhr: zr > 0 ? zr : nil)
        return VStack(spacing: 12) {
            ForEach((1...5).reversed(), id: \.self) { z in
                HStack(spacing: 12) {
                    WTitle(text: "Zona \(z)", size: 13.5).frame(width: 64, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Theme.wZone[z]).frame(width: g.size.width * (1 - 0.12 * Double(5 - z)), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 14)
                    WNumber(text: z == 5 ? "\(b[4])+ lpm" : "\(b[z - 1])–\(b[z] - 1) lpm", size: 17).frame(width: 96, alignment: .trailing)
                }
            }
        }
    }

    private func sexButton(_ code: String, _ label: String) -> some View {
        let on = sex == code
        return Button(action: { sex = code }) {
            WTitle(text: label, size: 13, color: on ? Theme.onAccent : Theme.textPrimary)
                .frame(maxWidth: Double.infinity).padding(.vertical, 9)
                .background(on ? Theme.wMint : Theme.wChip).cornerRadius(8)
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
        if let m = Formulas.observedHrMax() { hrMax = String(m) }
        if let z = Formulas.manualZoneRestingHr() { zoneRhr = String(z) }
    }

    private func save() {
        let w = Double(weight.replacingOccurrences(of: ",", with: ".")) ?? 0
        let h = Double(height.replacingOccurrences(of: ",", with: ".")) ?? 0
        if w < 30 || w > 250 || h < 120 || h > 230 {
            note = "Revisa peso (30–250 kg) y estatura (120–230 cm)."
            return
        }
        let hm = Int(hrMax.trimmingCharacters(in: .whitespaces)) ?? 0
        if hm != 0 && (hm < 140 || hm > 230) {
            note = "Revisa la FC máxima (140–230 lpm) o déjala vacía."
            return
        }
        let zr = Int(zoneRhr.trimmingCharacters(in: .whitespaces)) ?? 0
        if zr != 0 && (zr < 35 || zr > 100) {
            note = "Revisa la FC en reposo para zonas (35–100 lpm) o déjala vacía."
            return
        }
        Formulas.setObservedHrMax(hm)
        Formulas.setManualZoneRestingHr(zr)
        let old = AppStore.shared.getProfile()
        let ms = Int64(birthday.timeIntervalSince1970 * 1000.0)
        AppStore.shared.saveProfile(UserProfile(birthdayMillis: ms, weightKg: w, heightCm: h, sex: sex,
                                                vo2Max: old?.vo2Max, vo2MaxUpdatedDate: old?.vo2MaxUpdatedDate))
        WhoopManager.shared.refreshHrMax()
        AppModel.shared.refresh()
        HomeStore.shared.invalidate()
        note = "Guardado"
    }
}
