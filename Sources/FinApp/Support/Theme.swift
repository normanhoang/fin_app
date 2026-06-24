import SwiftUI

/// "Quiet Capital" design tokens — layered charcoal surfaces, restrained mint/coral
/// money accents. Reused across screens so the look stays consistent.
extension Color {
    static let appBackground = Color(hex: "#0E0F11")
    static let surface = Color(hex: "#1A1C1F")
    static let surfaceElevated = Color(hex: "#212429")
    static let hairline = Color(hex: "#2C2F34")
    static let textPrimary = Color(hex: "#F2F4F7")
    static let textSecondary = Color(hex: "#9AA0A8")
    static let positive = Color(hex: "#34E5B0")
    static let negative = Color(hex: "#FF6B6B")
    /// Brand tint (mint). Matches the AccentColor asset.
    static let brand = Color(hex: "#34E5B0")
}
