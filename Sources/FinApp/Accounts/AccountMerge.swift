import Foundation
import SwiftData

/// Deletes a duplicate account while keeping net-worth history continuous.
/// On days both accounts were snapshotted, that day's net-worth total counted
/// the balance twice, so the old account's balance is subtracted and its row
/// dropped. Its earlier rows move to the kept account so that account's
/// sparkline runs back. Totals on every other day are already right.
/// A total is only corrected when it still includes the old balance (it equals
/// the sum of that day's rows, old included). An account deleted mid-day leaves
/// its row behind while later restaging drops it from the total.
enum AccountMerge {
    struct Result: Equatable {
        let overlapDays: Int
        let movedRows: Int
        /// Overlap days whose total already excluded the old balance (left as is).
        var skippedDays = 0
    }

    /// Stages the history rewrite; does not save.
    @MainActor
    static func mergeHistory(from oldID: String, into keptID: String, in context: ModelContext,
                             calendar: Calendar = .current) throws -> Result {
        let snapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        let keptDays = snapshots.filter { $0.accountId == keptID }.map(\.day)
        let totals = try context.fetch(FetchDescriptor<NetWorthSnapshot>())
        var overlap = 0, moved = 0, skipped = 0
        for row in snapshots where row.accountId == oldID {
            if keptDays.contains(where: { calendar.isDate($0, inSameDayAs: row.day) }) {
                if let total = totals.first(where: { calendar.isDate($0.day, inSameDayAs: row.day) }) {
                    let dayRows = snapshots.filter { calendar.isDate($0.day, inSameDayAs: row.day) }
                    let sum = dayRows.reduce(Decimal(0)) { $0 + $1.balance }
                    if (total.value - sum).magnitude < 0.01 {
                        total.value -= row.balance
                        overlap += 1
                    } else {
                        skipped += 1
                    }
                }
                context.delete(row)
            } else {
                row.accountId = keptID
                moved += 1
            }
        }
        return Result(overlapDays: overlap, movedRows: moved, skippedDays: skipped)
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
