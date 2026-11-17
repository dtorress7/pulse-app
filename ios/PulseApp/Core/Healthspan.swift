import Foundation

/* 17/11: Healthspan / WHOOP Age como la pantalla de WHOOP (vídeo del usuario). WHOOP NO publica cómo la calcula: esto es una
   ESTIMACIÓN de PulseApp con los mismos 8 datos que enseña WHOOP (medias de 6 meses): regularidad y horas de sueño, tiempo semanal
   en zonas 1-3 y 4-5, tiempo semanal de fuerza, pasos, VO₂ máx y FC en reposo. Cada dato suma o resta años con una recta
   (punto neutro + pendiente, con tope), elegida para que con las medias del usuario del 16/11 salgan los mismos años que daba
   WHOOP: +0,5 / −0,2 / −1,5 / −0,2 / −1,6 / −0,4 / −2,6 / −0,3. Edad de WHOOP = edad real + suma (WHOOP no baja de 18: "<18,0").
   Se actualiza cada domingo con los datos hasta el sábado, como WHOOP. No entra en ningún otro cálculo. */
enum Healthspan {

    struct Factor {
        let key: String
        let name: String
        let group: String          // Sueño · Esfuerzo · Fitness
        let unit: String
        let lo: Double             // extremos de la barra
        let hi: Double
        let goodHigh: Bool
        let avg6m: Double?
        let avg30: Double?
        let years: Double?         // años que suma (+) o resta (−)
        let trendKey: String       // dato de la Vista de tendencias
    }

    struct Result {
        let chronoAge: Double?
        let whoopAge: Double?
        let pace: Double?
        let factors: [Factor]
        let weekStart: String
        let weekEnd: String
        let nextUpdateDays: Int
        /// (fin de cada semana, WHOOP Age, edad real), de la más antigua a la más reciente.
        let history: [(String, Double, Double)]
    }

    static let minAge = 18.0

    /// Modelo de cada dato: punto neutro, años por unidad, tope inferior y superior.
    private struct Model { let neutral: Double; let slope: Double; let minY: Double; let maxY: Double }

    private static func model(_ key: String, male: Bool, age: Double) -> Model {
        switch key {
        case "regularity": return Model(neutral: 75, slope: -0.0556, minY: -1.5, maxY: 2.0)
        case "sleep_hours": return Model(neutral: 7.75, slope: -0.74, minY: -1.0, maxY: 2.5)
        case "z13": return Model(neutral: 2.5, slope: -0.70, minY: -2.0, maxY: 1.75)
        case "z45": return Model(neutral: 0.5, slope: -0.71, minY: -1.5, maxY: 0.35)
        case "strength": return Model(neutral: 0.5, slope: -1.05, minY: -2.0, maxY: 0.5)
        case "steps": return Model(neutral: 8000, slope: -0.000184, minY: -1.0, maxY: 1.5)
        case "vo2": return Model(neutral: (male ? 45.0 : 38.0) - max(0, age - 25) * 0.3, slope: -0.236, minY: -3.0, maxY: 3.0)
        default: return Model(neutral: 60, slope: 0.10, minY: -1.0, maxY: 2.0)   // FC en reposo
        }
    }

    private struct Def { let key: String; let name: String; let group: String; let unit: String; let lo: Double; let hi: Double; let goodHigh: Bool; let trend: String }
    private static let defs: [Def] = [
        Def(key: "regularity", name: "Regularidad del sueño", group: "Sueño", unit: "%", lo: 40, hi: 100, goodHigh: true, trend: PanelKeys.regularity),
        Def(key: "sleep_hours", name: "Horas de sueño", group: "Sueño", unit: "h", lo: 5, hi: 9, goodHigh: true, trend: "sleep_hours"),
        Def(key: "z13", name: "Tiempo en zonas de FC 1-3 (semanal)", group: "Esfuerzo", unit: "h", lo: 0, hi: 6, goodHigh: true, trend: PanelKeys.z13),
        Def(key: "z45", name: "Tiempo en zonas de FC 4-5 (semanal)", group: "Esfuerzo", unit: "h", lo: 0, hi: 1, goodHigh: true, trend: PanelKeys.z45),
        Def(key: "strength", name: "Tiempo de actividad de fuerza (semanal)", group: "Esfuerzo", unit: "h", lo: 0, hi: 3, goodHigh: true, trend: PanelKeys.strength),
        Def(key: "steps", name: "Pasos", group: "Esfuerzo", unit: "pasos", lo: 0, hi: 16000, goodHigh: true, trend: PanelKeys.steps),
        Def(key: "vo2", name: "VO₂ máx", group: "Fitness", unit: "ml/kg/min", lo: 15, hi: 70, goodHigh: true, trend: PanelKeys.vo2),
        Def(key: "rhr", name: "FCR", group: "Fitness", unit: "lpm", lo: 40, hi: 80, goodHigh: false, trend: PanelKeys.rhr)
    ]

    /// Valor de un dato en un día (las horas semanales, como minutos de ese día: la media × 7 / 60 da horas por semana).
    private static func daily(_ key: String, _ r: DayRecord, _ s: [ActivitySession]) -> Double? {
        switch key {
        case "regularity": return r.consistency.map { Double($0) }
        case "sleep_hours": return r.sleepMinutes.map { Double($0) / 60.0 }
        case "steps": return r.steps.map { Double($0) }
        case "vo2": return r.vo2
        case "rhr": return r.rhr.map { Double($0) }
        case "strength":
            if r.strain == nil && s.isEmpty { return nil }
            return s.filter { Formulas.isStrength($0.type) || Formulas.isWeights($0.type) }
                .reduce(0.0) { $0 + Double($1.endMillis - $1.startMillis) / 60_000.0 }
        default:
            let zs = key == "z13" ? [1, 2, 3] : [4, 5]
            if let z = r.zones, z.totalSeconds > 0 {
                let secs = [0, z.z1, z.z2, z.z3, z.z4, z.z5]
                return Double(zs.reduce(0) { $0 + secs[$1] }) / 60.0
            }
            if r.strain == nil && s.isEmpty { return nil }
            return Double(s.reduce(0) { acc, x in
                let m = [x.minutesZone0, x.minutesZone1, x.minutesZone2, x.minutesZone3, x.minutesZone4, x.minutesZone5]
                return acc + zs.reduce(0) { $0 + m[$1] }
            })
        }
    }

    private static func isWeekly(_ key: String) -> Bool { return key == "z13" || key == "z45" || key == "strength" }

    /// Media de un dato en los [days] días que acaban en [end] (incluido). nil con menos de 5 días con dato.
    private static func mean(_ key: String, end: String, days: Int, _ recs: [String: DayRecord], _ sess: [String: [ActivitySession]]) -> Double? {
        var v = [Double]()
        var d = end
        for _ in 0..<days {
            if let r = recs[d], let x = daily(key, r, sess[d] ?? []) { v.append(x) }
            d = Day.add(d, -1)
        }
        guard v.count >= 5 else { return nil }
        let m = v.reduce(0, +) / Double(v.count)
        return isWeekly(key) ? m * 7 / 60.0 : m
    }

    private static func years(_ key: String, _ value: Double?, male: Bool, age: Double) -> Double? {
        guard let v = value else { return nil }
        let md = model(key, male: male, age: age)
        return min(max((v - md.neutral) * md.slope, md.minY), md.maxY)
    }

    private static func ageAt(_ date: String, _ profile: UserProfile?) -> Double? {
        guard let p = profile else { return nil }
        return Double(Day.start(date) - p.birthdayMillis) / (365.25 * 86_400_000)
    }

    /// WHOOP Age con las medias de [days] días que acaban en [end]; nil con menos de 4 datos.
    private static func ageWith(end: String, days: Int, _ recs: [String: DayRecord], _ sess: [String: [ActivitySession]],
                                _ profile: UserProfile?) -> Double? {
        guard let chrono = ageAt(end, profile) else { return nil }
        let male = profile?.sex != "F"
        let ys = defs.compactMap { years($0.key, mean($0.key, end: end, days: days, recs, sess), male: male, age: chrono) }
        guard ys.count >= 4 else { return nil }
        return chrono + ys.reduce(0, +)
    }

    static func compute(records: [DayRecord], sessions: [ActivitySession], profile: UserProfile?, today: String) -> Result {
        var recs = [String: DayRecord]()
        for r in records { recs[r.date] = r }
        var sess = [String: [ActivitySession]]()
        for s in sessions where s.type != Formulas.napType { sess[TimeUtil.dayKey(s.startMillis), default: []].append(s) }

        // Semana de WHOOP: de domingo a sábado; se calcula el domingo con los datos hasta el sábado
        let sinceSunday = (Day.weekdayIndex(today) + 1) % 7
        let weekStart = Day.add(today, -sinceSunday)
        let dataEnd = Day.add(weekStart, -1)
        let chrono = ageAt(dataEnd, profile)
        let male = profile?.sex != "F"

        let factors = defs.map { d -> Factor in
            let a6 = mean(d.key, end: dataEnd, days: 182, recs, sess)
            let a30 = mean(d.key, end: dataEnd, days: 30, recs, sess)
            return Factor(key: d.key, name: d.name, group: d.group, unit: d.unit, lo: d.lo, hi: d.hi, goodHigh: d.goodHigh,
                          avg6m: a6, avg30: a30, years: chrono.flatMap { years(d.key, a6, male: male, age: $0) }, trendKey: d.trend)
        }
        let whoopAge = ageWith(end: dataEnd, days: 182, recs, sess, profile)
        // Ritmo de envejecimiento: años de WHOOP Age que ganas por cada año real, comparando la edad con las medias de 30 días
        // (centro hace ~15 días) frente a la de 6 meses (centro hace ~91 días): 1,0x = al ritmo del calendario.
        var pace: Double? = nil
        if let a6 = whoopAge, let a30 = ageWith(end: dataEnd, days: 30, recs, sess, profile) {
            pace = min(max(1 + (a30 - a6) / (76.0 / 365.25), -1), 3)
        }
        var history = [(String, Double, Double)]()
        for k in stride(from: 25, through: 0, by: -1) {
            let end = Day.add(dataEnd, -7 * k)
            if let a = ageWith(end: end, days: 182, recs, sess, profile), let c = ageAt(end, profile) { history.append((end, a, c)) }
        }
        return Result(chronoAge: chrono, whoopAge: whoopAge, pace: pace, factors: factors, weekStart: weekStart,
                      weekEnd: Day.add(weekStart, 6), nextUpdateDays: 7 - sinceSunday, history: history)
    }
}
