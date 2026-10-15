// Sources/FinApp/FinanceKit/FinanceKitMerge.swift
import Foundation
import SwiftData

/// Folds a SimpleFin account (e.g. Apple Card via an aggregator) into the
/// FinanceKit account for the same card, keeping the row, rename, balance
/// history, and the user's notes/categories.
enum FinanceKitMerge {
    static let minimumMatches = 3
    /// Pending vs posted dates often differ by a day or two between sources.
    static let dayTolerance = 3

    struct Result: Equatable {
        let merged: Int
        let removed: Int
    }

    /// Equal-amount pairs within `dayTolerance`, closest dates first, each
    /// transaction used at most once.
    static func pair(
        _ old: [Transaction], _ new: [Transaction], calendar: Calendar = .current
    ) -> [(old: Transaction, new: Transaction)] {
        var candidates: [(old: Transaction, new: Transaction, distance: Int)] = []
        let newByAmount = Dictionary(grouping: new, by: \.amount)
        for o in old {
            for n in newByAmount[o.amount] ?? [] {
                let distance = abs(calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: o.posted), to: calendar.startOfDay(for: n.posted)
                ).day ?? .max)
                if distance <= dayTolerance { candidates.append((o, n, distance)) }
            }
        }
        candidates.sort { ($0.distance, $0.old.id, $0.new.id) < ($1.distance, $1.old.id, $1.new.id) }
        var usedOld = Set<PersistentIdentifier>(), usedNew = Set<PersistentIdentifier>()
        var pairs: [(old: Transaction, new: Transaction)] = []
        for c in candidates
            where !usedOld.contains(c.old.persistentModelID) && !usedNew.contains(c.new.persistentModelID) {
            usedOld.insert(c.old.persistentModelID)
            usedNew.insert(c.new.persistentModelID)
            pairs.append((c.old, c.new))
        }
        return pairs
    }

    /// The single SimpleFin account whose history overlaps `fk`, or nil if none
    /// or several. Rows without a scoped `providerID` (pre-migration legacy ids)
    /// are excluded: their id would never match what SimpleFin sync computes,
    /// so the superseded-skip would miss and the account would be re-created.
    static func candidate(for fk: Account, among accounts: [Account]) -> Account? {
        let matches = accounts.filter {
            $0.source == .simplefin && $0.providerID != nil
                && pair($0.transactions, fk.transactions).count >= minimumMatches
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Two saves: unique ids can't be handed from a deleted row to a live one
    /// within one save, so deletions/moves land first, then the rekey.
    @MainActor
    static func merge(_ fk: Account, into old: Account, in context: ModelContext) throws -> Result {
        let fkID = fk.id
        let oldID = old.id
        let pairs = pair(old.transactions, fk.transactions)
        let matchedOld = Set(pairs.map { $0.old.persistentModelID })
        let earliestFK = fk.transactions.map(\.posted).min()

        // Phase 1: drop duplicates, move FK-only rows, capture rekey data.
        struct Rekey { let txn: Transaction; let id: String; let providerID: String?
                       let posted: Date; let amount: Decimal; let detail: String
                       let payee: String?; let pending: Bool }
        var rekeys: [Rekey] = []
        for (o, n) in pairs {
            rekeys.append(Rekey(txn: o, id: n.id, providerID: n.providerID, posted: n.posted,
                                amount: n.amount, detail: n.detail, payee: n.payee, pending: n.pending))
            context.delete(n)
        }
        let matchedNew = Set(pairs.map { $0.new.persistentModelID })
        for n in fk.transactions where !matchedNew.contains(n.persistentModelID) {
            n.account = old
        }
        var removed = 0
        // Unmatched SimpleFin rows inside FinanceKit's range are duplicates FinanceKit
        // reports differently — drop them unless the user edited them. FK rows just
        // moved onto `old` may already appear here; their id prefix excludes them.
        for o in old.transactions
            where !matchedOld.contains(o.persistentModelID) && !o.id.hasPrefix("financekit-") {
            guard let earliestFK, o.posted >= earliestFK,
                  !o.categorizedByUser, o.note == nil else { continue }
            context.delete(o)
            removed += 1
        }
        let snapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        for s in snapshots where s.accountId == fkID { context.delete(s) }
        let fields = (providerID: fk.providerID, org: fk.org, name: fk.name, currency: fk.currency,
                      balance: fk.balance, available: fk.availableBalance, date: fk.balanceDate)
        context.delete(fk)
        try context.save()

        // Phase 2: rekey the surviving row and its matched transactions.
        old.supersededProviderID = oldID
        old.id = fkID
        old.source = .financeKit
        old.providerID = fields.providerID
        old.providerScope = nil
        old.org = fields.org
        old.name = fields.name
        old.currency = fields.currency
        old.balance = fields.balance
        old.availableBalance = fields.available
        old.balanceDate = fields.date
        old.lastSyncedAt = Date()
        for r in rekeys {
            r.txn.id = r.id
            r.txn.providerID = r.providerID
            r.txn.posted = r.posted
            r.txn.amount = r.amount
            r.txn.detail = r.detail
            r.txn.payee = r.payee
            r.txn.memo = nil
            r.txn.pending = r.pending
        }
        for s in snapshots where s.accountId == oldID { s.accountId = fkID }
        try context.save()
        return Result(merged: pairs.count, removed: removed)
    }
}
