import Foundation
import SwiftData

/// Where an account's data comes from. Each sync path only manages its own
/// source, so SimpleFin's prune can't delete FinanceKit or manual accounts.
enum AccountSource: String {
    case simplefin, manual, financeKit

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
