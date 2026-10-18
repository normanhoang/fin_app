#if DEBUG
import Foundation
import SwiftData

/// One-off repair for history stranded by accounts deleted before
/// `AccountMerge` existed: their `AccountBalanceSnapshot` rows outlive them.
/// Driven by the DEBUG launch variable `FINAPP_REPAIR_ORPHAN` — `list` prints
/// the orphans, `<orphanID>:<keptID>` merges one into a live account.
enum OrphanRepair {
    struct Orphan: Equatable {
        let id: String
        let rows: Int
        let first: Date
        let last: Date
    }

    @MainActor
    static func orphans(in context: ModelContext) throws -> [Orphan] {
        let live = Set(try context.fetch(FetchDescriptor<Account>()).map(\.id))
        let stranded = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
            .filter { !live.contains($0.accountId) }
        return Dictionary(grouping: stranded, by: \.accountId).map { id, rows in
            let days = rows.map(\.day)
            return Orphan(id: id, rows: rows.count, first: days.min()!, last: days.max()!)
        }
        .sorted { $0.id < $1.id }
    }

    /// Returns one log line (several for `list`); changes nothing on error.
    @MainActor
    static func run(_ env: String, in context: ModelContext) -> String {
        do {
            let orphans = try orphans(in: context)
            if env == "list" {
                if orphans.isEmpty { return "no orphaned balance history" }
                return orphans.map { "orphan \($0.id): \($0.rows) rows, \($0.first) … \($0.last)" }
                    .joined(separator: "\n")
            }
            let parts = env.split(separator: ":").map(String.init)
            guard parts.count == 2 else { return "error: expected list or <orphanID>:<keptID>" }
            let (oldID, keptID) = (parts[0], parts[1])
            guard orphans.contains(where: { $0.id == oldID }) else {
                return "error: \(oldID) is not an orphan"
            }
            guard try context.fetch(FetchDescriptor<Account>()).contains(where: { $0.id == keptID }) else {
                return "error: no live account \(keptID)"
            }
            let result = try AccountMerge.mergeHistory(from: oldID, into: keptID, in: context)
            try context.save()
            return "merged \(oldID) → \(keptID): \(result.overlapDays) overlap days, \(result.movedRows) rows moved"
        } catch {
            context.rollback()
            return "error: \(error)"
        }
    }
}
#endif
