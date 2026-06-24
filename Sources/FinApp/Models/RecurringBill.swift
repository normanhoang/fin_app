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
        self.category = category
    }
}
