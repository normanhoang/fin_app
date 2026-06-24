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
    }

    static let minOccurrences = 3
    /// Average gap must be within ±this fraction of a cadence's nominal days.
    static let tolerance = 0.25

    static func detectCandidates(from txns: [Transaction], calendar: Calendar = .current) -> [Candidate] {
        let outflows = txns.filter { $0.amount < 0 }
        let groups = Dictionary(grouping: outflows) {
            CategorizationEngine.normalizeMerchant($0.payee ?? $0.detail)
        }

        return groups.compactMap { merchant, items -> Candidate? in
            guard items.count >= minOccurrences, !merchant.isEmpty else { return nil }
            let dates = items.map(\.posted).sorted()
            guard let cadence = inferCadence(from: dates) else { return nil }

            let amounts = items.map { abs($0.amount) }.sorted()
            let lastSeen = dates.last!
            let nextDue = calendar.date(byAdding: .day, value: cadence.days, to: lastSeen) ?? lastSeen

            return Candidate(
                merchantName: merchant,
                expectedAmount: median(amounts),
                cadence: cadence,
                lastSeen: lastSeen,
                nextDue: nextDue
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
        let candidates = detectCandidates(from: txns, calendar: calendar)
        let existing = (try? context.fetch(FetchDescriptor<RecurringBill>())) ?? []
        let byName = Dictionary(existing.map { ($0.merchantName, $0) }, uniquingKeysWith: { a, _ in a })

        for candidate in candidates {
            if let bill = byName[candidate.merchantName] {
                bill.expectedAmount = candidate.expectedAmount
                bill.cadence = candidate.cadence
                bill.lastSeen = candidate.lastSeen
                bill.nextDue = candidate.nextDue
            } else {
                context.insert(RecurringBill(
                    merchantName: candidate.merchantName,
                    expectedAmount: candidate.expectedAmount,
                    cadence: candidate.cadence,
                    lastSeen: candidate.lastSeen,
                    nextDue: candidate.nextDue,
                    confirmed: false
                ))
            }
        }
        try? context.save()
        RecurringStore.dedupe(in: context)
    }
}
