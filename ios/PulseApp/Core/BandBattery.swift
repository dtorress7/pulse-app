import Foundation
import UserNotifications

/// Batería de la pulsera (31/10). La WHOOP 5.0 manda sola el EVENTO 3 (tipo 48, [10] = 3) más o menos cada 14 min:
/// [12..15] hora unix, [21..22] u16 = nivel en décimas de % (997 = 99,7 %), [25..26] u16 = tensión en mV (4380 → 3869 mV).
/// Comprobado con el historial crudo del 18–22/10: el nivel solo baja (99,7 % → 50,6 % en 4 días, ~12 %/día) y sigue a la tensión
/// (r 0,999). Carga: eventos 7/8 (carga sí/no), 5/6 (5 V externos) y 21/22 (batería externa puesta/quitada) según la numeración
/// de WHOOP que cuadra con nuestros datos en 3, 11/12 y 16 (aún sin verlos cargando); por si acaso, también "cargando" si el nivel sube.
enum BandBattery {
    struct State: Codable {
        var tenths: Int        // 0…1000
        var mv: Int
        var unix: Int64
        var charging: Bool
    }

    private static let key = "pulseapp_band_battery"
    private static let lowKey = "pulseapp_band_battery_low_notified"
    static var onChange: (() -> Void)? = nil

    static var current: State? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(State.self, from: d)
    }

    /// Porcentaje entero para mostrar (nil si no hay dato de las últimas 24 h).
    static var percent: Int? {
        guard let s = current, Int64(Date().timeIntervalSince1970) - s.unix < 86_400 else { return nil }
        return Int((Double(s.tenths) / 10).rounded())
    }
    static var isCharging: Bool { return percent != nil && (current?.charging ?? false) }

    private static func save(_ s: State) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
        onChange?()
    }

    /// Un evento de la pulsera (tipo 48). Devuelve un texto para el registro si cambió algo.
    @discardableResult
    static func handleEvent(_ frame: [UInt8]) -> String? {
        guard frame.count > 10 else { return nil }
        let id = Int(frame[10])
        var s = current ?? State(tenths: -1, mv: 0, unix: 0, charging: false)
        switch id {
        case 3:
            guard frame.count >= 27 else { return nil }
            let unix = Int64(Bytes.u32(frame, 12))
            let tenths = Bytes.u16(frame, 21), mv = Bytes.u16(frame, 25)
            if tenths > 1000 || mv < 2500 || mv > 4600 { return nil }
            if s.tenths >= 0 && unix - s.unix < 7200 && unix > s.unix {
                if tenths > s.tenths + 2 || mv > s.mv + 20 { s.charging = true }
                else if tenths < s.tenths { s.charging = false }
            }
            s.tenths = tenths; s.mv = mv; s.unix = max(unix, s.unix)
            save(s)
            checkLow(s)
            return "🔋 Batería de la pulsera: \(String(format: "%.1f", Double(tenths) / 10)) % (\(mv) mV)\(s.charging ? " · cargando" : "")"
        case 5, 7, 21:
            s.charging = true; s.unix = max(s.unix, Int64(Date().timeIntervalSince1970)); save(s)
            UserDefaults.standard.set(false, forKey: lowKey)
            return "🔌 Evento \(id): la pulsera empieza a cargar"
        case 6, 8, 22:
            s.charging = false; save(s)
            return "🔌 Evento \(id): la pulsera deja de cargar"
        default:
            return nil
        }
    }

    /// Aviso de batería baja: una vez al bajar del 20 % (se rearma al cargar o al pasar del 25 %).
    private static func checkLow(_ s: State) {
        let notified = UserDefaults.standard.bool(forKey: lowKey)
        if s.charging || s.tenths >= 250 { if notified { UserDefaults.standard.set(false, forKey: lowKey) }; return }
        if s.tenths < 200 && !notified {
            UserDefaults.standard.set(true, forKey: lowKey)
            Notifier.post(id: "battery-low", title: "Recordatorio de carga de batería",
                          body: "La batería de tu WHOOP está a menos del 20 % (\(Int((Double(s.tenths) / 10).rounded())) %). Cárgala.")
        }
    }
}

/// Notificaciones locales de PulseApp (31/10), como las de WHOOP.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(id: String, title: String, body: String, after seconds: TimeInterval = 1) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
    }
}
