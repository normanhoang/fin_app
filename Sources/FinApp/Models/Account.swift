import Foundation
import SwiftData

/// A financial account synced from SimpleFin. Keyed by SimpleFin's account `id`
/// for idempotent upsert.
@Model
final class Account {
    @Attribute(.unique) var id: String
    /// Raw ID and organization scope reported by SimpleFIN. Optional defaults
    /// allow existing stores to migrate in place on their next sync.
    var providerID: String? = nil
    var providerScope: String? = nil
    var org: String
    var name: String
    var currency: String
    var balance: Decimal
    var availableBalance: Decimal?
    var balanceDate: Date
    /// Asset/debt classification. Defaulted so existing stores migrate lightly.
    var typeRaw: String = AccountType.cash.rawValue
    /// True for accounts the user created locally (not synced from SimpleFin).
    var isManual: Bool = false
    /// User-chosen display name. Overrides the bank-provided `name`, which sync
    /// keeps overwriting — so a rename survives re-syncs. Defaulted nil for
    /// lightweight migration.
    var customName: String? = nil
    /// When this account last came through a SimpleFin sync. nil for manual
    /// accounts (never synced). Defaulted for lightweight migration.
    var lastSyncedAt: Date? = nil
    /// User-arranged position within its type group ("Custom" sort). Defaulted
    /// for lightweight migration.
    var customSortIndex: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Transaction.account)
    var transactions: [Transaction]

    var accountType: AccountType {
        get { AccountType(rawValue: typeRaw) ?? .cash }
        set { typeRaw = newValue.rawValue }
    }

    /// Name shown in the UI: the user's override if set, else the bank name.
    var displayName: String { customName ?? name }

    init(
        id: String,
        org: String,
        name: String,
        currency: String,
        balance: Decimal,
        availableBalance: Decimal? = nil,
        balanceDate: Date,
        typeRaw: String = AccountType.cash.rawValue,
        isManual: Bool = false,
        transactions: [Transaction] = []
    ) {
        self.id = id
        self.org = org
        self.name = name
        self.currency = currency
        self.balance = balance
        self.availableBalance = availableBalance
        self.balanceDate = balanceDate
        self.typeRaw = typeRaw
        self.isManual = isManual
        self.transactions = transactions
    }
}

extension Account: Hashable {
    static func == (lhs: Account, rhs: Account) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }
}
