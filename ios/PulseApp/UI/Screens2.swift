import Foundation
import SwiftUI

// MARK: - Editar actividad

struct EditSessionView: View {
    let sessionId: Int64
    @State private var type = ""
    @State private var loaded = false
    @State private var session: ActivitySession? = nil
    @State private var saved = false

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
        HomeStore.shared.invalidate()
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
        HomeStore.shared.invalidate()
        note = "Guardado"
    }
}
