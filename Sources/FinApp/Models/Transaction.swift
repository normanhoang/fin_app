import Foundation
import SwiftData

/// A single transaction. Keyed by SimpleFin's transaction `id`.
/// `amount` sign follows SimpleFin: negative = outflow/debit, positive = inflow.
@Model
final class Transaction {
    @Attribute(.unique) var id: String
    var posted: Date
    var amount: Decimal
    var detail: String          // SimpleFin "description"
    var payee: String?
    var memo: String?
    var pending: Bool
    /// True once the user has manually set the category, so re-categorization
    /// passes leave it untouched.
    var categorizedByUser: Bool

    var account: Account?

    @Relationship(inverse: \Category.transactions)
    var category: Category?

    init(
        id: String,
        posted: Date,
        amount: Decimal,
        detail: String,
        payee: String? = nil,
        memo: String? = nil,
        pending: Bool = false,
        categorizedByUser: Bool = false,
        account: Account? = nil,
        category: Category? = nil
    ) {
        self.id = id
        self.posted = posted
        self.amount = amount
        self.detail = detail
        self.payee = payee
        self.memo = memo
        self.pending = pending
        self.categorizedByUser = categorizedByUser
        self.account = account
        self.category = category
    }

    /// Best text to match merchant rules against.
    var matchText: String {
        (payee ?? detail).lowercased()
    }

    var isInflow: Bool { amount > 0 }
}
