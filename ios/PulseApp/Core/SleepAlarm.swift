import Foundation

/// 9/11: planificador de sueño y alarma como WHOOP (port 1:1 de Android `SleepAlarm.kt`).
/// - Modos de alarma: hora exacta, objetivo de sueño (vibra cuando has dormido tu meta), en verde (vibra cuando la
///   recuperación llega a verde). La alarma de la PULSERA queda siempre puesta a la hora de despertar (lo más tarde
///   posible); en los modos inteligentes el móvil la lanza antes si se cumple la condición (ventana de 90 min).
/// - Meta de mañana: "Lograr mi sueño necesario" (100 %) o "Mejorar mi sueño" (85 %, PROVISIONAL: falta el texto de WHOOP).
/// - Horario: días de la semana con su hora y su modo (o sin alarma), como "Mi horario" de WHOOP.
enum SleepAlarm {
    static let modeExact = 0, modeGoal = 1, modeGreen = 2, modeNone = -1
    static let smartWindowMin = 90

    struct Entry: Codable, Equatable {
        var days: Int        // bit 0 = lunes … bit 6 = domingo
        var minute: Int      // minuto del día
        var mode: Int        // modeExact/modeGoal/modeGreen o modeNone (sin alarma)
    }

    private static let d = UserDefaults.standard
    static var mode: Int {
        get { return d.object(forKey: "pulseapp_alarm_mode") as? Int ?? modeExact }
        set { d.set(newValue, forKey: "pulseapp_alarm_mode") }
    }
    /// 0 = lograr mi sueño necesario (100 %), 1 = mejorar mi sueño (85 %)
    static var goal: Int {
        get { return d.object(forKey: "pulseapp_sleep_goal") as? Int ?? 0 }
        set { d.set(newValue, forKey: "pulseapp_sleep_goal") }
    }
    static var scheduleOn: Bool {
        get { return d.bool(forKey: "pulseapp_schedule_on") }
        set { d.set(newValue, forKey: "pulseapp_schedule_on") }
    }
    static var schedule: [Entry] {
        get {
            if let data = d.data(forKey: "pulseapp_schedule"), let e = try? JSONDecoder().decode([Entry].self, from: data) { return e }
            let w = SleepPlanner.wakeMinute()
            return [Entry(days: 0b0011111, minute: w, mode: modeExact), Entry(days: 0b1100000, minute: 9 * 60 + 15, mode: modeNone)]
        }
        set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "pulseapp_schedule") } }
    }
    /// Hora (unix s) de una alarma que el móvil ya lanzó antes de tiempo: esa mañana no se vuelve a armar.
    static var firedUnix: Int64 {
        get { return Int64(d.integer(forKey: "pulseapp_alarm_fired")) }
        set { d.set(Int(newValue), forKey: "pulseapp_alarm_fired") }
    }

    static func goalFactor() -> Double { return goal == 1 ? 0.85 : 1.0 }

    /// Lunes = 0 … domingo = 6
    static func weekdayIndex(_ date: Date) -> Int { return (Calendar.current.component(.weekday, from: date) + 5) % 7 }

    static func dayNames(_ days: Int) -> String {
        let n = ["LUN.", "MAR.", "MIÉ.", "JUE.", "VIE.", "SÁB.", "DOM."]
        return (0..<7).filter { days & (1 << $0) != 0 }.map { n[$0] }.joined(separator: " · ")
    }

    static func modeName(_ m: Int) -> String {
        switch m {
        case modeGoal: return "OBJETIVO DE SUEÑO"
        case modeGreen: return "EN VERDE"
        case modeNone: return "ALARMA APAGADA"
        default: return "HORA EXACTA"
        }
    }

    struct Next { let unix: Int64; let minute: Int; let mode: Int }

    /// La próxima mañana (hoy si la hora aún no ha pasado, si no mañana) con su hora y modo.
    static func next(now: Date = Date()) -> Next {
        let cal = Calendar.current
        for add in 0...7 {
            guard let day = cal.date(byAdding: .day, value: add, to: now) else { continue }
            var minute = SleepPlanner.wakeMinute()
            var m = WhoopSettings.alarmEnabled ? mode : modeNone
            if scheduleOn {
                let wd = weekdayIndex(day)
                guard let e = schedule.first(where: { $0.days & (1 << wd) != 0 }) else { if add < 7 { continue } else { break } }
                minute = e.minute; m = e.mode
            }
            guard let t = cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) else { continue }
            if t <= now.addingTimeInterval(60) { continue }
            let u = Int64(t.timeIntervalSince1970)
            if u == firedUnix { continue }   // ya sonó antes de tiempo esa mañana
            return Next(unix: u, minute: minute, mode: m)
        }
        let w = SleepPlanner.wakeMinute()
        let t = cal.date(bySettingHour: w / 60, minute: w % 60, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        return Next(unix: Int64(t.timeIntervalSince1970), minute: w, mode: modeNone)
    }

    /// Tiempo medio despierto en la cama de las últimas 14 noches (WHOOP lo suma a la meta: "+0:30"). PROVISIONAL: con las
    /// noches de WHOOP la media de 14 da 27 min y WHOOP pone 30 (pendiente de saber su regla). Sin noches, 30.
    static func avgAwakeMinutes(store: AppStore) -> Int {
        let v = store.lastDays(14).compactMap { $0.awakeMinutes }.filter { $0 > 0 }
        if v.count < 3 { return 30 }
        return Int((Double(v.reduce(0, +)) / Double(v.count)).rounded())
    }

    struct Plan {
        let base: Int, strain: Int, debt: Int, nap: Int, need: Int
        let goal: Int, awake: Int, inBed: Int
        let bedMinute: Int, wakeMinute: Int, mode: Int, alarmUnix: Int64
    }

    /// Plan de esta noche con la necesidad que ya calcula Inicio.
    static func plan(store: AppStore, sleepPlan p: SleepPlan, now: Date = Date()) -> Plan {
        let nx = next(now: now)
        let goalMin = Int((Double(p.totalNeedMinutes) * goalFactor()).rounded())
        let awake = avgAwakeMinutes(store: store)
        let inBed = goalMin + awake
        var bed = (nx.minute - inBed) % 1440
        if bed < 0 { bed += 1440 }
        return Plan(base: p.baselineMinutes, strain: p.strainAdjustmentMinutes, debt: p.debtAdjustmentMinutes, nap: p.napAdjustmentMinutes,
                    need: p.totalNeedMinutes, goal: goalMin, awake: awake, inBed: inBed, bedMinute: bed, wakeMinute: nx.minute,
                    mode: nx.mode, alarmUnix: nx.unix)
    }

    /// ¿Hay que despertar ya? (modos inteligentes, dentro de la ventana antes de la hora de despertar)
    static func shouldWakeEarly(mode: Int, asleepMinutes: Int?, goalMinutes: Int, recovery: Int?) -> Bool {
        switch mode {
        case modeGoal: return (asleepMinutes ?? 0) >= goalMinutes
        case modeGreen: return (recovery ?? 0) >= 67
        default: return false
        }
    }
}
