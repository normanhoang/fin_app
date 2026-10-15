# FinanceKit Import for Apple Accounts — Design

Date: 2026-10-15
Status: Approved (pending written-spec review)

## Problem

Apple Card reaches FinApp through SimpleFin Bridge, whose aggregator connection breaks
whenever Apple's session expires or a fresh 2FA prompt is required. The user re-links
constantly. Apple's FinanceKit framework (iOS 17.4+, US) exposes Apple Card, Apple Cash,
and Apple Savings data on-device with one-time user consent — no bank login, no 2FA, no
reconnects.

## Goals

- Import every Apple account the user grants via FinanceKit (Card, Cash, Savings).
- Merge the existing SimpleFin Apple Card account into the FinanceKit one, preserving
  the account row, rename, balance history, and user categories/notes.
- Prompt the user to unlink Apple Card in SimpleFin Bridge while the overlap persists.
- Ship safely before Apple grants the entitlement: default build is unchanged.

## Non-goals

- FinanceKit background delivery extension (iOS 26) — foreground import only.
- History-token incremental sync (`transactionHistory(since:)`).
- Restoring a SimpleFin link after FinanceKit access is revoked.
- Dovenmuehle mortgage or any non-Apple account.

## Constraints

- Requires Apple's FinanceKit **managed entitlement**, granted per bundle ID
  (`com.normanhoang.finapp`) on request by the Account Holder. Apple's framework docs
  also state an **organization-level** developer account is required — possible
  blocker, see `AppStore/financekit-entitlement-request.md`.
- Adding an un-granted entitlement breaks automatic signing → gated by a build flag.
- `NSFinancialDataUsageDescription` must be in Info.plist.
- FinanceKit is unavailable in the Simulator (`isDataAvailable` false); data is
  readable only while the device is unlocked.
- Deployment target stays 17.0; FinanceKit code is `@available(iOS 17.4, *)`.
- The user picks accounts and the shared date range in the system sheet, so imported
  history may be shorter than the requested lookback.

## Feature flag

A `FINANCEKIT` Swift compilation condition in `project.yml`, **off by default**. When
on, it also adds `com.apple.developer.financekit` to the entitlements. With it off:
the client file compiles to nothing, the Settings section and Accounts banner for
FinanceKit are hidden, and behavior is identical to today. Enabling it is a single
`project.yml` change + `xcodegen generate`.

Everything that does not import FinanceKit (model field, importer, merge logic,
SyncService scoping, unlink banner) compiles and is tested regardless of the flag.

## Data model

`Account` gains (both defaulted → lightweight migration):

```swift
/// Where this account's data comes from. Defaulted so existing stores migrate.
var sourceRaw: String = AccountSource.simplefin.rawValue
/// For an account merged from SimpleFin into FinanceKit: its old SimpleFin storage
/// id, so SimpleFin sync can recognize and skip it.
var supersededProviderID: String? = nil
```

```swift
enum AccountSource: String { case simplefin, manual, financeKit }
```

- Launch-time one-shot (alongside `AccountType.migrateOther`): rows with
  `isManual == true` get `source = .manual`. `isManual` remains, meaning
  `source == .manual`; existing UI keeps using it.
- FinanceKit account storage id: `"financekit-<FinanceKit account UUID>"`;
  `providerID` = the UUID string. Transaction storage id is account-scoped:
  `"financekit-<account UUID>-<transaction UUID>"`.

## SyncService change

- Upsert, legacy-migration, rekey, and prune logic consider only
  `source == .simplefin` accounts. Prune never deletes `.manual` or `.financeKit` rows
  (today it deletes every non-manual account missing from the response —
  `SyncService.swift:113` — which would wipe FinanceKit accounts).
- An incoming DTO whose storage id equals some account's `supersededProviderID` is
  skipped (no upsert, no transactions). `sync` returns the skipped accounts' display
  names; `SyncCoordinator` exposes them as `supersededStillLinked: [String]`, reset
  each sync.

## Module layout — `Sources/FinApp/FinanceKit/`

| File | Responsibility | Imports FinanceKit |
|---|---|---|
| `FinanceKitDTO.swift` | Plain value types: `FKAccount`, `FKTransaction` (Decimal amounts already signed per app convention) | No |
| `FinanceKitClient.swift` | `FinanceKitSource` protocol + live impl mapping `FinanceStore` → DTOs; `#if FINANCEKIT`, `@available(iOS 17.4, *)` | Yes |
| `FinanceKitImporter.swift` | Pure SwiftData upsert, prune, merge-candidate detection, merge | No |
| `FinanceKitCoordinator.swift` | `@MainActor @Observable`: availability, authorization state, `connect()`, `importIfStale()`, error, merge prompt state | No (via protocol) |

`FinanceKitSource` protocol (the seam tests fake):

```swift
protocol FinanceKitSource: Sendable {
    func isAvailable() -> Bool
    func authorizationStatus() async throws -> FKAuthorization   // .notDetermined/.authorized/.denied
    func requestAuthorization() async throws -> FKAuthorization
    func fetch(since: Date) async throws -> [FKAccount]           // accounts + balances + transactions
}
```

## Import flow

Triggers: same call sites as SimpleFin — launch/foreground (`FinAppApp.swift:98`,
`RootView.swift:160`) and the Settings Sync button (`SettingsView.swift:123`). Runs only
when authorized. No `SyncThrottle`; a 5-minute minimum interval (`importIfStale`)
debounces rapid foregrounds.

Fetch window: first import 120 days back (`SyncCoordinator.initialLookbackDays`);
afterwards last successful import − 5 days (`resyncOverlapDays`). Last import date in
`UserDefaults` key `financeKitLastImportDate`.

Live client queries: `accounts(query:)`, `accountBalances(query:)`,
`transactions(query:)` filtered by date (API confirmed in the iOS 26.5 SDK's
`FinanceKit.swiftinterface`).

### Mapping

| FinanceKit | App |
|---|---|
| `Account` `.liability` / `.asset` | `accountType` `.creditCard` / `.cash` on insert only |
| `institutionName` / `displayName` | `org` / `name` (`customName` still wins) |
| `currentBalance` booked, else available | `balance`; liabilities stored negative |
| available amount if present | `availableBalance` |
| `creditDebitIndicator` `.debit` / `.credit` | `amount` negative / positive |
| `postedDate ?? transactionDate` | `posted` |
| `transactionDescription` / `merchantName` | `detail` / `payee` |
| `status` `.booked` | `pending = false` |
| `status` `.pending`, `.authorized` | `pending = true` |
| `status` `.rejected` | delete local row if present; else skip |
| `status` `.memo` | skip |

Never overwritten by import: `customName`, `customSortIndex`, `typeRaw` after insert,
transaction `note`, `category` when `categorizedByUser`.

Prune: `.financeKit` accounts absent from a fully successful fetch are deleted. A fetch
that throws prunes nothing.

Post-write: same staging as `SyncCoordinator.persist` — `CategorizationEngine
.stageCategorizeAll`, `RecurringDetector.stageRefresh`, `NetWorthSnapshotService.stage`,
`AccountBalanceSnapshotService.stage` — then one `context.save()`; on failure
`context.rollback()`.

## Merge

**Candidate detection** — runs when a FinanceKit account is first inserted. A candidate
is a `.simplefin` account with ≥ 3 transactions matching the FinanceKit account's
transactions (equal amount, posted dates within ±3 days). Exactly one candidate →
prompt; zero or several → no prompt (create fresh).

**Confirmation** — sheet: "Merge *<SimpleFin name>* into *<FinanceKit name>*?"
**Merge** / **Keep separate**. "Keep separate" is remembered per FinanceKit account
UUID (`UserDefaults` set `financeKitMergeDeclined`) and never re-asked. Until the user
answers, the FinanceKit account exists separately (both visible).

**Merge operation** (in one save):
1. The SimpleFin row becomes the FinanceKit row: `supersededProviderID` = old id,
   `id` = `financekit-<uuid>`, `source = .financeKit`, `providerID` = uuid,
   `providerScope = nil`, bank fields overwritten from FinanceKit. The temporary
   separate FinanceKit row (and its transactions) is deleted.
2. `AccountBalanceSnapshot.accountId` rows rekeyed old → new id.
3. Transactions paired greedily: equal amount, ±3 days, closest date first, each used
   once.
   - Matched: id → FinanceKit id, bank fields updated; `category`,
     `categorizedByUser`, `note` kept.
   - Unmatched, dated before the earliest FinanceKit transaction: kept.
   - Unmatched, within FinanceKit's date range: deleted, **unless**
     `categorizedByUser` or `note != nil` (kept).
   - FinanceKit transactions with no match: inserted.
4. Result summary shown in the sheet: "Merged N transactions, removed M duplicates."

## Unlink prompt

While `SyncCoordinator.supersededStillLinked` is non-empty, the Accounts tab shows a
banner: "*<name>* now syncs from Apple Wallet. Remove it from SimpleFin Bridge to stop
duplicate syncing." with an **Open Bridge** button (`https://bridge.simplefin.org`).
Not dismissable; disappears once a sync no longer returns the superseded account.

## UI

- **Settings → "Apple Wallet"** section (flag on and `isDataAvailable`):
  - not determined: **Connect Apple Wallet** → `requestAuthorization()` → import →
    merge sheet if a candidate exists.
  - authorized: last import time; "Manage access in Settings → Privacy & Security".
  - denied/revoked: status text explaining re-enabling in iOS Settings; imported
    accounts remain with their last data.
  - `errorMessage` shown inline, like SimpleFin's.
- **Accounts tab**: unlink banner; FinanceKit rows' subtitle reads "<type> · Apple
  Wallet" (`AccountsView.swift:363`); manual-only controls stay keyed on `isManual`.
- `project.yml`: `INFOPLIST_KEY_NSFinancialDataUsageDescription: "FinApp reads your
  Apple Card, Apple Cash, and Savings activity to show it alongside your other
  accounts. It stays on this iPhone."`

## Error isolation

FinanceKit failures surface only in `FinanceKitCoordinator.errorMessage` and never
modify SimpleFin rows; SimpleFin failures never modify FinanceKit rows.

## Testing

TDD for everything not importing FinanceKit (unit tests use `makeInMemoryContainer()`
and a fake `FinanceKitSource`):

- `FinanceKitImporterTests`: first import inserts; re-import idempotent;
  pending→booked updates in place; rejected deletes; memo skipped; sign mapping for
  asset/liability balances and debit/credit amounts; renames/notes/user categories
  survive; prune only on success and only `.financeKit`.
- `FinanceKitMergeTests`: single candidate found at ≥ 3 matches; none at < 3; none
  when several; pairing (±3 days, each once, closest wins); matched txns keep user
  edits; unmatched in-range deleted unless edited; pre-range history kept; snapshots
  rekeyed; declined merge not re-asked.
- `SyncServiceTests` additions: prune never touches `.financeKit`/`.manual`;
  superseded DTO skipped and reported.
- Migration: `isManual` rows → `source = .manual`; other rows default `.simplefin`.
- `FinanceKitCoordinatorTests`: unavailable hides section; denied state; import
  debounce; error doesn't touch SimpleFin rows.
- UI test: with the flag off, Settings has no "Apple Wallet" section.

### Device checklist (after entitlement)

1. Connect Apple Wallet → system sheet appears; grant Apple Card + Cash.
2. Accounts appear with correct signs (card balance negative, purchases negative).
3. Merge sheet offers the SimpleFin Apple Card; merge; rename/categories preserved;
   no duplicate spending in Dashboard for the overlap month.
4. Unlink banner appears on next SimpleFin sync; unlink in Bridge; banner disappears.
5. A pending Apple Card purchase later posts → same row updates, not duplicated.
6. Revoke in iOS Settings → status reflects it; accounts remain.

## Rollout

1. Merge with `FINANCEKIT` off; ship as normal.
2. Submit the entitlement request (`AppStore/financekit-entitlement-request.md`).
3. On approval: flip the flag, `xcodegen generate`, device checklist, update privacy
   policy wording, release.
