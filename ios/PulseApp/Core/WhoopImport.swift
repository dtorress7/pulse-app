import Foundation
import Compression

/// Importa el historial del export de WHOOP (23/10, igual que Android): "my_whoop_data_….zip" o sus CSV sueltos
/// (physiological_cycles.csv, sueño.csv, entrenamientos.csv).
/// - Cada ciclo con noche → fila del día en que te despertaste (noche que termina ese día + esfuerzo de ese ciclo). Hoy no.
/// - Entrenamientos y siestas → actividades; si se solapan con una de PulseApp, manda la de WHOOP.
/// - Lo que se sustituye se copia antes en whoop_import_backup_<fecha>.json (no se pierde nada).
enum WhoopImport {

    private static let keyUntil = "pulseapp_whoop_import_until"

    /// Último día importado de WHOOP ("" = ninguno).
    static func importedUntil() -> String { return UserDefaults.standard.string(forKey: keyUntil) ?? "" }

    struct Result {
        var days = 0, sessions = 0, naps = 0, replacedDays = 0, replacedSessions = 0
        var from: String? = nil, until: String? = nil, backup: String? = nil
        var text: String {
            if days == 0 && sessions == 0 { return "No he encontrado datos de WHOOP. Elige el zip del export o physiological_cycles.csv." }
            var t = "Importado de WHOOP:\n• \(days) días (\(from ?? "") → \(until ?? ""))\n• \(sessions) entrenos y \(naps) siestas"
            if replacedDays + replacedSessions > 0 {
                t += "\n\nSustituidos \(replacedDays) días y \(replacedSessions) actividades de PulseApp (copia en \(backup ?? ""))."
            }
            return t
        }
    }

    /// ¿Estos archivos son del export de WHOOP?
    static func looksLikeWhoop(_ urls: [URL]) -> Bool {
        let names = ["physiological_cycles.csv", "sueño.csv", "sleeps.csv", "entrenamientos.csv", "workouts.csv"]
        return urls.contains { u in
            u.pathExtension.lowercased() == "zip" || names.contains(u.lastPathComponent.lowercased().precomposedStringWithCanonicalMapping)
        }
    }

    // MARK: - Leer archivos

    static func readFiles(_ urls: [URL]) -> [String: String] {
        var out = [String: String]()
        for u in urls {
            guard let data = try? Data(contentsOf: u) else { continue }
            if data.count > 4 && data[0] == 0x50 && data[1] == 0x4B {
                for (name, d) in unzip(data) where name.lowercased().hasSuffix(".csv") {
                    out[key(name)] = String(decoding: d, as: UTF8.self)
                }
            } else {
                out[key(u.lastPathComponent)] = String(decoding: data, as: UTF8.self)
            }
        }
        return out
    }

    private static func key(_ name: String) -> String {
        return (name.components(separatedBy: "/").last ?? name).lowercased().precomposedStringWithCanonicalMapping
    }

    /// Lector de zip mínimo (sin cifrar, guardado o deflate), suficiente para el export de WHOOP.
    static func unzip(_ data: Data) -> [(String, Data)] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { return o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { return o + 3 < b.count ? u16(o) | u16(o + 2) << 16 : 0 }
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 70_000) {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        if eocd < 0 { return [] }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out = [(String, Data)]()
        for _ in 0..<count {
            guard u32(p) == 0x02014b50 else { break }
            let method = u16(p + 10), compSize = u32(p + 20), size = u32(p + 24)
            let nLen = u16(p + 28), eLen = u16(p + 30), cLen = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nLen <= b.count else { break }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nLen)], as: UTF8.self)
            p += 46 + nLen + eLen + cLen
            guard u32(local) == 0x04034b50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compSize <= b.count, size > 0 else { continue }
            let src = Array(b[start..<(start + compSize)])
            if method == 0 {
                out.append((name, Data(src)))
            } else if method == 8 {
                var dst = [UInt8](repeating: 0, count: size)
                let n = src.withUnsafeBufferPointer { sp in
                    dst.withUnsafeMutableBufferPointer { dp in
                        compression_decode_buffer(dp.baseAddress!, size, sp.baseAddress!, compSize, nil, COMPRESSION_ZLIB)
                    }
                }
                if n > 0 { out.append((name, Data(dst.prefix(n)))) }
            }
        }
        return out
    }

    // MARK: - CSV

    static func parseCsv(_ text: String) -> [[String: String]] {
        var rows = [[String]]()
        var row = [String]()
        var cur = ""
        var q = false
        let chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if q && c == "\"" && i + 1 < chars.count && chars[i + 1] == "\"" { cur.append("\""); i += 1 }
            else if c == "\"" { q.toggle() }
            else if !q && c == "," { row.append(cur); cur = "" }
            else if !q && (c == "\n" || c == "\r" || c == "\r\n") {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(cur); cur = ""; rows.append(row); row = []
            } else { cur.append(c) }
            i += 1
        }
        if !cur.isEmpty || !row.isEmpty { row.append(cur); rows.append(row) }
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return [] }
        return rows.dropFirst().filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }.map { r in
            var m = [String: String]()
            for (k, h) in header.enumerated() { m[h] = k < r.count ? r[k].trimmingCharacters(in: .whitespaces) : "" }
            return m
        }
    }

    private static func num(_ r: [String: String], _ keys: String...) -> Double? {
        for k in keys { if let v = r[k].flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }) { return v } }
        return nil
    }
    private static func str(_ r: [String: String], _ keys: String...) -> String? {
        for k in keys { if let v = r[k], !v.isEmpty { return v } }
        return nil
    }

    private static let tsFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static func millis(_ s: String?) -> Int64? {
        guard let s = s, let d = tsFmt.date(from: s) else { return nil }
        return Int64(d.timeIntervalSince1970 * 1000)
    }
    private static func minuteOfDay(_ s: String) -> Int? {
        let c = Array(s)
        guard c.count >= 16, let h = Int(String(c[11...12])), let m = Int(String(c[14...15])) else { return nil }
        return h * 60 + m
    }

    static func mapSport(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("fútbol") || n.contains("futbol") || n.contains("soccer") { return "Fútbol" }
        if n.contains("pádel") || n.contains("padel") { return "Pádel" }
        if n.contains("pickleball") { return "Pickleball" }
        if n.contains("funcional") { return "Entrenamiento funcional" }
        if n.contains("fuerza") || n.contains("potencia") || n.contains("weightlifting") { return "Entrenamiento de fuerza" }
        if n.contains("caminar") || n.contains("senderismo") || n.contains("walking") || n.contains("hiking") { return "Caminar" }
        if n.contains("correr") || n.contains("running") { return "Correr" }
        if n.contains("ciclismo") || n.contains("bicicleta") || n.contains("cycling") { return "Ciclismo" }
        if n == "actividad" || n == "activity" { return "Otro" }
        return name
    }

    // MARK: - Importar

    static func importFiles(_ urls: [URL]) -> Result {
        let files = readFiles(urls)
        func find(_ names: String...) -> [[String: String]] {
            for n in names { if let t = files[n.precomposedStringWithCanonicalMapping] { return parseCsv(t) } }
            return []
        }
        let cycles = find("physiological_cycles.csv")
        let sleeps = find("sueño.csv", "sleeps.csv", "sueno.csv")
        let workouts = find("entrenamientos.csv", "workouts.csv")
        let today = TimeUtil.dayKey(TimeUtil.nowMillis())
        let now = TimeUtil.nowMillis()

        var sleepByStart = [String: [String: String]]()
        for s in sleeps where s["Siesta"] != "true" { if let k = s["Inicio del sueño"] { sleepByStart[k] = s } }

        var newDays = [String: DailyMetrics]()
        for c in cycles {
            guard let wake = str(c, "Inicio de la vigilia"), let start = str(c, "Inicio del sueño") else { continue }
            let date = String(wake.prefix(10))
            if date >= today { continue }
            let s = sleepByStart[start] ?? c
            var d = DailyMetrics(date: date,
                                 restingHr: num(c, "Frecuencia cardíaca en reposo (lpm)").map { Int($0) },
                                 avgHrv: num(c, "Variabilidad de la frecuencia cardíaca (ms)"),
                                 sleepMinutes: num(s, "Duración del sueño (min)").map { Int($0) },
                                 strain: num(c, "Esfuerzo del día"),
                                 vo2Max: nil,
                                 caloriesKcal: num(c, "Energía quemada (cal)"))
            d.sleepStartMinuteOfDay = minuteOfDay(start)
            d.sleepEndMinuteOfDay = minuteOfDay(wake)
            d.sleepEfficiencyPct = num(s, "Eficiencia del sueño %").map { Int($0) }
            d.respiratoryRate = num(s, "Frecuencia respiratoria (rpm)")
            d.lightMinutes = num(s, "Duración de sueño ligero (min)").map { Int($0) }
            d.deepMinutes = num(s, "Duración de sueño profundo (SWS) (min)").map { Int($0) }
            d.remMinutes = num(s, "Duración de sueño REM (min)").map { Int($0) }
            d.awakeMinutes = num(s, "Tempo despierto/a (min)", "Tiempo despierto/a (min)").map { Int($0) }
            d.whoopRecovery = num(c, "Puntuación de recuperación (%)").map { Int($0) }
            d.whoopSleepScore = num(s, "Calificación del sueño (%)").map { Int($0) }
            d.whoopConsistency = num(s, "Regularidad del sueño %").map { Int($0) }
            d.whoopSleepNeed = num(s, "Sueño necesario (min)").map { Int($0) }
            newDays[date] = d
        }

        var newSessions = [ActivitySession]()
        for w in workouts {
            guard let a = millis(str(w, "Hora de inicio del entrenamiento")), let b = millis(str(w, "Hora de finalización del entrenamiento")),
                  b > a, a <= now else { continue }
            let mins = Double(b - a) / 60000.0
            let z = (1...5).map { (num(w, "Zona FC \($0)%") ?? 0) / 100.0 * mins }
            let z0 = max(mins - z.reduce(0, +), 0)
            newSessions.append(ActivitySession(id: 0, startMillis: a, endMillis: b + 999,
                avgHr: num(w, "FC promedio (lpm)").map { Int($0) } ?? 0, maxHr: num(w, "FC máx. (lpm)").map { Int($0) } ?? 0,
                strain: num(w, "Esfuerzo de actividad") ?? 0, caloriesKcal: num(w, "Energía quemada (cal)") ?? 0,
                minutesZone1: Int(z[0].rounded()), minutesZone2: Int(z[1].rounded()), minutesZone3: Int(z[2].rounded()),
                minutesZone4: Int(z[3].rounded()), minutesZone5: Int(z[4].rounded()),
                type: mapSport(str(w, "Nombre de la actividad") ?? "Otro"), autoDetected: false, minutesZone0: Int(z0.rounded())))
        }
        var naps = 0
        for s in sleeps where s["Siesta"] == "true" {
            guard let a = millis(str(s, "Inicio del sueño")), let b = millis(str(s, "Inicio de la vigilia")), b > a, a <= now else { continue }
            newSessions.append(ActivitySession(id: 0, startMillis: a, endMillis: b, avgHr: 0, maxHr: 0, strain: 0, caloriesKcal: 0,
                minutesZone1: 0, minutesZone2: 0, minutesZone3: 0, minutesZone4: 0, minutesZone5: 0,
                type: Formulas.napType, autoDetected: false, minutesZone0: 0))
            naps += 1
        }

        let store = AppStore.shared
        var result = Result()
        let replacedDays = newDays.keys.compactMap { store.getDay($0) }
        let replacedSessions = store.allSessions().filter { old in
            newSessions.contains { $0.startMillis < old.endMillis && $0.endMillis > old.startMillis }
        }
        if !replacedDays.isEmpty || !replacedSessions.isEmpty {
            struct Backup: Codable { let days: [DailyMetrics]; let sessions: [ActivitySession] }
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
            let name = "whoop_import_backup_\(f.string(from: Date())).json"
            if let data = try? JSONEncoder().encode(Backup(days: replacedDays, sessions: replacedSessions)) {
                try? data.write(to: AppPaths.file(name))
                result.backup = name
            }
        }
        var toSave = [DailyMetrics]()
        for (date, d) in newDays {
            var x = d
            x.vo2Max = store.getDay(date)?.vo2Max   // WHOOP no exporta VO₂ máx por día: se conserva el de PulseApp
            toSave.append(x)
        }
        store.saveDays(toSave)
        for s in replacedSessions { store.deleteSession(id: s.id) }
        store.saveSessions(newSessions)

        if let until = newDays.keys.max() { UserDefaults.standard.set(until, forKey: keyUntil) }

        result.days = newDays.count
        result.sessions = newSessions.count - naps
        result.naps = naps
        result.replacedDays = replacedDays.count
        result.replacedSessions = replacedSessions.count
        result.from = newDays.keys.min()
        result.until = newDays.keys.max()
        return result
    }
}
