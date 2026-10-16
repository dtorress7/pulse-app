import Foundation
import SwiftUI

// MARK: - Raíz con pestañas

struct RootView: View {
    @StateObject private var model = AppModel.shared
    @StateObject private var mgr = WhoopManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Inicio", systemImage: "house.fill") }
            HealthView()
                .tabItem { Label("Salud", systemImage: "heart.text.square.fill") }
            SleepView()
                .tabItem { Label("Sueño", systemImage: "moon.fill") }
            StrainView()
                .tabItem { Label("Esfuerzo", systemImage: "flame.fill") }
            CoachView()
                .tabItem { Label("Coach", systemImage: "sparkles") }
        }
        .tint(Theme.recoveryGreen)
        .preferredColorScheme(.dark)
        .onAppear {
            model.refresh()
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in AppModel.shared.refresh() }
        }
        .onChange(of: mgr.logVersion) { _ in model.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refresh() }
            if phase == .background { mgr.handler.flush() }
        }
    }
}

/// Fondo + desplazamiento común de las pantallas.
struct Screen<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(16)
            }
        }
    }
}

struct CoachView: View {
    var body: some View {
        NavigationStack {
            Screen("Coach") {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CapsLabel(text: "Próximamente")
                        Text("Coach").font(Theme.number(34)).foregroundColor(Theme.textPrimary)
                        Text("Aquí irá el entrenador personal que usa tus datos de recuperación, sueño y esfuerzo.")
                            .font(Theme.text(14)).foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .navigationTitle("Coach")
        }
    }
}

// MARK: - Inicio

struct HomeView: View {
    @StateObject private var model = AppModel.shared
    @StateObject private var mgr = WhoopManager.shared
    @State private var showProfile = false
    @State private var showWhoop = false
    @State private var manualStart: Int64? = ActivityState.manualStart()
    @State private var message = ""
    @State private var showMessage = false

    var body: some View {
        NavigationStack {
            Screen("Inicio") {
                header
                rings
                liveCard
                statsRow
                stressCard
                activityCard
                todaySessions
            }
            .navigationTitle("Inicio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { showWhoop = true }) { Image(systemName: "dot.radiowaves.left.and.right") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showProfile = true }) { Image(systemName: "person.crop.circle") }
                }
            }
            .sheet(isPresented: $showProfile) { ProfileView() }
            .sheet(isPresented: $showWhoop) { WhoopView() }
            .alert("PulseApp", isPresented: $showMessage, actions: { Button("OK", action: {}) }, message: { Text(message) })
        }
    }

    private var snap: Snapshot { return model.snap }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            CapsLabel(text: Fmt.longDate(TimeUtil.nowMillis()))
            Text(snap.recovery.total > 0 && snap.summary.avgHrv != nil ? Fmt.recoveryLabel(snap.recovery.total) : "Hoy")
                .font(Theme.number(34)).foregroundColor(Theme.textPrimary)
        }
    }

    private var rings: some View {
        let hasRecovery = snap.summary.avgHrv != nil || snap.summary.restingHr != nil
        let rec = hasRecovery ? snap.recovery.total : 0
        let strain = snap.summary.strain
        return Card {
            HStack(spacing: 0) {
                NavigationLink(destination: RecoveryView()) {
                    RingView(progress: Double(rec) / 100.0, value: hasRecovery ? "\(rec)%" : "–", label: "Recuperación",
                             color: Theme.recoveryColor(rec), size: 100)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: Double.infinity)
                RingView(progress: strain / 21.0, value: Fmt.comma(strain), label: "Esfuerzo", color: Theme.strainBlue, size: 100)
                    .frame(maxWidth: Double.infinity)
                RingView(progress: Double(snap.sleepPerf ?? 0) / 100.0,
                         value: snap.sleepPerf.map { "\($0)%" } ?? "–", label: "Sueño", color: Theme.sleepBlue, size: 100)
                    .frame(maxWidth: Double.infinity)
            }
        }
    }

    private var liveCard: some View {
        let bpm = mgr.lastBpm
        let fresh = bpm != nil && TimeUtil.nowMillis() - mgr.lastBpmTime < 30_000
        return Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    CapsLabel(text: "Pulso ahora")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(bpm.map { "\($0)" } ?? "–").font(Theme.number(44))
                            .foregroundColor(fresh ? Theme.textPrimary : Theme.textSecondary)
                        Text("lpm").font(Theme.label(16)).foregroundColor(Theme.textSecondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(mgr.state).font(Theme.text(12)).foregroundColor(Theme.textSecondary)
                    Button(action: { if mgr.isRunning { mgr.requestHistoryNow() } else { mgr.start() } }) {
                        Text(mgr.isRunning ? "Sincronizar" : "Conectar")
                            .font(Theme.label(15)).foregroundColor(Theme.onAccent)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Theme.recoveryGreen).cornerRadius(18)
                    }
                }
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard("Pasos", Fmt.thousands(Int64(snap.steps)))
            statCard("Calorías", snap.kcal.map { Fmt.thousands(Int64($0)) } ?? "–")
            statCard("FC reposo", snap.summary.restingHr.map { "\($0)" } ?? "–")
        }
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        return Card(padding: 12) {
            VStack(alignment: .leading, spacing: 4) {
                CapsLabel(text: title, size: 11)
                Text(value).font(Theme.number(26)).foregroundColor(Theme.textPrimary)
            }
        }
    }

    private var stressCard: some View {
        let s = snap.stress
        let score = Double(s.currentScore ?? 0)
        return NavigationLink(destination: StressView()) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        CapsLabel(text: "Estrés")
                        Spacer()
                        Text(s.currentScore == nil ? "Sin datos" : s.level.capitalized)
                            .font(Theme.label(15)).foregroundColor(Theme.stressColor(s.level))
                    }
                    GaugeView(value: score).frame(height: 96)
                    Text(s.currentScore.map { Fmt.comma(Double($0)) } ?? "–")
                        .font(Theme.number(30)).foregroundColor(Theme.textPrimary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var activityCard: some View {
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: "Actividad")
                if let start = manualStart {
                    Text("En curso desde las \(Fmt.clock(start))").font(Theme.text(14)).foregroundColor(Theme.textPrimary)
                    Button(action: { finishManual(start) }) {
                        Text("Terminar actividad").font(Theme.label(16)).foregroundColor(Theme.onAccent)
                            .frame(maxWidth: Double.infinity).padding(.vertical, 10)
                            .background(Theme.alertAmber).cornerRadius(10)
                    }
                } else {
                    Text("Se detectan solas cuando el pulso sube. También puedes marcarlas a mano.")
                        .font(Theme.text(13)).foregroundColor(Theme.textSecondary)
                    Button(action: { startManual() }) {
                        Text("Empezar actividad").font(Theme.label(16)).foregroundColor(Theme.onAccent)
                            .frame(maxWidth: Double.infinity).padding(.vertical, 10)
                            .background(Theme.strainBlue).cornerRadius(10)
                    }
                }
            }
        }
    }

    private func startManual() {
        let now = TimeUtil.nowMillis()
        ActivityState.setManualStart(now)
        manualStart = now
    }

    private func finishManual(_ start: Int64) {
        let end = TimeUtil.nowMillis()
        ActivityState.setManualStart(nil)
        manualStart = nil
        guard let p = snap.profile else {
            message = "Rellena tu perfil (peso, estatura, nacimiento) para calcular la actividad."
            showMessage = true
            return
        }
        if let s = ActivityRecorder.summarize(hrLog: mgr.hrLog, startMillis: start, endMillis: end, ageYears: snap.age,
                                              weightKg: p.weightKg, sex: p.sex, restingHr: snap.summary.restingHr) {
            _ = mgr.store.saveSession(s)
            model.refresh()
        } else {
            message = "No hay pulso grabado en ese tramo; no se guardó la actividad."
            showMessage = true
        }
    }

    private var todaySessions: some View {
        let list = snap.todaySessions
        return VStack(alignment: .leading, spacing: 8) {
            if !list.isEmpty {
                SectionTitle(text: "Actividades de hoy")
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<list.count) { i in
                            NavigationLink(destination: EditSessionView(sessionId: list[i].id)) {
                                SessionRow(session: list[i])
                            }
                            .buttonStyle(.plain)
                            if i < list.count - 1 { Hairline() }
                        }
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: ActivitySession
    var body: some View {
        let mins = Int((session.endMillis - session.startMillis) / 60_000)
        return ListRow(title: session.type,
                       value: Fmt.comma(session.strain),
                       valueColor: Theme.strainBlue,
                       subtitle: "\(Fmt.clock(session.startMillis)) · \(Fmt.hm(mins)) · \(session.avgHr) lpm")
    }
}

// MARK: - Recuperación

struct RecoveryView: View {
    @StateObject private var model = AppModel.shared
    var body: some View {
        let r = model.snap.recovery
        let s = model.snap.summary
        return Screen("Recuperación") {
            Card {
                HStack {
                    Spacer()
                    RingView(progress: Double(r.total) / 100.0, value: "\(r.total)%", label: Fmt.recoveryLabel(r.total),
                             color: Theme.recoveryColor(r.total), size: 160)
                    Spacer()
                }
            }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    ListRow(title: "VFC (noche)", value: s.avgHrv.map { "\(Fmt.int($0)) ms" } ?? "–")
                    Hairline()
                    ListRow(title: "VFC frente a tu media", value: r.hrvDeltaPct.map { signed($0) + " %" } ?? "–")
                    Hairline()
                    ListRow(title: "FC en reposo", value: s.restingHr.map { "\($0) lpm" } ?? "–")
                    Hairline()
                    ListRow(title: "FC reposo frente a tu media", value: r.rhrDelta.map { signed($0) + " lpm" } ?? "–")
                    Hairline()
                    ListRow(title: "Respiración", value: s.respiratoryRate.map { "\(Fmt.comma($0)) rpm" } ?? "–")
                }
            }
            Text(r.personalBaseline ? "Calculada con tu propia media de los últimos días."
                                    : "Aún no hay 3 días de datos: se usa una referencia genérica.")
                .font(Theme.text(12)).foregroundColor(Theme.textSecondary)
        }
        .navigationTitle("Recuperación")
    }

    private func signed(_ v: Double) -> String {
        return (v >= 0 ? "+" : "") + Fmt.comma(v)
    }
}

// MARK: - Estrés

struct StressView: View {
    @StateObject private var model = AppModel.shared
    var body: some View {
        let s = model.snap.stress
        let sum = model.snap.summary
        var acts = [ActivityPeriod]()
        for a in model.snap.todaySessions {
            acts.append(ActivityPeriod(startMinute: TimeUtil.minuteOfDay(a.startMillis), endMinute: TimeUtil.minuteOfDay(a.endMillis)))
        }
        return Screen("Estrés") {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        CapsLabel(text: "Ahora")
                        Spacer()
                        Text(s.currentScore == nil ? "Sin datos" : s.level.capitalized)
                            .font(Theme.label(16)).foregroundColor(Theme.stressColor(s.level))
                    }
                    GaugeView(value: Double(s.currentScore ?? 0)).frame(height: 120)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CapsLabel(text: "Últimas 24 horas")
                    if s.series.isEmpty {
                        EmptyNote(text: "Aún no hay suficientes datos de pulso.")
                    } else {
                        StressChart(points: s.series, sleepStartMinute: sum.sleepStartMinuteOfDay,
                                    sleepEndMinute: sum.sleepEndMinuteOfDay, activities: acts)
                            .frame(height: 180)
                    }
                }
            }
            Text("0 = relajado · 3 = estrés alto. Se calcula con tu pulso y tu variabilidad frente a tu media personal.")
                .font(Theme.text(12)).foregroundColor(Theme.textSecondary)
        }
        .navigationTitle("Estrés")
    }
}
