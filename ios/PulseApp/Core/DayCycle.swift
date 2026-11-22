import Foundation

/// Día "de sueño a sueño" como WHOOP (22/11, igual que Android `DayCycle`). El día empieza cuando te duermes y acaba cuando vuelves
/// a dormirte; lleva la fecha del día en que te despiertas. Pasadas las 00:00 sin haber dormido sigues en el día anterior.
/// Una noche abre el día nuevo con ≥ 3 h dormido y si acaba después de las 03:00 de ese día (export: dormido mínimo 3:29,
/// despertar más temprano 06:29).
enum DayCycle {
    static let minAsleepMin = 180
    static let minEndHour = 3

    /// ¿La noche que acaba en [date] abre ya el día [date]?
    static func opensDay(asleepMinutes: Int?, endMillis: Int64?, date: String) -> Bool {
        guard let a = asleepMinutes, let e = endMillis, a >= minAsleepMin else { return false }
        return e >= Day.start(date) + Int64(minEndHour) * 3_600_000
    }

    /// Inicio del día [date]: el comienzo de su noche (minutos del día guardados) o, sin noche, las 00:00.
    static func startMillis(_ date: String, _ sleepStartMinute: Int?, _ sleepEndMinute: Int?) -> Int64 {
        let d0 = Day.start(date)
        guard let s = sleepStartMinute, let e = sleepEndMinute else { return d0 }
        return s > e ? d0 - Int64(1440 - s) * 60_000 : d0 + Int64(s) * 60_000
    }

    private static let lock = NSLock()
    private static var current: String? = nil
    private static var currentAt: Int64 = 0

    /// Lo fija Inicio cada vez que calcula hoy.
    static func setToday(_ date: String) { lock.lock(); current = date; currentAt = TimeUtil.nowMillis(); lock.unlock() }

    /// Día en curso (para las pantallas que eligen "hoy" + desplazamiento). Si no se ha calculado hace poco, el día del reloj.
    static func today() -> String {
        lock.lock(); defer { lock.unlock() }
        let cal = Day.today()
        guard let c = current, TimeUtil.nowMillis() - currentAt <= 6 * 3_600_000, c >= Day.add(cal, -1), c <= cal else { return cal }
        return c
    }
}
