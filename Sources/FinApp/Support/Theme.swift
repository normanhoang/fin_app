import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension Color {
    /// Adaptive color resolved from separate light/dark hex values, so the whole
    /// palette follows the system (or the user's chosen) appearance.
    init(lightHex: String, darkHex: String) {
        #if canImport(UIKit)
        self = Color(UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? darkHex : lightHex))
        })
        #else
        self = Color(hex: darkHex)
        #endif
    }
}

/// "Quiet Capital" design tokens. Dark = layered charcoal; light = clean paper.
extension Color {
    static let appBackground = Color(lightHex: "#F3F4F6", darkHex: "#0E0F11")
    static let surface = Color(lightHex: "#FFFFFF", darkHex: "#1A1C1F")
    static let surfaceElevated = Color(lightHex: "#ECEEF1", darkHex: "#212429")
    static let hairline = Color(lightHex: "#E3E6EB", darkHex: "#2C2F34")
    static let textPrimary = Color(lightHex: "#14161A", darkHex: "#F2F4F7")
    static let textSecondary = Color(lightHex: "#6B7280", darkHex: "#9AA0A8")
    static let positive = Color(lightHex: "#0FA37F", darkHex: "#34E5B0")
    static let negative = Color(lightHex: "#E5484D", darkHex: "#FF6B6B")
    /// Brand tint (mint). Darkened in light mode for contrast on white.
    static let brand = Color(lightHex: "#0FB58A", darkHex: "#34E5B0")
}

/// User-selectable appearance, persisted across launches.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
