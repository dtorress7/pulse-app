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
        var line = TimeUtil.timestamp(timeMillis) + "," + String(bpm) + ",\""
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
        if b[s + 19] != 44 { return nil }
        let t = TimeUtil.localToMillis(year, month, day, hour, minute, second)
        if !accept(t) { return nil }

        // bpm
        var i = s + 20
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
}
