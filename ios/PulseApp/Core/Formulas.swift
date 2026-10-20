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

    // ---------- Detección automática de actividades (v2, 20/10) ----------
    // Igual que Android (Formulas.kt), calibrada con los funcionales que WHOOP detectó solo (19/10 y 20/10):
    // tramo ≥ 26 % de la reserva (tolera 2 min por debajo), núcleo ≥ 50 % (≥ 8 min), inicio = primer núcleo adelantado
    // mientras ≥ zona 1, fin = último núcleo o más tarde si el pulso vuelve a subir ≥ 5 lpm; dura ≥ 12 min.
    static func detectActivities(_ minutes: [(Int64, Double)], hrMax: Double, rhr: Int? = nil) -> [(Int64, Int64)] {
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
            if coreIdx.count >= 8, var s = coreIdx.first, var e = coreIdx.last {
                while s > s0 && minutes[s - 1].1 >= z1 && minutes[s].0 - minutes[s - 1].0 == 1 { s -= 1 }
                var low = Double.greatestFiniteMagnitude
                if e < e0 {
                    for k in (e + 1)...e0 {
                        let v = minutes[k].1
                        if v >= low + 5 { e = k }
                        low = min(low, v)
                    }
                }
                if minutes[e].0 - minutes[s].0 + 1 >= 12 { out.append((minutes[s].0, minutes[e].0)) }
            }
            i = e0 + 1
        }
        return out
    }

    // ---------- Esfuerzo ----------
    static let strainScale = 4.14
    static let strainTrimpRef = 2.6
    static let minHrFraction = 0.45
    static let defaultRestingHr = 58

    static func trimp(minutes: Double, hr: Int, restingHr: Int, hrMax: Double, male: Bool = true) -> Double {
        if minutes <= 0 || Double(hr) < minHrFraction * hrMax { return 0 }
        let reserve = max(hrMax - Double(restingHr), 20.0)
        let hrr = min(max((Double(hr) - Double(restingHr)) / reserve, 0.0), 1.1)
        if hrr <= 0 { return 0 }
        if male { return minutes * hrr * 0.64 * exp(1.92 * hrr) }
        return minutes * hrr * 0.86 * exp(1.67 * hrr)
    }

    static func strainFromTrimp(_ trimp: Double) -> Double {
        let v = strainScale * log(1.0 + max(0.0, trimp) / strainTrimpRef)
        return min(max(v, 0.0), 21.0)
    }

    /// [readings] = (hora en ms, pulso), en orden.
    static func strainOf(readings: [(Int64, Int)], restingHr: Int?, hrMax: Double, male: Bool = true,
                         maxGapMinutes: Double = 5.0) -> Double {
        if readings.count < 2 { return 0 }
        let rhr = restingHr ?? defaultRestingHr
        var total = 0.0
        for i in 1..<readings.count {
            let dt = Double(readings[i].0 - readings[i - 1].0) / 60000.0
            if dt <= 0 || dt > maxGapMinutes { continue }
            total += trimp(minutes: dt, hr: readings[i].1, restingHr: rhr, hrMax: hrMax, male: male)
        }
        return strainFromTrimp(total)
    }

    // ---------- Recuperación ----------
    static let kHrv = 5.5
    static let kRhr = 0.028
    static let bias = 0.84
    /// Referencias mientras no haya 3 noches propias: tu media reciente en WHOOP (VFC 86 ms, FC reposo 59 lpm).
    static let fallbackHrv = 86.0
    static let fallbackRhr = 59.0

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
        var logit = bias + kHrv * (delta ?? -0.1) - kRhr * (rhrDelta ?? 0.0)
        var penalty = false
        if let rr = respiratoryRate, rr >= 8.0, rr <= 25.0, let bb = b, let m = bb.respMean, let sd = bb.respSd {
            let z = (rr - m) / sd
            if z > 2.0 { logit -= 0.5 * (z - 2.0); penalty = true }
        }
        let raw = Int(100.0 / (1.0 + exp(-logit)))
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
