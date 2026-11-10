import Foundation

/// 9/11: planificador de sueño y alarma como WHOOP (port 1:1 de Android `SleepAlarm.kt`).
/// - Modos de alarma: hora exacta, objetivo de sueño (vibra cuando has dormido tu meta), en verde (vibra cuando la
///   recuperación llega a verde). La alarma de la PULSERA queda siempre puesta a la hora de despertar (lo más tarde
///   posible); en los modos inteligentes el móvil la lanza antes si se cumple la condición (ventana de 90 min).
/// - Meta de mañana (IA de WHOOP 9/11): "Lograr mi sueño necesario" al 70, 85 o 100 % de la necesidad, o "Mejorar mi sueño"
///   (regularidad + necesidad con cambios graduales, mira 28 días; sin regla publicada → de momento como lograr al 100 %, PROVISIONAL).
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
    /// 0 = lograr mi sueño necesario, 1 = mejorar mi sueño
    static var goal: Int {
        get { return d.object(forKey: "pulseapp_sleep_goal") as? Int ?? 0 }
        set { d.set(newValue, forKey: "pulseapp_sleep_goal") }
    }
    /// Porcentaje de "Lograr mi sueño necesario": 70, 85 o 100
    static var goalPct: Int {
        get { return d.object(forKey: "pulseapp_sleep_goal_pct") as? Int ?? 100 }
        set { d.set(newValue, forKey: "pulseapp_sleep_goal_pct") }
    }
    static func goalLabel() -> String { return goal == 1 ? "Mejorar mi sueño" : "Lograr el \(goalPct) % de mi sueño necesario" }
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

    static func goalFactor() -> Double { return goal == 1 ? 1.0 : Double(goalPct) / 100.0 }

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
            // 10/11: la alarma de hoy sigue siendo "la próxima" hasta 2 min DESPUÉS de su hora. Antes, en el último minuto pasaba a la de
            // mañana y PulseApp la reescribía (16:57:27 → 66 para el 11/11 16:58, evento 56 con 0x6AF49088): por eso nunca vibraba.
            if t <= now.addingTimeInterval(-120) { continue }
            let u = Int64(t.timeIntervalSince1970)
            if u == firedUnix { continue }   // ya sonó antes de tiempo esa mañana
            return Next(unix: u, minute: minute, mode: m)
        }
        let w = SleepPlanner.wakeMinute()
        let t = cal.date(bySettingHour: w / 60, minute: w % 60, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        return Next(unix: Int64(t.timeIntervalSince1970), minute: w, mode: modeNone)
    }

    /// Tiempo medio despierto en la cama (WHOOP lo suma a la meta: "+0:30"). PROVISIONAL: media de las últimas 28 noches
    /// redondeada hacia arriba a 5 min (con las 24 noches de WHOOP 17/10→9/11 la media es 26,8 → 30 = lo que muestra WHOOP;
    /// un solo dato, falta confirmar). Sin noches, 30.
    static func avgAwakeMinutes(store: AppStore) -> Int {
        return awakeRounded(store.lastDays(28).compactMap { $0.awakeMinutes })
    }
    static func awakeRounded(_ awake: [Int]) -> Int {
        let v = awake.filter { $0 > 0 }
        if v.count < 3 { return 30 }
        let mean = Double(v.reduce(0, +)) / Double(v.count)
        return Int((mean / 5).rounded(.up)) * 5
    }

    struct Plan {
        let base: Int, strain: Int, debt: Int, nap: Int, need: Int
        let goal: Int, awake: Int, inBed: Int
        let bedMinute: Int, wakeMinute: Int, mode: Int, alarmUnix: Int64
        /// "Óptimo" de WHOOP (franja sin depender de la alarma) y regularidad prevista para mañana (solo con "Mejorar").
        var optBed: Int? = nil, optWake: Int? = nil, regularity: Int? = nil
        /// Noches y siestas con las que se calculó (para rehacer el plan en el planificador al cambiar meta u hora).
        var nights: [Night] = []
        var naps: [[(Int, Int)]] = []
    }

    /// Una noche guardada: fecha en que acaba (yyyy-MM-dd), inicio y fin en minutos del día (hora local).
    struct Night { let date: String; let start: Int; let end: Int }

    private static func round(_ m: Int, to q: Int) -> Int { return Int((Double(m) / Double(q)).rounded()) * q }
    private static func wrap(_ m: Int) -> Int { return ((m % 1440) + 1440) % 1440 }

    /// 9/11 (capturas de WHOOP con "Mejorar mi sueño": despertar 7:30 → 22:45, 8:45 en cama, 66 %; despertar 8:30 → 23:15, 9:15, 74 %;
    /// Óptimo 22:45–7:35 en las dos):
    /// - Óptimo (PROVISIONAL) = tiempo en cama al 100 % redondeado a 5 min, acabando a tu hora media de despertar de las últimas
    ///   28 noches del mismo tipo de día (L–V o S–D), redondeada a 5 min. 9/11: 07:38 → 07:40 y 8:48 → 8:50 → 22:50–07:40 (WHOOP 22:45–07:35).
    /// - Mejorar (PROVISIONAL) = a mitad de camino entre la hora de acostarse para tu necesidad (con tu hora de despertar) y la del Óptimo,
    ///   redondeado a 15 min: 7:30 → 22:46 → 22:45 (W 22:45), 8:30 → 23:16 → 23:15 (W 23:15).
    /// - Regularidad prevista = Formulas.sleepConsistency de esa noche con las 3 anteriores (comprobado con las noches de WHOOP:
    ///   22:45–7:30 → 66,6 (W 66), 23:15–8:30 → 75,0 (W 74)).
    static func plan(store: AppStore, sleepPlan p: SleepPlan, nights: [Night] = [], naps: [[(Int, Int)]] = [], now: Date = Date()) -> Plan {
        let nx = next(now: now)
        let awake = avgAwakeMinutes(store: store)
        let fullInBed = p.totalNeedMinutes + awake
        var goalMin = Int((Double(p.totalNeedMinutes) * goalFactor()).rounded())
        var inBed = goalMin + awake
        var bed = wrap(nx.minute - inBed)
        let wakeDate = Date(timeIntervalSince1970: TimeInterval(nx.unix))
        let weekend = weekdayIndex(wakeDate) >= 5
        // Óptimo: hora media de despertar del mismo tipo de día (28 noches)
        var optBed: Int? = nil, optWake: Int? = nil
        let cutoff = TimeUtil.dayKey(Int64(wakeDate.addingTimeInterval(-28 * 86400).timeIntervalSince1970 * 1000))
        let same = nights.filter { n in
            guard n.date >= cutoff, let d = TimeUtil.parseDayKey(n.date) else { return false }
            return (weekdayIndex(Date(timeIntervalSince1970: TimeInterval(d / 1000))) >= 5) == weekend
        }
        if same.count >= 5 {
            let w = round(Int((Double(same.reduce(0) { $0 + $1.end }) / Double(same.count)).rounded()), to: 5)
            optWake = w
            optBed = wrap(w - round(fullInBed, to: 5))
        }
        var regularity: Int? = nil
        if goal == 1 {
            let needBed = nx.minute - fullInBed            // puede ser negativo (antes de medianoche)
            var b = needBed
            if let ob = optBed {
                var o = ob; if o > 720 { o -= 1440 }         // en el mismo eje que needBed
                b = Int((Double(needBed + o) / 2).rounded())
            }
            bed = wrap(round(b, to: 15))
            inBed = wrap(nx.minute - bed)
            goalMin = inBed - awake
            let prev = Array(nights.suffix(3))
            if prev.count >= 1 {
                let tomorrow = TimeUtil.dayKey(Int64(nx.unix) * 1000)
                let all = prev.map { Formulas.standardNight($0.date, $0.start, $0.end) } + [Formulas.standardNight(tomorrow, bed, nx.minute)]
                let np = Array(naps.suffix(prev.count)) + [[]]
                regularity = Formulas.sleepConsistency(all, naps: np.count == all.count ? np : nil)
            }
        }
        return Plan(base: p.baselineMinutes, strain: p.strainAdjustmentMinutes, debt: p.debtAdjustmentMinutes, nap: p.napAdjustmentMinutes,
                    need: p.totalNeedMinutes, goal: goalMin, awake: awake, inBed: inBed, bedMinute: bed, wakeMinute: nx.minute,
                    mode: nx.mode, alarmUnix: nx.unix, optBed: optBed, optWake: optWake, regularity: regularity,
                    nights: nights, naps: naps)
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
