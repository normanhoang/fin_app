import Foundation
import SwiftData

/// Finds recurring charges in transaction history by grouping on normalized
/// merchant and inferring a stable cadence. Pure detection logic is unit-tested;
/// persistence (`refresh`) reconciles candidates with stored bills.
enum RecurringDetector {
    struct Candidate: Equatable {
        var merchantName: String
        var expectedAmount: Decimal   // positive magnitude
        var cadence: Cadence
        var lastSeen: Date
        var nextDue: Date
        var category: Category?
        /// Set when the newest charge broke from a stable prior amount — the
        /// old amount and when the new one first posted. nil while stable.
        var previousAmount: Decimal?
        var amountChangedAt: Date?
    }

    static let minOccurrences = 3
    /// Average gap must be within ±this fraction of a cadence's nominal days.
    static let tolerance = 0.25
    /// Prior charges required at one amount before a differing newest charge
    /// counts as a price change.
    static let minStableCharges = 3
    /// Newest charge must differ from the stable amount by more than this fraction.
    static let priceChangeThreshold = 0.02

    static func detectCandidates(from txns: [Transaction], calendar: Calendar = .current) -> [Candidate] {
        let outflows = txns.filter { $0.amount < 0 }
        let groups = Dictionary(grouping: outflows) {
            CategorizationEngine.normalizeMerchant($0.payee ?? $0.detail)
        }

        return groups.compactMap { merchant, items -> Candidate? in
            guard items.count >= minOccurrences, !merchant.isEmpty else { return nil }
            let chronological = items.sorted { $0.posted < $1.posted }
            let dates = chronological.map(\.posted)
            guard let cadence = inferCadence(from: dates) else { return nil }

            let lastSeen = dates.last!
            let nextDue = RecurringSchedule.advance(lastSeen, by: cadence, calendar: calendar) ?? lastSeen
            // Most recent assigned category from this merchant's transactions.
            let category = chronological.reversed().compactMap(\.category).first

            let amountAnalysis = analyzeAmounts(in: chronological)

            return Candidate(
                merchantName: merchant,
                expectedAmount: amountAnalysis.expected,
                cadence: cadence,
                lastSeen: lastSeen,
                nextDue: nextDue,
                category: category,
                previousAmount: amountAnalysis.change?.previousAmount,
                amountChangedAt: amountAnalysis.change?.changedAt
            )
        }
        .sorted { $0.merchantName < $1.merchantName }
    }

    private static func inferCadence(from sortedDates: [Date]) -> Cadence? {
        guard sortedDates.count >= 2 else { return nil }
        let gaps = zip(sortedDates.dropFirst(), sortedDates).map {
            $0.0.timeIntervalSince($0.1) / 86_400
        }
        let avg = gaps.reduce(0, +) / Double(gaps.count)
        for cadence in Cadence.allCases {
            if abs(avg - Double(cadence.days)) <= Double(cadence.days) * tolerance {
                return cadence
            }
        }
        return nil
    }

    /// A price change: the newest charge differs by more than
    /// `priceChangeThreshold` from the last `minStableCharges`+ charges, which
    /// all shared one amount. `txns` must be chronological.
    private static func analyzeAmounts(in txns: [Transaction])
        -> (expected: Decimal, change: (previousAmount: Decimal, changedAt: Date)?) {
        let amounts = txns.map { abs($0.amount) }
        guard let new = amounts.last else { return (0, nil) }
        let newRun = amounts.reversed().prefix { $0 == new }.count
        if newRun >= minStableCharges {
            return (new, nil)
        }

        let prior = amounts.dropLast(newRun).suffix(minStableCharges)
        guard prior.count == minStableCharges,
              let old = prior.first,
              prior.allSatisfy({ $0 == old }),
              old != 0 else {
            return (median(amounts.sorted()), nil)
        }
        let delta = (((new - old) / old) as NSDecimalNumber).doubleValue
        guard abs(delta) > priceChangeThreshold else {
            return (median(amounts.sorted()), nil)
        }
        let changedAt = txns[txns.count - newRun].posted
        return (new, (old, changedAt))
    }

    private static func median(_ sorted: [Decimal]) -> Decimal {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Reconcile detected candidates into stored `RecurringBill`s. Confirmed bills
    /// are kept; unconfirmed candidates are refreshed to match current detection.
    @MainActor
    static func refresh(in context: ModelContext, calendar: Calendar = .current) {
        let txns = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        refresh(txns, in: context, calendar: calendar)
    }

    /// Same, over an already-fetched transaction list so the sync pipeline can
    /// share one fetch across its post-sync steps.
    @MainActor
    static func refresh(_ txns: [Transaction], in context: ModelContext, calendar: Calendar = .current) {
        try? stageRefresh(txns, in: context, calendar: calendar)
        try? context.save()
    }

    @MainActor
    static func stageRefresh(
        _ txns: [Transaction], in context: ModelContext, calendar: Calendar = .current
    ) throws {
        let candidates = detectCandidates(from: txns, calendar: calendar)
        let existing = try context.fetch(FetchDescriptor<RecurringBill>())
        let byName = Dictionary(grouping: existing, by: \.merchantName).mapValues { bills in
            bills.first(where: { $0.confirmed && !$0.dismissed })
                ?? bills.first(where: \.confirmed)
                ?? bills[0]
        }
        let detectedNames = Set(candidates.map(\.merchantName))

        // Retire stale unconfirmed candidates, but never ones carrying a user
        // edit (custom next-due) — a detection flicker must not destroy those.
        for bill in existing
            where !bill.confirmed && !bill.dismissed && !bill.nextDueSetByUser
                && !detectedNames.contains(bill.merchantName) {
            context.delete(bill)
        }

        for candidate in candidates {
            if let bill = byName[candidate.merchantName] {
                bill.expectedAmount = candidate.expectedAmount
                bill.cadence = candidate.cadence
                bill.lastSeen = candidate.lastSeen
                // Unconditional copy: nil clears the alert once charges settle
                // at the new amount.
                bill.previousAmount = candidate.previousAmount
                bill.amountChangedAt = candidate.amountChangedAt
                // A user-set next-due date sticks until a charge posts on/after it,
                // then auto-projection resumes.
                if bill.nextDueSetByUser, let userDate = bill.nextDue,
                   candidate.lastSeen < userDate {
                    // keep the user's date
                } else {
                    bill.nextDueSetByUser = false
                    bill.nextDue = candidate.nextDue
                }
                if bill.category == nil { bill.category = candidate.category }
            } else {
                let bill = RecurringBill(
                    merchantName: candidate.merchantName,
                    expectedAmount: candidate.expectedAmount,
                    cadence: candidate.cadence,
                    lastSeen: candidate.lastSeen,
                    nextDue: candidate.nextDue,
                    confirmed: false,
                    category: candidate.category
                )
                bill.previousAmount = candidate.previousAmount
                bill.amountChangedAt = candidate.amountChangedAt
                context.insert(bill)
            }
        }
        try RecurringStore.stageDedupe(in: context)
    }
}
