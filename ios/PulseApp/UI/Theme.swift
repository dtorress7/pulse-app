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

    // ---------- Aspecto WHOOP (17/10, los mismos colores w_* que Android) ----------
    static let wBgTop = Color(hex: 0x283237)
    static let wBgMid = Color(hex: 0x1C2327)
    static let wBgBottom = Color(hex: 0x12171A)
    static let wCard = Color(hex: 0x2A3237)
    static let wRow = Color(hex: 0x3A4348)
    static let wTrack = Color(hex: 0x3A4247)
    static let wRecoveryHigh = Color(hex: 0x16EC06)
    static let wRingSleep = Color(hex: 0x7BA1C3)
    static let wMint = Color(hex: 0x2CE5A3)
    static let wMintBg = Color(hex: 0x1F4A40)
    static let wLowBlue = Color(hex: 0x64A8EA)
    static let wLowBlueBg = Color(hex: 0x2B4A66)
    static let wTrendAmber = Color(hex: 0xF5A524)
    static let wChip = Color(hex: 0x3A4247)
    static let wPopupTop = Color(hex: 0x33365A)
    static let wPopupBottom = Color(hex: 0x262A44)
    static let wInsightStart = Color(hex: 0x8C7D6C)
    static let wInsightEnd = Color(hex: 0x3B4954)
    static let wInsightBorder = Color(hex: 0x7C6CF0)
    static let wStressLineLow = Color(hex: 0x38C6D9)
    static let wStressLineHigh = Color(hex: 0xA9E36B)
    static let wStressMidDim = Color(hex: 0x178A63)
    static let wStressLowDim = Color(hex: 0x3D5E80)
    static let wStressHighDim = Color(hex: 0x8A6420)
    static let wTextDim = Color(hex: 0x6F767B)
    static let wStageAwake = Color(hex: 0xD9DDE0)
    static let wStageLight = Color(hex: 0xA9A6F2)
    static let wStageDeep = Color(hex: 0xF49BEA)
    static let wStageRem = Color(hex: 0xA04BEA)
    static let wNeedBase = Color(hex: 0x5E666B)
    static let wNeedDebt = Color(hex: 0xD9DDE0)
    static let wHrSleep = Color(hex: 0x8FB0C9)
    static let wZone = [Color(hex: 0xF4F5F6), Color(hex: 0xB7CBD9), Color(hex: 0x58A8E6), Color(hex: 0x2CE5A3), Color(hex: 0xF7A400), Color(hex: 0xFF5A3C)]
    static let wZoneBar = [Color(hex: 0xB7CBD9), Color(hex: 0x3F8FCB), Color(hex: 0x4FB98A), Color(hex: 0xF7A44A), Color(hex: 0xF2662E)]
    static let tabBar = Color(hex: 0x1B2126, opacity: 0.92)
    static let logoBlue = Color(hex: 0x02A9F7)
    static let logoGreen = Color(hex: 0x16EC06)

    /// Fondo de pantalla de WHOOP: gris azulado arriba que se oscurece hacia abajo.
    static var wBackground: LinearGradient {
        return LinearGradient(colors: [wBgTop, wBgMid, wBgBottom], startPoint: .top, endPoint: .bottom)
    }

    static func wRecoveryColor(_ score: Int) -> Color {
        if score >= 67 { return wRecoveryHigh }
        if score >= 34 { return alertAmber }
        return alertRed
    }

    static func wStressColor(_ level: String) -> Color {
        if level == "ALTO" { return alertAmber }
        if level == "MEDIO" { return wMint }
        return wLowBlue
    }

    static func medium(_ size: Double) -> Font { return Font.custom("BarlowCondensed-Medium", size: size) }

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
