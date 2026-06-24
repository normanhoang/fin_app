import Foundation
import SwiftData

/// Upserts today's net-worth snapshot so the net-worth graph builds history over
/// time. One row per calendar day; re-syncing the same day overwrites it.
enum NetWorthSnapshotService {
    @MainActor
    static func record(value: Decimal, on date: Date = Date(), in context: ModelContext, calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: date)
        let existing = (try? context.fetch(FetchDescriptor<NetWorthSnapshot>())) ?? []
        if let match = existing.first(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            match.value = value
        } else {
            context.insert(NetWorthSnapshot(day: day, value: value))
        }
    }
}
