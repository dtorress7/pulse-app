import Foundation

/// Comunidad (equipos, chat y clasificaciones entre amigos) sobre Supabase, sin librerías: REST con URLSession.
/// Cada móvil entra con una cuenta anónima (no hace falta correo); los permisos del servidor (supabase/comunidad.sql)
/// hacen que cada uno solo vea a la gente de sus equipos.
enum CommunityConfig {
    /// Datos del proyecto de Supabase (públicos a propósito: la seguridad la ponen los permisos del servidor).
    static let builtInUrl = "https://neqnpiscmaslyymrmqws.supabase.co"
    static let builtInKey = "sb_publishable_vZHIpB4DQuFGHyl2jiS4lg_R0HppQvq"

    private static let kUrl = "pulseapp_sb_url", kKey = "pulseapp_sb_key"
    static var url: String {
        let v = UserDefaults.standard.string(forKey: kUrl) ?? ""
        // Se acepta también la "API URL" con /rest/v1/ al final (la que enseña Supabase)
        var u = (v.isEmpty ? builtInUrl : v).trimmingCharacters(in: CharacterSet(charactersIn: "/ \n"))
        if u.hasSuffix("/rest/v1") { u = String(u.dropLast("/rest/v1".count)) }
        return u.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static var key: String {
        let v = UserDefaults.standard.string(forKey: kKey) ?? ""
        return (v.isEmpty ? builtInKey : v).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var isConfigured: Bool { return url.hasPrefix("https://") && key.count > 20 }
    static func set(url: String, key: String) {
        UserDefaults.standard.set(url, forKey: kUrl)
        UserDefaults.standard.set(key, forKey: kKey)
    }
}

// MARK: - Modelos (las columnas del servidor en snake_case)

struct CTeam: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let inviteCode: String
    let createdBy: String
    let createdAt: String
}

struct CMember: Codable {
    let teamId: String
    let userId: String
    let role: String
    let joinedAt: String
}

struct CProfile: Codable {
    let id: String
    var name: String
    var username: String
}

struct CActivity: Codable {
    let type: String
    let strain: Double
}

struct CDayStat: Codable {
    let userId: String
    let date: String
    var strain: Double?
    var kcal: Int?
    var activities: [CActivity]?
    var recovery: Int?
    var hrv: Int?
    var rhr: Int?
    var sleepMinutes: Int?
    var sleepScore: Int?
    var updatedAt: String?
}

struct CMessage: Codable, Identifiable {
    let id: Int64
    let teamId: String
    let userId: String
    let body: String
    let createdAt: String
}

struct CommunityError: LocalizedError {
    let message: String
    var errorDescription: String? { return message }
}

/// Hora del servidor ("2026-10-17T16:02:31.123456+00:00") → ms unix.
func serverMillis(_ s: String) -> Int64 {
    let b = Array(s.utf8)
    if b.count < 19 { return 0 }
    func n(_ a: Int, _ len: Int) -> Int {
        var v = 0
        for i in a..<(a + len) { v = v * 10 + Int(b[i] &- 48) }
        return v
    }
    var secs = TimeUtil.daysFromCivil(n(0, 4), n(5, 2), n(8, 2)) * 86400 + Int64(n(11, 2) * 3600 + n(14, 2) * 60 + n(17, 2))
    // Desplazamiento al final: "+00:00" / "-05:00" / "Z"
    if let plus = s.lastIndex(where: { $0 == "+" || $0 == "-" }), s.distance(from: s.startIndex, to: plus) > 18 {
        let off = s[s.index(after: plus)...].split(separator: ":")
        if off.count >= 2, let h = Int(off[0]), let m = Int(off[1]) {
            let sign: Int64 = s[plus] == "+" ? 1 : -1
            secs -= sign * Int64(h * 3600 + m * 60)
        }
    }
    return secs * 1000
}

// MARK: - Cliente

actor CommunityAPI {
    static let shared = CommunityAPI()

    private struct Session: Codable {
        var access: String
        var refresh: String
        var expiresAt: Double
        var userId: String
    }

    private static let kSession = "pulseapp_sb_session"
    private var session: Session? = {
        guard let d = UserDefaults.standard.data(forKey: kSession) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: d)
    }()

    static var hasSession: Bool { return UserDefaults.standard.data(forKey: kSession) != nil }

    private func save(_ s: Session) {
        session = s
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: CommunityAPI.kSession) }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // ---------- Sesión ----------

    func userId() async throws -> String {
        _ = try await token()
        return session!.userId
    }

    /// Token válido: renueva si caduca y, si nunca se ha entrado, crea la cuenta anónima.
    private func token() async throws -> String {
        guard CommunityConfig.isConfigured else { throw CommunityError(message: "Comunidad sin configurar") }
        if let s = session {
            if Date().timeIntervalSince1970 < s.expiresAt - 60 { return s.access }
            let json = try await raw("POST", "/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": s.refresh], auth: nil)
            try storeAuth(json)
            return session!.access
        }
        let json = try await raw("POST", "/auth/v1/signup", body: ["data": [String: String]()], auth: nil)
        try storeAuth(json)
        return session!.access
    }

    private func storeAuth(_ data: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String, let refresh = o["refresh_token"] as? String,
              let user = o["user"] as? [String: Any], let id = user["id"] as? String else {
            throw CommunityError(message: "No se pudo iniciar sesión en Comunidad. ¿Están activados los accesos anónimos en Supabase?")
        }
        let expiresIn = (o["expires_in"] as? Double) ?? 3600
        save(Session(access: access, refresh: refresh, expiresAt: Date().timeIntervalSince1970 + expiresIn, userId: id))
    }

    // ---------- HTTP ----------

    private func raw(_ method: String, _ path: String, body: Any? = nil, auth: String?, prefer: String? = nil) async throws -> Data {
        guard let url = URL(string: CommunityConfig.url + path) else { throw CommunityError(message: "Dirección del servidor no válida") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(CommunityConfig.key, forHTTPHeaderField: "apikey")
        if let a = auth { req.setValue("Bearer " + a, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let p = prefer { req.setValue(p, forHTTPHeaderField: "Prefer") }
        if let b = body { req.httpBody = try JSONSerialization.data(withJSONObject: b) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 300 {
            var msg = "Error \(code) del servidor"
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let m = (o["message"] as? String) ?? (o["msg"] as? String) ?? (o["error_description"] as? String) { msg = m }
            }
            throw CommunityError(message: msg)
        }
        return data
    }

    private func rest(_ method: String, _ path: String, body: Any? = nil, prefer: String? = nil) async throws -> Data {
        let t = try await token()
        return try await raw(method, "/rest/v1/" + path, body: body, auth: t, prefer: prefer)
    }

    private func list<T: Decodable>(_ path: String) async throws -> [T] {
        return try decoder.decode([T].self, from: try await rest("GET", path))
    }

    private func nowIso() -> String { return ISO8601DateFormatter().string(from: Date()) }

    // ---------- Perfil ----------

    func myProfile() async throws -> CProfile? {
        let id = try await userId()
        let r: [CProfile] = try await list("profiles?id=eq.\(id)&select=id,name,username")
        return r.first
    }

    func saveProfile(name: String, username: String) async throws {
        let id = try await userId()
        _ = try await rest("POST", "profiles", body: ["id": id, "name": name, "username": username, "updated_at": nowIso()],
                           prefer: "resolution=merge-duplicates,return=minimal")
    }

    // ---------- Equipos ----------

    func myTeams() async throws -> [CTeam] {
        return try await list("teams?select=id,name,invite_code,created_by,created_at&order=created_at.asc")
    }

    func createTeam(_ name: String) async throws -> CTeam {
        return try decoder.decode(CTeam.self, from: try await rest("POST", "rpc/create_team", body: ["p_name": name]))
    }

    func joinTeam(_ code: String) async throws -> CTeam {
        return try decoder.decode(CTeam.self, from: try await rest("POST", "rpc/join_team", body: ["p_code": code]))
    }

    func leaveTeam(_ teamId: String) async throws {
        let id = try await userId()
        _ = try await rest("DELETE", "team_members?team_id=eq.\(teamId)&user_id=eq.\(id)")
    }

    func members(_ teamId: String) async throws -> [CMember] {
        return try await list("team_members?team_id=eq.\(teamId)&select=team_id,user_id,role,joined_at&order=joined_at.asc")
    }

    func profiles(_ ids: [String]) async throws -> [CProfile] {
        if ids.isEmpty { return [] }
        return try await list("profiles?id=in.(\(ids.joined(separator: ",")))&select=id,name,username")
    }

    // ---------- Datos del día ----------

    func stats(_ ids: [String], from: String, to: String) async throws -> [CDayStat] {
        if ids.isEmpty { return [] }
        return try await list("day_stats?user_id=in.(\(ids.joined(separator: ",")))&date=gte.\(from)&date=lte.\(to)&select=*")
    }

    func upload(_ rows: [[String: Any]]) async throws {
        if rows.isEmpty { return }
        let id = try await userId()
        let withUser = rows.map { r -> [String: Any] in
            var x = r
            x["user_id"] = id
            x["updated_at"] = nowIso()
            return x
        }
        _ = try await rest("POST", "day_stats?on_conflict=user_id,date", body: withUser, prefer: "resolution=merge-duplicates,return=minimal")
    }

    // ---------- Chat ----------

    func messages(_ teamId: String, after: Int64?) async throws -> [CMessage] {
        if let a = after {
            return try await list("messages?team_id=eq.\(teamId)&id=gt.\(a)&order=id.asc&select=*")
        }
        let r: [CMessage] = try await list("messages?team_id=eq.\(teamId)&order=id.desc&limit=200&select=*")
        return r.reversed()
    }

    func send(_ teamId: String, _ text: String) async throws {
        let id = try await userId()
        _ = try await rest("POST", "messages", body: ["team_id": teamId, "user_id": id, "body": text], prefer: "return=minimal")
    }
}

// MARK: - Subida de tus datos del día

/// Sube el resumen de hoy y de ayer (esfuerzo, actividades, calorías, recuperación, VFC, FCR, sueño) para que lo vean tus equipos.
/// Solo si ya entraste en Comunidad; como mucho cada 10 min si no ha cambiado nada.
enum CommunitySync {
    private static let kLast = "pulseapp_sb_last_upload"
    private static var running = false
    private static let lock = NSLock()

    static func upload(_ home: HomeData) {
        guard home.isToday, CommunityConfig.isConfigured, CommunityAPI.hasSession else { return }
        let yesterday = Day.add(home.date, -1)
        var rows = [[String: Any]]()
        rows.append(row(home.day, sessions: home.sessions))
        if let y = home.records.first(where: { $0.date == yesterday }) {
            let s = Day.start(yesterday), e = Day.start(home.date)
            rows.append(row(y, sessions: AppStore.shared.allSessions().filter { $0.startMillis >= s && $0.startMillis < e }))
        }
        let sig = rows.map { r in r.keys.sorted().map { "\($0)=\(r[$0]!)" }.joined(separator: ";") }.joined(separator: "|")
        let last = UserDefaults.standard.dictionary(forKey: kLast)
        if let l = last, l["sig"] as? String == sig, let t = l["t"] as? Double, Date().timeIntervalSince1970 - t < 600 { return }
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        Task {
            do {
                try await CommunityAPI.shared.upload(rows)
                UserDefaults.standard.set(["sig": sig, "t": Date().timeIntervalSince1970], forKey: kLast)
            } catch { }
            lock.lock(); running = false; lock.unlock()
        }
    }

    private static func row(_ d: DayRecord, sessions: [ActivitySession]) -> [String: Any] {
        var r: [String: Any] = ["date": d.date]
        r["strain"] = d.strain.map { (($0 * 10).rounded()) / 10 } ?? NSNull()
        r["kcal"] = d.kcal.map { Int($0.rounded()) } ?? NSNull()
        r["activities"] = sessions.sorted { $0.strain > $1.strain }.map { ["type": $0.type, "strain": (($0.strain * 10).rounded()) / 10] }
        r["recovery"] = d.recovery ?? NSNull()
        r["hrv"] = d.hrv.map { Int($0.rounded()) } ?? NSNull()
        r["rhr"] = d.rhr ?? NSNull()
        r["sleep_minutes"] = d.sleepMinutes ?? NSNull()
        r["sleep_score"] = d.sleepScore ?? NSNull()
        return r
    }
}
