import Foundation
import SwiftData

/// Mutations for recurring bills that keep one row per merchant, so a merchant
/// never shows in both "Detected" and "Upcoming".
enum RecurringStore {
    /// Confirm a recurring bill for a merchant. Promotes an existing bill (detected
    /// candidate or dismissed) in place instead of inserting a duplicate.
    @MainActor
    @discardableResult
    static func setRecurring(
        merchant: String,
        amount: Decimal,
        cadence: Cadence,
        lastSeen: Date,
        category: Category?,
        in context: ModelContext,
        calendar: Calendar = .current
    ) -> RecurringBill {
        let nextDue = RecurringSchedule.advance(lastSeen, by: cadence, calendar: calendar)
        let existing = (try? context.fetch(FetchDescriptor<RecurringBill>())) ?? []

        if let bill = existing.first(where: { $0.merchantName == merchant }) {
            bill.confirmed = true
            bill.dismissed = false
            bill.expectedAmount = amount
            bill.cadence = cadence
            bill.lastSeen = lastSeen
            bill.nextDue = nextDue
            if let category { bill.category = category }
            try? context.save()
            return bill
        }

        let bill = RecurringBill(
            merchantName: merchant, expectedAmount: amount, cadence: cadence,
            lastSeen: lastSeen, nextDue: nextDue, confirmed: true, category: category
        )
        context.insert(bill)
        try? context.save()
        return bill
    }

    /// Collapse any bills that share a merchant into a single row: keep one
    /// (preferring a confirmed bill), OR-in `dismissed`, keep the soonest `nextDue`,
    /// and delete the rest. Clears pre-existing duplicates on sync/launch.
    @MainActor
    static func dedupe(in context: ModelContext) {
        try? stageDedupe(in: context)
        try? context.save()
    }

    @MainActor
    static func stageDedupe(in context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<RecurringBill>())
        let groups = Dictionary(grouping: all, by: \.merchantName)
        var changed = false

        for (_, bills) in groups where bills.count > 1 {
            let keeper = bills.first(where: { $0.confirmed && !$0.dismissed })
                ?? bills.first(where: \.confirmed)
                ?? bills[0]
            keeper.confirmed = bills.contains(where: \.confirmed)
            keeper.dismissed = keeper.confirmed
                ? !bills.contains(where: { $0.confirmed && !$0.dismissed })
                : bills.contains(where: \.dismissed)
            keeper.nextDue = bills.compactMap(\.nextDue).min() ?? keeper.nextDue
            for bill in bills where bill !== keeper {
                context.delete(bill)
            }
            changed = true
        }
        _ = changed
    }
}
