# Auto-Calculated Loan Balance (Mortgage Schedule) — Design

Date: 2026-10-15
Status: Approved in conversation (pending written-spec review)

## Problem

The Dovenmuehle mortgage has no API, and its SimpleFin link breaks on every 2FA
prompt. A manual Loan account works but its balance goes stale unless the user
types it in each month. A fixed-rate mortgage's balance is deterministic from a
known balance, the rate, and the payment — so the app can keep it current itself.

## Goals

- A manual Loan account can carry a payment schedule; its balance updates
  automatically on each payment date with no network access.
- Inputs are anchored on the current statement balance, so past extra payments
  and servicer rounding are already absorbed.
- The user enters the total monthly payment and the escrow portion; only
  principal & interest (P&I) reduces the balance.
- Irregular extra principal payments: enter an amount, tap Apply.

## Non-goals

- Adjustable-rate loans, rate changes over time.
- Recurring extra principal.
- Generating transactions for payments (would duplicate the real payment seen
  in checking and pollute spending/recurring analytics).
- Backfilling snapshot history for days the app wasn't opened.
- Escrow balance tracking.

## Inputs

| Field | Required | Used for |
|---|---|---|
| Current balance (owed) | yes | anchor balance |
| As of date | yes (default today, not in the future) | anchor date |
| Interest rate (annual %) | yes | monthly rate `r = rate / 100 / 12` |
| Monthly payment (total) | yes | `pi = total − escrow` |
| Escrow | yes (may be 0) | subtracted from total |
| Payment day (1–28) | yes | payment dates |
| Original principal | no | display only ("Original loan") |
| Term (years) | no | display only |
| Start date | no | display only |

Validation (blocks Save, inline error): balance > 0; rate ≥ 0; total > 0;
0 ≤ escrow < total; `pi > anchorBalance × r` (payment must exceed the first
month's interest, else the balance never falls).

## Data model

New `@Model` in `Models/LoanSchedule.swift`, added to `AppSchema.models`:

```swift
@Model
final class LoanSchedule {
    var annualRate: Decimal        // percent, e.g. 6.25
    var totalPayment: Decimal
    var escrow: Decimal
    var paymentDay: Int            // 1...28
    var anchorBalance: Decimal     // owed, positive, as of anchorDate
    var anchorDate: Date
    var originalPrincipal: Decimal?
    var termMonths: Int?
    var startDate: Date?
    var account: Account?
}
```

`Account` gains:

```swift
@Relationship(deleteRule: .cascade, inverse: \LoanSchedule.account)
var loanSchedule: LoanSchedule? = nil
```

Optional/defaulted → lightweight migration. Deleting the account deletes its
schedule.

## Math — `Loans/Amortization.swift` (pure)

```swift
enum Amortization {
    /// Payment dates strictly after `anchorDate` through `asOf`, on `paymentDay`.
    static func paymentDates(after anchorDate: Date, through asOf: Date,
                             paymentDay: Int, calendar: Calendar) -> [Date]
    /// Balance after applying each payment date. Never below 0.
    static func balance(anchor: Decimal, annualRate: Decimal, pi: Decimal,
                        paymentDay: Int, anchorDate: Date, asOf: Date,
                        calendar: Calendar) -> Decimal
    static func nextPaymentDate(after: Date, paymentDay: Int, calendar: Calendar) -> Date
    /// Month of the final payment from `balance` onward; nil if pi ≤ interest.
    static func payoffDate(balance: Decimal, annualRate: Decimal, pi: Decimal,
                           paymentDay: Int, from: Date, calendar: Calendar) -> Date?
}
```

Per payment date: `interest = round2(balance × r)`; `principal = pi − interest`;
`balance = max(0, balance − principal)`. Rounding to cents each month
(round half up, `.plain`), matching servicer statements. A payment on the
anchor date itself is **not** applied (the statement balance already reflects it).

## Update — `Loans/LoanUpdater.swift`

`LoanUpdater.refresh(in context: ModelContext, now: Date = .now)`:
for each account where `isManual && loanSchedule != nil`, compute the balance as
of `now`; if it differs from `account.balance`, set
`account.balance = -computed` and `balanceDate` = last applied payment date (or
anchor date if none). If anything changed, stage `NetWorthSnapshotService` and
`AccountBalanceSnapshotService`, then save; on failure, `context.rollback()`.

Idempotent: always computed from the stored anchor; refresh never moves the anchor.

Triggers: launch (`FinAppApp.init`, after the other launch migrations), scene
becoming `.active`, after saving/editing a schedule, after applying extra principal.

## Re-anchoring

- **Apply extra principal X:** `anchorBalance = max(0, current computed balance − X)`,
  `anchorDate = now`, then refresh.
- **Edit schedule save:** the form is prefilled with the current computed balance
  as of today; saving writes all fields and re-anchors to the form's balance/date.
- **Manual balance edit** on a scheduled loan: `anchorBalance = typed value`,
  `anchorDate = now`, then refresh.

## UI

**Add Account** (`AddAccountView`), Loan tile selected:
- Toggle **Auto-calculate balance** (default off → today's behavior).
- On: balance label becomes **Current balance** + **As of** date picker; fields
  **Interest rate %**, **Monthly payment (total)**, **Escrow**, **Payment day**
  (1–28); **Optional** group: original principal, term (years), start date.
- Live preview: "P&I $X · next payment <date> · payoff ~<Mon YYYY>".
- Save disabled until valid; error text inline.

**Account detail** (`AccountDetailView` in `AccountsView.swift`), scheduled loan:
- Balance field stays editable; editing re-anchors (see above).
- **Loan schedule** section: rate, P&I, escrow, payment day, next payment,
  payoff; original loan info when provided.
  - **Edit schedule** → same form, prefilled.
  - **Extra principal** amount field + **Apply** → confirmation
    "Reduce balance by $X?" → re-anchor.
  - **Remove schedule** → deletes the `LoanSchedule`; account stays a plain
    manual loan with its current balance.
- Balance reaching 0 shows "Paid off".

**Accounts list row**: `metaLine` returns "\(type) · auto" for manual accounts
with a schedule (e.g. "Loans · auto").

The schedule form is one view (`Features/Accounts/LoanScheduleForm.swift`)
reused by Add and Edit; identifiers: `loanAutoToggle`, `loanRateField`,
`loanPaymentField`, `loanEscrowField`, `loanExtraField`, `loanApplyExtraButton`.

## Error isolation

SimpleFin and FinanceKit already skip `.manual` accounts; neither touches
`LoanSchedule`. Loan refresh only writes scheduled manual accounts.

## Testing (TDD)

- `AmortizationTests`: $300,000 at 6%/30y → P&I $1,798.65; balance after 12
  payments matches a standard amortization table to within $1 (cent-rounding
  differences); payment on anchor day not applied; multiple elapsed months;
  payoff clamps at 0; `payoffDate` nil when pi ≤ interest; month-end/paymentDay
  edge (Feb).
- `LoanUpdaterTests`: refresh twice same day → no change; balance stored
  negative; snapshots staged on change; accounts without schedule untouched;
  extra principal re-anchors; manual edit re-anchors; deleting account cascades
  schedule.
- UI test: add Loan with auto-calculate on → row shows "auto".
