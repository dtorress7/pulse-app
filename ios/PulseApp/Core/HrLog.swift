import Foundation

/// hr_log.csv: una lectura de pulso por línea → `2026-10-16T08:51:12,72,"812.0|790.5"` (hora LOCAL, sin zona).
/// Igual que en Android, así los CSV exportados sirven para el mismo análisis.
/// Las lecturas se escriben en bloques (cada 30 lecturas o 30 s) para gastar menos batería.
final class HrLog {

    let url: URL
    private let lock = NSLock()
    private var buffer = [UInt8]()
    private var pending = 0
    private var lastFlush = Date()

    // Caché de lo más reciente (últimos 3 días): evita releer el archivo entero cada minuto.
    private var cache = [HrReading]()
    private var cacheFrom: Int64 = 0
    private var cacheOffset: UInt64 = 0
    private var cacheValid = false
    private let cacheDays = 3

    init(url: URL) {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "timestamp,bpm,rr_intervals_ms\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // ---------- Escritura ----------

    func append(timeMillis: Int64, bpm: Int, rr: [Double]) {
        var line = TimeUtil.logTimestamp(timeMillis) + "," + String(bpm) + ",\""
        var first = true
        for v in rr {
            if !first { line += "|" }
            first = false
            line += String(format: "%.1f", v)
        }
        line += "\"\n"
        lock.lock()
        buffer.append(contentsOf: Array(line.utf8))
        pending += 1
        let due = pending >= 30 || Date().timeIntervalSince(lastFlush) > 30
        lock.unlock()
        if due { flush() }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
    }

    private func flushLocked() {
        if buffer.isEmpty { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(buffer))
            try? h.close()
        } else {
            try? Data(buffer).write(to: url)
        }
        buffer.removeAll(keepingCapacity: true)
        pending = 0
        lastFlush = Date()
    }

    /// Termina una importación: [tmp] ya tiene la cabecera y las lecturas nuevas; se le añade todo lo de este archivo
    /// (con el cerrojo puesto, para no perder lo que llegue de la pulsera mientras tanto) y lo sustituye.
    func finishMerge(_ tmp: URL) {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
        if let out = try? FileHandle(forWritingTo: tmp) {
            out.seekToEndOfFile()
            var first = true
            var buf = Data()
            HrLog.forEachLine(url) { b, s, e in
                if first { first = false; if e > s && (b[s] < 48 || b[s] > 57) { return } }   // cabecera
                buf.append(contentsOf: b[s..<e])
                buf.append(10)
                if buf.count > 4_000_000 { out.write(buf); buf.removeAll(keepingCapacity: true) }
            }
            out.write(buf)
            try? out.close()
        }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        cache.removeAll()
        cacheOffset = 0
        cacheValid = false
    }

    /// Una vez (25/10): marca con su desfase las líneas de la hora repetida del cambio de hora que se guardaron sin él.
    /// En la hora repetida las líneas van en orden: primero la pasada de verano y luego la de invierno; cuando la hora
    /// vuelve atrás ≥ 30 min empieza la 2.ª. Se guarda una copia del archivo antes (hr_log_antes_cambio_hora.csv).
    @discardableResult
    func repairDstOnce() -> Bool {
        let key = "pulseapp_dst_repair_v1"
        if UserDefaults.standard.bool(forKey: key) { return false }
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
        let tz = TimeUtil.timeZone
        func ambiguous(_ naive: Int64) -> (Int, Int)? {
            let o1 = tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(naive - 3 * 3600)))
            let o2 = tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(naive + 3 * 3600)))
            if o1 <= o2 { return nil }
            let t1 = naive - Int64(o1), t2 = naive - Int64(o2)
            if tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t1))) == o1 &&
                tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(t2))) == o2 { return (o1, o2) }
            return nil
        }
        func naiveOf(_ b: [UInt8], _ s: Int, _ e: Int) -> Int64? {
            if e - s < 20 || b[s] != 50 || b[s + 10] != 84 || b[s + 19] != 44 { return nil }
            func d2(_ o: Int) -> Int { return Int(b[o] &- 48) * 10 + Int(b[o + 1] &- 48) }
            let y = Int(b[s] &- 48) * 1000 + Int(b[s + 1] &- 48) * 100 + d2(s + 2)
            let mo = d2(s + 5), d = d2(s + 8), h = d2(s + 11), mi = d2(s + 14), se = d2(s + 17)
            if mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || se > 60 { return nil }
            return TimeUtil.daysFromCivil(y, mo, d) * 86400 + Int64(h * 3600 + mi * 60 + se)
        }
        var any = false
        HrLog.forEachLine(url) { b, s, e in
            if any { return }
            if let n = naiveOf(b, s, e), ambiguous(n) != nil { any = true }
        }
        if !any { UserDefaults.standard.set(true, forKey: key); return false }
        let dir = url.deletingLastPathComponent()
        let backup = dir.appendingPathComponent("hr_log_antes_cambio_hora.csv")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: url, to: backup) }
        let tmp = dir.appendingPathComponent("hr_log.dst.tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: tmp) else { return false }
        var buf = Data()
        var maxNaive = Int64.min
        var second = false
        HrLog.forEachLine(url) { b, s, e in
            if let n = naiveOf(b, s, e) {
                if let amb = ambiguous(n) {
                    if !second && maxNaive != Int64.min && n < maxNaive - 1800 { second = true }
                    if n > maxNaive { maxNaive = n }
                    buf.append(contentsOf: b[s..<(s + 19)])
                    buf.append(Data(TimeUtil.offsetSuffix(second ? amb.1 : amb.0).utf8))
                    buf.append(contentsOf: b[(s + 19)..<e])
                    buf.append(10)
                    return
                } else if maxNaive != Int64.min && n > maxNaive + 3600 {
                    maxNaive = Int64.min; second = false
                }
            }
            buf.append(contentsOf: b[s..<e])
            buf.append(10)
            if buf.count > 4_000_000 { out.write(buf); buf.removeAll(keepingCapacity: true) }
        }
        out.write(buf)
        try? out.close()
        if (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil {
            UserDefaults.standard.set(true, forKey: key)
        }
        cache.removeAll()
        cacheOffset = 0
        cacheValid = false
        return true
    }

    func fileSize() -> Int64 {
        lock.lock()
        flushLocked()
        lock.unlock()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // ---------- Lectura ----------

    /// Lecturas entre [from] y [to] (ms, inclusive), ordenadas y sin duplicados por segundo.
    func readings(from: Int64, to: Int64) -> [HrReading] {
        lock.lock()
        flushLocked()
        let nowMs = TimeUtil.nowMillis()
        let cacheStart = nowMs - Int64(cacheDays) * 86_400_000
        var result = [HrReading]()
        if from >= cacheStart {
            refreshCacheLocked(cacheStart: cacheStart)
            result = cache.filter { $0.timeMillis >= from && $0.timeMillis <= to }
        } else {
            result = HrLog.scan(url: url, fromOffset: 0, accept: { $0 >= from && $0 <= to }).readings
        }
        lock.unlock()
        return HrLog.sortedUnique(result)
    }

    /// Todas las lecturas del archivo (solo para exportar o análisis largos).
    func allReadings() -> [HrReading] {
        lock.lock()
        flushLocked()
        let r = HrLog.scan(url: url, fromOffset: 0, accept: { _ in true }).readings
        lock.unlock()
        return HrLog.sortedUnique(r)
    }

    private func refreshCacheLocked(cacheStart: Int64) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if !cacheValid || size < cacheOffset || cacheStart - cacheFrom > 12 * 3_600_000 {
            cache.removeAll()
            cacheOffset = 0
            cacheFrom = cacheStart
            cacheValid = true
        }
        if size > cacheOffset {
            let from = cacheFrom
            let r = HrLog.scan(url: url, fromOffset: cacheOffset, accept: { $0 >= from })
            cache.append(contentsOf: r.readings)
            cacheOffset = r.endOffset
            // se recorta lo que ya es más viejo que la ventana
            if cache.count > 400_000 {
                cache = cache.filter { $0.timeMillis >= cacheStart }
                cacheFrom = cacheStart
            }
        }
    }

    static func sortedUnique(_ input: [HrReading]) -> [HrReading] {
        if input.count < 2 { return input }
        let sorted = input.sorted { $0.timeMillis < $1.timeMillis }
        var out = [HrReading]()
        out.reserveCapacity(sorted.count)
        var lastSec: Int64 = Int64.min
        for r in sorted {
            let sec = r.timeMillis / 1000
            if sec == lastSec { continue }
            lastSec = sec
            out.append(r)
        }
        return out
    }

    /// Recorre el archivo desde [fromOffset] y devuelve las lecturas cuya hora cumple [accept].
    /// Solo se consumen líneas completas (terminadas en salto de línea).
    static func scan(url: URL, fromOffset: UInt64, accept: (Int64) -> Bool) -> (readings: [HrReading], endOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], fromOffset) }
        defer { try? handle.close() }
        handle.seek(toFileOffset: fromOffset)
        var out = [HrReading]()
        var consumed = fromOffset
        let chunkSize = 4 * 1024 * 1024
        var carry = [UInt8]()
        while true {
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            var bytes = carry
            bytes.append(contentsOf: data)
            var lineStart = 0
            var i = 0
            let n = bytes.count
            while i < n {
                if bytes[i] == 10 {
                    if let r = parseLine(bytes, lineStart, i, accept) { out.append(r) }
                    lineStart = i + 1
                }
                i += 1
            }
            consumed += UInt64(lineStart)
            carry = lineStart < n ? Array(bytes[lineStart..<n]) : []
        }
        return (out, consumed)
    }

    /// Una línea [s, e) → lectura. Formato: `yyyy-MM-ddTHH:mm:ss,bpm,"rr|rr"`.
    static func parseLine(_ b: [UInt8], _ s: Int, _ e: Int, _ accept: (Int64) -> Bool) -> HrReading? {
        if e - s < 21 { return nil }
        if b[s] < 48 || b[s] > 57 { return nil }          // cabecera "timestamp,…"
        func d2(_ o: Int) -> Int { return Int(b[o] &- 48) * 10 + Int(b[o + 1] &- 48) }
        if b[s + 4] != 45 || b[s + 7] != 45 || b[s + 13] != 58 || b[s + 16] != 58 { return nil }
        let year = Int(b[s] &- 48) * 1000 + Int(b[s + 1] &- 48) * 100 + d2(s + 2)
        let month = d2(s + 5), day = d2(s + 8), hour = d2(s + 11), minute = d2(s + 14), second = d2(s + 17)
        if month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60 { return nil }
        let suffix = TimeUtil.suffixOffset(b, s, e)          // "+01:00" cerca de un cambio de hora (25/10)
        let comma = s + (suffix == nil ? 19 : 25)
        if b[comma] != 44 { return nil }
        let t = TimeUtil.lineMillis(year, month, day, hour, minute, second, suffix: suffix)
        if !accept(t) { return nil }

        // bpm
        var i = comma + 1
        var bpm = 0
        var digits = 0
        while i < e && b[i] >= 48 && b[i] <= 57 { bpm = bpm * 10 + Int(b[i] - 48); i += 1; digits += 1 }
        if digits == 0 || bpm <= 0 || bpm > 250 { return nil }

        // rr (opcional)
        var rr = [Double]()
        if i < e && b[i] == 44 {
            i += 1
            var cur = 0.0
            var frac = 0.0
            var scale = 0.1
            var inFrac = false
            var has = false
            func flushValue() {
                if has {
                    let v = cur + frac
                    if v >= 300.0 && v <= 2000.0 { rr.append(v) }
                }
                cur = 0; frac = 0; scale = 0.1; inFrac = false; has = false
            }
            while i < e {
                let c = b[i]
                if c >= 48 && c <= 57 {
                    has = true
                    if inFrac { frac += Double(c - 48) * scale; scale *= 0.1 } else { cur = cur * 10 + Double(c - 48) }
                } else if c == 46 || c == 44 && inFrac == false && has {
                    // punto decimal (o coma decimal dentro de las comillas de un valor)
                    inFrac = true
                } else if c == 124 {   // '|'
                    flushValue()
                }
                i += 1
            }
            flushValue()
        }
        return HrReading(timeMillis: t, bpm: bpm, rr: rr)
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
}
