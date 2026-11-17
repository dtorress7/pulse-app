import Foundation
import SwiftUI

/* 17/11: Perfil como WHOOP (vídeo del usuario), SIN logros (el usuario no los quiere): nombre y "Miembro desde", nivel por
   recuperaciones, WHOOP Age, racha de días, aspectos destacados (1M / 3M / todo) y resumen de actividad. La rueda abre la
   configuración (Sobre mí y Mi WHOOP). Solo muestra datos que ya calcula PulseApp. */

/// Niveles de WHOOP por número de recuperaciones (leídos de su pantalla "Niveles").
enum Levels {
    static let list: [(level: Int, tier: String, need: Int)] = [
        (1, "Carbono", 0), (2, "Hierro", 4), (3, "Acero", 7), (4, "Bronce industrial", 14), (5, "Titanio", 21),
        (6, "Bronce", 30), (7, "Bronce", 40), (8, "Bronce", 50), (9, "Bronce", 65), (10, "Bronce", 80),
        (11, "Plata", 100), (12, "Plata", 125), (13, "Plata", 150), (14, "Plata", 200), (15, "Plata", 250),
        (16, "Oro", 300), (17, "Oro", 400), (18, "Oro", 500), (19, "Oro", 650), (20, "Oro", 800),
        (21, "Platino", 1000), (22, "Platino", 1200), (23, "Platino", 1400), (24, "Platino", 1600)
    ]

    static func level(_ recoveries: Int) -> Int { return list.last { $0.need <= recoveries }?.level ?? 1 }

    static func color(_ tier: String) -> Color {
        switch tier {
        case "Carbono": return Color(hex: 0x4A5056)
        case "Hierro": return Color(hex: 0x6B7178)
        case "Acero": return Color(hex: 0xA9B1B8)
        case "Bronce industrial": return Color(hex: 0x8C6A4A)
        case "Titanio": return Color(hex: 0x8A94A6)
        case "Bronce": return Color(hex: 0xC47A4A)
        case "Plata": return Color(hex: 0xC9D1D9)
        case "Oro": return Color(hex: 0xE2B84B)
        default: return Color(hex: 0x9FD8E8)
        }
    }
}

struct LevelBadge: View {
    let level: Int
    var size: Double = 56
    var locked = false
    var body: some View {
        let tier = Levels.list[max(0, min(level - 1, Levels.list.count - 1))].tier
        return ZStack {
            Image(systemName: "shield.fill").font(.system(size: size)).foregroundColor(locked ? Color.white.opacity(0.08) : Levels.color(tier))
            if locked {
                Image(systemName: "lock.fill").font(.system(size: size * 0.32)).foregroundColor(Theme.textSecondary)
            } else {
                WNumber(text: "\(level)", size: size * 0.42, color: Color.black.opacity(0.75)).offset(y: -size * 0.04)
            }
        }
        .frame(width: size * 1.1, height: size * 1.15)
    }
}

/// Lo que necesitan el Perfil, los Niveles y la Racha (se calcula una vez fuera del hilo principal).
struct ProfileStats {
    let records: [DayRecord]
    let sessions: [ActivitySession]
    let recoveries: Int
    let memberSince: String?
    let whoopAge: Double?
    let chronoAge: Double?
    let streak: Int
    let streakStart: String?
    let streakMax: Int
    let wornDays: Set<String>

    static func load() -> ProfileStats {
        let d = HomeDataLoader.load(dayOffset: 0, historyDays: 400)
        let sessions = AppStore.shared.allSessions()
        let recs = d.records.sorted { $0.date < $1.date }
        let hs = Healthspan.compute(records: d.records, sessions: sessions, profile: AppStore.shared.getProfile(), today: Day.today())
        // Día "llevado": con noche, esfuerzo o recuperación (los importados de WHOOP también cuentan)
        let worn = Set(recs.filter { $0.sleepMinutes != nil || $0.strain != nil || $0.recovery != nil }.map { $0.date })
        let today = Day.today()
        var cur = 0
        var cursor = worn.contains(today) ? today : Day.add(today, -1)
        while worn.contains(cursor) { cur += 1; cursor = Day.add(cursor, -1) }
        var best = 0, run = 0
        var prev: String? = nil
        for day in worn.sorted() {
            run = (prev.map { Day.add($0, 1) == day } ?? false) ? run + 1 : 1
            best = max(best, run)
            prev = day
        }
        return ProfileStats(records: recs, sessions: sessions, recoveries: recs.filter { $0.recovery != nil }.count,
                            memberSince: recs.first?.date, whoopAge: hs.whoopAge, chronoAge: hs.chronoAge, streak: cur,
                            streakStart: cur > 0 ? Day.add(cursor, 1) : nil, streakMax: max(best, cur), wornDays: worn)
    }
}

struct ProfileHubSheet: View {
    @State private var path = [Route]()
    var body: some View {
        NavigationStack(path: $path) {
            ProfileHubView(path: $path)
                .navigationDestination(for: Route.self) { r in RouteView(route: r, path: $path) }
        }
        .preferredColorScheme(.dark)
    }
}

struct ProfileHubView: View {
    @Binding var path: [Route]
    @Environment(\.dismiss) private var dismiss
    @State private var stats: ProfileStats? = nil
    @State private var period = 2          // 0 = 1M, 1 = 3M, 2 = todo
    @State private var actPeriod = 2
    @State private var showAllActs = false
    @State private var showConfig = false
    private let monthNames = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"]

    var body: some View {
        ZStack(alignment: .top) {
            Theme.wBackground.ignoresSafeArea()
            LinearGradient(colors: [Color(hex: 0x5A3F8F).opacity(0.85), Color.clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 260).ignoresSafeArea(edges: .top)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        WTitle(text: "Perfil", size: 15)
                        HStack {
                            Button(action: { dismiss() }) {
                                Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.textPrimary)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Cerrar")
                            Spacer()
                            Button(action: { showConfig = true }) {
                                Image(systemName: "gearshape").font(.system(size: 21)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Configuración")
                        }
                    }
                    .padding(.top, 4)
                    header
                    if let s = stats {
                        content(s)
                    } else {
                        ScreenLoading()
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 60)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { reload() }
        .sheet(isPresented: $showConfig, onDismiss: { reload() }) { ConfigView() }
    }

    private func reload() {
        HomeStore.shared.run({ ProfileStats.load() }, completion: { stats = $0 })
    }

    private var header: some View {
        let name = ProfileName.get()
        let p = AppStore.shared.getProfile()
        return VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0x8E7CF0), Color(hex: 0xE7A6F5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                if let i = ProfileName.initials() {
                    WNumber(text: i, size: 40, color: Color.white)
                } else {
                    Image(systemName: "person.fill").font(.system(size: 38)).foregroundColor(.white)
                }
            }
            .frame(width: 96, height: 96)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name.isEmpty ? "Tu perfil" : name).font(Theme.text(26, .semibold)).foregroundColor(Theme.textPrimary)
                    if let p = p {
                        Text("\(p.ageYears()) años · \(p.sex == "F" ? "Mujer" : "Hombre")").font(Theme.text(14)).foregroundColor(Theme.textSecondary)
                    }
                }
                Spacer()
                Button(action: { path.append(.aboutMe) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil").font(.system(size: 13, weight: .semibold))
                        WTitle(text: "Editar", size: 13)
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(Color.white.opacity(0.12)).cornerRadius(18)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 14)
    }

    @ViewBuilder private func content(_ s: ProfileStats) -> some View {
        if let m = s.memberSince {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                Text("Miembro desde ").font(Theme.text(14)).foregroundColor(Theme.textSecondary)
                    + Text("\(monthNames[Day.month(m) - 1]) \(TimeUtil.parts(Day.start(m)).year)").font(Theme.text(14, .semibold)).foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(14).background(Theme.wCard).cornerRadius(12).padding(.top, 16)
        }

        // Nivel y WHOOP Age
        let lvl = Levels.level(s.recoveries)
        HStack(spacing: 12) {
            Button(action: { path.append(.levels) }) {
                cardBox {
                    LevelBadge(level: lvl, size: 46)
                    WTitle(text: "Nivel \(lvl)", size: 14)
                    Text("\(s.recoveries) Recuperaciones").font(Theme.text(13)).foregroundColor(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
            Button(action: { path.append(.healthspan) }) {
                cardBox {
                    AgeBlob(text: AgeBlob.text(s.whoopAge), size: 72)
                    WTitle(text: "WHOOP Age", size: 14)
                    Text(ageWord(s)).font(Theme.text(13)).foregroundColor(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 12)

        // Racha
        Button(action: { path.append(.streak) }) {
            HStack {
                WTitle(text: "Racha de días", size: 14)
                Spacer()
                Image(systemName: "flame.fill").font(.system(size: 14)).foregroundColor(Color(hex: 0xFF4D4D))
                WNumber(text: "\(s.streak) Días", size: 16)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
            }
            .padding(16).background(Theme.wCard).cornerRadius(12)
        }
        .buttonStyle(.plain).padding(.top, 12)

        highlights(s).padding(.top, 34)
        activitySummary(s).padding(.top, 34)
    }

    private func ageWord(_ s: ProfileStats) -> String {
        guard let a = s.whoopAge, let c = s.chronoAge else { return "Sin datos aún" }
        return a <= c ? "Más joven" : "Mayor"
    }

    private func cardBox<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 6) { c() }
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(Theme.wCard).cornerRadius(14)
            .overlay(Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSecondary)
                .padding(12), alignment: .topTrailing)
    }

    // MARK: Aspectos destacados

    private func since(_ p: Int) -> String {
        switch p {
        case 0: return Day.add(Day.today(), -30)
        case 1: return Day.add(Day.today(), -91)
        default: return "0000-00-00"
        }
    }

    /// Racha más larga de días seguidos que cumplen [ok].
    private func longestRun(_ recs: [DayRecord], _ ok: (DayRecord) -> Bool) -> Int {
        var best = 0, run = 0
        var prev: String? = nil
        for r in recs {
            if ok(r) {
                run = (prev.map { Day.add($0, 1) == r.date } ?? false) ? run + 1 : 1
                best = max(best, run)
                prev = r.date
            } else {
                run = 0; prev = nil
            }
        }
        return best
    }

    private func highlights(_ s: ProfileStats) -> some View {
        let from = since(period)
        let recs = s.records.filter { $0.date >= from }
        let sessions = s.sessions.filter { TimeUtil.dayKey($0.startMillis) >= from && $0.type != Formulas.napType }
        let bestSleep = recs.compactMap { $0.sleepScore }.max()
        let bestRec = recs.compactMap { $0.recovery }.max()
        let bestStrain = recs.compactMap { $0.strain }.max()
        let rhrs = recs.compactMap { $0.rhr }, hrvs = recs.compactMap { $0.hrv }
        let maxHr = sessions.map { $0.maxHr }.max()
        let longest = recs.compactMap { $0.sleepMinutes }.max()
        let worstRec = recs.compactMap { $0.recovery }.min()
        return VStack(alignment: .leading, spacing: 0) {
            Text("Aspectos destacados").font(Theme.text(22)).foregroundColor(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 0) {
                Segmented(labels: ["1M", "3M", "Todo el tiempo"], selected: $period).padding(.top, -20)
                HStack(alignment: .top) {
                    ringStat(WRing(progress: Double(bestSleep ?? 0) / 100, value: bestSleep.map { "\($0)%" } ?? "--", color: Theme.wRingSleep, size: 78),
                             "Dormir mejor")
                    ringStat(WRing(progress: Double(bestRec ?? 0) / 100, value: bestRec.map { "\($0)%" } ?? "--",
                                   color: bestRec.map { Theme.wRecoveryColor($0) } ?? Theme.wRecoveryHigh, size: 78), "Punto máximo de recuperación")
                    ringStat(WRing(progress: (bestStrain ?? 0) / 21, value: bestStrain.map { Fmt.comma($0) } ?? "--", color: Theme.strainBlue, size: 78),
                             "Esfuerzo máximo")
                }
                .padding(.top, 18)
                WTitle(text: "Rachas", size: 12, color: Theme.textSecondary).padding(.top, 22)
                HStack(alignment: .top) {
                    runStat("moon.fill", Theme.wRingSleep, longestRun(recs) { ($0.sleepScore ?? 0) >= 70 }, "Sueño 70 %+")
                    runStat("bolt.heart.fill", Theme.wRecoveryHigh, longestRun(recs) { ($0.recovery ?? 0) >= 67 }, "Recuperación en verde")
                    runStat("flame.fill", Theme.strainBlue, longestRun(recs) { ($0.strain ?? 0) >= 10 }, "Esfuerzo 10+")
                }
                .padding(.top, 12)
                WTitle(text: "Estadísticas destacadas", size: 12, color: Theme.textSecondary).padding(.top, 24)
                VStack(spacing: 0) {
                    statRow("heart", "FCR más baja", rhrs.min().map { "\($0)" }, "lpm")
                    statRow("heart", "FCR más alta", rhrs.max().map { "\($0)" }, "lpm")
                    statRow("waveform.path.ecg", "VFC más baja", hrvs.min().map { Fmt.int($0) }, "ms")
                    statRow("waveform.path.ecg", "VFC más alta", hrvs.max().map { Fmt.int($0) }, "ms")
                    statRow("heart.circle", "Frecuencia cardíaca máxima", maxHr.map { "\($0)" }, "lpm")
                    statRow("moon", "Sueño más largo", longest.map { Fmt.hm($0) }, "hr")
                    statRow("bolt.circle", "Recuperación más baja", worstRec.map { "\($0)" }, "%")
                }
            }
            .padding(16).background(Theme.wCard).cornerRadius(14).padding(.top, 14)
        }
    }

    private func ringStat(_ ring: WRing, _ label: String) -> some View {
        VStack(spacing: 8) {
            ring
            Text(label).font(Theme.text(13)).foregroundColor(Theme.textPrimary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func runStat(_ icon: String, _ color: Color, _ days: Int, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(color)
                .frame(width: 34, height: 34).background(Circle().fill(color.opacity(0.15)))
            WNumber(text: "\(days) Días", size: 16)
            Text(label).font(Theme.text(11.5)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func statRow(_ icon: String, _ label: String, _ value: String?, _ unit: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14)).foregroundColor(Theme.alertAmber)
                .frame(width: 32, height: 32).overlay(Circle().stroke(Theme.alertAmber.opacity(0.5), lineWidth: 1))
            Text(label).font(Theme.text(15)).foregroundColor(Theme.textPrimary)
            Spacer()
            WNumber(text: value ?? "--", size: 20)
            Text(unit).font(Theme.text(12)).foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 10)
    }

    // MARK: Resumen de actividad

    private func activitySummary(_ s: ProfileStats) -> some View {
        let from = since(actPeriod)
        let list = s.sessions.filter { TimeUtil.dayKey($0.startMillis) >= from && $0.type != Formulas.napType }
        var groups = [String: (Int, Double)]()
        for x in list { let g = groups[x.type] ?? (0, 0); groups[x.type] = (g.0 + 1, g.1 + x.strain) }
        let rows = groups.map { (type: $0.key, count: $0.value.0, avg: $0.value.1 / Double(max($0.value.0, 1))) }
            .sorted { $0.count > $1.count }
        let maxCount = max(rows.first?.count ?? 1, 1)
        let shown = showAllActs ? rows : Array(rows.prefix(3))
        return VStack(alignment: .leading, spacing: 0) {
            Text("Resumen de actividad").font(Theme.text(22)).foregroundColor(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 0) {
                Segmented(labels: ["1M", "3M", "Todo el tiempo"], selected: $actPeriod).padding(.top, -20)
                WNumber(text: "\(list.count)x", size: 28).padding(.top, 16)
                WTitle(text: "Actividades totales", size: 12, color: Theme.textSecondary)
                HStack {
                    WTitle(text: "Actividad | Esfuerzo prom.", size: 11.5, color: Theme.textSecondary)
                    Spacer()
                    WTitle(text: "Total", size: 11.5, color: Theme.textSecondary)
                }
                .padding(.top, 18)
                if rows.isEmpty {
                    WBody(text: "Aún no hay actividades en este periodo.", size: 14).padding(.vertical, 14)
                }
                ForEach(shown.indices, id: \.self) { i in
                    let r = shown[i]
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: WText.sportIcon(r.type)).font(.system(size: 14)).foregroundColor(Theme.textSecondary)
                            WTitle(text: r.type, size: 13)
                            WNumber(text: Fmt.comma(r.avg), size: 14, color: Theme.textSecondary)
                            Spacer()
                            WNumber(text: "\(r.count)x", size: 16, color: Theme.strainBlue)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(Theme.strainBlue).frame(width: Double(g.size.width) * Double(r.count) / Double(maxCount))
                            }
                        }
                        .frame(height: 5)
                    }
                    .padding(.vertical, 12)
                }
                if rows.count > 3 {
                    Button(action: { withAnimation(.easeOut(duration: 0.2)) { showAllActs.toggle() } }) {
                        HStack(spacing: 6) {
                            Image(systemName: showAllActs ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .semibold))
                            WTitle(text: showAllActs ? "Mostrar menos" : "Mostrar todo", size: 12.5)
                        }
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(Color.white.opacity(0.08)).cornerRadius(8)
                    }
                    .buttonStyle(.plain).padding(.top, 6)
                }
            }
            .padding(16).background(Theme.wCard).cornerRadius(14).padding(.top, 14)
        }
    }
}

// MARK: - Niveles

struct LevelsView: View {
    @State private var stats: ProfileStats? = nil

    var body: some View {
        WScreen {
            DetailHeader(title: "Niveles")
            if let s = stats {
                let lvl = Levels.level(s.recoveries)
                let cur = Levels.list[lvl - 1]
                let next = lvl < Levels.list.count ? Levels.list[lvl] : nil
                VStack(spacing: 8) {
                    LevelBadge(level: lvl, size: 110)
                    WTitle(text: cur.tier, size: 13, color: Theme.textSecondary)
                    WTitle(text: "Nivel \(lvl)", size: 22)
                    if let n = next {
                        let span = Double(n.need - cur.need)
                        let done = Double(s.recoveries - cur.need)
                        ProgressView(value: min(max(done / max(span, 1), 0), 1)).tint(Theme.wRecoveryHigh).frame(width: 220).padding(.top, 6)
                        Text("\(n.need - s.recoveries) recuperaciones más a Nivel \(n.level)").font(Theme.text(13)).foregroundColor(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity).padding(.top, 16)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 22) {
                    ForEach(Levels.list.indices, id: \.self) { i in
                        let l = Levels.list[i]
                        VStack(spacing: 4) {
                            LevelBadge(level: l.level, size: 46, locked: l.level > lvl)
                            WTitle(text: l.tier, size: 10.5, color: Theme.textSecondary).multilineTextAlignment(.center)
                            WTitle(text: "Nivel \(l.level)", size: 13, color: l.level > lvl ? Theme.textSecondary : Theme.textPrimary)
                            Text(l.need == 0 ? "La membresía comienza" : "\(l.need) Recuperaciones").font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                .padding(.top, 30)
                WBody(text: "Cada mañana con recuperación cuenta (también los días importados de WHOOP).", size: 13).padding(.top, 24)
            } else {
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if stats == nil { HomeStore.shared.run({ ProfileStats.load() }, completion: { stats = $0 }) } }
    }
}

// MARK: - Racha de días

struct StreakView: View {
    @State private var stats: ProfileStats? = nil
    private static let milestones = [3, 7, 14, 21, 30, 50, 75, 100, 150, 200, 250, 300, 365, 500, 730, 1000]
    private let monthsShort = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"]

    var body: some View {
        WScreen {
            DetailHeader(title: "Racha de días")
            if let s = stats {
                VStack(spacing: 6) {
                    ZStack {
                        Image(systemName: "flame.fill").font(.system(size: 150))
                            .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFF6A3D), Color(hex: 0xE0123A)], startPoint: .top, endPoint: .bottom))
                        WNumber(text: "\(s.streak)", size: 96).offset(y: 40)
                    }
                    .padding(.top, 10)
                    Text("Racha de días").font(Theme.text(22, .semibold)).foregroundColor(Theme.textPrimary).padding(.top, 20)
                    Text("Usa tu pulsera a diario").font(Theme.text(14)).foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                HStack {
                    stat(s.streakStart.map { "\(Day.dayOfMonth($0)) \(monthsShort[Day.month($0) - 1]), \(TimeUtil.parts(Day.start($0)).year)" } ?? "--", "Racha iniciada")
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 34)
                    stat("\(s.streakMax)", "Racha máxima")
                }
                .padding(.top, 24)
                VStack(alignment: .leading, spacing: 12) {
                    WTitle(text: "Esta semana", size: 13)
                    HStack {
                        ForEach(0..<7, id: \.self) { i in
                            let d = weekDay(i)
                            VStack(spacing: 8) {
                                WTitle(text: ["Lun", "Mar", "Mié", "Jue", "Vie", "Sáb", "Dom"][i], size: 11,
                                       color: d == Day.today() ? Theme.textPrimary : Theme.textSecondary)
                                if s.wornDays.contains(d) {
                                    Image(systemName: "flame.fill").font(.system(size: 18)).foregroundColor(Color(hex: 0xFF4D4D)).frame(width: 30, height: 30)
                                } else {
                                    Circle().stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(width: 30, height: 30)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(16).background(Theme.wCard).cornerRadius(14).padding(.top, 24)
                milestone(s.streak).padding(.top, 12)
            } else {
                ScreenLoading()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if stats == nil { HomeStore.shared.run({ ProfileStats.load() }, completion: { stats = $0 }) } }
    }

    private func weekDay(_ i: Int) -> String {
        let today = Day.today()
        return Day.add(today, i - Day.weekdayIndex(today))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            WNumber(text: value, size: 17)
            Text(label).font(Theme.text(12)).foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func milestone(_ streak: Int) -> some View {
        let prev = StreakView.milestones.last { $0 <= streak } ?? 0
        let next = StreakView.milestones.first { $0 > streak } ?? (streak + 100)
        let frac = Double(streak - prev) / Double(max(next - prev, 1))
        return HStack(spacing: 14) {
            badge(prev, on: true)
            VStack(spacing: 6) {
                WNumber(text: "\(next - streak) días más", size: 14)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Color(hex: 0xFF4D4D)).frame(width: Double(g.size.width) * frac)
                    }
                }
                .frame(height: 4)
                Text("para desbloquear tu próximo hito").font(Theme.text(12)).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
            }
            badge(next, on: false)
        }
        .padding(16).background(Theme.wCard).cornerRadius(14)
    }

    private func badge(_ n: Int, on: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "flame.fill").font(.system(size: 28)).foregroundColor(on ? Color(hex: 0xFF4D4D) : Color.white.opacity(0.3))
                .frame(width: 58, height: 58).background(Circle().fill(Color.black.opacity(0.4)))
            WNumber(text: "\(n)", size: 24, color: on ? Theme.textPrimary : Theme.textSecondary)
        }
    }
}

// MARK: - Configuración (rueda del Perfil)

struct ConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showWhoop = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.wBackground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack {
                            WTitle(text: "Configuración", size: 15)
                            HStack {
                                Button(action: { dismiss() }) {
                                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Cerrar")
                                Spacer()
                            }
                        }
                        WTitle(text: "Cuenta y configuración", size: 13, color: Theme.textSecondary).padding(.top, 14)
                        NavigationLink(destination: ProfileView().toolbar(.hidden, for: .navigationBar)) { row("person.crop.circle", "Mi cuenta (Sobre mí)") }
                            .buttonStyle(.plain)
                        Button(action: { showWhoop = true }) { row("applewatch.side.right", "Configuración del dispositivo") }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showWhoop) { WhoopView() }
    }

    private func row(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundColor(Theme.textSecondary).frame(width: 26)
            WTitle(text: title, size: 14)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16).frame(height: 56)
        .background(Theme.wCard).cornerRadius(12)
    }
}
