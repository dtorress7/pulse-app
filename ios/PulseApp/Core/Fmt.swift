import Foundation

/// Formatos de texto en español (coma decimal, miles con punto) — iguales que en la app de Android.
enum Fmt {
    static func hm(_ minutes: Int) -> String {
        return String(format: "%d:%02d", minutes / 60, abs(minutes % 60))
    }

    static func comma(_ value: Double, _ decimals: Int = 1) -> String {
        let s = String(format: "%.\(decimals)f", value)
        return s.replacingOccurrences(of: ".", with: ",")
    }

    static func int(_ value: Double) -> String { return String(format: "%.0f", value) }

    /// 12345 → "12.345" (agrupación manual: el formato de es_ES de iOS no agrupa los números de 4 cifras).
    static func thousands(_ value: Int64) -> String {
        let neg = value < 0
        let digits = Array(String(neg ? -value : value))
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out += "." }
            out.append(c)
        }
        return neg ? "-" + out : out
    }

    static func weekdayLetter(_ isoDate: String) -> String {
        guard let ms = TimeUtil.parseDayKey(isoDate) else { return "?" }
        let letters = ["L", "M", "X", "J", "V", "S", "D"]
        return letters[TimeUtil.parts(ms).weekday - 1]
    }

    private static let weekdays = ["lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo"]
    private static let months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
                                 "septiembre", "octubre", "noviembre", "diciembre"]
    private static let monthsShort = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]

    /// "Viernes, 16 de octubre"
    static func longDate(_ millis: Int64) -> String {
        let p = TimeUtil.parts(millis)
        let wd = weekdays[p.weekday - 1]
        let first = wd.prefix(1).uppercased() + wd.dropFirst()
        return "\(first), \(p.day) de \(months[p.month - 1])"
    }

    /// "16 oct"
    static func shortDate(_ millis: Int64) -> String {
        let p = TimeUtil.parts(millis)
        return "\(p.day) \(monthsShort[p.month - 1])"
    }

    /// "16 oct 2026 · 08:51"
    static func dateTime(_ millis: Int64) -> String {
        let p = TimeUtil.parts(millis)
        return String(format: "%02d %@ %04d · %02d:%02d", p.day, monthsShort[p.month - 1], p.year, p.hour, p.minute)
    }

    static func clock(_ millis: Int64) -> String {
        let p = TimeUtil.parts(millis)
        return String(format: "%02d:%02d", p.hour, p.minute)
    }

    static func clock(minuteOfDay m: Int) -> String {
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// "Noche del 15 al 16 de octubre"
    static func nightTitle(_ now: Int64) -> String {
        let y = TimeUtil.parts(TimeUtil.addDays(now, -1))
        let t = TimeUtil.parts(now)
        return "Noche del \(y.day) al \(t.day) de \(months[t.month - 1])"
    }

    static func recoveryLabel(_ score: Int) -> String {
        if score >= 67 { return "Recuperado" }
        if score >= 34 { return "Moderada" }
        return "Baja"
    }
}
