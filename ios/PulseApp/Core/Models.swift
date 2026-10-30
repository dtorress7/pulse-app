import Foundation

struct UserProfile: Codable, Equatable {
    var birthdayMillis: Int64
    var weightKg: Double
    var heightCm: Double
    var sex: String               // "M" o "F"
    var vo2Max: Double? = nil
    var vo2MaxUpdatedDate: String? = nil

    func ageYears() -> Int {
        let diff = Double(TimeUtil.nowMillis() - birthdayMillis)
        return Int(diff / (365.25 * 24 * 60 * 60 * 1000))
    }
}

struct DailyMetrics: Codable, Equatable {
    var date: String                 // yyyy-MM-dd
    var restingHr: Int?
    var avgHrv: Double?
    var sleepMinutes: Int?
    var strain: Double?
    var vo2Max: Double?
    var caloriesKcal: Double?
    var sleepStartMinuteOfDay: Int? = nil
    var sleepEndMinuteOfDay: Int? = nil
    var sleepEfficiencyPct: Int? = nil
    var respiratoryRate: Double? = nil
    // Fases de esa noche (17/10, como la base de datos v9 de Android). Vacías en noches sin movimiento o guardadas antes.
    var lightMinutes: Int? = nil
    var deepMinutes: Int? = nil
    var remMinutes: Int? = nil
    var awakeMinutes: Int? = nil
    var wakeEpisodes: Int? = nil
    var latencyMinutes: Int? = nil
    // Notas oficiales de WHOOP, solo en días importados del export (23/10). En los de PulseApp, nil.
    var whoopRecovery: Int? = nil
    var whoopSleepScore: Int? = nil
    var whoopConsistency: Int? = nil
    var whoopSleepNeed: Int? = nil
}

struct ActivitySession: Codable, Equatable, Identifiable {
    var id: Int64 = 0
    var startMillis: Int64
    var endMillis: Int64
    var avgHr: Int
    var maxHr: Int
    var strain: Double
    var caloriesKcal: Double
    var minutesZone1: Int
    var minutesZone2: Int
    var minutesZone3: Int
    var minutesZone4: Int
    var minutesZone5: Int
    var type: String = "Sin clasificar"
    var autoDetected: Bool = false
    var minutesZone0: Int = 0
}

struct PersonalBaseline {
    var avgHrv: Double
    var avgRestingHr: Double
    var daysUsed: Int
    var lnHrvMean: Double
    var lnHrvSd: Double = 0.12
    var rhrSd: Double = 2.5
    var respMean: Double? = nil
    var respSd: Double? = nil
    /// Media simple de ln VFC de esas noches (percentil de la recuperación, 30/10); nil con < 7 noches.
    var lnHrvMean30: Double? = nil
}

/// Una lectura de pulso con su hora real y los intervalos RR (ms) si los hay.
struct HrReading {
    let timeMillis: Int64
    let bpm: Int
    let rr: [Double]
}

struct DailySummary {
    var restingHr: Int?
    var avgHr: Int?
    var avgHrv: Double?
    var vo2Max: Double?
    var strain: Double
    var sleepMinutes: Int?        // tiempo REALMENTE dormido
    var timeInBedMinutes: Int?
    var awakeMinutes: Int?
    var sleepStart: String?
    var sleepEnd: String?
    var sleepStartMinuteOfDay: Int?
    var sleepEndMinuteOfDay: Int?
    var sleepEfficiencyPct: Int?
    var respiratoryRate: Double?
    var totalReadings: Int
    var sleepStartMillis: Int64? = nil
    var sleepEndMillis: Int64? = nil
    /// Inicio de la ventana de descanso antes del recorte de las fases (para la latencia del sueño).
    var restStartMillis: Int64? = nil
    /// Fases minuto a minuto (solo si esa noche hay movimiento grabado).
    var stages: SleepStager.Result? = nil

    static func empty() -> DailySummary {
        return DailySummary(restingHr: nil, avgHr: nil, avgHrv: nil, vo2Max: nil, strain: 0,
                            sleepMinutes: nil, timeInBedMinutes: nil, awakeMinutes: nil,
                            sleepStart: nil, sleepEnd: nil, sleepStartMinuteOfDay: nil, sleepEndMinuteOfDay: nil,
                            sleepEfficiencyPct: nil, respiratoryRate: nil, totalReadings: 0)
    }
}

struct SleepPlan {
    let baselineMinutes: Int
    let strainAdjustmentMinutes: Int
    let debtAdjustmentMinutes: Int
    let napAdjustmentMinutes: Int
    let totalNeedMinutes: Int
    let suggestedBedtime: String?
}

struct StressPoint {
    let minuteOfDay: Int
    let score: Float          // 0…3
    let timeMillis: Int64
}

struct StressSummary {
    let currentScore: Float?
    let level: String          // BAJO / MEDIO / ALTO
    let lastUpdateMinute: Int?
    let series: [StressPoint]
}

struct ActivityPeriod {
    let startMinute: Int
    let endMinute: Int
}
