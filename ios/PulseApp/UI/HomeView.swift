import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Inicio con el aspecto de la app de WHOOP (port de MainActivity de Android, 17/10): cabecera con racha y día, tres anillos,
/// monitores de salud y estrés, "Mi día" (perspectiva, actividades, sueño de esta noche) y "Mi panel de control".
struct HomeView: View {
    @StateObject private var mgr = WhoopManager.shared
    @ObservedObject private var store = HomeStore.shared
    @State private var path = [Route]()
    @State private var dayOffset = 0
    @State private var data: HomeData? = nil
    @State private var loadingOffset: Int? = nil
    @State private var lastRefresh = Date.distantPast
    @State private var showLoading = true
    @State private var loadingShownAt = Date()
    @State private var showSticky = false
    @State private var manualStart: Int64? = ActivityState.manualStart()
    @State private var tick = 0

    // Hojas y diálogos
    @State private var showProfile = false
    @State private var showWhoop = false
    @State private var showAdd = false
    @State private var showWake = false
    @State private var showPersonalize = false
    @State private var showInsight = false
    @State private var showSummary = false
    @State private var showStrainInfo = false
    @State private var showTypePicker = false
    @State private var showSetup = false
    @State private var setupAsked = false
    @State private var pendingStop: (Int64, Int64)? = nil
    @State private var message = ""
    @State private var showMessage = false
    @State private var showImporter = false
    @State private var importing = false

    static let types = ["Fútbol", "Pádel", "Pickleball", "Entrenamiento funcional", "Entrenamiento de fuerza", "Otro"]
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                Theme.wBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Text("PULSE").font(Theme.medium(24)).tracking(24 * 0.32).foregroundColor(Theme.textPrimary)
                            .frame(maxWidth: .infinity).padding(.top, 18)
                        if let note = connectionNote {
                            Text(note).font(Theme.text(12)).foregroundColor(Theme.textSecondary)
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 4)
                        }
                        rings
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RingsBottomKey.self, value: g.frame(in: .named("homeScroll")).maxY)
                            })
                        monitors.padding(.top, 28)
                        myDay
                        tonightCard
                        panelSection
                        moreSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 120)
                }
                .coordinateSpace(name: "homeScroll")
                .onPreferenceChange(RingsBottomKey.self) { y in
                    let show = y < 20
                    if show != showSticky { withAnimation(.easeInOut(duration: 0.15)) { showSticky = show } }
                }
                if showSticky { stickyHeader.transition(.opacity) }
                if showLoading {
                    LoadingView().ignoresSafeArea().transition(.opacity).zIndex(10)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { r in RouteView(route: r, path: $path) }
        }
        .onAppear {
            manualStart = ActivityState.manualStart()
            refresh(force: false)
            checkSetup()
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { hideLoading() }
        }
        .onReceive(ticker) { _ in
            tick += 1
            if dayOffset == 0 && Date().timeIntervalSince(lastRefresh) > 60 { refresh(force: true) }
            if manualStart != nil { manualStart = ActivityState.manualStart() }
        }
        .onChange(of: store.version) { _ in refresh(force: false) }
        .sheet(isPresented: $showProfile, onDismiss: { HomeStore.shared.invalidate() }) { ProfileView() }
        .sheet(isPresented: $showWhoop) { WhoopView() }
        .sheet(isPresented: $showAdd) {
            AddActivitySheet(dayOffset: dayOffset) { start, end, type in saveSession(start, end, type) }
        }
        .sheet(isPresented: $showWake) {
            WakeTimeSheet(minute: SleepPlanner.wakeMinute()) { m in
                SleepPlanner.setWakeMinute(m)
                HomeStore.shared.invalidate()
            }
        }
        .sheet(isPresented: $showPersonalize) {
            PersonalizeSheet { HomeStore.shared.invalidate() }
        }
        .alert(insightTitle, isPresented: $showInsight, actions: { Button("Cerrar", action: {}) }, message: { Text(data?.insight ?? "") })
        .alert("Resumen", isPresented: $showSummary, actions: { Button("Cerrar", action: {}) }, message: { Text(summaryText) })
        .alert("Esfuerzo y recuperación", isPresented: $showStrainInfo, actions: { Button("Cerrar", action: {}) }, message: {
            Text("En azul, el esfuerzo de cada día (0–21, escala de la izquierda). En círculos, la recuperación de esa mañana (0–100 %, a la derecha): verde ≥ 67 %, amarillo 34–66 %, rojo < 34 %.")
        })
        .alert("PulseApp", isPresented: $showMessage, actions: { Button("OK", action: {}) }, message: { Text(message) })
        .alert("Antes de empezar: ¿quién lleva la pulsera?", isPresented: $showSetup, actions: {
            Button("Completar ahora") { showProfile = true }
        }, message: {
            Text("Necesito tu fecha de nacimiento, peso, altura y sexo. Con ellos calculo tu FC máxima y tus zonas, el esfuerzo, las calorías, el VO₂ máx y cuánto sueño necesitas.")
        })
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importAndroid(urls) }
        }
        .confirmationDialog("¿Qué actividad ha sido?", isPresented: $showTypePicker, titleVisibility: .visible) {
            ForEach(HomeView.types, id: \.self) { t in
                Button(t) { if let p = pendingStop { saveSession(p.0, p.1, t) }; pendingStop = nil }
            }
            Button("Cancelar", role: .cancel) {
                // Si cancela, se guarda igualmente como "Sin clasificar" para no perder el registro
                if let p = pendingStop { saveSession(p.0, p.1, "Sin clasificar") }
                pendingStop = nil
            }
        }
    }

    // MARK: - Datos

    private func refresh(force: Bool) {
        let offset = dayOffset
        if loadingOffset == offset { return }
        loadingOffset = offset
        lastRefresh = Date()
        HomeStore.shared.load(offset, maxAge: force ? 0 : 50) { d in
            if loadingOffset == offset { loadingOffset = nil }
            if offset == dayOffset {
                data = d
                hideLoading()
            } else {
                refresh(force: false)
            }
        }
    }

    private func changeDay(_ delta: Int) {
        let n = dayOffset + delta
        if n > 0 || n < -60 { return }
        dayOffset = n
        loadingOffset = nil
        refresh(force: false)
    }

    /// Quita la pantalla de carga con un fundido (como mínimo se ve 1,6 s para que la animación luzca).
    private func hideLoading() {
        if !showLoading { return }
        let wait = max(0, 1.6 - Date().timeIntervalSince(loadingShownAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            withAnimation(.easeOut(duration: 0.35)) { showLoading = false }
        }
    }

    private func checkSetup() {
        if setupAsked { return }
        setupAsked = true
        if AppStore.shared.getProfile() == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showSetup = true }
        }
    }

    // MARK: - Cabecera

    private var bandLive: Bool { return mgr.lastBpm != nil && TimeUtil.nowMillis() - mgr.lastBpmTime < 15_000 }

    private var connectionNote: String? {
        _ = tick
        if bandLive { return nil }
        if WhoopSettings.deviceId == nil && !mgr.isRunning { return "Toca la pulsera de arriba a la derecha para vincular tu WHOOP" }
        if !mgr.isRunning { return "WHOOP desconectada · toca la pulsera para conectar" }
        return "Esperando pulso de la WHOOP…"
    }

    private var dayLabel: String {
        if dayOffset == 0 { return "HOY" }
        if dayOffset == -1 { return "AYER" }
        let d = Day.add(Day.today(), dayOffset)
        return "\(WText.weekdayUpper(d)). \(Day.dayOfMonth(d))"
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 2) {
                Button(action: { showProfile = true }) {
                    Image(systemName: "person.fill").font(.system(size: 17)).foregroundColor(Theme.textPrimary)
                        .frame(width: 40, height: 40)
                        .overlay(Circle().stroke(Theme.textPrimary, lineWidth: 2))
                }
                Button(action: { message = "Días seguidos llevando la pulsera"; showMessage = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "flame.fill").font(.system(size: 16)).foregroundColor(Theme.wZone[5])
                        WNumber(text: "\(data?.streak ?? 0)", size: 18)
                    }
                    .padding(.leading, 10).padding(.trailing, 14).frame(height: 40)
                    .background(Color.white.opacity(0.08)).cornerRadius(20)
                }
                Spacer()
                Button(action: { showWhoop = true }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "applewatch.side.right").font(.system(size: 24)).foregroundColor(Theme.textPrimary)
                            .frame(width: 44, height: 44)
                        Circle().fill(bandDotColor).frame(width: 11, height: 11).padding(.top, 5).padding(.trailing, 6)
                    }
                }
            }
            HStack(spacing: 0) {
                Button(action: { changeDay(-1) }) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.textPrimary)
                        .frame(width: 36, height: 36)
                }
                Button(action: { if dayOffset != 0 { dayOffset = 0; loadingOffset = nil; refresh(force: false) } }) {
                    Text(dayLabel).font(Theme.number(15)).tracking(15 * 0.12).foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 16).frame(minWidth: 76).frame(height: 36)
                        .background(Color.white.opacity(0.15)).cornerRadius(18)
                }
                Button(action: { changeDay(1) }) {
                    Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.textPrimary)
                        .frame(width: 36, height: 36).opacity(dayOffset < 0 ? 1 : 0.35)
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.08)).cornerRadius(20)
        }
        .frame(height: 48)
    }

    private var bandDotColor: Color {
        _ = tick
        if bandLive { return Theme.wMint }
        if mgr.isRunning { return Theme.alertAmber }
        return Theme.textSecondary
    }

    // MARK: - Anillos

    private var day: DayRecord? { return data?.day }

    private var rings: some View {
        let sleepScore = day?.sleepScore
        let rec = day?.recovery
        let strain = day?.strain
        return HStack(alignment: .top, spacing: 0) {
            ringBox(WRing(progress: Double(sleepScore ?? 0) / 100, value: sleepScore.map { "\($0)%" } ?? "--", color: Theme.wRingSleep),
                    "Sueño", .sleep(dayOffset)).frame(maxWidth: .infinity)
            ringBox(WRing(progress: Double(rec ?? 0) / 100, value: rec.map { "\($0)%" } ?? "--",
                          color: rec.map { Theme.wRecoveryColor($0) } ?? Theme.wRecoveryHigh),
                    "Recuperación", .recovery).frame(maxWidth: .infinity).layoutPriority(1)
            ringBox(WRing(progress: (strain ?? 0) / 21, value: strain.map { Fmt.comma($0) } ?? "--", color: Theme.strainBlue),
                    "Esfuerzo", .strain(dayOffset)).frame(maxWidth: .infinity)
        }
        .padding(.top, 22)
    }

    private func ringBox(_ ring: WRing, _ title: String, _ route: Route) -> some View {
        return Button(action: { path.append(route) }) {
            VStack(spacing: 14) {
                ring
                HStack(spacing: 2) {
                    WTitle(text: title, size: 15)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var stickyHeader: some View {
        let sleepScore = day?.sleepScore ?? 0
        let rec = day?.recovery
        let strain = day?.strain ?? 0
        return HStack {
            miniRing(WRing(progress: Double(sleepScore) / 100, value: "", color: Theme.wRingSleep, size: 26, strokeRatio: 0.14),
                     day?.sleepScore.map { "\($0)%" } ?? "--", .sleep(dayOffset))
            miniRing(WRing(progress: Double(rec ?? 0) / 100, value: "", color: rec.map { Theme.wRecoveryColor($0) } ?? Theme.wRecoveryHigh,
                           size: 26, strokeRatio: 0.14), rec.map { "\($0)%" } ?? "--", .recovery)
            miniRing(WRing(progress: strain / 21, value: "", color: Theme.strainBlue, size: 26, strokeRatio: 0.14),
                     day?.strain.map { Fmt.comma($0) } ?? "--", .strain(dayOffset))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.wBgTop.opacity(0.95).ignoresSafeArea(edges: .top))
    }

    private func miniRing(_ ring: WRing, _ label: String, _ route: Route) -> some View {
        return Button(action: { path.append(route) }) {
            HStack(spacing: 8) {
                ring
                WTitle(text: label, size: 12)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Monitores

    private var monitors: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: { path.append(.health) }) { healthCard }.buttonStyle(.plain)
            Button(action: { path.append(.stress) }) { stressCard }.buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var healthCard: some View {
        let total = data?.healthTotal ?? 0
        let ok = data?.healthOk ?? 0
        let status: String, color: Color, icon: String, iconColor: Color, box: Color, count: String
        if total == 0 {
            status = "CALIBRANDO"; color = Theme.textPrimary; icon = "waveform.path.ecg"; iconColor = Theme.textSecondary
            box = Theme.wRow; count = "Necesita \(BaselineProvider.minDaysRequired) noches"
        } else if ok == total {
            status = "DENTRO\nDEL RANGO"; color = Theme.wMint; icon = "checkmark"; iconColor = Theme.wMint
            box = Theme.wMintBg; count = "\(ok)/\(total) métricas"
        } else {
            status = "FUERA\nDEL RANGO"; color = Theme.alertAmber; icon = "info"; iconColor = Theme.alertAmber
            box = Theme.wStressHighDim; count = "\(ok)/\(total) métricas"
        }
        return monitorCard(title: "Monitor de salud") {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16, weight: .bold)).foregroundColor(iconColor)
                    .frame(width: 40, height: 40).background(box).cornerRadius(8)
                VStack(alignment: .leading, spacing: 4) {
                    WTitle(text: status, color: color)
                    Text(count).font(Theme.text(14)).foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    private var stressCard: some View {
        let level = data?.stressLevel ?? "BAJO"
        let score = data?.stressScore
        let c = Theme.wStressColor(level)
        let bg = level == "ALTO" ? Theme.wStressHighDim : (level == "MEDIO" ? Theme.wMintBg : Theme.wLowBlueBg)
        return monitorCard(title: "Monitor\nde estrés") {
            HStack(spacing: 14) {
                WNumber(text: score.map { Fmt.comma(Double($0)) } ?? "--", size: 19, color: c)
                    .padding(.horizontal, 6).frame(minWidth: 40, minHeight: 40).background(bg).cornerRadius(8)
                VStack(alignment: .leading, spacing: 4) {
                    WTitle(text: score != nil ? level : "SIN DATOS", color: score != nil ? c : Theme.textSecondary)
                    Text(data?.stressMinute.map { Fmt.clock(minuteOfDay: $0) } ?? "").font(Theme.text(14)).foregroundColor(Theme.textSecondary)
                }
            }
        }
    }

    private func monitorCard<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                WTitle(text: title)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.wCard).cornerRadius(14)
    }

    // MARK: - Mi día

    private var insightTitle: String {
        guard let d = data else { return "Perspectiva diaria" }
        return d.isToday ? "Perspectiva diaria" : "Perspectiva del \(Day.dayOfMonth(d.date))/\(Day.month(d.date))"
    }

    private var myDay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WHeading(text: "Mi día")
                Spacer()
                Menu {
                    Button(action: { showAdd = true }) { Label("Agregar actividad", systemImage: "plus") }
                    if dayOffset == 0 {
                        Button(action: { toggleRecording() }) {
                            Label(manualStart == nil ? "Iniciar actividad" : "Detener actividad", systemImage: "stopwatch")
                        }
                    }
                    Button(action: { showWhoop = true }) { Label("Mi WHOOP", systemImage: "applewatch.side.right") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 22, weight: .semibold)).foregroundColor(Theme.background)
                        .frame(width: 52, height: 52).background(Color.white).clipShape(Circle())
                }
            }
            .padding(.top, 34)

            Button(action: { showInsight = true }) {
                HStack(spacing: 14) {
                    Image(systemName: "sun.max").font(.system(size: 20)).foregroundColor(Theme.textPrimary)
                    Text("Perspectiva diaria").font(Theme.text(17, .medium)).foregroundColor(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.textPrimary)
                }
                .padding(.horizontal, 16).frame(height: 58)
                .background(LinearGradient(colors: [Theme.wInsightStart, Theme.wInsightEnd], startPoint: .leading, endPoint: .trailing))
                .cornerRadius(14)
            }
            .buttonStyle(.plain)
            .padding(.top, 16)

            WCard {
                HStack {
                    WTitle(text: data?.isToday == false ? "Actividades del día" : "Actividades de hoy")
                    Spacer()
                    Button(action: { path.append(.strain(dayOffset)) }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 15)).foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.bottom, 14)
                activitiesList
                HStack(spacing: 10) {
                    cardButton("Agregar actividad", "plus", Theme.wRow) { showAdd = true }
                    if dayOffset == 0 {
                        if let s = manualStart {
                            cardButton("Detener · \((TimeUtil.nowMillis() - s) / 60_000) min", "stopwatch", Theme.alertRed) { toggleRecording() }
                        } else {
                            cardButton("Iniciar actividad", "stopwatch", Theme.wRow) { toggleRecording() }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(.top, 12)
        }
    }

    private func cardButton(_ title: String, _ icon: String, _ bg: Color, _ action: @escaping () -> Void) -> some View {
        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                WTitle(text: title, size: 13.5)
            }
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity).frame(height: 46)
            .background(bg).cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var activitiesList: some View {
        let d = data
        let hasSleep = d?.day.sleepMinutes != nil && d?.sleepFromMillis != nil && d?.sleepToMillis != nil
        let sessions = d?.sessions ?? []
        VStack(spacing: 10) {
            if let dd = d, hasSleep {
                Button(action: { path.append(.sleep(dayOffset)) }) {
                    ActivityRowView(color: Theme.wRingSleep, icon: "moon.fill", value: Fmt.hm(dd.day.sleepMinutes!), name: "Sueño",
                                    start: WText.time(dd.sleepFromMillis!), end: WText.time(dd.sleepToMillis!))
                }
                .buttonStyle(.plain)
            }
            ForEach(sessions) { s in
                Button(action: { path.append(.activity(s.id)) }) {
                    ActivityRowView(color: Theme.strainBlue, icon: WText.sportIcon(s.type), value: Fmt.comma(s.strain), name: s.type,
                                    start: WText.time(s.startMillis), end: WText.time(s.endMillis))
                }
                .buttonStyle(.plain)
            }
            if !hasSleep && sessions.isEmpty {
                WBody(text: d?.isToday == false ? "No hay actividades ese día." : "Aún no hay actividades hoy.", size: 14)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - El sueño de esta noche

    @ViewBuilder private var tonightCard: some View {
        if data?.isToday ?? true {
            let wake = data?.wakeMinute ?? SleepPlanner.wakeMinute()
            WCard {
                Button(action: { path.append(.sleep(0)) }) {
                    HStack {
                        WTitle(text: "El sueño de esta noche")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                HStack(alignment: .center, spacing: 10) {
                    timeColumn("sunset.fill", data?.bedtime ?? "--:--", "Hora de dormir\nrecomendada")
                    Line().stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [4, 4])).frame(width: 34, height: 2)
                    timeColumn("applewatch.side.right", Fmt.clock(minuteOfDay: wake), "Hora de\ndespertar")
                }
                .padding(.top, 18)
                Button(action: { showWake = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil").font(.system(size: 14, weight: .semibold))
                        WTitle(text: "Editar hora de despertar", size: 13.5)
                    }
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Theme.wRow).cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.top, 18)
            }
            .padding(.top, 12)
        }
    }

    private func timeColumn(_ icon: String, _ value: String, _ caption: String) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 20)).foregroundColor(Theme.textPrimary)
                WNumber(text: value, size: 32)
            }
            Text(caption).font(Theme.text(13)).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Mi panel de control

    private var panelSection: some View {
        let hidden = PanelKeys.hidden()
        var rows = [String: PanelRow]()
        for r in data?.panel ?? [] { rows[r.key] = r }
        let keys = PanelKeys.all.map { $0.0 }.filter { !hidden.contains($0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                WHeading(text: "Mi panel de control")
                Spacer()
                Button(action: { showPersonalize = true }) {
                    HStack(spacing: 6) {
                        WTitle(text: "Personalizar", size: 13.5)
                        Image(systemName: "pencil").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    }
                    .frame(height: 40)
                }
            }
            .padding(.top, 34)
            ForEach(keys, id: \.self) { key in
                if key == PanelKeys.stress {
                    stressChartCard
                } else if key == PanelKeys.strainRecovery {
                    strainRecoveryCard
                } else if let r = rows[key] {
                    PanelRowView(row: r)
                }
            }
        }
        .id(store.version)
    }

    private var stressChartCard: some View {
        let d = data
        let level = d?.stressLevel ?? "BAJO"
        let time = d?.stressMinute.map { Fmt.clock(minuteOfDay: $0) } ?? ""
        return Button(action: { path.append(.stress) }) {
            WCard {
                HStack {
                    WTitle(text: "Monitor de estrés")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(d?.stressScore == nil ? "Sin datos todavía" : "Última actualización a la(s) \(time)")
                        .font(Theme.text(15)).foregroundColor(Theme.textSecondary)
                    Spacer()
                    WTitle(text: d?.stressScore != nil ? level : "", size: 16, color: Theme.wStressColor(level))
                    WNumber(text: d?.stressScore.map { Fmt.comma(Double($0)) } ?? "--", size: 24)
                }
                .padding(.top, 10)
                if let dd = d {
                    StressDayChart(points: dd.stressSeries, from: dd.stressFrom, to: dd.stressTo,
                                   sleepFrom: dd.sleepFromMillis, sleepTo: dd.sleepToMillis, showNow: dd.isToday)
                        .frame(height: 250).padding(.top, 10)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var strainRecoveryCard: some View {
        let items = (data?.week ?? []).map {
            StrainRecoveryChart.Item(weekday: WText.weekday($0.date) + ".", dayOfMonth: "\(Day.dayOfMonth($0.date))",
                                     strain: $0.strain, recovery: $0.recovery)
        }
        return WCard {
            HStack {
                WTitle(text: "Esfuerzo y recuperación")
                Spacer()
                Button(action: { showStrainInfo = true }) {
                    Image(systemName: "info.circle").font(.system(size: 17)).foregroundColor(Theme.textSecondary)
                }
            }
            StrainRecoveryChart(days: items).frame(height: 300).padding(.top, 12)
        }
    }

    // MARK: - Más

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            WHeading(text: "Más").padding(.top, 34)
            VStack(spacing: 0) {
                moreRow("applewatch.side.right", "Mi WHOOP · conexión") { showWhoop = true }
                WDivider()
                moreRow("person", "Sobre mí") { showProfile = true }
                WDivider()
                moreRow("list.bullet.rectangle", "Resumen detallado") { showSummary = true }
                WDivider()
                moreRow("square.and.arrow.down", importing ? "Importando… (puede tardar un poco)" : "Importar datos de Android") {
                    if !importing { showImporter = true }
                }
                WDivider()
                ShareLink(item: AppPaths.file(AppPaths.hrLog)) {
                    moreRowContent("square.and.arrow.up", "Exportar CSV")
                }
                .buttonStyle(.plain)
            }
            .background(Theme.wCard).cornerRadius(14)
        }
    }

    private func moreRow(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        return Button(action: action) { moreRowContent(icon, title) }.buttonStyle(.plain)
    }

    private func moreRowContent(_ icon: String, _ title: String) -> some View {
        return HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 17)).foregroundColor(Theme.textPrimary).frame(width: 24)
            Text(title).font(Theme.text(16)).foregroundColor(Theme.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16).frame(height: 56)
        .contentShape(Rectangle())
    }

    private var summaryText: String {
        guard let d = data else { return "" }
        let day = d.day
        var s = ""
        if d.profileMissing { s += "Sin perfil guardado, usando edad estimada de 30 años.\n\n" }
        if let sum = d.summary { s += "Lecturas analizadas: \(sum.totalReadings)\n\n" }
        s += "FC en reposo: \(day.rhr.map { "\($0) lpm" } ?? "sin datos suficientes")\n"
        s += "VFC (RMSSD): \(day.hrv.map { String(format: "%.0f ms", $0) } ?? "sin RR registrados")\n"
        s += "Respiración: \(day.resp.map { Fmt.comma($0) + " rpm" } ?? "--")\n"
        s += "VO2máx: \(day.vo2.map { String(format: "%.0f", $0) } ?? "--")\n"
        s += "Esfuerzo (0-21): \(day.strain.map { Fmt.comma($0) } ?? "--")\n\n"
        if let m = day.sleepMinutes {
            s += "Dormido: \(Fmt.hm(m))\n"
            if let f = d.sleepFromMillis, let t = d.sleepToMillis { s += "De \(Fmt.clock(f)) a \(Fmt.clock(t))\n" }
        } else {
            s += "No se detectó ningún periodo de descanso largo (mínimo 90 min).\n"
        }
        return s
    }

    // MARK: - Importar de Android

    /// Copia los archivos elegidos a una carpeta propia (el permiso para leerlos solo dura mientras se copian) y los importa.
    private func importAndroid(_ urls: [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var local = [URL]()
        for u in urls {
            let ok = u.startAccessingSecurityScopedResource()
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { local.append(dest) }
            if ok { u.stopAccessingSecurityScopedResource() }
        }
        if local.isEmpty {
            message = "No pude leer los archivos elegidos."
            showMessage = true
            return
        }
        importing = true
        HomeStore.shared.run({ () -> String in
            let r = AndroidImport.importFiles(local)
            try? FileManager.default.removeItem(at: dir)
            return r.text
        }, completion: { text in
            importing = false
            HomeStore.shared.invalidate()
            AppModel.shared.refresh()
            message = text
            showMessage = true
        })
    }

    // MARK: - Actividades

    private func toggleRecording() {
        if let start = manualStart {
            let end = TimeUtil.nowMillis()
            ActivityState.setManualStart(nil)
            manualStart = nil
            pendingStop = (start, end)
            showTypePicker = true
        } else {
            let now = TimeUtil.nowMillis()
            ActivityState.setManualStart(now)
            manualStart = now
            message = "Actividad iniciada"
            showMessage = true
        }
    }

    private func saveSession(_ start: Int64, _ end: Int64, _ type: String) {
        let s = AppStore.shared
        HomeStore.shared.run({ () -> Int64? in
            let p = s.getProfile()
            let rhr = BaselineProvider.compute(store: s).map { Int($0.avgRestingHr) }
            guard let session = ActivityRecorder.summarize(
                hrLog: WhoopManager.shared.hrLog, startMillis: start, endMillis: end,
                ageYears: p?.ageYears() ?? 30, weightKg: p?.weightKg ?? 75, sex: p?.sex ?? "M",
                type: type, autoDetected: false, restingHr: rhr) else { return nil }
            Formulas.updateObservedHrMax(session.maxHr)
            return s.saveSession(session)
        }, completion: { id in
            if let id = id {
                HomeStore.shared.invalidate()
                AppModel.shared.refresh()
                path.append(.activity(id))
            } else {
                message = "No hay suficientes datos de pulso en esa franja"
                showMessage = true
            }
        })
    }
}

private struct RingsBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 1000
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Pantalla a la que lleva cada ruta (dentro de cualquier pestaña).
struct RouteView: View {
    let route: Route
    @Binding var path: [Route]
    var body: some View {
        switch route {
        case .sleep(let o): SleepDetailView(dayOffset: o, showBack: true)
        case .strain(let o): StrainDetailView(dayOffset: o, showBack: true, path: $path)
        case .health: HealthMonitorView(showBack: true, path: $path)
        case .stress: StressDetailView()
        case .recovery: RecoveryView().toolbar(.visible, for: .navigationBar)
        case .activity(let id): ActivityDetailView(sessionId: id, path: $path)
        case .editActivity(let id): EditSessionView(sessionId: id).toolbar(.visible, for: .navigationBar)
        }
    }
}

// MARK: - Hojas

/// Agregar actividad a mano: tipo, inicio y fin (se calcula con el pulso guardado).
struct AddActivitySheet: View {
    let dayOffset: Int
    let onSave: (Int64, Int64, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var type = HomeView.types[0]
    @State private var start = Date()
    @State private var end = Date()
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Actividad") {
                    Picker("Tipo", selection: $type) {
                        ForEach(HomeView.types, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("Horario") {
                    DatePicker("Inicio", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Fin", selection: $end, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                if !error.isEmpty { Text(error).foregroundColor(Theme.alertRed) }
            }
            .navigationTitle("Agregar actividad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let s = Int64(start.timeIntervalSince1970 * 1000)
                        let e = Int64(end.timeIntervalSince1970 * 1000)
                        if e <= s { error = "La hora de fin tiene que ser posterior al inicio"; return }
                        if e > TimeUtil.nowMillis() + 60_000 { error = "La hora de fin no puede ser futura"; return }
                        dismiss()
                        onSave(s, e, type)
                    }
                }
            }
            .onAppear {
                // Por defecto: el día elegido en Inicio, de hace 1 h a ahora (o 18:00–19:00 si es otro día)
                let now = Date()
                if dayOffset == 0 {
                    end = now
                    start = now.addingTimeInterval(-3600)
                } else {
                    let base = TimeUtil.setTime(TimeUtil.addDays(TimeUtil.nowMillis(), dayOffset), hour: 18, minute: 0)
                    start = Date(timeIntervalSince1970: Double(base) / 1000)
                    end = start.addingTimeInterval(3600)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct WakeTimeSheet: View {
    let minute: Int
    let onSave: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time = Date()
    var body: some View {
        NavigationStack {
            VStack {
                DatePicker("Hora de despertar", selection: $time, displayedComponents: [.hourAndMinute])
                    .datePickerStyle(.wheel).labelsHidden()
                Spacer()
            }
            .padding()
            .navigationTitle("Hora de despertar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                        onSave((c.hour ?? 7) * 60 + (c.minute ?? 30))
                        dismiss()
                    }
                }
            }
            .onAppear {
                time = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }
}

struct PersonalizeSheet: View {
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var visible = Set<String>()
    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<PanelKeys.all.count, id: \.self) { i in
                    let key = PanelKeys.all[i].0
                    Toggle(PanelKeys.all[i].1, isOn: Binding(get: { visible.contains(key) }, set: { on in
                        if on { visible.insert(key) } else { visible.remove(key) }
                    }))
                }
            }
            .navigationTitle("Mi panel de control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        PanelKeys.setHidden(Set(PanelKeys.all.map { $0.0 }.filter { !visible.contains($0) }))
                        onSave()
                        dismiss()
                    }
                }
            }
            .onAppear {
                let hidden = PanelKeys.hidden()
                visible = Set(PanelKeys.all.map { $0.0 }.filter { !hidden.contains($0) })
            }
        }
        .preferredColorScheme(.dark)
    }
}
