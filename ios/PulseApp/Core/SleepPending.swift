import Foundation

/// 11/11 (igual que Android SleepPending): "Sueño detectado" como WHOOP. Tras despertar (≥ 5 min sin dormir) los anillos quedan en
/// "--" hasta que pulsas "FIN DEL SUEÑO" / "PROCESO", o solos a las 2 h (PROVISIONAL). Procesar no cambia las cuentas.
enum SleepPending {
    static let minAwakeMs: Int64 = 5 * 60_000
    static let autoMs: Int64 = 120 * 60_000
    private static func key(_ date: String) -> String { "pulseapp_sleep_processed_" + date }

    static func processed(_ date: String) -> Bool { UserDefaults.standard.bool(forKey: key(date)) }
    static func markProcessed(_ date: String) { UserDefaults.standard.set(true, forKey: key(date)) }

    /// [date] = día en que acaba la noche (yyyy-MM-dd); [sleepEnd] = fin de la noche (ms).
    static func isPending(date: String, sleepEnd: Int64?, now: Int64 = TimeUtil.nowMillis()) -> Bool {
        guard let e = sleepEnd, !processed(date) else { return false }
        let d = now - e
        return d >= minAwakeMs && d < autoMs
    }
}
