import Foundation
import SwiftUI

enum Money {
    /// Currency string for a Decimal amount. Uses the account currency when known.
    static func string(_ value: Decimal, code: String = "USD") -> String {
        value.formatted(.currency(code: code))
    }
}

/// Balance coloring: red is reserved for liabilities (negative balances);
/// positive balances stay neutral.
func balanceColor(_ value: Decimal) -> Color {
    value < 0 ? .negative : .textPrimary
}

/// Transaction-amount coloring: green for inflows, neutral for outflows.
func amountColor(_ value: Decimal) -> Color {
    value > 0 ? .positive : .textPrimary
}

/// Memoizes parsed hex colors — category colors are re-resolved on every row
/// render, and the palette is a handful of strings.
private final class HexColorCache: @unchecked Sendable {
    static let shared = HexColorCache()
    private let lock = NSLock()
    private var colors: [String: Color] = [:]

    func color(for hex: String) -> Color {
        lock.lock()
        defer { lock.unlock() }
        if let cached = colors[hex] { return cached }
        let parsed = Self.parse(hex)
        colors[hex] = parsed
        return parsed
    }

    /// Parse a "#RRGGBB" hex string; falls back to gray.
    private static func parse(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let int = UInt64(cleaned, radix: 16), cleaned.count == 6 else { return .gray }
        return Color(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
    }
}

extension Color {
    /// Build a Color from a "#RRGGBB" hex string; falls back to gray. Cached.
    init(hex: String) {
        self = HexColorCache.shared.color(for: hex)
    }
}
