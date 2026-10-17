import Foundation
import SwiftUI

// MARK: - Pestaña Comunidad

/// Comunidad como la de WHOOP: tus equipos, crear uno o unirte con un código.
struct CommunityView: View {
    @State private var path = [CTeam]()
    @State private var configured = CommunityConfig.isConfigured
    @State private var profile: CProfile? = nil
    @State private var teams = [CTeam]()
    @State private var loading = true
    @State private var error = ""
    @State private var askCreate = false
    @State private var askJoin = false
    @State private var newName = ""
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        NavigationStack(path: $path) {
            WScreen {
                HStack {
                    Text("Comunidad").font(Theme.text(30, .semibold)).foregroundColor(Theme.textPrimary)
                    Spacer()
                }
                .padding(.top, 14)
                if !configured {
                    ServerSetupCard { configured = CommunityConfig.isConfigured; load() }.padding(.top, 18)
                } else if loading {
                    ProgressView().tint(Theme.textSecondary).frame(maxWidth: .infinity).padding(.top, 80)
                } else if profile == nil || profile!.name.isEmpty {
                    ProfileSetupCard(initial: profile) { p in profile = p; load() }.padding(.top, 18)
                } else {
                    teamsList
                }
                if !error.isEmpty {
                    WBody(text: error, size: 14, color: Theme.alertAmber).padding(.top, 14)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: CTeam.self) { t in
                TeamView(team: t, me: profile?.id ?? "") { load() }
            }
            .onAppear { load() }
            .refreshable { load() }
            .alert("Crear equipo", isPresented: $askCreate) {
                TextField("Nombre del equipo", text: $newName)
                Button("Cancelar", role: .cancel) {}
                Button("Crear") { create() }
            } message: { Text("Luego compartes el código con tus amigos para que se unan.") }
            .alert("Unirme a un equipo", isPresented: $askJoin) {
                TextField("Código (6 letras)", text: $code).textInputAutocapitalization(.characters)
                Button("Cancelar", role: .cancel) {}
                Button("Unirme") { join() }
            } message: { Text("Pide el código a quien creó el equipo.") }
        }
    }

    private var teamsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            WTitle(text: "Mis equipos", color: Theme.textSecondary).padding(.top, 22)
            if teams.isEmpty {
                WBody(text: "Aún no estás en ningún equipo. Crea uno y comparte el código, o únete con el código de un amigo. Solo veréis los datos de la gente de vuestros equipos.", size: 15)
            }
            ForEach(teams) { t in
                Button(action: { path.append(t) }) {
                    HStack(spacing: 14) {
                        TeamBadge(name: t.name, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            WTitle(text: t.name, size: 17)
                            Text("Código \(t.inviteCode)").font(Theme.text(13)).foregroundColor(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textSecondary)
                    }
                    .padding(16).background(Theme.wCard).cornerRadius(14)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                bigButton("Crear equipo", "plus") { newName = ""; askCreate = true }
                bigButton("Unirme con código", "person.badge.plus") { code = ""; askJoin = true }
            }
            .padding(.top, 6)
            if busy { ProgressView().tint(Theme.textSecondary).frame(maxWidth: .infinity) }
            WBody(text: "Tú apareces como \(profile?.name ?? "") (@\(profile?.username ?? "")). Lo que compartes: esfuerzo, actividades y calorías, recuperación con VFC y FC en reposo, y horas y calificación del sueño.", size: 13)
                .padding(.top, 10)
            Button("Cambiar mi nombre") { profile?.name = "" }
                .font(Theme.text(14)).foregroundColor(Theme.strainBlue)
        }
    }

    private func bigButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        return Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                WTitle(text: title, size: 13.5)
            }
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(Theme.wRow).cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private func load() {
        guard CommunityConfig.isConfigured else { loading = false; return }
        // Sin sesión todavía: no se crea la cuenta hasta que la persona escriba su nombre
        if !CommunityAPI.hasSession { loading = false; profile = nil; return }
        Task {
            do {
                let p = try await CommunityAPI.shared.myProfile()
                let t = try await CommunityAPI.shared.myTeams()
                profile = p; teams = t; error = ""
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func create() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return }
        busy = true
        Task {
            do {
                let t = try await CommunityAPI.shared.createTeam(String(n.prefix(40)))
                teams.append(t); error = ""
                path.append(t)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func join() {
        let c = code.trimmingCharacters(in: .whitespaces)
        if c.isEmpty { return }
        busy = true
        Task {
            do {
                let t = try await CommunityAPI.shared.joinTeam(c)
                if !teams.contains(where: { $0.id == t.id }) { teams.append(t) }
                error = ""
                path.append(t)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// Solo si la app no trae ya los datos del servidor: pegar la dirección y la clave pública de Supabase.
struct ServerSetupCard: View {
    let onSave: () -> Void
    @State private var url = CommunityConfig.url
    @State private var key = CommunityConfig.key
    var body: some View {
        WCard {
            WTitle(text: "Conectar con el servidor")
            WBody(text: "Pega la Project URL y la clave anon/publishable de tu proyecto de Supabase.", size: 14).padding(.top, 8)
            TextField("https://xxxx.supabase.co", text: $url)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.wRow).cornerRadius(10).padding(.top, 12)
            TextField("Clave pública", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.wRow).cornerRadius(10).padding(.top, 8)
            Button(action: { CommunityConfig.set(url: url, key: key); onSave() }) {
                WTitle(text: "Guardar", color: Theme.onAccent).frame(maxWidth: .infinity).frame(height: 46)
                    .background(Theme.recoveryGreen).cornerRadius(12)
            }
            .padding(.top, 12)
        }
        .foregroundColor(Theme.textPrimary)
    }
}

/// Primera vez: tu nombre y tu @usuario (es lo que ven tus amigos).
struct ProfileSetupCard: View {
    let initial: CProfile?
    let onSaved: (CProfile) -> Void
    @State private var name = ""
    @State private var user = ""
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        WCard {
            WTitle(text: "¿Cómo te verán tus amigos?")
            TextField("Nombre y apellido", text: $name)
                .padding(12).background(Theme.wRow).cornerRadius(10).padding(.top, 14)
            TextField("Usuario (sin @)", text: $user)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(Theme.wRow).cornerRadius(10).padding(.top, 8)
            if !error.isEmpty { WBody(text: error, size: 13, color: Theme.alertAmber).padding(.top, 8) }
            Button(action: save) {
                Group {
                    if busy { ProgressView().tint(Theme.onAccent) } else { WTitle(text: "Continuar", color: Theme.onAccent) }
                }
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(Theme.recoveryGreen).cornerRadius(12)
            }
            .padding(.top, 12)
            WBody(text: "No hace falta correo ni contraseña: tu móvil entra con una cuenta anónima. Si borras la app, pierdes el acceso a tus equipos (podrás volver a unirte con el código).", size: 12)
                .padding(.top, 10)
        }
        .foregroundColor(Theme.textPrimary)
        .onAppear {
            name = initial?.name ?? ""
            user = initial?.username ?? ""
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let u = user.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "").replacingOccurrences(of: " ", with: "")
        if n.count < 2 || u.count < 2 { error = "Escribe tu nombre y un usuario."; return }
        busy = true
        Task {
            do {
                try await CommunityAPI.shared.saveProfile(name: String(n.prefix(40)), username: String(u.prefix(30)))
                let id = try await CommunityAPI.shared.userId()
                onSaved(CProfile(id: id, name: n, username: u))
                HomeStore.shared.invalidate()   // así se suben ya tus datos de hoy
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct TeamBadge: View {
    let name: String
    var size: Double = 48
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(Theme.number(size * 0.48)).foregroundColor(Theme.textPrimary)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [Theme.logoBlue, Theme.logoGreen], startPoint: .bottomLeading, endPoint: .topTrailing))
            .clipShape(Circle())
    }
}

/// Avatar con iniciales y, opcionalmente, un anillo de progreso alrededor.
struct MemberAvatar: View {
    let name: String
    var size: Double = 46
    var progress: Double? = nil
    var color: Color = Theme.strainBlue
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
        return ZStack {
            if let p = progress {
                Circle().stroke(Theme.wTrack, lineWidth: 3)
                Circle().trim(from: 0, to: min(max(p, 0), 1)).stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            Text(initials.isEmpty ? "?" : initials).font(Theme.number(size * 0.34)).foregroundColor(Theme.textPrimary)
                .frame(width: size - 10, height: size - 10).background(Color(hex: 0x4A545A)).clipShape(Circle())
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Equipo

/// Todo lo de un equipo, cargado de una vez (miembros, perfiles y datos de las últimas 9 semanas).
@MainActor
final class TeamModel: ObservableObject {
    let team: CTeam
    @Published var members = [CMember]()
    @Published var profiles = [String: CProfile]()
    @Published var stats = [CDayStat]()
    @Published var messages = [CMessage]()
    @Published var error = ""
    @Published var loaded = false
    private var lastId: Int64? = nil

    init(team: CTeam) { self.team = team }

    var fromDate: String {
        let today = Day.today()
        let monday = Day.add(today, -Day.weekdayIndex(today))
        let nineWeeks = Day.add(monday, -63)
        let monthStart = String(today.prefix(8)) + "01"
        return min(nineWeeks, monthStart)
    }

    func load() async {
        do {
            let m = try await CommunityAPI.shared.members(team.id)
            let ids = m.map { $0.userId }
            let p = try await CommunityAPI.shared.profiles(ids)
            let s = try await CommunityAPI.shared.stats(ids, from: fromDate, to: Day.today())
            members = m
            var byId = [String: CProfile]()
            for x in p { byId[x.id] = x }
            profiles = byId
            stats = s
            error = ""
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    func pollMessages() async {
        do {
            let new = try await CommunityAPI.shared.messages(team.id, after: lastId)
            if lastId == nil { messages = new } else { messages.append(contentsOf: new) }
            if let l = messages.last { lastId = l.id } else if lastId == nil { lastId = 0 }
        } catch { self.error = error.localizedDescription }
    }

    func send(_ text: String) async {
        do {
            try await CommunityAPI.shared.send(team.id, text)
            await pollMessages()
        } catch { self.error = error.localizedDescription }
    }

    func name(_ id: String) -> String { return profiles[id]?.name ?? "Miembro" }
    func username(_ id: String) -> String { return profiles[id]?.username ?? "" }
}

enum TeamTab: String, CaseIterable { case info = "Información", chat = "Chat", strain = "Esfuerzo", recovery = "Recuperación", sleep = "Sueño" }

struct TeamView: View {
    let team: CTeam
    let me: String
    let onLeave: () -> Void
    @StateObject private var model: TeamModel
    @State private var tab = TeamTab.info
    @State private var confirmLeave = false
    @Environment(\.dismiss) private var dismiss
    private let ticker = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var ticks = 0

    init(team: CTeam, me: String, onLeave: @escaping () -> Void) {
        self.team = team
        self.me = me
        self.onLeave = onLeave
        _model = StateObject(wrappedValue: TeamModel(team: team))
    }

    var body: some View {
        ZStack {
            Theme.wBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                DetailHeader(title: team.name, trailing: AnyView(
                    Menu {
                        ShareLink(item: inviteText(team)) { Label("Compartir invitación", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive, action: { confirmLeave = true }) { Label("Salir del equipo", systemImage: "rectangle.portrait.and.arrow.right") }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundColor(Theme.textPrimary).frame(width: 44, height: 44)
                    })).padding(.horizontal, 16)
                tabStrip
                Group {
                    switch tab {
                    case .info: TeamInfoView(model: model, me: me)
                    case .chat: TeamChatView(model: model, me: me)
                    case .strain: LeaderboardView(model: model, kind: .strain)
                    case .recovery: LeaderboardView(model: model, kind: .recovery)
                    case .sleep: LeaderboardView(model: model, kind: .sleep)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load(); await model.pollMessages() }
        .onReceive(ticker) { _ in
            ticks += 1
            if tab == .chat { Task { await model.pollMessages() } }
            if ticks % 12 == 0 { Task { await model.load() } }
        }
        .alert("¿Salir de \(team.name)?", isPresented: $confirmLeave) {
            Button("Salir", role: .destructive) {
                Task {
                    try? await CommunityAPI.shared.leaveTeam(team.id)
                    onLeave()
                    dismiss()
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Dejarás de ver a sus miembros y ellos a ti. Puedes volver con el código.") }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(TeamTab.allCases, id: \.self) { t in
                    Button(action: { tab = t; if t == .chat { Task { await model.pollMessages() } } }) {
                        VStack(spacing: 6) {
                            Text(t.rawValue.uppercased()).font(Theme.number(13)).tracking(13 * 0.08)
                                .foregroundColor(tab == t ? Theme.textPrimary : Theme.textSecondary)
                            Rectangle().fill(tab == t ? Theme.textPrimary : Color.clear).frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 6).padding(.bottom, 4)
    }
}

func inviteText(_ t: CTeam) -> String {
    return "Únete a mi equipo «\(t.name)» en PulseApp: abre PulseApp → Comunidad → Unirme con código y escribe \(t.inviteCode)"
}

// MARK: Información

struct TeamInfoView: View {
    @ObservedObject var model: TeamModel
    let me: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    TeamBadge(name: model.team.name, size: 64)
                    WTitle(text: model.team.name, size: 28)
                }
                .padding(.top, 20)
                WTitle(text: "Uso compartido de datos", size: 12.5).padding(.top, 28)
                Text("Esfuerzo, recuperación y sueño").font(Theme.text(15)).foregroundColor(Theme.textSecondary).padding(.top, 6)
                HStack {
                    WTitle(text: "\(model.members.count) miembros", size: 12.5)
                    Spacer()
                    WTitle(text: "Código \(model.team.inviteCode)", size: 12.5, color: Theme.textSecondary)
                }
                .padding(.top, 26)
                ShareLink(item: inviteText(model.team)) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.3.fill").font(.system(size: 15)).foregroundColor(Theme.alertRed)
                            .frame(width: 40, height: 40).overlay(Circle().stroke(Theme.alertRed, lineWidth: 2))
                        WTitle(text: "Agregar miembros", size: 14, color: Theme.alertRed)
                    }
                }
                .padding(.top, 16)
                ForEach(model.members, id: \.userId) { m in
                    HStack(spacing: 14) {
                        ZStack(alignment: .bottom) {
                            MemberAvatar(name: model.name(m.userId), size: 40)
                            if m.role == "admin" {
                                Text("ADMIN").font(Theme.number(8)).foregroundColor(Theme.background)
                                    .padding(.horizontal, 3).background(Theme.textPrimary).cornerRadius(2).offset(y: 6)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            WTitle(text: model.name(m.userId) + (m.userId == me ? " (tú)" : ""), size: 13.5)
                            Text("@" + model.username(m.userId)).font(Theme.text(12)).foregroundColor(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.top, 16)
                }
                if !model.error.isEmpty { WBody(text: model.error, size: 13, color: Theme.alertAmber).padding(.top, 16) }
            }
            .padding(.horizontal, 16).padding(.bottom, 120)
        }
    }
}

// MARK: Chat

struct TeamChatView: View {
    @ObservedObject var model: TeamModel
    let me: String
    @State private var text = ""

    /// Una entrada del chat: mensaje de alguien o el aviso de los ganadores del lunes a las 17:00.
    struct Entry: Identifiable {
        let id: String
        let time: Int64
        let userId: String?
        let body: String
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(entries) { e in row(e).id(e.id) }
                        Color.clear.frame(height: 4).id("end")
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.messages.count) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            HStack(spacing: 10) {
                TextField("Decir algo", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Theme.wRow).cornerRadius(10)
                    .foregroundColor(Theme.textPrimary)
                Button(action: send) {
                    Image(systemName: "paperplane.fill").font(.system(size: 18)).foregroundColor(text.isEmpty ? Theme.textSecondary : Theme.recoveryGreen)
                        .frame(width: 44, height: 44)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 96)
            .background(Theme.wBgBottom)
        }
    }

    private var entries: [Entry] {
        var out = model.messages.map { Entry(id: "m\($0.id)", time: serverMillis($0.createdAt), userId: $0.userId, body: $0.body) }
        out.append(contentsOf: WeeklyWinners.entries(model))
        return out.sorted { $0.time < $1.time }
    }

    private func row(_ e: Entry) -> some View {
        let isBot = e.userId == nil
        let name = isBot ? "PulseApp" : model.name(e.userId!)
        let user = isBot ? "@pulseapp" : "@" + model.username(e.userId!)
        let p = TimeUtil.parts(e.time)
        let when = TimeUtil.dayKey(e.time) == Day.today() ? Fmt.clock(e.time) : String(format: "%d/%d %02d:%02d", p.day, p.month, p.hour, p.minute)
        return HStack(alignment: .top, spacing: 12) {
            if isBot { TeamBadge(name: "P", size: 36) } else { MemberAvatar(name: name, size: 36) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    WTitle(text: name, size: 12.5)
                    Text(user).font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                    if e.userId == me { Text("· tú").font(Theme.text(11)).foregroundColor(Theme.textSecondary) }
                }
                Text(when).font(Theme.text(11)).foregroundColor(Theme.textSecondary)
                Text(e.body).font(Theme.text(16)).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        text = ""
        Task { await model.send(String(t.prefix(1000))) }
    }
}

/// Cada lunes a las 17:00: campeones de la semana anterior (lun–dom) en esfuerzo, recuperación y sueño (medias).
@MainActor
enum WeeklyWinners {
    static func entries(_ m: TeamModel) -> [TeamChatView.Entry] {
        let now = TimeUtil.nowMillis()
        let today = Day.today()
        let thisMonday = Day.add(today, -Day.weekdayIndex(today))
        let created = serverMillis(m.team.createdAt)
        var out = [TeamChatView.Entry]()
        for k in 1...8 {
            let weekStart = Day.add(thisMonday, -7 * k)
            let weekEnd = Day.add(weekStart, 6)
            let post = TimeUtil.setTime(Day.start(Day.add(weekStart, 7)) + 12 * 3_600_000, hour: 17, minute: 0)
            if post > now || post < created { continue }
            let rows = m.stats.filter { $0.date >= weekStart && $0.date <= weekEnd }
            func best(_ pick: (CDayStat) -> Double?) -> (String, Double)? {
                var sums = [String: (Double, Int)]()
                for r in rows { if let v = pick(r) { let s = sums[r.userId] ?? (0, 0); sums[r.userId] = (s.0 + v, s.1 + 1) } }
                return sums.map { ($0.key, $0.value.0 / Double($0.value.1)) }.max { $0.1 < $1.1 }
            }
            var lines = [String]()
            if let b = best({ $0.strain }) { lines.append("@\(m.username(b.0)) — Esfuerzo prom. de \(Fmt.comma(b.1)) 💪") }
            if let b = best({ $0.recovery.map { Double($0) } }) { lines.append("@\(m.username(b.0)) — Recuperación prom. del \(Int(b.1.rounded()))% 🎯") }
            if let b = best({ $0.sleepScore.map { Double($0) } }) { lines.append("@\(m.username(b.0)) — Calificación del sueño prom. del \(Int(b.1.rounded()))% 😴") }
            if lines.isEmpty { continue }
            let range = "\(Day.dayOfMonth(weekStart))/\(Day.month(weekStart)) - \(Day.dayOfMonth(weekEnd))/\(Day.month(weekEnd))"
            out.append(TeamChatView.Entry(id: "w\(weekStart)", time: post, userId: nil,
                                          body: "👑 ¡Felicidades a los campeones de la semana pasada! (\(range))\n\n" + lines.joined(separator: "\n")))
        }
        return out
    }
}

// MARK: Clasificaciones

enum BoardKind { case strain, recovery, sleep }
enum BoardRange: String, CaseIterable { case day = "Diario", week = "Lun - Dom", month = "Mensual" }

struct LeaderboardView: View {
    @ObservedObject var model: TeamModel
    let kind: BoardKind
    @State private var range = BoardRange.day

    struct Line {
        let userId: String
        let value: Double?
        let sub: [String]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(BoardRange.allCases, id: \.self) { r in
                        Button(action: { range = r }) {
                            Text(r.rawValue.uppercased()).font(Theme.number(13)).tracking(1)
                                .foregroundColor(range == r ? Theme.textPrimary : Theme.textSecondary)
                                .frame(maxWidth: .infinity).frame(height: 38)
                                .overlay(RoundedRectangle(cornerRadius: 19).stroke(range == r ? Theme.textPrimary : Color.clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.textSecondary.opacity(0.5), lineWidth: 1))
                .padding(.top, 16)

                let lines = computeLines()
                let withValue = lines.filter { $0.value != nil }
                let mean: Double? = withValue.isEmpty ? nil : withValue.reduce(0.0) { $0 + $1.value! } / Double(withValue.count)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        WTitle(text: title, size: 12.5, color: color(mean))
                        Text(mean.map { format($0) + " prom." } ?? "Sin datos").font(Theme.text(12)).foregroundColor(color(mean).opacity(0.8))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        WTitle(text: rangeLabel, size: 12.5)
                        Text(updatedText).font(Theme.text(12)).foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.top, 22)

                ForEach(0..<lines.count, id: \.self) { i in
                    let l = lines[i]
                    HStack(alignment: .top, spacing: 14) {
                        MemberAvatar(name: model.name(l.userId), size: 52, progress: l.value.map { progress($0) } ?? 0, color: color(l.value))
                        VStack(alignment: .leading, spacing: 3) {
                            (Text("\(i + 1). \(model.name(l.userId))  ").foregroundColor(Theme.textPrimary)
                             + Text(l.value.map { format($0) } ?? "--").foregroundColor(color(l.value)))
                                .font(Theme.text(16, .semibold))
                            ForEach(0..<l.sub.count, id: \.self) { k in
                                Text(l.sub[k]).font(Theme.text(14.5)).foregroundColor(Theme.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .opacity(l.value == nil ? 0.5 : 1)
                    .padding(.top, 20)
                }
                if !model.loaded { ProgressView().tint(Theme.textSecondary).frame(maxWidth: .infinity).padding(.top, 40) }
                if !model.error.isEmpty { WBody(text: model.error, size: 13, color: Theme.alertAmber).padding(.top, 16) }
            }
            .padding(.horizontal, 16).padding(.bottom, 120)
        }
    }

    private var title: String {
        switch kind {
        case .strain: return range == .day ? "Esfuerzo del día" : "Esfuerzo"
        case .recovery: return "Recuperación"
        case .sleep: return "Calificación del sueño"
        }
    }

    private var rangeLabel: String {
        switch range {
        case .day: return "Hoy"
        case .week: return "Esta semana"
        case .month: return "Este mes"
        }
    }

    private var dateRange: (String, String) {
        let today = Day.today()
        switch range {
        case .day: return (today, today)
        case .week: return (Day.add(today, -Day.weekdayIndex(today)), today)
        case .month: return (String(today.prefix(8)) + "01", today)
        }
    }

    private var updatedText: String {
        let (a, b) = dateRange
        let latest = model.stats.filter { $0.date >= a && $0.date <= b }.compactMap { $0.updatedAt.map { serverMillis($0) } }.max()
        return latest.map { "Última actualización: " + Fmt.clock($0) } ?? ""
    }

    private func value(_ s: CDayStat) -> Double? {
        switch kind {
        case .strain: return s.strain
        case .recovery: return s.recovery.map { Double($0) }
        case .sleep: return s.sleepScore.map { Double($0) }
        }
    }

    private func format(_ v: Double) -> String {
        return kind == .strain ? Fmt.comma(v) : "\(Int(v.rounded()))%"
    }

    private func progress(_ v: Double) -> Double { return kind == .strain ? v / 21 : v / 100 }

    private func color(_ v: Double?) -> Color {
        switch kind {
        case .strain: return Theme.strainBlue
        case .recovery: return v.map { Theme.wRecoveryColor(Int($0.rounded())) } ?? Theme.wRecoveryHigh
        case .sleep: return Theme.wRingSleep
        }
    }

    private func avg(_ v: [Double]) -> Double? { return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    private func computeLines() -> [Line] {
        let (a, b) = dateRange
        var out = [Line]()
        for m in model.members {
            let rows = model.stats.filter { $0.userId == m.userId && $0.date >= a && $0.date <= b }
            let vals = rows.compactMap { value($0) }
            let v = avg(vals)
            var sub = [String]()
            switch kind {
            case .strain:
                if range == .day, let r = rows.first {
                    let acts = (r.activities ?? []).map { "\($0.type) \(Fmt.comma($0.strain))" }
                    if !acts.isEmpty { sub.append(acts.joined(separator: ", ")) }
                    if let k = r.kcal { sub.append("\(Fmt.thousands(Int64(k))) Calorías") }
                } else {
                    let n = rows.reduce(0) { $0 + ($1.activities?.count ?? 0) }
                    if n > 0 { sub.append("\(n) actividades") }
                    if let k = avg(rows.compactMap { $0.kcal.map { Double($0) } }) { sub.append("\(Fmt.thousands(Int64(k.rounded()))) Calorías de media") }
                }
            case .recovery:
                let h = avg(rows.compactMap { $0.hrv.map { Double($0) } }), r = avg(rows.compactMap { $0.rhr.map { Double($0) } })
                if h != nil || r != nil {
                    sub.append("VFC: \(h.map { "\(Int($0.rounded()))" } ?? "--"), FCREP: \(r.map { "\(Int($0.rounded()))" } ?? "--")")
                }
            case .sleep:
                if let s = avg(rows.compactMap { $0.sleepMinutes.map { Double($0) } }) {
                    sub.append("\(Fmt.hm(Int(s.rounded()))) horas de sueño" + (range == .day ? "" : " de media"))
                }
            }
            out.append(Line(userId: m.userId, value: v, sub: sub))
        }
        return out.sorted { ($0.value ?? -1) > ($1.value ?? -1) }
    }
}
