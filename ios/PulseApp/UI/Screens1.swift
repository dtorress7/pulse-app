import Foundation
import SwiftUI

// MARK: - Raíz con pestañas

enum AppTab { case home, health, sleep, strain, community }

/// Pestañas con la barra flotante de WHOOP (Inicio · Salud · Sueño · Esfuerzo + botón Coach), igual que Android.
struct RootView: View {
    @StateObject private var model = AppModel.shared
    @StateObject private var mgr = WhoopManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.home
    @State private var healthPath = [Route]()
    @State private var sleepPath = [Route]()
    @State private var strainPath = [Route]()
    @State private var showCoach = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .home:
                    HomeView()
                case .health:
                    NavigationStack(path: $healthPath) {
                        HealthMonitorView(showBack: false, path: $healthPath)
                            .navigationDestination(for: Route.self) { r in RouteView(route: r, path: $healthPath) }
                    }
                case .sleep:
                    NavigationStack(path: $sleepPath) {
                        SleepDetailView(dayOffset: 0, showBack: false)
                            .navigationDestination(for: Route.self) { r in RouteView(route: r, path: $sleepPath) }
                    }
                case .strain:
                    NavigationStack(path: $strainPath) {
                        StrainDetailView(dayOffset: 0, showBack: false, path: $strainPath)
                            .navigationDestination(for: Route.self) { r in RouteView(route: r, path: $strainPath) }
                    }
                case .community:
                    CommunityView()
                }
            }
            tabBar
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showCoach) { CoachView() }
        .onAppear {
            model.refresh()
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in AppModel.shared.refresh() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refresh(); HomeStore.shared.invalidate() }
            if phase == .background { mgr.handler.flush() }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                tabItem(.home, "house", "Inicio")
                tabItem(.health, "heart.text.square", "Salud")
                tabItem(.sleep, "moon", "Sueño")
                tabItem(.strain, "flame", "Esfuerzo")
                tabItem(.community, "person.3", "Equipos")
            }
            .frame(height: 64)
            .background(Theme.tabBar)
            .overlay(RoundedRectangle(cornerRadius: 32).stroke(Theme.textPrimary.opacity(0.1), lineWidth: 0.5))
            .cornerRadius(32)
            Button(action: { showCoach = true }) {
                Image(systemName: "bubble.left.fill").font(.system(size: 22)).foregroundColor(Theme.onAccent)
                    .frame(width: 64, height: 64).background(Theme.recoveryGreen).clipShape(Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private func tabItem(_ t: AppTab, _ icon: String, _ title: String) -> some View {
        let active = tab == t
        return Button(action: {
            if tab == t {
                // Tocar la pestaña activa vuelve a su pantalla principal
                switch t {
                case .health: healthPath = []
                case .sleep: sleepPath = []
                case .strain: strainPath = []
                case .home, .community: break
                }
            }
            tab = t
        }) {
            VStack(spacing: 4) {
                Image(systemName: active ? icon + ".fill" : icon).font(.system(size: 19))
                Text(title).font(Theme.text(11, active ? .semibold : .medium))
            }
            .foregroundColor(active ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

