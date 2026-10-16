import Foundation
import SwiftUI

/// Colores y tipografía del rediseño (los mismos que en Android).
enum Theme {
    static let background = Color(hex: 0x0F1519)
    static let card = Color(hex: 0x1B2126)
    static let cardElevated = Color(hex: 0x292F33)
    static let track = Color(hex: 0x33393E)
    static let hairline = Color(hex: 0xF4F5F6, opacity: 0.08)
    static let recoveryGreen = Color(hex: 0x00F88A)
    static let sleepBlue = Color(hex: 0x8FB3D2)
    static let strainBlue = Color(hex: 0x02A9F7)
    static let alertRed = Color(hex: 0xF04C55)
    static let alertAmber = Color(hex: 0xF9C718)
    static let textPrimary = Color(hex: 0xF4F5F6)
    static let textSecondary = Color(hex: 0x95999D)
    static let onAccent = Color(hex: 0x0F1519)
    static let stageAwake = Color(hex: 0xDBE6F2)
    static let stageRem = Color(hex: 0xB1B0EF)
    static let stageLight = Color(hex: 0x6291BA)
    static let stageDeep = Color(hex: 0x2C5A9D)
    static let zone1 = Color(hex: 0x546673)
    static let zone2 = Color(hex: 0x578DB2)
    static let zone3 = Color(hex: 0x02A9F7)
    static let zone4 = Color(hex: 0xF9C718)
    static let zone5 = Color(hex: 0xF04C55)

    static func recoveryColor(_ score: Int) -> Color {
        if score >= 67 { return recoveryGreen }
        if score >= 34 { return alertAmber }
        return alertRed
    }

    static func stressColor(_ level: String) -> Color {
        if level == "ALTO" { return alertAmber }
        if level == "MEDIO" { return recoveryGreen }
        return strainBlue
    }

    static func stageColor(_ stage: Int) -> Color {
        switch stage {
        case SleepStager.awake: return stageAwake
        case SleepStager.light: return stageLight
        case SleepStager.deep: return stageDeep
        default: return stageRem
        }
    }

    // Tipografía: números y etiquetas en Barlow Condensed (incluida en la app); texto con la fuente del sistema.
    static func number(_ size: Double) -> Font { return Font.custom("BarlowCondensed-Bold", size: size) }
    static func label(_ size: Double) -> Font { return Font.custom("BarlowCondensed-SemiBold", size: size) }
    static func text(_ size: Double, _ weight: Font.Weight = .regular) -> Font { return Font.system(size: size, weight: weight) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }
}
