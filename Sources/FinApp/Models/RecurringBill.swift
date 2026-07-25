import Foundation
import SwiftData

enum Cadence: String, Codable, CaseIterable {
    case weekly
    case biweekly
    case monthly
    case quarterly
    case yearly

    /// Nominal day span, used to project the next due date.
    var days: Int {
        switch self {
        case .weekly: 7
        case .biweekly: 14
        case .monthly: 30
        case .quarterly: 91
        case .yearly: 365
        }
    }
}

/// A detected or user-confirmed recurring charge.
@Model
final class RecurringBill {
    @Attribute(.unique) var id: UUID
    var merchantName: String
    var expectedAmount: Decimal
    var cadenceRaw: String
    var lastSeen: Date
    var nextDue: Date?
    /// false = a candidate awaiting user confirmation; true = confirmed bill.
    var confirmed: Bool
    /// User dismissed this detected candidate; kept (not deleted) so re-detection
    /// on the next sync doesn't resurface it. Defaulted for lightweight migration.
    var dismissed: Bool = false
    /// User set `nextDue` by hand; detection keeps its hands off until a new charge
    /// posts on/after that date, then auto-projection resumes. Defaulted for
    /// lightweight migration.
    var nextDueSetByUser: Bool = false
    /// The previous stable charge amount when the newest charge changed price
    /// (`expectedAmount` then holds the new amount). nil while the price is
    /// stable — detection clears it once charges settle at the new amount.
    /// Defaulted for lightweight migration.
    var previousAmount: Decimal? = nil
    /// When the price change was observed (posted date of the first charge at
    /// the new amount). Defaulted for lightweight migration.
    var amountChangedAt: Date? = nil
    /// The `expectedAmount` the user acknowledged via the price-alert close button;
    /// the alert stays hidden while this equals the current amount, and reappears
    /// if the price moves again. Defaulted for lightweight migration.
    var priceAckAmount: Decimal? = nil
    @Relationship(deleteRule: .nullify) var category: Category?

    var cadence: Cadence {
        get { Cadence(rawValue: cadenceRaw) ?? .monthly }
        set { cadenceRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        merchantName: String,
        expectedAmount: Decimal,
        cadence: Cadence,
        lastSeen: Date,
        nextDue: Date? = nil,
        confirmed: Bool = false,
        dismissed: Bool = false,
        nextDueSetByUser: Bool = false,
        category: Category? = nil
    ) {
        self.id = id
        self.merchantName = merchantName
        self.expectedAmount = expectedAmount
        self.cadenceRaw = cadence.rawValue
        self.lastSeen = lastSeen
        self.nextDue = nextDue
        self.confirmed = confirmed
        self.dismissed = dismissed
        self.nextDueSetByUser = nextDueSetByUser
        self.category = category
    }
}
