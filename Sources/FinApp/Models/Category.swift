import Foundation
import SwiftData

/// A spending or income category. SimpleFin provides none, so these are
/// local: seeded defaults plus anything the user creates.
@Model
final class Category {
    @Attribute(.unique) var name: String
    var colorHex: String
    var systemIcon: String
    /// Income categories (paycheck, refunds) are kept out of spending totals.
    var isIncome: Bool
    /// Hidden categories are omitted from the Dashboard "Spending Categories" list.
    var isHidden: Bool = false

    @Relationship(deleteRule: .nullify)
    var transactions: [Transaction]

    @Relationship(deleteRule: .cascade, inverse: \CategoryRule.category)
    var rules: [CategoryRule]

    init(
        name: String,
        colorHex: String,
        systemIcon: String,
        isIncome: Bool = false,
        transactions: [Transaction] = [],
        rules: [CategoryRule] = []
    ) {
        self.name = name
        self.colorHex = colorHex
        self.systemIcon = systemIcon
        self.isIncome = isIncome
        self.transactions = transactions
        self.rules = rules
    }
}
