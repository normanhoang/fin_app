import Foundation
import SwiftData

/// One balance per account per calendar day, recorded on sync — the history
/// behind the per-account mini sparklines. Like `NetWorthSnapshot`, history
/// accumulates going forward only (balances carry no past, so no backfill).
/// The upsert key is (accountId, day), enforced by the recording service since
/// SwiftData has no compound unique attribute.
@Model
final class AccountBalanceSnapshot {
    var accountId: String
    var day: Date
    var balance: Decimal

    init(accountId: String, day: Date, balance: Decimal) {
        self.accountId = accountId
        self.day = day
        self.balance = balance
    }
}
