import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class LoanUpdaterTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Manual loan owing `owed`, 12%/yr, P&I 100 (150 total − 50 escrow), due the 1st,
    /// anchored 2026-01-15.
    private func makeLoan(_ ctx: ModelContext, owed: Decimal = 1000, type: AccountType = .loan) -> Account {
        let account = Account(id: "manual-loan", org: "Manual", name: "Mortgage", currency: "USD",
                              balance: -owed, balanceDate: date(2026, 1, 15),
                              typeRaw: type.rawValue, isManual: true)
        ctx.insert(account)
        account.loanSchedule = LoanSchedule(inputs: .init(
            balance: owed, asOf: date(2026, 1, 15), annualRate: 12, totalPayment: 150, escrow: 50,
            paymentDay: 1, originalPrincipal: nil, termMonths: nil, startDate: nil))
        try? ctx.save()
        return account
    }

    func testRefreshWritesNegativeComputedBalanceAndSnapshots() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let loan = makeLoan(ctx)

        LoanUpdater.refresh(in: ctx, now: date(2026, 3, 1, 12), calendar: cal)

        XCTAssertEqual(loan.balance, Decimal(string: "-819.10"))
        XCTAssertEqual(loan.balanceDate, date(2026, 3, 1))
        let snaps = try ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        XCTAssertEqual(snaps.map(\.balance), [Decimal(string: "-819.10")!])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<NetWorthSnapshot>()).count, 1)
    }

    func testRefreshIsIdempotent() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let loan = makeLoan(ctx)
        let now = date(2026, 3, 1, 12)

        LoanUpdater.refresh(in: ctx, now: now, calendar: cal)
        LoanUpdater.refresh(in: ctx, now: now, calendar: cal)

        XCTAssertEqual(loan.balance, Decimal(string: "-819.10"))
        XCTAssertEqual(loan.loanSchedule?.anchorBalance, 1000)
        XCTAssertEqual(loan.loanSchedule?.anchorDate, date(2026, 1, 15))
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>()).count, 1)
    }

    func testAccountsWithoutScheduleUntouched() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let plain = Account(id: "manual-x", org: "Manual", name: "Car", currency: "USD", balance: -500,
                            balanceDate: date(2026, 1, 1), typeRaw: AccountType.loan.rawValue, isManual: true)
        let synced = Account(id: "sf", org: "Bank", name: "Checking", currency: "USD", balance: 42,
                             balanceDate: date(2026, 1, 1))
        ctx.insert(plain); ctx.insert(synced)
        try ctx.save()

        LoanUpdater.refresh(in: ctx, now: date(2026, 3, 1), calendar: cal)

        XCTAssertEqual(plain.balance, -500)
        XCTAssertEqual(synced.balance, 42)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>()).isEmpty)
    }

    func testNonLoanTypeIgnored() {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let account = makeLoan(ctx, type: .cash)
        account.balance = 1000

        LoanUpdater.refresh(in: ctx, now: date(2026, 3, 1), calendar: cal)

        XCTAssertEqual(account.balance, 1000)
    }

    func testPaidOffIsCleanZero() {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let loan = makeLoan(ctx, owed: 150)

        LoanUpdater.refresh(in: ctx, now: date(2026, 3, 1), calendar: cal)

        XCTAssertEqual(loan.balance, 0)
        XCTAssertEqual("\(loan.balance)", "0")
    }

    func testExtraPrincipalReanchorsToday() {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let loan = makeLoan(ctx)
        let now = date(2026, 3, 1, 12)
        LoanUpdater.refresh(in: ctx, now: now, calendar: cal)

        LoanUpdater.applyExtraPrincipal(Decimal(string: "19.10")!, to: loan, now: now, in: ctx, calendar: cal)

        XCTAssertEqual(loan.loanSchedule?.anchorBalance, 800)
        XCTAssertEqual(loan.loanSchedule?.anchorDate, now)
        XCTAssertEqual(loan.balance, -800)

        // Next month projects from the new anchor: 800 + 8.00 − 100.
        LoanUpdater.refresh(in: ctx, now: date(2026, 4, 1, 12), calendar: cal)
        XCTAssertEqual(loan.balance, -708)
    }

    func testManualEditReanchors() {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let loan = makeLoan(ctx)
        let now = date(2026, 2, 10)

        LoanUpdater.reanchor(loan, to: 500, now: now, in: ctx, calendar: cal)

        XCTAssertEqual(loan.loanSchedule?.anchorBalance, 500)
        XCTAssertEqual(loan.loanSchedule?.anchorDate, now)
        XCTAssertEqual(loan.balance, -500)
    }

    func testDeletingAccountDeletesSchedule() throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let loan = makeLoan(ctx)

        ctx.delete(loan)
        try ctx.save()

        XCTAssertTrue(try ctx.fetch(FetchDescriptor<LoanSchedule>()).isEmpty)
    }
}
