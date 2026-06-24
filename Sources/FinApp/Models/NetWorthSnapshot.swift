import Foundation
import SwiftData

/// One net-worth value per calendar day, recorded on sync. History accumulates
/// going forward (balances carry no past, so we can't backfill). `day` is the
/// start-of-day used as the unique upsert key.
@Model
final class NetWorthSnapshot {
    @Attribute(.unique) var day: Date
    var value: Decimal

    init(day: Date, value: Decimal) {
        self.day = day
        self.value = value
    }
}
