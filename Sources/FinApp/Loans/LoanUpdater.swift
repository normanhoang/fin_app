import Foundation
import SwiftData

/// Writes computed balances into manual loans that carry a `LoanSchedule`.
/// Idempotent: always projects from the stored anchor and never moves it —
/// only `reanchor`/`applyExtraPrincipal` do.
@MainActor
enum LoanUpdater {
    static func refresh(in context: ModelContext, now: Date = Date(), calendar: Calendar = .current) {
        guard let accounts = try? context.fetch(FetchDescriptor<Account>()) else { return }
        var changed = false
        for account in accounts where account.isManual && account.accountType == .loan {
            guard let schedule = account.loanSchedule else { continue }
            let owed = schedule.balance(asOf: now, calendar: calendar)
            // Debts are stored negative; avoid a sign-minus zero once paid off.
            let signed: Decimal = owed > 0 ? -owed : 0
            guard account.balance != signed else { continue }
            account.balance = signed
            account.balanceDate = schedule.lastPaymentDate(asOf: now, calendar: calendar) ?? schedule.anchorDate
            changed = true
        }
        guard changed else { return }
        do {
            try NetWorthSnapshotService.stage(value: Analytics.netWorth(accounts), on: now,
                                              in: context, calendar: calendar)
            try AccountBalanceSnapshotService.stage(accounts, on: now, in: context, calendar: calendar)
            try context.save()
        } catch {
            context.rollback()
        }
    }

    /// Restart the projection from `owed` (positive) as of `now` — a manual
    /// balance edit — then recompute.
    static func reanchor(_ account: Account, to owed: Decimal, now: Date = Date(),
                         in context: ModelContext, calendar: Calendar = .current) {
        guard let schedule = account.loanSchedule else { return }
        schedule.reanchor(to: owed, at: now)
        try? context.save()
        refresh(in: context, now: now, calendar: calendar)
    }

    /// Apply an irregular extra principal payment made today.
    static func applyExtraPrincipal(_ amount: Decimal, to account: Account, now: Date = Date(),
                                    in context: ModelContext, calendar: Calendar = .current) {
        guard let schedule = account.loanSchedule else { return }
        let current = schedule.balance(asOf: now, calendar: calendar)
        reanchor(account, to: current - amount.magnitude, now: now, in: context, calendar: calendar)
    }
}
