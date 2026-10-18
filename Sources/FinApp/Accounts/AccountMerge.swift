import Foundation
import SwiftData

/// Deletes a duplicate account while keeping net-worth history continuous.
/// On days both accounts were snapshotted, that day's net-worth total counted
/// the balance twice, so the old account's balance is subtracted and its row
/// dropped. Its earlier rows move to the kept account so that account's
/// sparkline runs back. Totals on every other day are already right.
enum AccountMerge {
    struct Result: Equatable {
        let overlapDays: Int
        let movedRows: Int
    }

    /// Stages the history rewrite; does not save.
    @MainActor
    static func mergeHistory(from oldID: String, into keptID: String, in context: ModelContext,
                             calendar: Calendar = .current) throws -> Result {
        let snapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        let keptDays = snapshots.filter { $0.accountId == keptID }.map(\.day)
        let totals = try context.fetch(FetchDescriptor<NetWorthSnapshot>())
        var overlap = 0, moved = 0
        for row in snapshots where row.accountId == oldID {
            if keptDays.contains(where: { calendar.isDate($0, inSameDayAs: row.day) }) {
                if let total = totals.first(where: { calendar.isDate($0.day, inSameDayAs: row.day) }) {
                    total.value -= row.balance
                }
                context.delete(row)
                overlap += 1
            } else {
                row.accountId = keptID
                moved += 1
            }
        }
        return Result(overlapDays: overlap, movedRows: moved)
    }

    /// Deletes `old`, first merging its history into `kept` when given. One
    /// save; on failure nothing is written. Returns nil when not merging.
    @MainActor
    @discardableResult
    static func delete(_ old: Account, mergingInto kept: Account?, in context: ModelContext,
                       calendar: Calendar = .current) throws -> Result? {
        do {
            let result = try kept.map {
                try mergeHistory(from: old.id, into: $0.id, in: context, calendar: calendar)
            }
            context.delete(old)
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }
}
