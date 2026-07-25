import Foundation
import SwiftData

/// A per-category monthly spending limit.
@Model
final class Budget {
    @Attribute(.unique) var id: UUID
    var monthlyLimit: Decimal
    @Relationship(deleteRule: .nullify) var category: Category?
    /// Start-of-month the user dismissed this budget's over-budget alert; the
    /// alert stays hidden for that month and re-evaluates next month. Defaulted
    /// for lightweight migration.
    var overBudgetDismissedMonth: Date? = nil

    init(id: UUID = UUID(), monthlyLimit: Decimal, category: Category? = nil) {
        self.id = id
        self.monthlyLimit = monthlyLimit
        self.category = category
    }
}
