import Foundation
import SwiftData

/// Injects realistic fake data so the UI can be exercised without a live
/// SimpleFin connection. Compiled into release too, so the Settings screen can
/// offer a "Preview with sample data" path (used for App Review demos).
enum SampleData {
    @MainActor
    static func inject(into context: ModelContext) {
        CategorySeed.seedIfNeeded(in: context)

        let checking = Account(id: "s-checking", org: "Sample Bank", name: "Checking", currency: "USD",
                               balance: Decimal(string: "4250.18")!, availableBalance: Decimal(string: "4250.18")!, balanceDate: Date())
        let card = Account(id: "s-card", org: "Sample Bank", name: "Rewards Card", currency: "USD",
                           balance: Decimal(string: "-612.44")!, balanceDate: Date())
        let invest = Account(id: "s-invest", org: "Sample Brokerage", name: "Brokerage", currency: "USD",
                             balance: Decimal(string: "31980.05")!, availableBalance: Decimal(string: "120.00")!, balanceDate: Date())
        [checking, card, invest].forEach(context.insert)

        let cal = Calendar.current
        func day(_ ago: Int) -> Date { cal.date(byAdding: .day, value: -ago, to: Date())! }

        let rows: [(String, String, String, Account, Int)] = [
            ("Payroll Direct Deposit", "ACME PAYROLL", "2600.00", checking, 2),
            ("Whole Foods Market", "Whole Foods", "-142.37", card, 3),
            ("Starbucks", "Starbucks", "-6.45", card, 4),
            ("Uber Trip", "Uber", "-23.10", card, 5),
            ("Netflix", "Netflix", "-15.49", card, 6),
            ("Shell Gas", "Shell", "-58.20", card, 8),
            ("Amazon Marketplace", "Amazon", "-89.99", card, 9),
            ("Trader Joe's", "Trader Joe", "-76.12", card, 12),
            ("Rent", "Property Mgmt", "-1850.00", checking, 14),
            ("Doordash", "DoorDash", "-34.88", card, 16),
            ("Payroll Direct Deposit", "ACME PAYROLL", "2600.00", checking, 17),
            ("PG&E Utility", "PG&E", "-128.44", checking, 19),
            ("Spotify", "Spotify", "-11.99", card, 22),
            ("Costco", "Costco", "-204.51", card, 25),
        ]
        for (i, r) in rows.enumerated() {
            let t = Transaction(id: "s-tx-\(i)", posted: day(r.4), amount: Decimal(string: r.2)!,
                                detail: r.0, payee: r.1, account: r.3)
            context.insert(t)
        }

        // Month-to-date rows pinned to days of the CURRENT month (capped at today),
        // so the Dashboard's month tiles are never empty — even on the 1st, when
        // every day-ago offset above lands in the previous month.
        let startOfMonth = cal.dateInterval(of: .month, for: Date())!.start
        func monthDay(_ dayOfMonth: Int) -> Date {
            let target = cal.date(byAdding: .day, value: dayOfMonth - 1, to: startOfMonth)!
            return Swift.min(target, Date())
        }
        let monthRows: [(String, String, String, Account, Int)] = [
            ("Payroll Direct Deposit", "ACME PAYROLL", "2600.00", checking, 1),
            ("Rent", "Property Mgmt", "-1850.00", checking, 1),
            ("Whole Foods Market", "Whole Foods", "-118.62", card, 2),
            ("PG&E Utility", "PG&E", "-131.07", checking, 5),
            ("Starbucks", "Starbucks", "-7.15", card, 6),
            ("Uber Trip", "Uber", "-19.80", card, 8),
            ("Amazon Marketplace", "Amazon", "-64.25", card, 10),
            ("Payroll Direct Deposit", "ACME PAYROLL", "2600.00", checking, 15),
            ("Trader Joe's", "Trader Joe", "-83.44", card, 17),
            ("Doordash", "DoorDash", "-28.60", card, 21),
        ]
        for (i, r) in monthRows.enumerated() {
            let t = Transaction(id: "s-mtx-\(i)", posted: monthDay(r.4), amount: Decimal(string: r.2)!,
                                detail: r.0, payee: r.1, account: r.3)
            context.insert(t)
        }
        try? context.save()
        CategorizationEngine.categorizeAll(in: context)

        // A couple of budgets so the Budgets screen has content.
        let cats = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        if let groceries = cats.first(where: { $0.name == "Groceries" }) {
            context.insert(Budget(monthlyLimit: Decimal(string: "400")!, category: groceries))
        }
        if let dining = cats.first(where: { $0.name == "Dining" }) {
            context.insert(Budget(monthlyLimit: Decimal(string: "30")!, category: dining))
        }
        try? context.save()

        // Repeating charges so the recurring detector has something to find.
        func recurring(_ merchant: String, _ amount: String, count: Int, gap: Int, account: Account) {
            for i in 0..<count {
                let posted = cal.date(byAdding: .day, value: -gap * i, to: Date())!
                context.insert(Transaction(id: "s-rec-\(merchant)-\(i)", posted: posted,
                                           amount: Decimal(string: amount)!, detail: merchant, payee: merchant, account: account))
            }
        }
        recurring("Netflix", "-15.49", count: 6, gap: 30, account: card)
        recurring("Spotify", "-11.99", count: 6, gap: 30, account: card)
        recurring("Planet Fitness", "-24.99", count: 6, gap: 30, account: card)
        try? context.save()
        CategorizationEngine.categorizeAll(in: context)
        RecurringDetector.refresh(in: context)

        // Net worth history so the graph and dashboard sparkline render in the demo.
        let base = (checking.balance + card.balance + invest.balance as NSDecimalNumber).doubleValue
        let span = 45
        for d in 0..<span {
            let date = cal.startOfDay(for: cal.date(byAdding: .day, value: -(span - 1 - d), to: Date())!)
            let progress = Double(d) / Double(span - 1)
            let trend = base * 0.9 + base * 0.1 * progress
            let noise = sin(Double(d) * 0.6) * base * 0.012
            context.insert(NetWorthSnapshot(day: date, value: Decimal(trend + noise)))
        }
        try? context.save()
    }

    /// Deletes every persisted object, so a user (or App Review) can remove
    /// sample data or wipe all local financial data.
    @MainActor
    static func wipeAll(in context: ModelContext) {
        for model in AppSchema.models {
            try? context.delete(model: model)
        }
        try? context.save()
    }
}
