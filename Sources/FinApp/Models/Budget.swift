import Foundation
import SwiftData

/// A per-category monthly spending limit.
@Model
final class Budget {
    @Attribute(.unique) var id: UUID
    var monthlyLimit: Decimal
    @Relationship(deleteRule: .nullify) var category: Category?

    init(id: UUID = UUID(), monthlyLimit: Decimal, category: Category? = nil) {
        self.id = id
        self.monthlyLimit = monthlyLimit
        self.category = category
    }
}
