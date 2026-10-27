import Foundation

/// Fórmulas de PulseApp, calibradas con tu histórico real de WHOOP (155 noches, 173 entrenamientos).
/// Son las MISMAS que en Android (ver Formulas.kt):
///  - Esfuerzo (0–21): TRIMP de Banister con reserva de FC, solo minutos ≥ 45 % de FC máx → 4,14·ln(1+TRIMP/2,6).
///  - Recuperación: sigmoide(0,84 + 5,5·ΔlnVFC − 0,028·ΔFCreposo), resta si la respiración sube mucho.
///  - Sueño: 0,281·horas vs necesidad (máx 100) + 0,202·eficiencia + 0,288·regularidad + 19,6.
///  - Necesidad de sueño = 7:50 + max(0, esfuerzo − 8)·6 min + deuda − siestas.
enum Formulas {

    // ---------- FC máxima ----------
    private static let keyHrMax = "pulseapp_hr_max_observed"

    static func tanaka(_ ageYears: Int) -> Double { return 208.0 - 0.7 * Double(ageYears) }

    /// FC máxima registrada (0 = ninguna). Se guarda en UserDefaults.
    static func observedHrMax() -> Int? {
        let v = UserDefaults.standard.integer(forKey: keyHrMax)
        return v > 0 ? v : nil
    }

    /// 0 = borrar (volver a la fórmula por edad).
    static func setObservedHrMax(_ bpm: Int) {
        // Si cambia, se rehacen zonas/esfuerzo/calorías de las actividades guardadas (AutoActivityScanner)
        if UserDefaults.standard.integer(forKey: keyHrMax) != bpm { UserDefaults.standard.set(0, forKey: "pulseapp_act_recalc") }
        UserDefaults.standard.set(bpm, forKey: keyHrMax)
    }

    /// FC máx usada en zonas y esfuerzo: la mayor entre la de tu edad y la máxima real registrada.
    static func hrMax(ageYears: Int) -> Double {
        return max(tanaka(ageYears), Double(observedHrMax() ?? 0))
    }

    /// Si en una actividad alcanzas una FC más alta (y creíble), pasa a ser tu FC máx (como hace WHOOP).
    static func updateObservedHrMax(_ bpm: Int) {
        if bpm < 150 || bpm > 220 { return }
        let current = observedHrMax() ?? 0
        // Un salto de más de 8 lpm sobre tu máximo suele ser un artefacto del sensor: no se acepta.
        if bpm > current && (current == 0 || bpm <= current + 8) { setObservedHrMax(bpm) }
    }

    // ---------- Zonas de FC como WHOOP (20/10) ----------
    // WHOOP (rangos del 19/10: 112/141/155/168/182) usa % de la RESERVA de FC: FCR + p·(FCmáx − FCR), p = 40/60/70/80/90 %.
    // Igual que Android (Formulas.kt). FCR = media de tus noches (se guarda al calcular Inicio).
    // Confirmado con "Ajustes de FC" de WHOOP (20/10): FCR 59, FCmáx 195 → 112/141/155/168/182.
    static let zoneHrr: [Double] = [0.385, 0.60, 0.70, 0.80, 0.90]
    private static let keyRhrZone = "pulseapp_rhr_zone"
    private static let keyBmr = "pulseapp_bmr_kcal"

    static func zoneRestingHr() -> Int {
        let v = UserDefaults.standard.integer(forKey: keyRhrZone)
        return v > 0 ? v : defaultRestingHr
    }

    static func setZoneRestingHr(_ rhr: Int) {
        if rhr < 35 || rhr > 100 || rhr == zoneRestingHr() { return }
        UserDefaults.standard.set(rhr, forKey: keyRhrZone)
    }

    /// Límite inferior (lpm) de las zonas 1..5.
    static func zoneBounds(hrMax: Double, rhr: Int? = nil) -> [Int] {
        let r = Double(rhr ?? zoneRestingHr())
        return zoneHrr.map { Int((r + $0 * (hrMax - r)).rounded(.up)) }
    }

    static func zoneOf(_ bpm: Int, _ bounds: [Int]) -> Int { return bounds.filter { bpm >= $0 }.count }

    // ---------- Calorías de actividad (20/10) ----------
    // Ajustadas con tus 173 entrenamientos de WHOOP: kcal/min por zona 0..5 = factor × metabolismo basal por minuto.
    static let zoneKcalBmr: [Double] = [1.09, 5.13, 10.14, 10.14, 14.56, 16.53]

    static func bmr() -> Double { return UserDefaults.standard.double(forKey: keyBmr) }

    static func setBmr(_ v: Double) {
        if v < 800 || abs(v - bmr()) < 1 { return }
        UserDefaults.standard.set(v, forKey: keyBmr)
    }

    static func activityKcal(zoneMinutes: [Double], bmrPerDay: Double) -> Double {
        var f = 0.0
        for i in 0..<6 { f += zoneMinutes[i] * zoneKcalBmr[i] }
        return f * bmrPerDay / 1440.0
    }

    // ---------- Siestas (21/10), igual que Android (Formulas.detectNaps) ----------
    // Tramo de minutos quietos (≥50 s, giro < 2,5, 0 pasos; tolera 2 min sueltos) ≥ 20 min que empiece entre las 10:00 y las 21:00,
    // con el pulso mediano ≤ FC en reposo + 12. No cuenta en sueño ni recuperación; resta de la necesidad de sueño.
    static let napType = "Siesta"

    static func detectNaps(_ minutes: [(Int64, Double)], motion: [MotionMinute], rhr: Int) -> [(Int64, Int64)] {
        var byMin = [Int64: MotionMinute](minimumCapacity: motion.count)
        for mm in motion { byMin[mm.minuteStartUnix / 60] = mm }
        var hrByMin = [Int64: Double](minimumCapacity: minutes.count)
        for (k, v) in minutes { hrByMin[k] = v }
        func still(_ m: MotionMinute?) -> Bool {
            guard let m = m else { return false }
            return m.stillSecs >= 50 && m.gyroDps < 2.5 && m.steps == 0
        }
        let keys = byMin.keys.sorted()
        var out = [(Int64, Int64)]()
        var i = 0
        while i < keys.count {
            if !still(byMin[keys[i]]) { i += 1; continue }
            let a = keys[i]
            var b = a, k = a + 1
            while true {
                if still(byMin[k]) { b = k; k += 1 }
                else if k - b <= 2 && (still(byMin[k + 1]) || still(byMin[k + 2])) { k += 1 }
                else { break }
            }
            let len = b - a + 1
            let h = TimeUtil.parts(a * 60_000).hour
            // 25/10 (igual que Android): una siesta va después de estar levantado; si en las 3 h de antes casi no hay pasos,
            // es el final de la noche (24/10 10:47–11:12).
            var walked = 0, covered = 0
            for q in (a - 180)..<a { guard let mm = byMin[q] else { continue }; covered += 1; if mm.steps >= 10 { walked += 1 } }
            let afterNight = covered >= 108 && walked < 5
            if len >= 20 && h >= 10 && h <= 20 && !afterNight {
                let hrs = (a...b).compactMap { hrByMin[$0] }.sorted()
                if Double(hrs.count) >= Double(len) * 0.6 && hrs[hrs.count / 2] <= Double(rhr + 12) { out.append((a, b)) }
            }
            i = keys.firstIndex(where: { $0 > b }) ?? keys.count
        }
        return out
    }

    // ---------- Detección automática de actividades (v2, 20/10) ----------
    // Igual que Android (Formulas.kt), calibrada con los funcionales que WHOOP detectó solo (19/10 y 20/10):
    // tramo ≥ 26 % de la reserva (tolera 2 min por debajo), núcleo ≥ 50 % (≥ 8 min), inicio = primer núcleo adelantado
    // mientras ≥ zona 1, fin = último núcleo o más tarde si el pulso vuelve a subir ≥ 5 lpm; dura ≥ 12 min.
    static func detectActivities(_ minutes: [(Int64, Double)], hrMax: Double, rhr: Int? = nil,
                                 motion: [Int64: MotionMinute]? = nil) -> [(Int64, Int64)] {
        let r = Double(rhr ?? zoneRestingHr())
        let res = hrMax - r
        let elevated = r + 0.26 * res, core = r + 0.50 * res, z1 = r + zoneHrr[0] * res
        var out = [(Int64, Int64)]()
        let n = minutes.count
        var i = 0
        while i < n {
            if minutes[i].1 < elevated { i += 1; continue }
            let s0 = i
            var e0 = i, j = i + 1
            while j < n && minutes[j].0 - minutes[e0].0 <= 3 {
                if minutes[j].1 >= elevated { e0 = j }
                j += 1
            }
            let coreIdx = (s0...e0).filter { minutes[$0].1 >= core }
            if coreIdx.count >= 8, var e = coreIdx.last {
                let s = s0   // inicio = primer minuto del tramo elevado (22/10, como Android)
                let lastCore = e
                var low = Double.greatestFiniteMagnitude
                if e < e0 {
                    for k in (e + 1)...e0 {
                        let v = minutes[k].1
                        if v >= low + 5 { e = k }
                        low = min(low, v)
                    }
                }
                // 25/10 (igual que Android): con movimiento grabado, ≥ 10 min quieto tras el último minuto intenso = fin
                // (fútbol 24/10: 21:07 como WHOOP; antes los paseos de después lo alargaban hasta las 21:48).
                if let mo = motion, e > lastCore {
                    var lastMove = lastCore, stillRun = 0
                    for k in (lastCore + 1)...e {
                        guard let mm = mo[minutes[k].0] else { stillRun = 0; continue }
                        if mm.steps >= 10 || mm.gyroDps >= 40 { lastMove = k; stillRun = 0 }
                        else { stillRun += 1; if stillRun >= 10 { e = lastMove; break } }
                    }
                }
                if minutes[e].0 - minutes[s].0 + 1 >= 12 { out.append((minutes[s].0, minutes[e].0)) }
            }
            i = e0 + 1
        }
        return out
    }

    // ---------- Paseos (25/10, igual que Android detectWalks) ----------
    // Minuto andando = ≥ 30 pasos; pausas ≤ 10 min. Paseo si dura ≥ 12 min, ≥ 8 min andando, ≥ 40 pasos/min y FC media ≥ 26 % de la reserva.
    static let walkType = "Caminar"

    static func detectWalks(_ minutes: [(Int64, Double)], motion: [Int64: MotionMinute], hrMax: Double, rhr: Int? = nil) -> [(Int64, Int64)] {
        let r = Double(rhr ?? zoneRestingHr())
        let elevated = r + 0.26 * (hrMax - r)
        var hrBy = [Int64: Double](minimumCapacity: minutes.count)
        for (k, v) in minutes { hrBy[k] = v }
        let walk = motion.filter { $0.value.steps >= 30 }.keys.sorted()
        var out = [(Int64, Int64)]()
        var i = 0
        while i < walk.count {
            let a = walk[i]
            var b = a, cnt = 1, j = i + 1
            while j < walk.count && walk[j] - b <= 11 { b = walk[j]; cnt += 1; j += 1 }
            let dur = b - a + 1
            var steps = 0
            var hrs = [Double]()
            for q in a...b { steps += motion[q]?.steps ?? 0; if let h = hrBy[q] { hrs.append(h) } }
            if dur >= 12 && cnt >= 8 && Int64(steps) >= 40 * dur && Double(hrs.count) >= Double(dur) * 0.6
                && hrs.reduce(0, +) / Double(hrs.count) >= elevated { out.append((a, b)) }
            i = j
        }
        return out
    }

    // ---------- Esfuerzo ----------
    // Ronda de esfuerzo 22/10 v2 (igual que Android, ver Formulas.kt): carga = Σ min · r · e^(6,694·r), r = reserva de FC;
    // esfuerzo = 2,014 · ln(1 + (carga + 50 · minutos de fuerza/funcional) / 10,418).
    // Esfuerzo v3 (24/10, igual que Android): carga/min = r·e^(5,005 r) + 0,0951; esfuerzo = 4,252·ln(1 + (carga + 13,21·min fuerza)/68,87)
    // Esfuerzo v4 (25/10, igual que Android): + carga por minuto de los paseos (WHOOP: paseo 24–30 min a 100–107 lpm ≈ 4,6–4,9).
    static let strainScale = 4.5300296
    static let strainTrimpRef = 90.426399
    static let strainExp = 5.1623827
    static let strainBasePerMin = 0.1208666
    static let strengthLoadPerMin = 14.613395
    static let walkLoadPerMin = 4.3826189
    static let defaultRestingHr = 58

    static func isStrength(_ type: String?) -> Bool {
        guard let t = type?.lowercased() else { return false }
        return t.contains("funcional") || t.contains("fuerza") || t.contains("crossfit") || t.contains("gimnasio") || t.contains("pesas")
    }

    static func isWalk(_ type: String?) -> Bool {
        guard let t = type?.lowercased() else { return false }
        return t.contains("caminar") || t.contains("paseo") || t.contains("senderismo") || t.contains("andar")
    }

    /// Minutos "de fuerza equivalentes": fuerza = sus minutos; paseo = sus minutos × 4,38/14,61; resto 0.
    static func muscleMinutes(_ type: String?, _ minutes: Double) -> Double {
        if minutes <= 0 { return 0 }
        if isStrength(type) { return minutes }
        if isWalk(type) { return minutes * walkLoadPerMin / strengthLoadPerMin }
        return 0
    }

    static func trimp(minutes: Double, hr: Int, restingHr: Int, hrMax: Double, male: Bool = true, withBase: Bool = true) -> Double {
        if minutes <= 0 { return 0 }
        let reserve = max(hrMax - Double(restingHr), 20.0)
        let hrr = min(max((Double(hr) - Double(restingHr)) / reserve, 0.0), 1.1)
        return minutes * (hrr * exp(strainExp * hrr) + (withBase ? strainBasePerMin : 0))
    }

    static func strainFromTrimp(_ trimp: Double, strengthMinutes: Double = 0) -> Double {
        let v = strainScale * log(1.0 + (max(0.0, trimp) + strengthLoadPerMin * max(0.0, strengthMinutes)) / strainTrimpRef)
        return min(max(v, 0.0), 21.0)
    }

    /// Esfuerzo del día + la carga muscular de [strengthMinutes] minutos de fuerza/funcional + la base por minuto de las
    /// actividades ([activityMinutes], 27/10): el pulso del día va SIN base (ver strainOf). Igual que Android.
    static func addStrength(_ strain: Double, _ strengthMinutes: Double, _ activityMinutes: Double = 0) -> Double {
        if strengthMinutes <= 0 && activityMinutes <= 0 { return strain }
        let t = strainTrimpRef * (exp(strain / strainScale) - 1.0) + strainBasePerMin * max(0, activityMinutes)
        return strainFromTrimp(t, strengthMinutes: max(0, strengthMinutes))
    }

    /// Minutos de actividades que llevan la base por minuto en el esfuerzo del día (todas menos las siestas).
    static func activityLoadMinutes(_ type: String?, _ minutes: Double) -> Double {
        (minutes <= 0 || type == napType) ? 0 : minutes
    }

    /// [readings] = (hora en ms, pulso), en orden. Esfuerzo del DÍA (27/10): sin la base por minuto (24 h en reposo sumaban
    /// 2,5–3 puntos que WHOOP no da); la base solo cuenta dentro de las actividades (addStrength).
    static func strainOf(readings: [(Int64, Int)], restingHr: Int?, hrMax: Double, male: Bool = true,
                         maxGapMinutes: Double = 5.0) -> Double {
        if readings.count < 2 { return 0 }
        let rhr = restingHr ?? defaultRestingHr
        var total = 0.0
        for i in 1..<readings.count {
            let dt = Double(readings[i].0 - readings[i - 1].0) / 60000.0
            if dt <= 0 || dt > maxGapMinutes { continue }
            total += trimp(minutes: dt, hr: readings[i].1, restingHr: rhr, hrMax: hrMax, male: male, withBase: false)
        }
        return strainFromTrimp(total)
    }

    // ---------- Recuperación ----------
    /// 23/10 (igual que Android): lineal, ajustada con 199 noches de WHOOP (error medio en validación cruzada 4,8):
    ///   recuperación = 64,28 + 89,74 · (ln VFC − media) − 0,4625 · (FCR − media)
    static let recBias = 64.2755
    static let recKHrv = 89.7396
    static let recKRhr = 0.4625
    /// Línea base de partida: la de WHOOP el 14/10, antes de usar PulseApp (VFC 88 ms, FC reposo 58,5 lpm).
    static let fallbackHrv = 88.0
    static let fallbackRhr = 58.5

    struct RecoveryResult {
        let total: Int
        let hrvDeltaPct: Double?    // % de tu VFC frente a tu media (+10 = un 10 % por encima)
        let rhrDelta: Double?       // lpm frente a tu media
        let respPenalty: Bool
        let usedPersonalBaseline: Bool
    }

    static func recovery(hrv: Double?, restingHr: Int?, respiratoryRate: Double?, baseline b: PersonalBaseline?) -> RecoveryResult {
        let lnRef = b?.lnHrvMean ?? log(fallbackHrv)
        var delta: Double? = nil
        if let h = hrv, h > 0 { delta = log(h) - lnRef }
        var rhrDelta: Double? = nil
        if let r = restingHr { rhrDelta = Double(r) - (b?.avgRestingHr ?? fallbackRhr) }
        var score = recBias + recKHrv * (delta ?? -0.1) - recKRhr * (rhrDelta ?? 0.0)
        var penalty = false
        if let rr = respiratoryRate, rr >= 8.0, rr <= 25.0, let bb = b, let m = bb.respMean, let sd = bb.respSd {
            let z = (rr - m) / sd
            if z > 2.0 { score -= 12.0 * (z - 2.0); penalty = true }
        }
        let raw = Int(score.rounded(.down))
        let total = min(max(raw, 1), 99)
        var pct: Double? = nil
        if let d = delta { pct = (exp(d) - 1) * 100 }
        return RecoveryResult(total: total, hrvDeltaPct: pct, rhrDelta: rhrDelta, respPenalty: penalty, usedPersonalBaseline: b != nil)
    }

    // ---------- Sueño ----------
    /// Calificación del sueño como WHOOP. consistency nil → se usa 66 (tu media en WHOOP).
    static func sleepScore(hoursVsNeedPct: Int, efficiencyPct: Int?, consistencyPct: Int?) -> Int {
        let h = Double(min(max(hoursVsNeedPct, 0), 100))
        let v = 0.281 * h + 0.202 * Double(efficiencyPct ?? 93) + 0.288 * Double(consistencyPct ?? 66) + 19.6
        return min(max(Int(v), 0), 100)
    }

    /// Regularidad 0–100 como WHOOP (18/10): cuánto se solapa la última noche con cada una de las 3 anteriores
    /// (intersección / unión del tramo en cama, por hora del día), en media, menos 7. Ajustado con 145 noches del export
    /// de WHOOP: error medio 4,9 puntos (la fórmula anterior fallaba 27). Cada noche = (minuto de inicio, minuto de fin);
    /// la última es la que se califica. nil con menos de 2 noches.
    /// 26/10: WHOOP mide la regularidad en hora "del cuerpo", sin el cambio de hora (con sus propias horas de 9 noches: en hora
    /// local la noche 25→26 da 54 %, sin cambio de hora 67 %, WHOOP 66 %). Pasa la noche [date] (inicio s, fin e en minutos del
    /// día, hora local) a hora de invierno: en verano se resta 1 h. Igual que Android.
    static func standardNight(_ date: String, _ s: Int, _ e: Int) -> (Int, Int) {
        guard let day = TimeUtil.parseDayKey(date) else { return (s, e) }
        let tz = TimeUtil.timeZone
        func shift(_ dayStart: Int64, _ minute: Int) -> Int {
            let t = Date(timeIntervalSince1970: TimeInterval(dayStart / 1000 + Int64(minute) * 60))
            return Int(tz.daylightSavingTimeOffset(for: t) / 60)
        }
        let startDay = s > e ? TimeUtil.addDays(day, -1) : day
        return (s - shift(startDay, s), e - shift(day, e))
    }

    static func sleepConsistency(_ nightsOldestFirst: [(Int, Int)]) -> Int? {
        if nightsOldestFirst.count < 2 { return nil }
        func axis(_ n: (Int, Int)) -> (Int, Int) {
            let s = ((n.0 - 720) % 1440 + 1440) % 1440
            var e = ((n.1 - 720) % 1440 + 1440) % 1440
            if e <= s { e += 1440 }
            return (s, e)
        }
        let last = axis(nightsOldestFirst.last!)
        let prev = nightsOldestFirst.dropLast().suffix(3).map { axis($0) }
        var sum = 0.0
        for p in prev {
            let inter = max(min(last.1, p.1) - max(last.0, p.0), 0)
            let union = (last.1 - last.0) + (p.1 - p.0) - inter
            sum += union > 0 ? Double(inter) / Double(union) : 0
        }
        let v = Int((sum / Double(prev.count) * 100 - 7).rounded())
        return min(max(v, 0), 100)
    }

    /// Minutos extra de sueño por el esfuerzo del día (0 hasta 8, luego 6 min por punto).
    static func sleepNeedFromStrain(_ strain: Double) -> Int {
        return Int(max(0.0, strain - 8.0) * 6.0)
    }
}
