import Foundation
import SwiftData

/// Upserts today's balance snapshot for each account so account rows can draw
/// mini sparklines. One row per account per calendar day; re-syncing the same
/// day overwrites it. Mirrors `NetWorthSnapshotService`.
enum AccountBalanceSnapshotService {
    @MainActor
    static func record(_ accounts: [Account], on date: Date = Date(), in context: ModelContext, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        let existing = (try? context.fetch(FetchDescriptor<AccountBalanceSnapshot>())) ?? []
        let todays = Dictionary(
            existing.filter { calendar.isDate($0.day, inSameDayAs: day) }.map { ($0.accountId, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        for account in accounts {
            if let match = todays[account.id] {
                match.balance = account.balance
            } else {
                context.insert(AccountBalanceSnapshot(accountId: account.id, day: day, balance: account.balance))
            }
        }
        // Persist explicitly — this runs last in the sync pipeline, so there's
        // no later save to piggyback on.
        try? context.save()
    }
}
