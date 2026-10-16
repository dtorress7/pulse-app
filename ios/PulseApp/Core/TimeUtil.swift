import Foundation

/// Fechas y horas locales sin DateFormatter (rápido para millones de líneas del CSV).
/// El CSV guarda la hora LOCAL "yyyy-MM-ddTHH:mm:ss" sin zona, igual que la app de Android.
enum TimeUtil {

    static var timeZone: TimeZone = TimeZone.current {
        didSet { lock.lock(); offsets.removeAll(); lock.unlock() }
    }
    private static let lock = NSLock()
    private static var offsets = [Int64: Int]()

    /// Desplazamiento (segundos) de la zona horaria en ese instante, con caché de 30 min.
    static func offset(atEpoch epoch: Int64) -> Int {
        let key = epoch / 1800
        lock.lock()
        if let v = offsets[key] { lock.unlock(); return v }
        lock.unlock()
        let v = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(epoch)))
        lock.lock()
        if offsets.count > 20000 { offsets.removeAll() }
        offsets[key] = v
        lock.unlock()
        return v
    }

    // Algoritmos de calendario civil (Howard Hinnant), valen para cualquier fecha moderna.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Int64(era * 146097 + doe - 719468)
    }

    static func civilFromDays(_ z0: Int64) -> (y: Int, m: Int, d: Int) {
        let z = Int(z0) + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Hora local (año, mes, día, h, m, s) → milisegundos unix.
    static func localToMillis(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Int64 {
        let guess = daysFromCivil(y, mo, d) * 86400 + Int64(h * 3600 + mi * 60 + s)
        let off1 = offset(atEpoch: guess)
        let off2 = offset(atEpoch: guess - Int64(off1))
        return (guess - Int64(off2)) * 1000
    }

    struct Parts {
        let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
        let weekday: Int   // 1 = lunes … 7 = domingo
    }

    static func parts(_ millis: Int64) -> Parts {
        let epoch = floorDiv(millis, 1000)
        let local = epoch + Int64(offset(atEpoch: epoch))
        let days = floorDiv(local, 86400)
        let secs = Int(local - days * 86400)
        let c = civilFromDays(days)
        // 1970-01-01 fue jueves (4)
        var wd = Int((days + 3) % 7)       // 0 = lunes
        if wd < 0 { wd += 7 }
        return Parts(year: c.y, month: c.m, day: c.d, hour: secs / 3600, minute: (secs % 3600) / 60, second: secs % 60, weekday: wd + 1)
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        var q = a / b
        if (a % b != 0) && ((a < 0) != (b < 0)) { q -= 1 }
        return q
    }

    /// "yyyy-MM-ddTHH:mm:ss" en hora local.
    static func timestamp(_ millis: Int64) -> String {
        let p = parts(millis)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", p.year, p.month, p.day, p.hour, p.minute, p.second)
    }

    /// "yyyy-MM-dd" en hora local.
    static func dayKey(_ millis: Int64) -> String {
        let p = parts(millis)
        return String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
    }

    static func minuteOfDay(_ millis: Int64) -> Int {
        let p = parts(millis)
        return p.hour * 60 + p.minute
    }

    /// Medianoche local del día de [millis].
    static func startOfDay(_ millis: Int64) -> Int64 {
        let p = parts(millis)
        return localToMillis(p.year, p.month, p.day, 0, 0, 0)
    }

    /// Mismo instante desplazado [days] días de calendario (respeta el cambio de hora).
    static func addDays(_ millis: Int64, _ days: Int) -> Int64 {
        let p = parts(millis)
        let day = daysFromCivil(p.year, p.month, p.day) + Int64(days)
        let c = civilFromDays(day)
        return localToMillis(c.y, c.m, c.d, p.hour, p.minute, p.second) + (millis - floorDiv(millis, 1000) * 1000)
    }

    /// Fija la hora del día en el mismo día local.
    static func setTime(_ millis: Int64, hour: Int, minute: Int) -> Int64 {
        let p = parts(millis)
        return localToMillis(p.year, p.month, p.day, hour, minute, 0)
    }

    static func nowMillis() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Fecha "yyyy-MM-dd" → millis a las 00:00 local (nil si no es válida).
    static func parseDayKey(_ s: String) -> Int64? {
        let a = s.split(separator: "-")
        if a.count != 3 { return nil }
        guard let y = Int(a[0]), let m = Int(a[1]), let d = Int(a[2]) else { return nil }
        return localToMillis(y, m, d, 0, 0, 0)
    }
}
