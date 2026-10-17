import Foundation

/// Importa lo exportado desde la app de Android (Más → Exportar datos): hr_log.csv, motion_minutes.csv,
/// pulse_daily_metrics.csv, pulse_activity_sessions.csv y pulse_profile.csv. Nunca borra nada de lo que ya hay en el iPhone:
/// el pulso y el movimiento se MEZCLAN (sin duplicar segundos/minutos) y los días, actividades y perfil solo rellenan lo que falta.
enum AndroidImport {

    struct Report {
        var hrLines = 0
        var motionLines = 0
        var days = 0
        var sessions = 0
        var profile = false
        var unknown = [String]()

        var text: String {
            var parts = [String]()
            if hrLines > 0 { parts.append("\(Fmt.thousands(Int64(hrLines))) lecturas de pulso") }
            if motionLines > 0 { parts.append("\(Fmt.thousands(Int64(motionLines))) minutos de movimiento") }
            if days > 0 { parts.append("\(days) días") }
            if sessions > 0 { parts.append("\(sessions) actividades") }
            if profile { parts.append("tu perfil") }
            var s = parts.isEmpty ? "No había nada nuevo que importar." : "Importado: " + parts.joined(separator: ", ") + "."
            if !unknown.isEmpty { s += "\n\nNo reconocí: " + unknown.joined(separator: ", ") }
            return s
        }
    }

    /// [urls] ya copiados a una carpeta propia (o accesibles). Puede tardar con un hr_log.csv grande: llamar fuera del hilo principal.
    static func importFiles(_ urls: [URL]) -> Report {
        var r = Report()
        // Primero perfil y días (el resto los usa), luego actividades, movimiento y pulso
        let kinds = urls.map { ($0, kind(of: $0)) }
        for (u, k) in kinds where k == .profile { r.profile = importProfile(u) || r.profile }
        for (u, k) in kinds where k == .daily { r.days += importDaily(u) }
        for (u, k) in kinds where k == .sessions { r.sessions += importSessions(u) }
        for (u, k) in kinds where k == .motion { r.motionLines += mergeMotion(u) }
        for (u, k) in kinds where k == .hr { r.hrLines += WhoopManager.shared.hrLog.mergeImport(u) }
        for (u, k) in kinds where k == .unknown { r.unknown.append(u.lastPathComponent) }
        return r
    }

    enum Kind { case hr, motion, daily, sessions, profile, unknown }

    static func kind(of url: URL) -> Kind {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 300)) ?? Data()
        let head = String(decoding: data, as: UTF8.self)
        let first = head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if first.hasPrefix("#pulseapp_daily_metrics") { return .daily }
        if first.hasPrefix("#pulseapp_activity_sessions") { return .sessions }
        if first.hasPrefix("#pulseapp_profile") { return .profile }
        if first.hasPrefix("minute_unix") { return .motion }
        if first.hasPrefix("timestamp") { return .hr }
        // hr_log sin cabecera: empieza por "2026-10-16T08:51:12,"
        let b = Array(first.utf8)
        if b.count > 20 && b[4] == 45 && b[10] == 84 && b[19] == 44 { return .hr }
        return .unknown
    }

    /// Filas de datos de uno de nuestros CSV (sin la marca "#…" ni la cabecera).
    private static func rows(_ url: URL) -> [[String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out = [[String]]()
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() where i >= 2 {
            out.append(line.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        return out
    }

    private static func int(_ s: String) -> Int? { return s.isEmpty ? nil : Int(s) }
    private static func dbl(_ s: String) -> Double? { return s.isEmpty ? nil : Double(s.replacingOccurrences(of: ",", with: ".")) }

    private static func importProfile(_ url: URL) -> Bool {
        guard let p = rows(url).first, p.count >= 4, let birth = Int64(p[0]), let w = dbl(p[1]), let h = dbl(p[2]) else { return false }
        if p.count >= 7, let hm = int(p[6]), hm > (Formulas.observedHrMax() ?? 0) { Formulas.setObservedHrMax(hm) }
        if AppStore.shared.getProfile() != nil { return false }
        AppStore.shared.saveProfile(UserProfile(birthdayMillis: birth, weightKg: w, heightCm: h, sex: p[3] == "F" ? "F" : "M",
                                                vo2Max: p.count > 4 ? dbl(p[4]) : nil, vo2MaxUpdatedDate: p.count > 5 && !p[5].isEmpty ? p[5] : nil))
        WhoopManager.shared.refreshHrMax()
        return true
    }

    private static func importDaily(_ url: URL) -> Int {
        var list = [DailyMetrics]()
        for p in rows(url) where p.count >= 17 && p[0].count == 10 {
            if AppStore.shared.getDay(p[0]) != nil { continue }   // lo calculado en el iPhone manda
            list.append(DailyMetrics(date: p[0], restingHr: int(p[1]), avgHrv: dbl(p[2]), sleepMinutes: int(p[3]), strain: dbl(p[4]),
                                     vo2Max: dbl(p[5]), caloriesKcal: dbl(p[6]), sleepStartMinuteOfDay: int(p[7]), sleepEndMinuteOfDay: int(p[8]),
                                     sleepEfficiencyPct: int(p[9]), respiratoryRate: dbl(p[10]), lightMinutes: int(p[11]), deepMinutes: int(p[12]),
                                     remMinutes: int(p[13]), awakeMinutes: int(p[14]), wakeEpisodes: int(p[15]), latencyMinutes: int(p[16])))
        }
        AppStore.shared.saveDays(list)
        return list.count
    }

    private static func importSessions(_ url: URL) -> Int {
        var existing = AppStore.shared.allSessions()
        var added = [ActivitySession]()
        for p in rows(url) where p.count >= 14 {
            guard let s = Int64(p[0]), let e = Int64(p[1]), e > s else { continue }
            // Una actividad que se solape con otra ya guardada se da por repetida
            if existing.contains(where: { $0.startMillis < e && $0.endMillis > s }) { continue }
            let a = ActivitySession(startMillis: s, endMillis: e, avgHr: int(p[2]) ?? 0, maxHr: int(p[3]) ?? 0, strain: dbl(p[4]) ?? 0,
                                    caloriesKcal: dbl(p[5]) ?? 0, minutesZone1: int(p[6]) ?? 0, minutesZone2: int(p[7]) ?? 0,
                                    minutesZone3: int(p[8]) ?? 0, minutesZone4: int(p[9]) ?? 0, minutesZone5: int(p[10]) ?? 0,
                                    type: p[11].isEmpty ? "Sin clasificar" : p[11], autoDetected: p[12] == "1", minutesZone0: int(p[13]) ?? 0)
            added.append(a)
            existing.append(a)
        }
        AppStore.shared.saveSessions(added)
        return added.count
    }

    /// Mezcla motion_minutes.csv: añade los minutos que no estén ya y deja el archivo ordenado.
    private static func mergeMotion(_ url: URL) -> Int {
        let mine = AppPaths.file(MotionTracker.fileName)
        func lines(_ u: URL) -> [Substring] {
            guard let t = try? String(contentsOf: u, encoding: .utf8) else { return [] }
            return t.split(separator: "\n").filter { !$0.hasPrefix("minute_unix") }
        }
        func key(_ l: Substring) -> Int64? { return l.split(separator: ",", maxSplits: 1).first.flatMap { Int64($0) } }
        var byMinute = [Int64: Substring]()
        for l in lines(mine) { if let k = key(l) { byMinute[k] = l } }
        var added = 0
        for l in lines(url) {
            guard let k = key(l), byMinute[k] == nil else { continue }
            byMinute[k] = l
            added += 1
        }
        if added == 0 { return 0 }
        var out = MotionMinute.csvHeader + "\n"
        for k in byMinute.keys.sorted() { out += byMinute[k]! + "\n" }
        try? out.write(to: mine, atomically: true, encoding: .utf8)
        return added
    }
}

extension HrLog {
    /// Mezcla otro hr_log.csv (el de Android) con el de este iPhone sin duplicar segundos.
    /// Se recorre por trozos (sirve con archivos de cientos de MB) y se reescribe el archivo de una vez.
    func mergeImport(_ other: URL) -> Int {
        flush()
        // Segundos que ya hay en el iPhone (clave sin zona horaria: día civil × 86400 + segundo del día)
        var have = Set<Int64>()
        HrLog.forEachLine(url) { b, s, e in
            if let k = HrLog.secondKey(b, s, e) { have.insert(k) }
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("hr_log.merge.tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmp) else { return 0 }
        var buf = Data()
        buf.append(Data("timestamp,bpm,rr_intervals_ms\n".utf8))
        var added = 0
        func copy(_ from: URL) {
            HrLog.forEachLine(from) { b, s, e in
                guard let k = HrLog.secondKey(b, s, e) else { return }
                if have.contains(k) { return }
                have.insert(k)
                added += 1
                buf.append(contentsOf: b[s..<e])
                buf.append(10)
                if buf.count > 4_000_000 { out.write(buf); buf.removeAll(keepingCapacity: true) }
            }
        }
        copy(other)          // lo de Android que falta (más antiguo, normalmente)
        out.write(buf)
        try? out.close()
        if added == 0 { try? FileManager.default.removeItem(at: tmp); return 0 }
        finishMerge(tmp)                      // y detrás todo lo del iPhone
        return added
    }

    /// Recorre las líneas completas de un archivo: (bytes, inicio, fin sin el salto de línea).
    static func forEachLine(_ u: URL, _ body: ([UInt8], Int, Int) -> Void) {
        guard let h = try? FileHandle(forReadingFrom: u) else { return }
        defer { try? h.close() }
        var carry = [UInt8]()
        while true {
            guard let data = try? h.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            var bytes = carry
            bytes.append(contentsOf: data)
            var start = 0
            let n = bytes.count
            var i = 0
            while i < n {
                if bytes[i] == 10 {
                    var e = i
                    if e > start && bytes[e - 1] == 13 { e -= 1 }
                    body(bytes, start, e)
                    start = i + 1
                }
                i += 1
            }
            carry = start < n ? Array(bytes[start..<n]) : []
        }
        if !carry.isEmpty { body(carry, 0, carry.count) }
    }

    /// "2026-10-16T08:51:12,…" → clave del segundo; nil si la línea no es una lectura.
    static func secondKey(_ b: [UInt8], _ s: Int, _ e: Int) -> Int64? {
        if e - s < 21 || b[s] < 48 || b[s] > 57 || b[s + 4] != 45 || b[s + 10] != 84 || b[s + 19] != 44 { return nil }
        func d2(_ o: Int) -> Int { return Int(b[o] &- 48) * 10 + Int(b[o + 1] &- 48) }
        let y = Int(b[s] &- 48) * 1000 + Int(b[s + 1] &- 48) * 100 + d2(s + 2)
        let mo = d2(s + 5), d = d2(s + 8), h = d2(s + 11), mi = d2(s + 14), se = d2(s + 17)
        if mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 60 { return nil }
        return TimeUtil.daysFromCivil(y, mo, d) * 86400 + Int64(h * 3600 + mi * 60 + se)
    }
}
