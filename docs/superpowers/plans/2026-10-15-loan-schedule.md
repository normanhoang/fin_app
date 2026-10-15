# Auto-Calculated Loan Balance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A manual Loan account can carry a fixed-rate payment schedule so its balance updates itself on each payment date.

**Architecture:** Pure `Amortization` math projects a balance forward from a stored anchor (balance + date). A new `LoanSchedule` SwiftData model (cascade-owned by `Account`) holds the inputs; `LoanDraft` parses/validates form text. `LoanUpdater` writes computed balances into manual loan accounts at launch/foreground and after edits. UI: an "Auto-calculate balance" toggle in Add Account and a "Loan schedule" section in account detail.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest/XCUITest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-15-loan-schedule-design.md`

## Global Constraints

- iOS deployment target 17.0; Xcode 26.5; Swift 6.
- `project.yml` is the source of truth: run `xcodegen generate` after adding/removing files.
- New stored properties must be optional or defaulted (lightweight migration only); add new `@Model` types to `AppSchema.models`.
- Tests must keep the `ModelContainer` alive in a local (`let container = AppSchema.makeInMemoryContainer()`), never `AppSchema.makeInMemoryContainer().mainContext` inline.
- In the test target qualify `FinApp.Category` (not used here, but don't introduce bare `Category`).
- Amount sign convention: debt balances are stored **negative**. `LoanSchedule.anchorBalance` is **positive** (amount owed).
- Interest is rounded to cents per payment with `.plain` (half up).
- Payment day is 1...28. A payment on the anchor date itself is **not** applied.
- Test command: `xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:<Target>/<Class>`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Paid-off balance must be a clean `0`, not a sign-minus Decimal zero — `LoanUpdater` writes `owed > 0 ? -owed : 0`; Task 3 test asserts `"\(balance)" == "0"`.
2. Account detail's balance field fires `onChange` when `onAppear` seeds it; for a scheduled loan that must **not** move the anchor unless the typed magnitude differs from the current balance (Task 5 code guards it).
3. Inputs that never pay off (payment barely above interest) must not loop forever — `Amortization.maxPayments` bound; Task 1 test `testPayoffNilBeyondMaxPayments`.
4. Payment dates across February / month-ends — payment day ≤ 28 plus `startOfDay`; Task 1 test `testFebruaryPaymentDay28`.
5. Changing a scheduled account's type away from Loan must stop auto-updates (refresh filters `accountType == .loan`); Task 3 test `testNonLoanTypeIgnored`.

---

### Task 1: Amortization math

**Files:**
- Create: `Sources/FinApp/Loans/Amortization.swift`
- Test: `Tests/FinAppTests/AmortizationTests.swift`

**Interfaces:**
- Produces (used by Tasks 2–5):
  - `Amortization.maxPayments: Int` (1200)
  - `Amortization.monthlyRate(_ annualRate: Decimal) -> Decimal`
  - `Amortization.roundCents(_ value: Decimal) -> Decimal`
  - `Amortization.paymentCoversInterest(balance: Decimal, annualRate: Decimal, pi: Decimal) -> Bool`
  - `Amortization.nextPaymentDate(after: Date, paymentDay: Int, calendar: Calendar) -> Date`
  - `Amortization.paymentDates(after: Date, through: Date, paymentDay: Int, calendar: Calendar) -> [Date]`
  - `Amortization.balance(anchor: Decimal, annualRate: Decimal, pi: Decimal, payments: Int) -> Decimal`
  - `Amortization.balance(anchor: Decimal, annualRate: Decimal, pi: Decimal, paymentDay: Int, anchorDate: Date, asOf: Date, calendar: Calendar) -> Decimal`
  - `Amortization.payoffDate(balance: Decimal, annualRate: Decimal, pi: Decimal, paymentDay: Int, from: Date, calendar: Calendar) -> Date?`

- [ ] **Step 1: Write the failing tests**

`Tests/FinAppTests/AmortizationTests.swift`:

```swift
import XCTest
@testable import FinApp

final class AmortizationTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testOnePaymentAppliesRoundedInterest() {
        // 12%/yr → 1%/mo. 1000 + 10.00 interest − 100 = 910.00
        XCTAssertEqual(Amortization.balance(anchor: 1000, annualRate: 12, pi: 100, payments: 1), 910)
        XCTAssertEqual(Amortization.balance(anchor: 1000, annualRate: 12, pi: 100, payments: 2),
                       Decimal(string: "819.10"))
    }

    func testThirtyYearMortgageAfterTwelvePayments() {
        // $300k, 6%, P&I 1,798.65. Closed-form table says ≈296,315.99; per-month
        // cent rounding gives 296,316.00.
        let b = Amortization.balance(anchor: 300_000, annualRate: 6, pi: Decimal(string: "1798.65")!, payments: 12)
        XCTAssertEqual(b, Decimal(string: "296316.00"))
    }

    func testPaymentDatesStrictlyAfterAnchorDay() {
        // Anchor on a payment day: that day's payment is already in the balance.
        let dates = Amortization.paymentDates(after: date(2026, 2, 1, 10), through: date(2026, 2, 1, 12),
                                              paymentDay: 1, calendar: cal)
        XCTAssertTrue(dates.isEmpty)
    }

    func testPaymentDatesAcrossMonths() {
        let dates = Amortization.paymentDates(after: date(2026, 1, 15), through: date(2026, 3, 1, 9),
                                              paymentDay: 1, calendar: cal)
        XCTAssertEqual(dates, [date(2026, 2, 1), date(2026, 3, 1)])
        let before = Amortization.paymentDates(after: date(2026, 1, 15), through: date(2026, 2, 28),
                                               paymentDay: 1, calendar: cal)
        XCTAssertEqual(before, [date(2026, 2, 1)])
    }

    func testFebruaryPaymentDay28() {
        XCTAssertEqual(Amortization.nextPaymentDate(after: date(2026, 1, 31), paymentDay: 28, calendar: cal),
                       date(2026, 2, 28))
    }

    func testDatedBalanceUsesElapsedPayments() {
        let b = Amortization.balance(anchor: 1000, annualRate: 12, pi: 100, paymentDay: 1,
                                     anchorDate: date(2026, 1, 15), asOf: date(2026, 3, 1, 9), calendar: cal)
        XCTAssertEqual(b, Decimal(string: "819.10"))
    }

    func testBalanceClampsAtZero() {
        // 150 → 51.50 → (51.50 + 0.52 − 100) < 0 → 0
        XCTAssertEqual(Amortization.balance(anchor: 150, annualRate: 12, pi: 100, payments: 5), 0)
    }

    func testPayoffDate() {
        XCTAssertEqual(Amortization.payoffDate(balance: 150, annualRate: 12, pi: 100, paymentDay: 1,
                                               from: date(2026, 1, 15), calendar: cal),
                       date(2026, 3, 1))
        // 30-year loan: P&I rounded down leaves $1.44 after 360, paid by payment 361.
        XCTAssertEqual(Amortization.payoffDate(balance: 300_000, annualRate: 6, pi: Decimal(string: "1798.65")!,
                                               paymentDay: 1, from: date(2026, 1, 15), calendar: cal),
                       date(2056, 2, 1))
    }

    func testPayoffNilWhenPaymentDoesNotCoverInterest() {
        XCTAssertFalse(Amortization.paymentCoversInterest(balance: 1000, annualRate: 12, pi: 10))
        XCTAssertTrue(Amortization.paymentCoversInterest(balance: 1000, annualRate: 12, pi: Decimal(string: "10.01")!))
        XCTAssertNil(Amortization.payoffDate(balance: 1000, annualRate: 12, pi: 10, paymentDay: 1,
                                             from: date(2026, 1, 15), calendar: cal))
        XCTAssertNil(Amortization.payoffDate(balance: 0, annualRate: 12, pi: 100, paymentDay: 1,
                                             from: date(2026, 1, 15), calendar: cal))
    }

    func testPayoffNilBeyondMaxPayments() {
        // Covers interest by one cent: would take far more than 1200 payments.
        XCTAssertNil(Amortization.payoffDate(balance: 300_000, annualRate: 6, pi: Decimal(string: "1500.01")!,
                                             paymentDay: 1, from: date(2026, 1, 15), calendar: cal))
    }

    func testZeroRate() {
        XCTAssertEqual(Amortization.balance(anchor: 1000, annualRate: 0, pi: 100, payments: 3), 700)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppTests/AmortizationTests`
Expected: build FAIL — `cannot find 'Amortization' in scope`.

- [ ] **Step 3: Implement**

`Sources/FinApp/Loans/Amortization.swift`:

```swift
import Foundation

/// Fixed-rate amortization projected forward from a known (anchor) balance.
/// Pure — no SwiftData. Interest is rounded to cents each payment, like a
/// servicer statement.
enum Amortization {
    /// Upper bound on projected payments (100 years) so bad input can't loop forever.
    static let maxPayments = 1200

    static func monthlyRate(_ annualRate: Decimal) -> Decimal { annualRate / 100 / 12 }

    static func roundCents(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    /// True when `pi` exceeds the next payment's interest, so the balance falls.
    static func paymentCoversInterest(balance: Decimal, annualRate: Decimal, pi: Decimal) -> Bool {
        pi > roundCents(balance * monthlyRate(annualRate))
    }

    /// First payment date (start of day, on `paymentDay`) strictly after `date`'s day.
    static func nextPaymentDate(after date: Date, paymentDay: Int, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        var comps = calendar.dateComponents([.year, .month], from: day)
        comps.day = paymentDay
        guard let thisMonth = calendar.date(from: comps) else { return day }
        if thisMonth > day { return thisMonth }
        return calendar.date(byAdding: .month, value: 1, to: thisMonth) ?? thisMonth
    }

    /// Payment dates strictly after `anchorDate`'s day, up to and including `asOf`.
    static func paymentDates(after anchorDate: Date, through asOf: Date,
                             paymentDay: Int, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var next = nextPaymentDate(after: anchorDate, paymentDay: paymentDay, calendar: calendar)
        while next <= asOf, dates.count < maxPayments {
            dates.append(next)
            guard let following = calendar.date(byAdding: .month, value: 1, to: next) else { break }
            next = following
        }
        return dates
    }

    /// Balance after `payments` monthly payments of `pi`. Never below 0.
    static func balance(anchor: Decimal, annualRate: Decimal, pi: Decimal, payments: Int) -> Decimal {
        let rate = monthlyRate(annualRate)
        var balance = anchor
        for _ in 0..<max(0, payments) where balance > 0 {
            let interest = roundCents(balance * rate)
            balance = max(0, balance - (pi - interest))
        }
        return balance
    }

    /// Balance as of `asOf`, applying each payment date after `anchorDate`.
    static func balance(anchor: Decimal, annualRate: Decimal, pi: Decimal, paymentDay: Int,
                        anchorDate: Date, asOf: Date, calendar: Calendar) -> Decimal {
        let count = paymentDates(after: anchorDate, through: asOf,
                                 paymentDay: paymentDay, calendar: calendar).count
        return balance(anchor: anchor, annualRate: annualRate, pi: pi, payments: count)
    }

    /// Date of the payment that brings `balance` to 0, counting from the first
    /// payment after `from`. nil when already paid off, when the payment never
    /// covers interest, or beyond `maxPayments`.
    static func payoffDate(balance: Decimal, annualRate: Decimal, pi: Decimal,
                           paymentDay: Int, from: Date, calendar: Calendar) -> Date? {
        guard balance > 0,
              paymentCoversInterest(balance: balance, annualRate: annualRate, pi: pi) else { return nil }
        var remaining = balance
        var date = nextPaymentDate(after: from, paymentDay: paymentDay, calendar: calendar)
        for _ in 0..<maxPayments {
            remaining = self.balance(anchor: remaining, annualRate: annualRate, pi: pi, payments: 1)
            if remaining == 0 { return date }
            guard let following = calendar.date(byAdding: .month, value: 1, to: date) else { return nil }
            date = following
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2 (no regenerate needed).
Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/Loans/Amortization.swift Tests/FinAppTests/AmortizationTests.swift FinApp.xcodeproj
git commit -m "feat(loans): add fixed-rate amortization math

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: LoanSchedule model + LoanDraft validation

**Files:**
- Create: `Sources/FinApp/Models/LoanSchedule.swift`
- Create: `Sources/FinApp/Loans/LoanDraft.swift`
- Modify: `Sources/FinApp/Models/Account.swift` (add relationship after `supersededProviderID`)
- Modify: `Sources/FinApp/Models/AppSchema.swift` (append `LoanSchedule.self`)
- Test: `Tests/FinAppTests/LoanDraftTests.swift`

**Interfaces:**
- Consumes: `Amortization` (Task 1).
- Produces:
  - `LoanSchedule` (`@Model`): stored `annualRate, totalPayment, escrow: Decimal`, `paymentDay: Int`, `anchorBalance: Decimal`, `anchorDate: Date`, `originalPrincipal: Decimal?`, `termMonths: Int?`, `startDate: Date?`, `account: Account?`; `init(inputs: LoanDraft.Inputs)`; `apply(_ inputs: LoanDraft.Inputs)`; `var pi: Decimal`; `balance(asOf: Date, calendar: Calendar = .current) -> Decimal`; `lastPaymentDate(asOf:calendar:) -> Date?`; `nextPaymentDate(asOf:calendar:) -> Date`; `payoffDate(asOf:calendar:) -> Date?`; `reanchor(to owed: Decimal, at date: Date)`.
  - `Account.loanSchedule: LoanSchedule?` (cascade).
  - `LoanDraft` (struct, text fields), `LoanDraft.Inputs`, `LoanDraft.Problem` (`.incomplete`, `.futureDate`, `.escrowTooLarge`, `.paymentBelowInterest`, `message: String?`), `validate(now:) -> Result<Inputs, Problem>`, `isValid`, `init()`, `init(schedule:now:calendar:)`, `static text(_ Decimal) -> String`, `Inputs.preview(now:calendar:) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/FinAppTests/LoanDraftTests.swift`:

```swift
import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class LoanDraftTests: XCTestCase {
    private func validDraft() -> LoanDraft {
        var d = LoanDraft()
        d.balanceText = "1000"
        d.asOf = Date(timeIntervalSince1970: 1_767_614_400) // 2026-01-05 12:00 UTC — mid-month in any time zone
        d.rateText = "12"
        d.totalText = "150"
        d.escrowText = "50"
        d.paymentDay = 1
        return d
    }

    private let now = Date(timeIntervalSince1970: 1_768_000_000) // 2026-01-10

    func testValidDraftProducesInputs() throws {
        let inputs = try validDraft().validate(now: now).get()
        XCTAssertEqual(inputs.balance, 1000)
        XCTAssertEqual(inputs.pi, 100)
        XCTAssertNil(inputs.termMonths)
        XCTAssertNil(inputs.startDate)
    }

    func testBlankEscrowIsZero() throws {
        var d = validDraft(); d.escrowText = ""
        XCTAssertEqual(try d.validate(now: now).get().escrow, 0)
    }

    func testMissingRequiredIsIncomplete() {
        var d = validDraft(); d.rateText = ""
        XCTAssertEqual(d.validate(now: now), .failure(.incomplete))
        XCTAssertNil(LoanDraft.Problem.incomplete.message)
        XCTAssertFalse(d.isValid)
    }

    func testEscrowMustBeBelowTotal() {
        var d = validDraft(); d.escrowText = "150"
        XCTAssertEqual(d.validate(now: now), .failure(.escrowTooLarge))
    }

    func testPaymentMustCoverInterest() {
        var d = validDraft(); d.totalText = "60" // pi 10 == interest 10
        XCTAssertEqual(d.validate(now: now), .failure(.paymentBelowInterest))
        XCTAssertNotNil(LoanDraft.Problem.paymentBelowInterest.message)
    }

    func testFutureAsOfRejected() {
        var d = validDraft(); d.asOf = now.addingTimeInterval(86_400)
        XCTAssertEqual(d.validate(now: now), .failure(.futureDate))
    }

    func testOptionalFields() throws {
        var d = validDraft()
        d.principalText = "300000"; d.termYearsText = "30"; d.hasStartDate = true
        let inputs = try d.validate(now: now).get()
        XCTAssertEqual(inputs.originalPrincipal, 300_000)
        XCTAssertEqual(inputs.termMonths, 360)
        XCTAssertEqual(inputs.startDate, d.startDate)
    }

    func testScheduleRoundTripAndPrefill() throws {
        let container = AppSchema.makeInMemoryContainer() // keep alive
        let ctx = container.mainContext
        let inputs = try validDraft().validate(now: now).get()
        let schedule = LoanSchedule(inputs: inputs)
        ctx.insert(schedule)
        try ctx.save()
        XCTAssertEqual(schedule.pi, 100)
        XCTAssertEqual(schedule.anchorBalance, 1000)

        // Prefill uses today's computed balance (no payment due between Jan 5 and Jan 10).
        let prefill = LoanDraft(schedule: schedule, now: now)
        XCTAssertEqual(prefill.balanceText, "1000")
        XCTAssertEqual(prefill.rateText, "12")
        XCTAssertEqual(prefill.escrowText, "50")
        XCTAssertEqual(prefill.asOf, now)
    }

    func testPreviewMentionsPIAndPayoff() throws {
        let preview = try validDraft().validate(now: now).get().preview(now: now)
        XCTAssertTrue(preview.hasPrefix("P&I "), preview)
        XCTAssertTrue(preview.contains("next payment"), preview)
        XCTAssertTrue(preview.contains("payoff"), preview)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppTests/LoanDraftTests`
Expected: build FAIL — `cannot find 'LoanDraft' in scope`.

- [ ] **Step 3: Implement**

`Sources/FinApp/Models/LoanSchedule.swift`:

```swift
import Foundation
import SwiftData

/// Payment schedule for a manual loan whose balance the app computes
/// (`LoanUpdater`). Projects forward from a known anchor balance; see
/// `Amortization`. Owned by its `Account` (cascade delete).
@Model
final class LoanSchedule {
    /// Annual rate in percent, e.g. 6.25.
    var annualRate: Decimal
    /// Total monthly payment, including escrow.
    var totalPayment: Decimal
    /// Taxes/insurance portion of `totalPayment`; doesn't reduce the balance.
    var escrow: Decimal
    /// Day of month payments post (1...28).
    var paymentDay: Int
    /// Amount owed (positive) as of `anchorDate`.
    var anchorBalance: Decimal
    var anchorDate: Date
    /// Display-only loan details.
    var originalPrincipal: Decimal? = nil
    var termMonths: Int? = nil
    var startDate: Date? = nil
    var account: Account? = nil

    init(inputs: LoanDraft.Inputs) {
        annualRate = inputs.annualRate
        totalPayment = inputs.totalPayment
        escrow = inputs.escrow
        paymentDay = inputs.paymentDay
        anchorBalance = inputs.balance
        anchorDate = inputs.asOf
        originalPrincipal = inputs.originalPrincipal
        termMonths = inputs.termMonths
        startDate = inputs.startDate
    }

    /// Overwrite every field from an edited form; re-anchors to its balance/date.
    func apply(_ inputs: LoanDraft.Inputs) {
        annualRate = inputs.annualRate
        totalPayment = inputs.totalPayment
        escrow = inputs.escrow
        paymentDay = inputs.paymentDay
        anchorBalance = inputs.balance
        anchorDate = inputs.asOf
        originalPrincipal = inputs.originalPrincipal
        termMonths = inputs.termMonths
        startDate = inputs.startDate
    }

    /// Principal & interest — the part of the payment that amortizes.
    var pi: Decimal { totalPayment - escrow }

    func balance(asOf date: Date, calendar: Calendar = .current) -> Decimal {
        Amortization.balance(anchor: anchorBalance, annualRate: annualRate, pi: pi,
                             paymentDay: paymentDay, anchorDate: anchorDate,
                             asOf: date, calendar: calendar)
    }

    func lastPaymentDate(asOf date: Date, calendar: Calendar = .current) -> Date? {
        Amortization.paymentDates(after: anchorDate, through: date,
                                  paymentDay: paymentDay, calendar: calendar).last
    }

    func nextPaymentDate(asOf date: Date, calendar: Calendar = .current) -> Date {
        Amortization.nextPaymentDate(after: date, paymentDay: paymentDay, calendar: calendar)
    }

    func payoffDate(asOf date: Date, calendar: Calendar = .current) -> Date? {
        Amortization.payoffDate(balance: balance(asOf: date, calendar: calendar),
                                annualRate: annualRate, pi: pi, paymentDay: paymentDay,
                                from: date, calendar: calendar)
    }

    /// Restart the projection from a known balance (extra payment, manual edit).
    func reanchor(to owed: Decimal, at date: Date) {
        anchorBalance = max(0, owed)
        anchorDate = date
    }
}
```

`Sources/FinApp/Loans/LoanDraft.swift`:

```swift
import Foundation

/// Text-field state for the loan schedule form, parsed and validated into
/// `Inputs`. Pure value type so validation is unit-tested without UI.
struct LoanDraft: Equatable {
    var balanceText = ""
    var asOf = Date()
    var rateText = ""
    var totalText = ""
    var escrowText = ""
    var paymentDay = 1
    var principalText = ""
    var termYearsText = ""
    var hasStartDate = false
    var startDate = Date()

    struct Inputs: Equatable {
        var balance: Decimal
        var asOf: Date
        var annualRate: Decimal
        var totalPayment: Decimal
        var escrow: Decimal
        var paymentDay: Int
        var originalPrincipal: Decimal?
        var termMonths: Int?
        var startDate: Date?

        var pi: Decimal { totalPayment - escrow }
    }

    enum Problem: Error, Equatable {
        case incomplete, futureDate, escrowTooLarge, paymentBelowInterest

        /// nil for `.incomplete`: Save is just disabled until required fields are filled.
        var message: String? {
            switch self {
            case .incomplete: nil
            case .futureDate: "The as-of date can't be in the future."
            case .escrowTooLarge: "Escrow must be less than the monthly payment."
            case .paymentBelowInterest: "Payment minus escrow doesn't cover the monthly interest, so the balance would never go down."
            }
        }
    }

    init() {}

    /// Prefill for editing: the balance is the schedule's computed balance as of `now`.
    init(schedule: LoanSchedule, now: Date = Date(), calendar: Calendar = .current) {
        balanceText = Self.text(schedule.balance(asOf: now, calendar: calendar))
        asOf = now
        rateText = Self.text(schedule.annualRate)
        totalText = Self.text(schedule.totalPayment)
        escrowText = Self.text(schedule.escrow)
        paymentDay = schedule.paymentDay
        principalText = schedule.originalPrincipal.map(Self.text) ?? ""
        termYearsText = schedule.termMonths.map { String($0 / 12) } ?? ""
        hasStartDate = schedule.startDate != nil
        startDate = schedule.startDate ?? now
    }

    static func text(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }

    private static func number(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Decimal(string: trimmed, locale: .current)
    }

    var isValid: Bool {
        if case .success = validate() { true } else { false }
    }

    func validate(now: Date = Date()) -> Result<Inputs, Problem> {
        guard let balance = Self.number(balanceText), balance > 0,
              let rate = Self.number(rateText), rate >= 0,
              let total = Self.number(totalText), total > 0 else { return .failure(.incomplete) }
        let escrow = Self.number(escrowText) ?? 0
        guard escrow >= 0 else { return .failure(.incomplete) }
        guard escrow < total else { return .failure(.escrowTooLarge) }
        guard asOf <= now else { return .failure(.futureDate) }
        guard Amortization.paymentCoversInterest(balance: balance, annualRate: rate, pi: total - escrow) else {
            return .failure(.paymentBelowInterest)
        }
        let principal = Self.number(principalText).flatMap { $0 > 0 ? $0 : nil }
        let years = Int(termYearsText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        return .success(Inputs(
            balance: balance, asOf: asOf, annualRate: rate, totalPayment: total, escrow: escrow,
            paymentDay: min(max(paymentDay, 1), 28), originalPrincipal: principal,
            termMonths: years.map { $0 * 12 }, startDate: hasStartDate ? startDate : nil))
    }
}

extension LoanDraft.Inputs {
    /// "P&I $1,798.65 · next payment Nov 1 · payoff ~Mar 2052"
    func preview(now: Date = Date(), calendar: Calendar = .current) -> String {
        let current = Amortization.balance(anchor: balance, annualRate: annualRate, pi: pi,
                                           paymentDay: paymentDay, anchorDate: asOf,
                                           asOf: now, calendar: calendar)
        let next = Amortization.nextPaymentDate(after: now, paymentDay: paymentDay, calendar: calendar)
        var parts = ["P&I \(Money.string(pi))",
                     "next payment \(next.formatted(.dateTime.month(.abbreviated).day()))"]
        if let payoff = Amortization.payoffDate(balance: current, annualRate: annualRate, pi: pi,
                                                paymentDay: paymentDay, from: now, calendar: calendar) {
            parts.append("payoff ~\(payoff.formatted(.dateTime.month(.abbreviated).year()))")
        }
        return parts.joined(separator: " · ")
    }
}
```

In `Sources/FinApp/Models/Account.swift`, after the `supersededProviderID` property:

```swift
    /// Payment schedule for a manual loan whose balance the app computes
    /// (`LoanUpdater`). nil for every other account. Defaulted for migration.
    @Relationship(deleteRule: .cascade, inverse: \LoanSchedule.account)
    var loanSchedule: LoanSchedule? = nil
```

In `Sources/FinApp/Models/AppSchema.swift`, append `LoanSchedule.self,` after `AccountBalanceSnapshot.self,`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppTests/LoanDraftTests -only-testing:FinAppTests/SchemaTests`
Expected: all pass. (`Money.string` uses the simulator locale; the preview test only checks fixed words.)

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/Models/LoanSchedule.swift Sources/FinApp/Loans/LoanDraft.swift Sources/FinApp/Models/Account.swift Sources/FinApp/Models/AppSchema.swift Tests/FinAppTests/LoanDraftTests.swift FinApp.xcodeproj
git commit -m "feat(loans): add LoanSchedule model and form validation

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: LoanUpdater + launch/foreground triggers

**Files:**
- Create: `Sources/FinApp/Loans/LoanUpdater.swift`
- Modify: `Sources/FinApp/App/FinAppApp.swift` (init after `AccountSource.migrateManual(...)`; `.active` branch of `onChange(of: scenePhase)`)
- Test: `Tests/FinAppTests/LoanUpdaterTests.swift`

**Interfaces:**
- Consumes: `LoanSchedule`, `Account.loanSchedule` (Task 2); `NetWorthSnapshotService.stage(value:on:in:calendar:)`, `AccountBalanceSnapshotService.stage(_:on:in:calendar:)`, `Analytics.netWorth(_:)` (existing).
- Produces (used by Tasks 4–5):
  - `LoanUpdater.refresh(in: ModelContext, now: Date = Date(), calendar: Calendar = .current)`
  - `LoanUpdater.reanchor(_ account: Account, to owed: Decimal, now: Date = Date(), in: ModelContext, calendar: Calendar = .current)`
  - `LoanUpdater.applyExtraPrincipal(_ amount: Decimal, to account: Account, now: Date = Date(), in: ModelContext, calendar: Calendar = .current)`

- [ ] **Step 1: Write the failing tests**

`Tests/FinAppTests/LoanUpdaterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppTests/LoanUpdaterTests`
Expected: build FAIL — `cannot find 'LoanUpdater' in scope`.

- [ ] **Step 3: Implement**

`Sources/FinApp/Loans/LoanUpdater.swift`:

```swift
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
```

In `Sources/FinApp/App/FinAppApp.swift` `init()`, after `AccountSource.migrateManual(in: self.container.mainContext)`:

```swift
        LoanUpdater.refresh(in: self.container.mainContext)
```

In the `.onChange(of: scenePhase)` `else if phase == .active` branch, after the FinanceKit line:

```swift
                LoanUpdater.refresh(in: container.mainContext)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppTests`
Expected: all unit tests pass (previous 205 + new).

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/Loans/LoanUpdater.swift Sources/FinApp/App/FinAppApp.swift Tests/FinAppTests/LoanUpdaterTests.swift FinApp.xcodeproj
git commit -m "feat(loans): recompute scheduled loan balances at launch and foreground

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Add Account auto-calculate + row tag + UI test

**Files:**
- Create: `Sources/FinApp/Features/Accounts/LoanScheduleFields.swift`
- Modify: `Sources/FinApp/Features/Accounts/AddAccountView.swift`
- Modify: `Sources/FinApp/Features/Accounts/AccountsView.swift` (`metaLine`, ~line 381)
- Test: `Tests/FinAppUITests/FinAppUITests.swift` (new test after `testManualAccountCreateEditDelete`)

**Interfaces:**
- Consumes: `LoanDraft`, `LoanSchedule(inputs:)`, `LoanUpdater.refresh(in:)`.
- Produces (used by Task 5): `LoanScheduleFields(draft: Binding<LoanDraft>)` — a multi-row view (no container) with as-of date, rate, total payment, escrow, payment day, optional fields, and the error/preview line. Identifiers: `loanAsOfPicker`, `loanRateField`, `loanPaymentField`, `loanEscrowField`, `loanPaymentDayStepper`, `loanPreview`, `loanError`.

- [ ] **Step 1: Write the failing UI test**

Add to `FinAppUITests` after `testManualAccountCreateEditDelete`:

```swift
    // 11b. A manual loan with auto-calculate on is created with a schedule.
    func testAddLoanWithAutoCalculatedBalance() {
        let app = launch(tab: 0)
        XCTAssertTrue(app.buttons["addAccountButton"].waitForExistence(timeout: 8))
        app.buttons["addAccountButton"].tap()

        let name = "Test Mortgage"
        let nameField = app.textFields["accountNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Add Account form missing")
        nameField.tap(); nameField.typeText(name)
        app.buttons["accountType-Loan"].tap()
        let balanceField = app.textFields["0.00"]
        balanceField.tap(); balanceField.typeText("250000")

        let toggle = app.switches["loanAutoToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "Auto-calculate toggle missing for Loan")
        // Tap the switch itself (right edge), not the label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()

        let rate = app.textFields["loanRateField"]
        XCTAssertTrue(rate.waitForExistence(timeout: 3), "Schedule fields did not appear")
        rate.tap(); rate.typeText("6")
        let payment = app.textFields["loanPaymentField"]
        payment.tap(); payment.typeText("2500")
        let escrow = app.textFields["loanEscrowField"]
        escrow.tap(); escrow.typeText("400")
        XCTAssertTrue(app.staticTexts["loanPreview"].waitForExistence(timeout: 3), "Preview missing")

        app.buttons["Save"].tap()

        let row = app.staticTexts[name]
        swipeUpUntilHittable(app, row)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Loan account not added")
        let autoTag = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "· auto")).firstMatch
        XCTAssertTrue(autoTag.exists, "Row should be tagged auto")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppUITests/FinAppUITests/testAddLoanWithAutoCalculatedBalance`
Expected: FAIL — "Auto-calculate toggle missing for Loan".

- [ ] **Step 3: Implement**

`Sources/FinApp/Features/Accounts/LoanScheduleFields.swift`:

```swift
import SwiftUI

/// Loan schedule inputs, as bare rows so they work inside a `Form` section
/// (Edit Schedule) and inside a card `VStack` (Add Account). The balance
/// field itself is owned by the caller.
struct LoanScheduleFields: View {
    @Binding var draft: LoanDraft

    var body: some View {
        DatePicker("As of", selection: $draft.asOf, in: ...Date(), displayedComponents: .date)
            .accessibilityIdentifier("loanAsOfPicker")
        field("Interest rate %", text: $draft.rateText, prompt: "6.25", id: "loanRateField")
        field("Monthly payment (total)", text: $draft.totalText, prompt: "0.00", id: "loanPaymentField")
        field("Escrow (taxes & insurance)", text: $draft.escrowText, prompt: "0.00", id: "loanEscrowField")
        Stepper("Payment day: \(draft.paymentDay)", value: $draft.paymentDay, in: 1...28)
            .accessibilityIdentifier("loanPaymentDayStepper")
        Text("Optional")
            .font(.caption).foregroundStyle(Color.textSecondary)
        field("Original principal", text: $draft.principalText, prompt: "0.00", id: "loanPrincipalField")
        field("Term (years)", text: $draft.termYearsText, prompt: "30", id: "loanTermField", decimal: false)
        Toggle("Start date", isOn: $draft.hasStartDate)
        if draft.hasStartDate {
            DatePicker("Started", selection: $draft.startDate, displayedComponents: .date)
        }
        switch draft.validate() {
        case .success(let inputs):
            Text(inputs.preview())
                .font(.caption).foregroundStyle(Color.textSecondary)
                .accessibilityIdentifier("loanPreview")
        case .failure(let problem):
            if let message = problem.message {
                Text(message)
                    .font(.caption).foregroundStyle(Color.negative)
                    .accessibilityIdentifier("loanError")
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String,
                       id: String, decimal: Bool = true) -> some View {
        LabeledContent(label) {
            TextField(prompt, text: text)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(id)
        }
    }
}
```

Changes to `AddAccountView.swift`:

1. New state after `balanceText`:

```swift
    @State private var autoCalculate = false
    @State private var draft = LoanDraft()

    /// Loan with auto-calculate on: balance comes from the schedule.
    private var usesSchedule: Bool { type == .loan && autoCalculate }
```

2. In `body`, replace the Balance `VStack` + `infoCard` with:

```swift
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(usesSchedule ? "Current balance" : "Balance")
                        balanceCard
                    }
                    if type == .loan {
                        scheduleCard
                    }
                    infoCard
```

3. Save button `.disabled(...)` becomes:

```swift
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || magnitude == nil
                                  || (usesSchedule && !draft.isValid))
```

4. After `.navigationBarTitleDisplayMode(.inline)` add:

```swift
            .onChange(of: balanceText) { _, new in draft.balanceText = new }
```

5. New card:

```swift
    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Auto-calculate balance", isOn: $autoCalculate)
                .accessibilityIdentifier("loanAutoToggle")
            if autoCalculate {
                LoanScheduleFields(draft: $draft)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 1))
    }
```

6. `infoCard` text becomes conditional:

```swift
            Text(usesSchedule
                 ? "The balance updates on each payment date from your rate and payment. Escrow doesn't reduce the balance."
                 : "Manual accounts aren't synced — update the balance yourself. Credit cards and loans are stored as debts; enter the amount you owe.")
```

7. In `save()`, after `context.insert(account)` and before `try? context.save()`:

```swift
        if usesSchedule, case .success(let inputs) = draft.validate() {
            account.loanSchedule = LoanSchedule(inputs: inputs)
        }
```

and after `try? context.save()`:

```swift
        if account.loanSchedule != nil { LoanUpdater.refresh(in: context) }
```

In `AccountsView.swift` `metaLine`, replace the `.manual` case:

```swift
        case .manual: return account.loanSchedule != nil ? "\(type) · auto" : "\(type) · manual"
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodegen generate && xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppUITests/FinAppUITests/testAddLoanWithAutoCalculatedBalance -only-testing:FinAppUITests/FinAppUITests/testManualAccountCreateEditDelete`
Expected: both PASS. If the toggle tap or fields below the fold misbehave, dump `app.debugDescription` from inside the test (simulator screenshots can't capture test UI) and adjust the test's element queries only — not the product behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/Features/Accounts/LoanScheduleFields.swift Sources/FinApp/Features/Accounts/AddAccountView.swift Sources/FinApp/Features/Accounts/AccountsView.swift Tests/FinAppUITests/FinAppUITests.swift FinApp.xcodeproj
git commit -m "feat(loans): add auto-calculate option when adding a loan

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Account detail schedule section, edit sheet, docs

**Files:**
- Create: `Sources/FinApp/Features/Accounts/LoanScheduleSection.swift` (section + `EditLoanScheduleView`)
- Modify: `Sources/FinApp/Features/Accounts/AccountsView.swift` (`AccountDetailView`: insert section, `applyBalance`, balance resync)
- Modify: `CLAUDE.md` (Architecture: add a **Loans** paragraph after **FinanceKit**)
- Test: `Tests/FinAppUITests/FinAppUITests.swift` (extend 11b)

**Interfaces:**
- Consumes: `LoanScheduleFields`, `LoanDraft(schedule:)`, `LoanSchedule.apply/pi/balance/nextPaymentDate/payoffDate`, `LoanUpdater.refresh/reanchor/applyExtraPrincipal`.
- Produces: `LoanScheduleSection(account: Account, schedule: LoanSchedule)`; identifiers `loanExtraField`, `loanApplyExtraButton`, `loanEditButton`, `loanRemoveButton`.

- [ ] **Step 1: Extend the failing UI test**

Append to the end of `testAddLoanWithAutoCalculatedBalance`:

```swift
        // Detail shows the schedule section with its controls.
        row.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
        let edit = app.buttons["loanEditButton"]
        swipeUpUntilHittable(app, edit)
        XCTAssertTrue(edit.exists, "Edit schedule button missing")
        XCTAssertTrue(app.textFields["loanExtraField"].exists, "Extra principal field missing")
        XCTAssertTrue(app.buttons["loanRemoveButton"].exists, "Remove schedule button missing")
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppUITests/FinAppUITests/testAddLoanWithAutoCalculatedBalance`
Expected: FAIL — "Edit schedule button missing".

- [ ] **Step 3: Implement**

`Sources/FinApp/Features/Accounts/LoanScheduleSection.swift`:

```swift
import SwiftUI
import SwiftData

/// Account-detail section for a manual loan with a `LoanSchedule`: summary,
/// irregular extra principal, edit, and remove.
struct LoanScheduleSection: View {
    @Environment(\.modelContext) private var context
    let account: Account
    let schedule: LoanSchedule
    @State private var extraText = ""
    @State private var showExtraConfirmation = false
    @State private var editing = false

    private var extra: Decimal? {
        Decimal(string: extraText, locale: .current).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        let now = Date()
        Section("Loan schedule") {
            LabeledContent("Interest rate", value: "\(LoanDraft.text(schedule.annualRate))%")
            LabeledContent("Principal & interest", value: Money.string(schedule.pi))
            LabeledContent("Escrow", value: Money.string(schedule.escrow))
            LabeledContent("Payment day", value: "\(schedule.paymentDay)")
            if schedule.balance(asOf: now) == 0 {
                LabeledContent("Status", value: "Paid off")
            } else {
                LabeledContent("Next payment",
                               value: schedule.nextPaymentDate(asOf: now).formatted(date: .abbreviated, time: .omitted))
                if let payoff = schedule.payoffDate(asOf: now) {
                    LabeledContent("Payoff", value: payoff.formatted(.dateTime.month(.abbreviated).year()))
                }
            }
            if let principal = schedule.originalPrincipal {
                LabeledContent("Original loan", value: Money.string(principal))
            }
            if let months = schedule.termMonths {
                LabeledContent("Term", value: "\(months / 12) years")
            }
            if let start = schedule.startDate {
                LabeledContent("Start date", value: start.formatted(date: .abbreviated, time: .omitted))
            }
            HStack {
                TextField("Extra principal", text: $extraText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("loanExtraField")
                Button("Apply") { showExtraConfirmation = true }
                    .buttonStyle(.borderless)
                    .disabled(extra == nil)
                    .accessibilityIdentifier("loanApplyExtraButton")
            }
            Button("Edit schedule") { editing = true }
                .accessibilityIdentifier("loanEditButton")
            Button("Remove schedule", role: .destructive) { remove() }
                .accessibilityIdentifier("loanRemoveButton")
        }
        .listRowBackground(Color.surface)
        .confirmationDialog("Reduce balance by \(Money.string(extra ?? 0))?",
                            isPresented: $showExtraConfirmation, titleVisibility: .visible) {
            Button("Apply Extra Payment") { applyExtra() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editing) {
            EditLoanScheduleView(schedule: schedule)
        }
    }

    private func applyExtra() {
        guard let extra else { return }
        LoanUpdater.applyExtraPrincipal(extra, to: account, in: context)
        extraText = ""
    }

    /// Back to a plain manual loan; the current balance stays.
    private func remove() {
        account.loanSchedule = nil
        context.delete(schedule)
        try? context.save()
    }
}

/// Edit a schedule. Prefilled with today's computed balance; saving
/// re-anchors to the form's balance and as-of date.
struct EditLoanScheduleView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let schedule: LoanSchedule
    @State private var draft: LoanDraft

    init(schedule: LoanSchedule) {
        self.schedule = schedule
        _draft = State(initialValue: LoanDraft(schedule: schedule))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current balance") {
                    LabeledContent("Balance") {
                        TextField("0.00", text: $draft.balanceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("Schedule") {
                    LoanScheduleFields(draft: $draft)
                }
            }
            .navigationTitle("Edit Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!draft.isValid)
                }
            }
        }
    }

    private func save() {
        guard case .success(let inputs) = draft.validate() else { return }
        schedule.apply(inputs)
        try? context.save()
        LoanUpdater.refresh(in: context)
        dismiss()
    }
}
```

Changes to `AccountDetailView` in `AccountsView.swift`:

1. After the Balance/Type `Section { ... }.listRowBackground(Color.surface)` (before the Delete section) insert:

```swift
            if account.isManual, account.accountType == .loan, let schedule = account.loanSchedule {
                LoanScheduleSection(account: account, schedule: schedule)
            }
```

2. Replace `applyBalance()` with:

```swift
    /// Persist an edited balance for a manual account (ignores unparseable input).
    /// A scheduled loan re-anchors its projection instead — only when the typed
    /// amount differs, since seeding the field on appear also fires onChange.
    private func applyBalance() {
        if account.isManual, let value = Decimal(string: balanceText, locale: .current) {
            if account.accountType == .loan, account.loanSchedule != nil {
                if value.magnitude != account.balance.magnitude {
                    LoanUpdater.reanchor(account, to: value.magnitude, in: context)
                }
                return
            }
            account.balance = account.accountType.signedBalance(from: value)
        }
        try? context.save()
    }
```

3. After `.onChange(of: account.accountType) { applyBalance() }` add (keeps the field in sync when an extra payment or schedule edit changes the balance):

```swift
        .onChange(of: account.balance) { _, new in
            if Decimal(string: balanceText, locale: .current)?.magnitude != new.magnitude {
                balanceText = NSDecimalNumber(decimal: new.magnitude).stringValue
            }
        }
```

`CLAUDE.md` — after the **FinanceKit** paragraph add:

```markdown
**Loans** (`Loans/`): a manual Loan account may carry a `LoanSchedule` (cascade-owned
by `Account`) so its balance computes itself. `Amortization` (pure) projects forward
from the schedule's anchor balance/date (interest rounded to cents per payment; a
payment on the anchor day is not applied). `LoanUpdater.refresh` writes the result
(stored negative) at launch/foreground and after edits — idempotent, never moves the
anchor; extra principal and manual balance edits re-anchor. Only P&I
(`totalPayment − escrow`) reduces the balance.
```

- [ ] **Step 4: Run the full suite**

Run: `xcodegen generate && xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` — all unit and UI tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/Features/Accounts/LoanScheduleSection.swift Sources/FinApp/Features/Accounts/AccountsView.swift CLAUDE.md Tests/FinAppUITests/FinAppUITests.swift FinApp.xcodeproj
git commit -m "feat(loans): add loan schedule section with extra principal and editing

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
