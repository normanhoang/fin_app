import Foundation
import SwiftData

/// Where an account's data comes from. Each sync path only manages its own
/// source, so SimpleFin's prune can't delete FinanceKit or manual accounts.
enum AccountSource: String {
    case simplefin, manual, financeKit

    /// Account-detail footer under Delete: deleting a synced account only lasts
    /// until its source re-adds it. nil for manual accounts (deletion is final).
    var deleteNote: String? {
        switch self {
        case .simplefin:
            "A deleted account comes back on the next sync if it's still in your SimpleFin connection."
        case .financeKit:
            "A deleted account comes back on the next Apple Wallet import while FinApp has access. You can turn off access in iOS Settings."
        case .manual:
            nil
        }
    }

    /// One-shot for stores created before `sourceRaw` existed: those rows all
    /// defaulted to `.simplefin`, including manual ones.
    @MainActor
    static func migrateManual(in context: ModelContext) {
        guard let accounts = try? context.fetch(FetchDescriptor<Account>()) else { return }
        var changed = false
        for account in accounts where account.isManual && account.source != .manual {
            account.source = .manual
            changed = true
        }
        if changed { try? context.save() }
    }
}
