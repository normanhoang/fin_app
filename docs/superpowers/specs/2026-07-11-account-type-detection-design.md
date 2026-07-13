# Account Type Detection on First SimpleFin Sync — Design

Date: 2026-07-11
Status: Approved

## Problem

SimpleFin provides no account-type field, so every synced account is inserted as
`AccountType.cash`. Users must manually reclassify credit cards, loans, and
investment accounts. Detect the type heuristically when the account is first
inserted.

## Scope

- **New accounts only.** Detection runs on the insert path of
  `SyncService.upsertAccount`. Existing accounts (already synced, sitting as
  Cash) are not touched; the user reclassifies those manually.
- The update path of `upsertAccount` never writes `typeRaw`, so a user
  reclassification survives re-sync (existing behavior, unchanged).
- Manual accounts are unaffected — the user picks a type in `AddAccountView`.

## Detection heuristic

New pure static function (no SwiftData, no UI):

```swift
// Sources/FinApp/SimpleFin/AccountTypeDetector.swift
enum AccountTypeDetector {
    static func infer(name: String, balance: Decimal) -> AccountType
}
```

Lowercased substring match against the account name, checked in this order
(first match wins):

1. **loan** — "loan", "mortgage", "heloc"
2. **investment** — "brokerage", "invest", "401k", "401(k)", "ira", "roth",
   "hsa", "529", "mutual", "stock", "crypto", "retirement"
3. **creditCard** — "credit", "visa", "mastercard", "amex", "card"
4. **cash** — "checking", "chequing", "savings", "saving", "cash", "money market"

Order rationale: loan before creditCard so "Car Loan" and "Mortgage Card
Services" style names don't land as cards; investment before creditCard so
e.g. "Fidelity Rewards Investment Card" errs toward investment (rare; ties are
inherently ambiguous, first-match order is the tiebreak).

Substring caution: "ira" and "hsa" match only as whole words (word-boundary
check) so names like "Admiral Shares" don't classify as investment. All other
keywords use plain lowercased substring matching.

**Fallback (no keyword match):**
- `balance < 0` → `.creditCard` (most negative-balance bank accounts are cards)
- otherwise → `.cash` (current default, unchanged)

## Wiring

`SyncService.upsertAccount`, insert path only:

```swift
let account = Account(
    id: dto.id, org: dto.org, name: dto.name, currency: dto.currency,
    balance: dto.balance, availableBalance: dto.availableBalance,
    balanceDate: dto.balanceDate,
    typeRaw: AccountTypeDetector.infer(name: dto.name, balance: dto.balance).rawValue
)
```

## Schema / migration

None. No new stored properties; `typeRaw` already exists with a default.

## Testing (TDD)

New unit-test file `Tests/FinAppTests/AccountTypeDetectorTests.swift`:

- One case per keyword group (loan, investment, creditCard, cash).
- Word-boundary case: name containing "admiral" does not become investment.
- Precedence: "Car Loan" → loan (not creditCard); an investment+card name →
  investment.
- Fallback: unknown name + negative balance → creditCard; unknown name +
  positive balance → cash.
- Case-insensitivity: "SAVINGS" → cash.

`SyncService`-level tests (in-memory container, qualify `FinApp.Category` if
needed):

- New DTO named e.g. "Chase Sapphire Credit Card" inserts with
  `accountType == .creditCard`.
- Re-sync of an existing account whose type the user changed does not clobber
  the type.

## Out of scope

- Decoding SimpleFin `holdings` (investment signal) — bridge support spotty.
- Re-detecting existing accounts.
- Any UI change.
