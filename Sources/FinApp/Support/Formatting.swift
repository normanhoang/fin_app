import Foundation
import SwiftUI

enum Money {
    /// Currency string for a Decimal amount. Uses the account currency when known.
    static func string(_ value: Decimal, code: String = "USD") -> String {
        value.formatted(.currency(code: code))
    }
}

extension Color {
    /// Build a Color from a "#RRGGBB" hex string; falls back to gray.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let int = UInt64(cleaned, radix: 16), cleaned.count == 6 else {
            self = .gray
            return
        }
        self = Color(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}
