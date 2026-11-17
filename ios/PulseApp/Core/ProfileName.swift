import Foundation

/// 17/11: nombre que se muestra en el Perfil (como WHOOP). Solo se guarda en este móvil; no entra en ningún cálculo.
enum ProfileName {
    private static let key = "pulseapp_profile_name"
    static func get() -> String { return UserDefaults.standard.string(forKey: key) ?? "" }
    static func set(_ name: String) {
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }
    /// Iniciales para el avatar ("Daniel Torres" → "DT"); sin nombre, nil.
    static func initials() -> String? {
        let parts = get().split(separator: " ").filter { !$0.isEmpty }
        guard let first = parts.first?.first else { return nil }
        let second = parts.count > 1 ? parts[1].first : nil
        return (String(first) + (second.map { String($0) } ?? "")).uppercased()
    }
}
