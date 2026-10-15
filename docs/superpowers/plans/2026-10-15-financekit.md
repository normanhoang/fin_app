# FinanceKit Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import Apple Card / Apple Cash / Apple Savings via FinanceKit, merge the existing SimpleFin Apple Card account into it, and nag the user to unlink it in SimpleFin Bridge — all behind an off-by-default `FINANCEKIT` build flag.

**Architecture:** `Account` gains a `source` (simplefin/manual/financeKit) so SimpleFin sync only manages its own rows. A new `Sources/FinApp/FinanceKit/` module mirrors `SimpleFin/`: plain DTOs, a pure SwiftData importer + merge, an `@Observable` coordinator behind a `FinanceKitSource` protocol, and a live client compiled only under `#if FINANCEKIT`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, FinanceKit (iOS 17.4+), XCTest/XCUITest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-15-financekit-design.md`

## Global Constraints

- Deployment target stays iOS 17.0; FinanceKit code is `@available(iOS 17.4, *)` and inside `#if FINANCEKIT`.
- `FINANCEKIT` is **off** by default; with it off, app behavior is identical to today.
- New `@Model` stored properties MUST have defaults (lightweight migration).
- Amount sign: negative = outflow/debit, positive = inflow; debt balances stored negative.
- Storage ids: account `financekit-<UUID>`; transaction `financekit-<accountUUID>-<txnUUID>`.
- First import looks back 120 days (`SyncCoordinator.initialLookbackDays`); later imports go to last import − 5 days (`SyncCoordinator.resyncOverlapDays`).
- Import debounce: 300 s. Merge: ≥ 3 matches, ±3 days tolerance.
- UserDefaults keys: `financeKitLastImportDate`, `financeKitMergeDeclined`.
- Info.plist: `NSFinancialDataUsageDescription`.
- In test code, qualify `FinApp.Category` (ambiguous in the test target). Tests never import FinanceKit.
- After adding/removing source files: `xcodegen generate`.
- Build: `xcodebuild build -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17'`
- Unit tests: `xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppTests/<Class>`

## Review Focus

1. **Legacy SimpleFin row merged** (`providerID == nil`, id not yet `simplefin-account:…`): its id would never match the scoped id SimpleFin computes, so the superseded skip misses and SimpleFin re-creates a duplicate. Expected: such rows are never merge candidates. → test in Task 4.
2. **Same amount, many transactions** (e.g. three $9.99 subscriptions in a week): pairing must use each transaction once and pick the closest date. → test in Task 4.
3. **SimpleFin sync while the merged Apple Card is still linked in Bridge**: must not resurrect a SimpleFin Apple Card row nor delete the FinanceKit row. → test in Task 2.
4. **FinanceKit fetch throws mid-import** (device locks, revoked access): no SimpleFin or FinanceKit rows change, error is surfaced. → test in Task 5.
5. **Liability balance sign**: FinanceKit's debit/credit indicator for a card balance is the one mapping we can't unit-verify against real data. Expected: card balance owed shows negative. Rule is centralized in one pure function (Task 3) and verified on device (Task 8 checklist).

---

### Task 1: `AccountSource` on `Account`

**Files:**
- Create: `Sources/FinApp/Models/AccountSource.swift`
- Modify: `Sources/FinApp/Models/Account.swift`
- Modify: `Sources/FinApp/App/FinAppApp.swift` (call migration after `AccountType.migrateOther`)
- Test: `Tests/FinAppTests/AccountSourceTests.swift`

**Interfaces:**
- Produces: `enum AccountSource: String { case simplefin, manual, financeKit }`;
  `Account.sourceRaw: String`, `Account.source: AccountSource`, `Account.supersededProviderID: String?`;
  `AccountSource.migrateManual(in: ModelContext)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FinAppTests/AccountSourceTests.swift
import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class AccountSourceTests: XCTestCase {
    func testInitDerivesSourceFromIsManual() {
        let synced = Account(id: "a", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date())
        let manual = Account(id: "m", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date(), isManual: true)
        XCTAssertEqual(synced.source, .simplefin)
        XCTAssertEqual(manual.source, .manual)
        XCTAssertNil(synced.supersededProviderID)
    }

    func testMigrateManualTagsExistingManualRows() throws {
        let ctx = AppSchema.makeInMemoryContainer().mainContext
        let manual = Account(id: "m", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date(), isManual: true)
        manual.sourceRaw = AccountSource.simplefin.rawValue // simulate a pre-migration row
        let synced = Account(id: "a", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date())
        ctx.insert(manual); ctx.insert(synced)
        try ctx.save()

        AccountSource.migrateManual(in: ctx)

        XCTAssertEqual(manual.source, .manual)
        XCTAssertEqual(synced.source, .simplefin)
    }

    func testUnknownRawFallsBackToSimplefin() {
        let a = Account(id: "a", org: "B", name: "C", currency: "USD", balance: 1, balanceDate: Date())
        a.sourceRaw = "bogus"
        XCTAssertEqual(a.source, .simplefin)
    }
}
```

- [ ] **Step 2: Run `xcodegen generate`, then the tests — expect compile failure** (`AccountSource` undefined).

Run: `xcodegen generate && xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppTests/AccountSourceTests`

- [ ] **Step 3: Implement**

```swift
// Sources/FinApp/Models/AccountSource.swift
import Foundation
import SwiftData

/// Where an account's data comes from. Each sync path only manages its own
/// source, so SimpleFin's prune can't delete FinanceKit or manual accounts.
enum AccountSource: String {
    case simplefin, manual, financeKit

    /// One-shot for stores created before `sourceRaw` existed: those rows all
    /// defaulted to `.simplefin`, including manual ones.
    @MainActor
    static func migrateManual(in context: ModelContext) {
        guard let accounts = try? context.fetch(FetchDescriptor<Account>()) else { return }
        var changed = false
        for account in accounts where account.isManual && account.source != .manual {
            account.source = .manual
            changed = true
        }
        if changed { try? context.save() }
    }
}
```

In `Account.swift`, after `customSortIndex`:

```swift
    /// Data source (see `AccountSource`). Defaulted for lightweight migration;
    /// manual rows from older stores are fixed up by `AccountSource.migrateManual`.
    var sourceRaw: String = AccountSource.simplefin.rawValue
    /// For a SimpleFin account merged into FinanceKit: its old SimpleFin storage
    /// id, so SimpleFin sync recognizes and skips it. Defaulted for migration.
    var supersededProviderID: String? = nil
```

Next to `accountType`:

```swift
    var source: AccountSource {
        get { AccountSource(rawValue: sourceRaw) ?? .simplefin }
        set { sourceRaw = newValue.rawValue }
    }
```

In `init`, after `self.isManual = isManual`:

```swift
        self.sourceRaw = (isManual ? AccountSource.manual : .simplefin).rawValue
```

In `FinAppApp.init`, after `AccountType.migrateOther(in: self.container.mainContext)`:

```swift
        AccountSource.migrateManual(in: self.container.mainContext)
```

- [ ] **Step 4: Run tests — expect PASS.** Also run `-only-testing:FinAppTests/SchemaTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/Models/AccountSource.swift Sources/FinApp/Models/Account.swift Sources/FinApp/App/FinAppApp.swift Tests/FinAppTests/AccountSourceTests.swift FinApp.xcodeproj
git commit -m "feat(accounts): add account source and superseded provider id"
```

---

### Task 2: Scope SimpleFin sync to `.simplefin` rows; skip superseded accounts

**Files:**
- Modify: `Sources/FinApp/SimpleFin/SyncService.swift` (filters at lines ~24, ~32, prune at ~113, dto loop)
- Modify: `Sources/FinApp/SimpleFin/SyncCoordinator.swift`
- Test: `Tests/FinAppTests/SyncServiceTests.swift`, `Tests/FinAppTests/SyncCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Account.source`, `Account.supersededProviderID` (Task 1).
- Produces:
  - `SyncService.supersededNames(in dtos: [AccountDTO], context: ModelContext) throws -> [String]`
  - `SyncCoordinator.supersededStillLinked: [String]` (observable, reset each sync and on disconnect)
  - `SyncCoordinator.stageDerivedData(in: ModelContext) throws` — categorize + recurring + net-worth + per-account snapshots (no save). Reused by Task 5.

- [ ] **Step 1: Write failing tests** (append to `SyncServiceTests`)

```swift
    private func financeKitAccount(id: String = "financekit-X", superseding: String? = nil) -> Account {
        let a = Account(id: id, org: "Apple", name: "Apple Card", currency: "USD",
                        balance: -50, balanceDate: Date(), typeRaw: AccountType.creditCard.rawValue)
        a.source = .financeKit
        a.supersededProviderID = superseding
        return a
    }

    func testPruneLeavesFinanceKitAccountsAlone() throws {
        let ctx = makeContext()
        ctx.insert(financeKitAccount())
        try ctx.save()

        try SyncService.sync(accounts: [account(id: "a1", txns: [])], pruneMissing: true, into: ctx)

        let ids = try ctx.fetch(FetchDescriptor<Account>()).map(\.id)
        XCTAssertTrue(ids.contains("financekit-X"))
    }

    func testSupersededAccountIsSkippedAndReported() throws {
        let ctx = makeContext()
        let dto = account(id: "card", txns: [tx(id: "t1", amount: "-5.00")])
        let oldID = SyncService.accountStorageID(providerScope: dto.providerScope, providerID: dto.id)
        let fk = financeKitAccount(superseding: oldID)
        fk.customName = "My Card"
        ctx.insert(fk)
        try ctx.save()

        try SyncService.sync(accounts: [dto], pruneMissing: true, into: ctx)

        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.map(\.id), ["financekit-X"], "no SimpleFin row resurrected")
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Transaction>()).isEmpty)
        XCTAssertEqual(try SyncService.supersededNames(in: [dto], context: ctx), ["My Card"])
    }

    func testSupersededNamesEmptyWhenNotReturned() throws {
        let ctx = makeContext()
        ctx.insert(financeKitAccount(superseding: "simplefin-account:gone"))
        try ctx.save()
        XCTAssertEqual(try SyncService.supersededNames(in: [account(id: "a1", txns: [])], context: ctx), [])
    }
```

Append to `SyncCoordinatorTests` (uses the existing injectable init; adjust the access-URL plumbing to match the file's other tests):

```swift
    func testSyncReportsSupersededStillLinked() async throws {
        let container = AppSchema.makeInMemoryContainer()
        let ctx = container.mainContext
        let accessURL = URL(string: "https://user:pass@bridge.example/simplefin")!
        let dto = AccountDTO(id: "card", providerScope: "apple.example", org: "Apple", name: "Apple Card",
                             currency: "USD", balance: -5, availableBalance: nil,
                             balanceDate: Date(), transactions: [])
        let fk = Account(id: "financekit-X", org: "Apple", name: "Apple Card", currency: "USD",
                         balance: -5, balanceDate: Date())
        fk.source = .financeKit
        fk.supersededProviderID = SyncService.accountStorageID(providerScope: "apple.example", providerID: "card")
        ctx.insert(fk)
        try ctx.save()
        let coordinator = SyncCoordinator(
            context: ctx,
            loadAccessURL: { accessURL }, saveAccessURL: { _ in }, deleteAccessURL: {},
            claim: { _ in accessURL },
            fetch: { _, _ in SimpleFinResponse(errors: [], accounts: [dto]) }
        )

        await coordinator.sync()

        XCTAssertEqual(coordinator.supersededStillLinked, ["Apple Card"])
        coordinator.disconnect()
        XCTAssertEqual(coordinator.supersededStillLinked, [])
    }
```

- [ ] **Step 2: Run** `-only-testing:FinAppTests/SyncServiceTests -only-testing:FinAppTests/SyncCoordinatorTests` — expect FAIL (compile: `supersededNames`, `supersededStillLinked` missing).

- [ ] **Step 3: Implement**

In `SyncService.sync`, replace the two `!$0.isManual &&` filters with `$0.source == .simplefin &&`:

```swift
        var legacyAccounts = Dictionary(
            grouping: existingAccounts.filter { $0.source == .simplefin && $0.providerID == nil },
            by: \.id
        )
        ...
        let byProviderID = Dictionary(
            grouping: existingAccounts.filter { $0.source == .simplefin && $0.providerID != nil },
            by: { $0.providerID! }
        )
```

Before `for dto in dtos {` add:

```swift
        // Accounts merged into FinanceKit: SimpleFin keeps returning them until the
        // user unlinks them in Bridge. Skip so the merged row isn't duplicated.
        let supersededIDs = Set(existingAccounts.compactMap(\.supersededProviderID))
```

First line inside the loop, after computing `accountID`:

```swift
            if supersededIDs.contains(accountID) { continue }
```

Prune loop and its comment:

```swift
        // ... Only SimpleFin-sourced accounts are pruned: manual and FinanceKit
        // accounts never appear in the response.
        if pruneMissing {
            ...
            for account in existingAccounts where account.source == .simplefin && !dtoIDs.contains(account.id) {
```

Add below `transactionStorageID`:

```swift
    /// Display names of merged-into-FinanceKit accounts that SimpleFin still
    /// returns — i.e. the user hasn't unlinked them in Bridge yet.
    @MainActor
    static func supersededNames(in dtos: [AccountDTO], context: ModelContext) throws -> [String] {
        let incoming = Set(dtos.map { accountStorageID(providerScope: $0.providerScope, providerID: $0.id) })
        return try context.fetch(FetchDescriptor<Account>())
            .filter { $0.supersededProviderID.map(incoming.contains) ?? false }
            .map(\.displayName)
            .sorted()
    }
```

In `SyncCoordinator`:

```swift
    /// Merged-into-FinanceKit accounts SimpleFin still returns (unlink prompt).
    var supersededStillLinked: [String] = []
```

In `performSync`, after `providerErrors = response.errors`:

```swift
            supersededStillLinked = (try? SyncService.supersededNames(in: response.accounts, context: context)) ?? []
```

In `disconnect()`, add `supersededStillLinked = []`.

Extract derived staging from `persist`:

```swift
    static func persist(_ response: SimpleFinResponse, in context: ModelContext) throws {
        // Prune accounts removed from the connection only on a clean response —
        // a provider error can mean a bank's accounts are temporarily missing.
        try SyncService.sync(accounts: response.accounts,
                             pruneMissing: response.errors.isEmpty,
                             save: false, into: context)
        try stageDerivedData(in: context)
        try context.save()
    }

    /// Categorize, refresh recurring bills, and snapshot net worth (dashboard
    /// graph) and per-account balances (sparklines). Shared with FinanceKit import.
    static func stageDerivedData(in context: ModelContext) throws {
        let txns = try context.fetch(FetchDescriptor<Transaction>())
        try CategorizationEngine.stageCategorizeAll(txns, in: context)
        try RecurringDetector.stageRefresh(txns, in: context)
        let accounts = try context.fetch(FetchDescriptor<Account>())
        try NetWorthSnapshotService.stage(value: Analytics.netWorth(accounts), in: context)
        try AccountBalanceSnapshotService.stage(accounts, in: context)
    }
```

(Keep the existing doc comment above `persist`; `persist`/`stageDerivedData` stay `static`, inheriting the class's `@MainActor`.)

- [ ] **Step 4: Run** both test classes — expect PASS, including all pre-existing SyncService/SyncCoordinator tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/SimpleFin Tests/FinAppTests/SyncServiceTests.swift Tests/FinAppTests/SyncCoordinatorTests.swift
git commit -m "feat(sync): scope SimpleFin sync to its own accounts, skip superseded"
```

---

### Task 3: FinanceKit DTOs + importer

**Files:**
- Create: `Sources/FinApp/FinanceKit/FinanceKitDTO.swift`
- Create: `Sources/FinApp/FinanceKit/FinanceKitImporter.swift`
- Test: `Tests/FinAppTests/FinanceKitImporterTests.swift`

**Interfaces:**
- Consumes: `Account.source` (Task 1).
- Produces:

```swift
struct FKTransaction: Equatable, Sendable {
    enum Status: Sendable { case booked, pending, rejected, memo }
    let id: UUID; let posted: Date; let amount: Decimal; let detail: String
    let payee: String?; let status: Status
}
struct FKAccount: Equatable, Sendable {
    let id: UUID; let institutionName: String; let displayName: String; let currency: String
    let isLiability: Bool; let balance: Decimal; let availableBalance: Decimal?
    let balanceDate: Date; let transactions: [FKTransaction]
}
enum FinanceKitMapping { static func signed(_ amount: Decimal, isDebit: Bool) -> Decimal }
enum FinanceKitImporter {
    static func accountStorageID(_ id: UUID) -> String
    static func transactionStorageID(accountID: UUID, transactionID: UUID) -> String
    @MainActor static func stage(_ accounts: [FKAccount], into context: ModelContext) throws
}
```

- [ ] **Step 1: Write failing tests**

```swift
// Tests/FinAppTests/FinanceKitImporterTests.swift
import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class FinanceKitImporterTests: XCTestCase {
    private var ctx: ModelContext!
    private let cardID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let day = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUp() async throws {
        ctx = AppSchema.makeInMemoryContainer().mainContext
    }

    private func txn(_ n: Int, _ amount: String, status: FKTransaction.Status = .booked) -> FKTransaction {
        FKTransaction(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                      posted: day, amount: Decimal(string: amount)!, detail: "DESC \(n)",
                      payee: "Merchant \(n)", status: status)
    }

    private func card(balance: String = "-120.00", _ txns: [FKTransaction]) -> FKAccount {
        FKAccount(id: cardID, institutionName: "Apple", displayName: "Apple Card", currency: "USD",
                  isLiability: true, balance: Decimal(string: balance)!, availableBalance: 4880,
                  balanceDate: day, transactions: txns)
    }

    private func accounts() throws -> [Account] { try ctx.fetch(FetchDescriptor<Account>()) }
    private func txns() throws -> [Transaction] { try ctx.fetch(FetchDescriptor<Transaction>()) }

    func testSignedMapping() {
        XCTAssertEqual(FinanceKitMapping.signed(12, isDebit: true), -12)
        XCTAssertEqual(FinanceKitMapping.signed(12, isDebit: false), 12)
        XCTAssertEqual(FinanceKitMapping.signed(-12, isDebit: true), -12, "magnitude is used")
    }

    func testFirstImportInsertsAccountAndTransactions() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00"), txn(2, "25.00")])], into: ctx)

        let a = try XCTUnwrap(accounts().first)
        XCTAssertEqual(a.id, "financekit-\(cardID.uuidString)")
        XCTAssertEqual(a.source, .financeKit)
        XCTAssertEqual(a.providerID, cardID.uuidString)
        XCTAssertEqual(a.accountType, .creditCard)
        XCTAssertEqual(a.org, "Apple")
        XCTAssertEqual(a.balance, Decimal(string: "-120.00"))
        XCTAssertEqual(a.availableBalance, 4880)
        XCTAssertNotNil(a.lastSyncedAt)
        XCTAssertEqual(try txns().count, 2)
        XCTAssertEqual(Set(try txns().map(\.amount)), [Decimal(string: "-10.00")!, 25])
        XCTAssertEqual(try txns().first?.account?.id, a.id)
    }

    func testAssetAccountTypedCash() throws {
        let cash = FKAccount(id: UUID(), institutionName: "Apple", displayName: "Apple Cash", currency: "USD",
                             isLiability: false, balance: 40, availableBalance: nil, balanceDate: day, transactions: [])
        try FinanceKitImporter.stage([cash], into: ctx)
        XCTAssertEqual(try accounts().first?.accountType, .cash)
    }

    func testReimportIsIdempotentAndUpdatesInPlace() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00", status: .pending)])], into: ctx)
        let first = try XCTUnwrap(txns().first)

        try FinanceKitImporter.stage([card(balance: "-130.00", [txn(1, "-10.00", status: .booked)])], into: ctx)

        XCTAssertEqual(try accounts().count, 1)
        XCTAssertEqual(try txns().count, 1)
        XCTAssertTrue(try txns().first === first)
        XCTAssertFalse(first.pending)
        XCTAssertEqual(try accounts().first?.balance, Decimal(string: "-130.00"))
    }

    func testRejectedDeletesAndMemoSkipped() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00", status: .pending)])], into: ctx)
        try FinanceKitImporter.stage([card([txn(1, "-10.00", status: .rejected), txn(2, "-1.00", status: .memo)])], into: ctx)
        XCTAssertTrue(try txns().isEmpty)
    }

    func testUserEditsSurviveReimport() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00")])], into: ctx)
        let a = try XCTUnwrap(accounts().first)
        a.customName = "Card"; a.customSortIndex = 3; a.accountType = .loan
        let t = try XCTUnwrap(txns().first)
        t.note = "lunch"; t.categorizedByUser = true
        let cat = FinApp.Category(name: "Food", colorHex: "#FF0000", systemIcon: "fork.knife")
        ctx.insert(cat); t.category = cat

        try FinanceKitImporter.stage([card([txn(1, "-10.00")])], into: ctx)

        XCTAssertEqual(a.displayName, "Card")
        XCTAssertEqual(a.customSortIndex, 3)
        XCTAssertEqual(a.accountType, .loan)
        XCTAssertEqual(t.note, "lunch")
        XCTAssertTrue(t.category === cat)
    }

    func testPruneRemovesOnlyMissingFinanceKitAccounts() throws {
        try FinanceKitImporter.stage([card([txn(1, "-10.00")])], into: ctx)
        let simplefin = Account(id: "simplefin-account:x", org: "Bank", name: "Checking", currency: "USD",
                                balance: 1, balanceDate: day)
        let manual = Account(id: "manual-1", org: "Manual", name: "Cash", currency: "USD",
                             balance: 1, balanceDate: day, isManual: true)
        ctx.insert(simplefin); ctx.insert(manual)

        try FinanceKitImporter.stage([], into: ctx)

        XCTAssertEqual(Set(try accounts().map(\.id)), ["simplefin-account:x", "manual-1"])
        XCTAssertTrue(try txns().isEmpty, "cascade deleted")
    }
}
```

- [ ] **Step 2: `xcodegen generate`, run `-only-testing:FinAppTests/FinanceKitImporterTests`** — expect compile FAIL.

- [ ] **Step 3: Implement**

```swift
// Sources/FinApp/FinanceKit/FinanceKitDTO.swift
import Foundation

/// FinanceKit data mapped to plain values (amounts already signed per app
/// convention), so the importer and tests never touch FinanceKit types.
struct FKTransaction: Equatable, Sendable {
    enum Status: Sendable { case booked, pending, rejected, memo }
    let id: UUID
    let posted: Date
    let amount: Decimal
    let detail: String
    let payee: String?
    let status: Status
}

struct FKAccount: Equatable, Sendable {
    let id: UUID
    let institutionName: String
    let displayName: String
    let currency: String
    let isLiability: Bool
    let balance: Decimal
    let availableBalance: Decimal?
    let balanceDate: Date
    let transactions: [FKTransaction]
}

enum FinanceKitMapping {
    /// Debit = money out of the user's pocket (purchase, or balance owed on a
    /// card) → negative; credit → positive. Single place to flip if device
    /// testing shows FinanceKit reports card balances the other way.
    static func signed(_ amount: Decimal, isDebit: Bool) -> Decimal {
        isDebit ? -amount.magnitude : amount.magnitude
    }
}
```

```swift
// Sources/FinApp/FinanceKit/FinanceKitImporter.swift
import Foundation
import SwiftData

/// Upserts FinanceKit data into SwiftData. Pure persistence (no FinanceKit
/// import) so it is unit-tested with plain DTOs. Mirrors `SyncService`.
enum FinanceKitImporter {
    static func accountStorageID(_ id: UUID) -> String { "financekit-\(id.uuidString)" }

    static func transactionStorageID(accountID: UUID, transactionID: UUID) -> String {
        "financekit-\(accountID.uuidString)-\(transactionID.uuidString)"
    }

    /// Stages (no save) a complete FinanceKit fetch. Callers pass only a fetch
    /// that succeeded, so FinanceKit accounts absent from it were revoked or
    /// removed and are deleted (transactions cascade).
    @MainActor
    static func stage(_ dtos: [FKAccount], into context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<Account>())
        let accountsByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let txnsByID = Dictionary(
            try context.fetch(FetchDescriptor<Transaction>()).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        for dto in dtos {
            let account = upsertAccount(dto, existing: accountsByID[accountStorageID(dto.id)], in: context)
            for txDTO in dto.transactions {
                let id = transactionStorageID(accountID: dto.id, transactionID: txDTO.id)
                switch txDTO.status {
                case .memo:
                    continue
                case .rejected:
                    if let txn = txnsByID[id] { context.delete(txn) }
                case .booked, .pending:
                    upsertTransaction(txDTO, storageID: id, existing: txnsByID[id], account: account, in: context)
                }
            }
        }

        let incoming = Set(dtos.map { accountStorageID($0.id) })
        for account in existing where account.source == .financeKit && !incoming.contains(account.id) {
            context.delete(account)
        }
    }

    @MainActor
    private static func upsertAccount(_ dto: FKAccount, existing: Account?, in context: ModelContext) -> Account {
        let account = existing ?? {
            let a = Account(
                id: accountStorageID(dto.id), org: dto.institutionName, name: dto.displayName,
                currency: dto.currency, balance: dto.balance, balanceDate: dto.balanceDate,
                typeRaw: (dto.isLiability ? AccountType.creditCard : .cash).rawValue
            )
            a.source = .financeKit
            a.providerID = dto.id.uuidString
            context.insert(a)
            return a
        }()
        // Never written here: customName, customSortIndex, typeRaw (after insert).
        account.org = dto.institutionName
        account.name = dto.displayName
        account.currency = dto.currency
        account.balance = dto.balance
        account.availableBalance = dto.availableBalance
        account.balanceDate = dto.balanceDate
        account.lastSyncedAt = Date()
        return account
    }

    @MainActor
    private static func upsertTransaction(
        _ dto: FKTransaction, storageID: String, existing: Transaction?,
        account: Account, in context: ModelContext
    ) {
        // Never written here: note, category, categorizedByUser.
        let txn = existing ?? {
            let t = Transaction(id: storageID, posted: dto.posted, amount: dto.amount, detail: dto.detail)
            t.providerID = dto.id.uuidString
            context.insert(t)
            return t
        }()
        txn.posted = dto.posted
        txn.amount = dto.amount
        txn.detail = dto.detail
        txn.payee = dto.payee
        txn.pending = dto.status == .pending
        txn.account = account
    }
}
```

- [ ] **Step 4: Run tests — expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/FinanceKit Tests/FinAppTests/FinanceKitImporterTests.swift FinApp.xcodeproj
git commit -m "feat(financekit): add DTOs and SwiftData importer"
```

---

### Task 4: Merge — candidate detection, pairing, merge operation

**Files:**
- Create: `Sources/FinApp/FinanceKit/FinanceKitMerge.swift`
- Test: `Tests/FinAppTests/FinanceKitMergeTests.swift`

**Interfaces:**
- Consumes: `Account.source/supersededProviderID` (Task 1), `FinanceKitImporter` (Task 3, used in tests to set up FK rows).
- Produces:

```swift
enum FinanceKitMerge {
    static let minimumMatches = 3
    static let dayTolerance = 3
    struct Result: Equatable { let merged: Int; let removed: Int }
    static func pair(_ old: [Transaction], _ new: [Transaction], calendar: Calendar = .current)
        -> [(old: Transaction, new: Transaction)]
    static func candidate(for fk: Account, among accounts: [Account]) -> Account?
    @MainActor static func merge(_ fk: Account, into old: Account, in context: ModelContext) throws -> Result
}
```

- [ ] **Step 1: Write failing tests**

```swift
// Tests/FinAppTests/FinanceKitMergeTests.swift
import XCTest
import SwiftData
@testable import FinApp

@MainActor
final class FinanceKitMergeTests: XCTestCase {
    private var ctx: ModelContext!
    private let cal = Calendar(identifier: .gregorian)
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUp() async throws {
        ctx = AppSchema.makeInMemoryContainer().mainContext
    }

    private func d(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: base)! }

    /// SimpleFin-sourced account that has been through a scoped sync (providerID set).
    private func simplefin(_ id: String = "simplefin-account:old", _ txns: [(Int, String)]) -> Account {
        let a = Account(id: id, org: "Apple", name: "Apple Card (SF)", currency: "USD",
                        balance: -100, balanceDate: base, typeRaw: AccountType.creditCard.rawValue)
        a.providerID = "raw-\(id)"
        ctx.insert(a)
        for (i, (day, amount)) in txns.enumerated() {
            let t = Transaction(id: "\(id)-t\(i)", posted: d(day), amount: Decimal(string: amount)!,
                                detail: "SF \(i)", account: a)
            t.providerID = "sf\(i)"
            ctx.insert(t)
        }
        return a
    }

    /// FinanceKit account built via the real importer.
    private func financeKit(_ txns: [(Int, String)]) throws -> Account {
        let accountID = UUID()
        let dtos = txns.enumerated().map { i, t in
            FKTransaction(id: UUID(), posted: d(t.0), amount: Decimal(string: t.1)!,
                          detail: "FK \(i)", payee: "Merchant", status: .booked)
        }
        try FinanceKitImporter.stage([FKAccount(
            id: accountID, institutionName: "Apple", displayName: "Apple Card", currency: "USD",
            isLiability: true, balance: -100, availableBalance: nil, balanceDate: base, transactions: dtos
        )], into: ctx)
        return try XCTUnwrap(ctx.fetch(FetchDescriptor<Account>()).first { $0.id == FinanceKitImporter.accountStorageID(accountID) })
    }

    func testPairUsesEachOnceAndPrefersClosestDate() throws {
        let old = simplefin([(0, "-9.99"), (5, "-9.99"), (20, "-50.00")])
        let fk = try financeKit([(1, "-9.99"), (5, "-9.99"), (40, "-50.00")])

        let pairs = FinanceKitMerge.pair(old.transactions, fk.transactions, calendar: cal)

        XCTAssertEqual(pairs.count, 2, "-50 is 20 days apart → unmatched")
        let byOldDay = Dictionary(uniqueKeysWithValues: pairs.map { (cal.dateComponents([.day], from: base, to: $0.old.posted).day!, cal.dateComponents([.day], from: base, to: $0.new.posted).day!) })
        XCTAssertEqual(byOldDay, [0: 1, 5: 5])
    }

    func testCandidateRequiresThreeMatches() throws {
        let fk = try financeKit([(0, "-1"), (1, "-2"), (2, "-3")])
        let two = simplefin("simplefin-account:two", [(0, "-1"), (1, "-2")])
        XCTAssertNil(FinanceKitMerge.candidate(for: fk, among: [fk, two]))

        let three = simplefin("simplefin-account:three", [(0, "-1"), (1, "-2"), (3, "-3")])
        XCTAssertTrue(FinanceKitMerge.candidate(for: fk, among: [fk, two, three]) === three)
    }

    func testNoCandidateWhenAmbiguous() throws {
        let fk = try financeKit([(0, "-1"), (1, "-2"), (2, "-3")])
        let a = simplefin("simplefin-account:a", [(0, "-1"), (1, "-2"), (2, "-3")])
        let b = simplefin("simplefin-account:b", [(0, "-1"), (1, "-2"), (2, "-3")])
        XCTAssertNil(FinanceKitMerge.candidate(for: fk, among: [fk, a, b]))
    }

    func testLegacyAndNonSimplefinRowsAreNeverCandidates() throws {
        let fk = try financeKit([(0, "-1"), (1, "-2"), (2, "-3")])
        let legacy = simplefin("legacy-raw-id", [(0, "-1"), (1, "-2"), (2, "-3")])
        legacy.providerID = nil
        XCTAssertNil(FinanceKitMerge.candidate(for: fk, among: [fk, legacy]))

        let manual = simplefin("manual-x", [(0, "-1"), (1, "-2"), (2, "-3")])
        manual.source = .manual
        XCTAssertNil(FinanceKitMerge.candidate(for: fk, among: [fk, manual]))
    }

    func testMergeRekeysPreservesEditsAndPrunesDuplicates() throws {
        // old: 3 matching, 1 pre-range (day -30), 1 in-range unmatched, 1 in-range unmatched but edited
        let old = simplefin([(0, "-1"), (1, "-2"), (2, "-3"), (-30, "-7"), (1, "-8"), (2, "-9")])
        old.customName = "My Card"
        let sorted = old.transactions.sorted { $0.id < $1.id }
        sorted[0].note = "kept note"            // matched
        sorted[5].categorizedByUser = true       // in-range unmatched, edited → kept
        ctx.insert(AccountBalanceSnapshot(accountId: old.id, day: d(-1), balance: -90))
        let fk = try financeKit([(0, "-1"), (1, "-2"), (2, "-3"), (3, "-4")])
        let fkID = fk.id
        ctx.insert(AccountBalanceSnapshot(accountId: fkID, day: d(0), balance: -100))
        let oldID = old.id
        try ctx.save()

        let result = try FinanceKitMerge.merge(fk, into: old, in: ctx)

        XCTAssertEqual(result, .init(merged: 3, removed: 1))
        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.count, 1)
        let merged = try XCTUnwrap(accounts.first)
        XCTAssertTrue(merged === old, "same row survives")
        XCTAssertEqual(merged.id, fkID)
        XCTAssertEqual(merged.source, .financeKit)
        XCTAssertEqual(merged.supersededProviderID, oldID)
        XCTAssertEqual(merged.displayName, "My Card")
        XCTAssertNil(merged.providerScope)

        let txns = try ctx.fetch(FetchDescriptor<Transaction>())
        // 3 matched (rekeyed) + 1 FK-only + 1 pre-range + 1 edited = 6; "-8" removed
        XCTAssertEqual(txns.count, 6)
        XCTAssertFalse(txns.contains { $0.amount == -8 })
        XCTAssertTrue(txns.allSatisfy { $0.account === merged })
        let noted = try XCTUnwrap(txns.first { $0.note == "kept note" })
        XCTAssertTrue(noted.id.hasPrefix(fkID), "matched txn rekeyed to FinanceKit id")
        XCTAssertEqual(noted.detail, "FK 0", "bank fields come from FinanceKit")

        let snaps = try ctx.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        XCTAssertEqual(snaps.map(\.accountId), [fkID])
        XCTAssertEqual(snaps.first?.balance, -90, "old history kept, FK's temp snapshot dropped")
    }
}
```

- [ ] **Step 2: `xcodegen generate`, run `-only-testing:FinAppTests/FinanceKitMergeTests`** — expect compile FAIL.

- [ ] **Step 3: Implement**

```swift
// Sources/FinApp/FinanceKit/FinanceKitMerge.swift
import Foundation
import SwiftData

/// Folds a SimpleFin account (e.g. Apple Card via an aggregator) into the
/// FinanceKit account for the same card, keeping the row, rename, balance
/// history, and the user's notes/categories.
enum FinanceKitMerge {
    static let minimumMatches = 3
    /// Pending vs posted dates often differ by a day or two between sources.
    static let dayTolerance = 3

    struct Result: Equatable {
        let merged: Int
        let removed: Int
    }

    /// Equal-amount pairs within `dayTolerance`, closest dates first, each
    /// transaction used at most once.
    static func pair(
        _ old: [Transaction], _ new: [Transaction], calendar: Calendar = .current
    ) -> [(old: Transaction, new: Transaction)] {
        var candidates: [(old: Transaction, new: Transaction, distance: Int)] = []
        let newByAmount = Dictionary(grouping: new, by: \.amount)
        for o in old {
            for n in newByAmount[o.amount] ?? [] {
                let distance = abs(calendar.dateComponents(
                    [.day], from: calendar.startOfDay(for: o.posted), to: calendar.startOfDay(for: n.posted)
                ).day ?? .max)
                if distance <= dayTolerance { candidates.append((o, n, distance)) }
            }
        }
        candidates.sort { ($0.distance, $0.old.id, $0.new.id) < ($1.distance, $1.old.id, $1.new.id) }
        var usedOld = Set<PersistentIdentifier>(), usedNew = Set<PersistentIdentifier>()
        var pairs: [(old: Transaction, new: Transaction)] = []
        for c in candidates
            where !usedOld.contains(c.old.persistentModelID) && !usedNew.contains(c.new.persistentModelID) {
            usedOld.insert(c.old.persistentModelID)
            usedNew.insert(c.new.persistentModelID)
            pairs.append((c.old, c.new))
        }
        return pairs
    }

    /// The single SimpleFin account whose history overlaps `fk`, or nil if none
    /// or several. Rows without a scoped `providerID` (pre-migration legacy ids)
    /// are excluded: their id would never match what SimpleFin sync computes,
    /// so the superseded-skip would miss and the account would be re-created.
    static func candidate(for fk: Account, among accounts: [Account]) -> Account? {
        let matches = accounts.filter {
            $0.source == .simplefin && $0.providerID != nil
                && pair($0.transactions, fk.transactions).count >= minimumMatches
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Two saves: unique ids can't be handed from a deleted row to a live one
    /// within one save, so deletions/moves land first, then the rekey.
    @MainActor
    static func merge(_ fk: Account, into old: Account, in context: ModelContext) throws -> Result {
        let fkID = fk.id
        let oldID = old.id
        let pairs = pair(old.transactions, fk.transactions)
        let matchedOld = Set(pairs.map { $0.old.persistentModelID })
        let earliestFK = fk.transactions.map(\.posted).min()

        // Phase 1: drop duplicates, move FK-only rows, capture rekey data.
        struct Rekey { let txn: Transaction; let id: String; let providerID: String?
                       let posted: Date; let amount: Decimal; let detail: String
                       let payee: String?; let pending: Bool }
        var rekeys: [Rekey] = []
        for (o, n) in pairs {
            rekeys.append(Rekey(txn: o, id: n.id, providerID: n.providerID, posted: n.posted,
                                amount: n.amount, detail: n.detail, payee: n.payee, pending: n.pending))
            context.delete(n)
        }
        let matchedNew = Set(pairs.map { $0.new.persistentModelID })
        for n in fk.transactions where !matchedNew.contains(n.persistentModelID) {
            n.account = old
        }
        var removed = 0
        // Unmatched SimpleFin rows inside FinanceKit's range are duplicates FinanceKit
        // reports differently — drop them unless the user edited them. FK rows just
        // moved onto `old` may already appear here; their id prefix excludes them.
        for o in old.transactions
            where !matchedOld.contains(o.persistentModelID) && !o.id.hasPrefix("financekit-") {
            guard let earliestFK, o.posted >= earliestFK,
                  !o.categorizedByUser, o.note == nil else { continue }
            context.delete(o)
            removed += 1
        }
        let snapshots = try context.fetch(FetchDescriptor<AccountBalanceSnapshot>())
        for s in snapshots where s.accountId == fkID { context.delete(s) }
        let fields = (providerID: fk.providerID, org: fk.org, name: fk.name, currency: fk.currency,
                      balance: fk.balance, available: fk.availableBalance, date: fk.balanceDate)
        context.delete(fk)
        try context.save()

        // Phase 2: rekey the surviving row and its matched transactions.
        old.supersededProviderID = oldID
        old.id = fkID
        old.source = .financeKit
        old.providerID = fields.providerID
        old.providerScope = nil
        old.org = fields.org
        old.name = fields.name
        old.currency = fields.currency
        old.balance = fields.balance
        old.availableBalance = fields.available
        old.balanceDate = fields.date
        old.lastSyncedAt = Date()
        for r in rekeys {
            r.txn.id = r.id
            r.txn.providerID = r.providerID
            r.txn.posted = r.posted
            r.txn.amount = r.amount
            r.txn.detail = r.detail
            r.txn.payee = r.payee
            r.txn.memo = nil
            r.txn.pending = r.pending
        }
        for s in snapshots where s.accountId == oldID { s.accountId = fkID }
        try context.save()
        return Result(merged: pairs.count, removed: removed)
    }
}
```

- [ ] **Step 4: Run tests — expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/FinanceKit/FinanceKitMerge.swift Tests/FinAppTests/FinanceKitMergeTests.swift FinApp.xcodeproj
git commit -m "feat(financekit): merge SimpleFin account into FinanceKit account"
```

---

### Task 5: `FinanceKitCoordinator` + `FinanceKitSource` seam

**Files:**
- Create: `Sources/FinApp/FinanceKit/FinanceKitCoordinator.swift`
- Test: `Tests/FinAppTests/FinanceKitCoordinatorTests.swift`

**Interfaces:**
- Consumes: `FinanceKitImporter.stage` (T3), `FinanceKitMerge` (T4), `SyncCoordinator.stageDerivedData`, `initialLookbackDays`, `resyncOverlapDays` (T2).
- Produces:

```swift
enum FKAuthorization: Sendable { case notDetermined, authorized, denied }
protocol FinanceKitSource: Sendable {
    func isAvailable() -> Bool
    func authorizationStatus() async throws -> FKAuthorization
    func requestAuthorization() async throws -> FKAuthorization
    func fetch(since: Date) async throws -> [FKAccount]
}
struct UnavailableFinanceKitSource: FinanceKitSource   // flag off / old iOS
struct MergeProposal: Equatable, Identifiable { let financeKitAccountID: String; let simplefinAccountID: String
                                  let financeKitName: String; let simplefinName: String
                                  var id: String { financeKitAccountID } }
@MainActor @Observable final class FinanceKitCoordinator {
    let isAvailable: Bool
    private(set) var authorization: FKAuthorization
    private(set) var isImporting: Bool
    var errorMessage: String?
    var pendingMerge: MergeProposal?
    var lastMergeResult: FinanceKitMerge.Result?
    var lastImportDate: Date?
    init(source: any FinanceKitSource, context: ModelContext, now: @escaping () -> Date = Date.init)
    func refreshAuthorization() async
    func connect() async
    func importIfStale(minInterval: TimeInterval = 300) async
    func importNow() async
    func confirmMerge()
    func declineMerge()
}
```

- [ ] **Step 1: Write failing tests**

```swift
// Tests/FinAppTests/FinanceKitCoordinatorTests.swift
import XCTest
import SwiftData
@testable import FinApp

final class FakeFinanceKitSource: FinanceKitSource, @unchecked Sendable {
    var available = true
    var status: FKAuthorization = .authorized
    var requestResult: FKAuthorization = .authorized
    var result: Result<[FKAccount], Error> = .success([])
    var fetchCount = 0
    var lastSince: Date?
    func isAvailable() -> Bool { available }
    func authorizationStatus() async throws -> FKAuthorization { status }
    func requestAuthorization() async throws -> FKAuthorization { status = requestResult; return requestResult }
    func fetch(since: Date) async throws -> [FKAccount] { fetchCount += 1; lastSince = since; return try result.get() }
}

@MainActor
final class FinanceKitCoordinatorTests: XCTestCase {
    private var ctx: ModelContext!
    private var source: FakeFinanceKitSource!
    private var clock = Date(timeIntervalSince1970: 1_760_000_000)
    private let cardID = UUID()

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "financeKitLastImportDate")
        UserDefaults.standard.removeObject(forKey: "financeKitMergeDeclined")
        ctx = AppSchema.makeInMemoryContainer().mainContext
        source = FakeFinanceKitSource()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "financeKitLastImportDate")
        UserDefaults.standard.removeObject(forKey: "financeKitMergeDeclined")
    }

    private func make() -> FinanceKitCoordinator {
        FinanceKitCoordinator(source: source, context: ctx, now: { [unowned self] in clock })
    }

    private func card(_ amounts: [String]) -> FKAccount {
        FKAccount(id: cardID, institutionName: "Apple", displayName: "Apple Card", currency: "USD",
                  isLiability: true, balance: -10, availableBalance: nil, balanceDate: clock,
                  transactions: amounts.enumerated().map { i, a in
                      FKTransaction(id: UUID(), posted: clock.addingTimeInterval(Double(-i) * 86_400),
                                    amount: Decimal(string: a)!, detail: "FK", payee: nil, status: .booked)
                  })
    }

    func testFirstImportLooksBack120DaysThenOverlap() async {
        let c = make()
        await c.importNow()
        XCTAssertEqual(source.lastSince, Calendar.current.date(byAdding: .day, value: -120, to: clock))
        XCTAssertEqual(c.lastImportDate, clock)

        clock = clock.addingTimeInterval(10 * 86_400)
        await c.importNow()
        XCTAssertEqual(source.lastSince, Calendar.current.date(byAdding: .day, value: -15, to: clock))
    }

    func testImportIfStaleDebounces() async {
        let c = make()
        await c.importIfStale()
        clock = clock.addingTimeInterval(60)
        await c.importIfStale()
        XCTAssertEqual(source.fetchCount, 1)
        clock = clock.addingTimeInterval(300)
        await c.importIfStale()
        XCTAssertEqual(source.fetchCount, 2)
    }

    func testImportSkippedWhenNotAuthorized() async {
        source.status = .denied
        let c = make()
        await c.refreshAuthorization()
        await c.importIfStale()
        XCTAssertEqual(c.authorization, .denied)
        XCTAssertEqual(source.fetchCount, 0)
    }

    func testFetchErrorSurfacesAndChangesNothing() async throws {
        let simplefin = Account(id: "simplefin-account:x", org: "Bank", name: "Checking",
                                currency: "USD", balance: 5, balanceDate: clock)
        ctx.insert(simplefin)
        try ctx.save()
        source.result = .failure(URLError(.notConnectedToInternet))
        let c = make()

        await c.importNow()

        XCTAssertNotNil(c.errorMessage)
        XCTAssertNil(c.lastImportDate)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).map(\.id), ["simplefin-account:x"])
    }

    func testConnectRequestsAuthorizationThenImports() async throws {
        source.status = .notDetermined
        source.result = .success([card(["-1"])])
        let c = make()
        await c.connect()
        XCTAssertEqual(c.authorization, .authorized)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
    }

    private func seedSimplefinOverlap() throws -> Account {
        let sf = Account(id: "simplefin-account:card", org: "Apple", name: "Apple Card (SF)",
                         currency: "USD", balance: -10, balanceDate: clock)
        sf.providerID = "card"
        ctx.insert(sf)
        for (i, a) in ["-1", "-2", "-3"].enumerated() {
            ctx.insert(Transaction(id: "sf\(i)", posted: clock.addingTimeInterval(Double(-i) * 86_400),
                                   amount: Decimal(string: a)!, detail: "SF", account: sf))
        }
        try ctx.save()
        return sf
    }

    func testOverlapProposesMergeAndConfirmMerges() async throws {
        let sf = try seedSimplefinOverlap()
        source.result = .success([card(["-1", "-2", "-3"])])
        let c = make()

        await c.importNow()

        let proposal = try XCTUnwrap(c.pendingMerge)
        XCTAssertEqual(proposal.simplefinAccountID, "simplefin-account:card")
        c.confirmMerge()
        XCTAssertNil(c.pendingMerge)
        XCTAssertEqual(c.lastMergeResult, .init(merged: 3, removed: 0))
        XCTAssertEqual(sf.source, .financeKit)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 1)
    }

    func testDeclinedMergeIsNotReproposed() async throws {
        _ = try seedSimplefinOverlap()
        source.result = .success([card(["-1", "-2", "-3"])])
        let c = make()
        await c.importNow()
        c.declineMerge()
        XCTAssertNil(c.pendingMerge)

        await c.importNow()
        XCTAssertNil(c.pendingMerge)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Account>()).count, 2)
    }

    func testUnavailableSourceReportsUnavailable() {
        source.available = false
        XCTAssertFalse(make().isAvailable)
        XCTAssertFalse(FinanceKitCoordinator(source: UnavailableFinanceKitSource(), context: ctx).isAvailable)
    }
}
```

- [ ] **Step 2: `xcodegen generate`, run `-only-testing:FinAppTests/FinanceKitCoordinatorTests`** — expect compile FAIL.

- [ ] **Step 3: Implement**

```swift
// Sources/FinApp/FinanceKit/FinanceKitCoordinator.swift
import Foundation
import SwiftData
import Observation

enum FKAuthorization: Sendable { case notDetermined, authorized, denied }

/// Seam over `FinanceStore` so the coordinator is testable without FinanceKit
/// (which the Simulator doesn't support). Live impl: `LiveFinanceKitSource`.
protocol FinanceKitSource: Sendable {
    func isAvailable() -> Bool
    func authorizationStatus() async throws -> FKAuthorization
    func requestAuthorization() async throws -> FKAuthorization
    /// Accounts + balances + transactions on or after `since`.
    func fetch(since: Date) async throws -> [FKAccount]
}

/// Used when the FINANCEKIT flag is off or iOS < 17.4: hides the feature.
struct UnavailableFinanceKitSource: FinanceKitSource {
    func isAvailable() -> Bool { false }
    func authorizationStatus() async throws -> FKAuthorization { .denied }
    func requestAuthorization() async throws -> FKAuthorization { .denied }
    func fetch(since: Date) async throws -> [FKAccount] { [] }
}

struct MergeProposal: Equatable, Identifiable {
    let financeKitAccountID: String
    let simplefinAccountID: String
    let financeKitName: String
    let simplefinName: String
    var id: String { financeKitAccountID }
}

/// Orchestrates FinanceKit authorization + import (Apple Card/Cash/Savings).
/// UI-facing observable state; mirrors `SyncCoordinator`.
@MainActor
@Observable
final class FinanceKitCoordinator {
    static let minImportInterval: TimeInterval = 300
    private static let lastImportKey = "financeKitLastImportDate"
    private static let declinedKey = "financeKitMergeDeclined"

    private let source: any FinanceKitSource
    private let context: ModelContext
    private let now: () -> Date
    private var lastAttempt: Date?

    let isAvailable: Bool
    private(set) var authorization: FKAuthorization = .notDetermined
    private(set) var isImporting = false
    var errorMessage: String?
    var pendingMerge: MergeProposal?
    var lastMergeResult: FinanceKitMerge.Result?

    var lastImportDate: Date? {
        get { UserDefaults.standard.object(forKey: Self.lastImportKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastImportKey) }
    }

    private var declined: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.declinedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.declinedKey) }
    }

    init(source: any FinanceKitSource, context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.context = context
        self.now = now
        self.isAvailable = source.isAvailable()
    }

    func refreshAuthorization() async {
        guard isAvailable else { return }
        authorization = (try? await source.authorizationStatus()) ?? .notDetermined
    }

    /// Shows the system account picker, then imports what the user granted.
    func connect() async {
        guard isAvailable else { return }
        do {
            authorization = try await source.requestAuthorization()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        await importNow()
    }

    /// On-device data, so no server throttle — just debounce rapid foregrounds.
    func importIfStale(minInterval: TimeInterval = FinanceKitCoordinator.minImportInterval) async {
        if let lastAttempt, now().timeIntervalSince(lastAttempt) < minInterval { return }
        await refreshAuthorization()
        guard authorization == .authorized else { return }
        await importNow()
    }

    func importNow() async {
        guard isAvailable, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        lastAttempt = now()
        errorMessage = nil
        do {
            let accounts = try await source.fetch(since: fetchStart())
            do {
                try FinanceKitImporter.stage(accounts, into: context)
                try SyncCoordinator.stageDerivedData(in: context)
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            lastImportDate = now()
            proposeMergeIfNeeded()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func confirmMerge() {
        guard let proposal = pendingMerge else { return }
        pendingMerge = nil
        guard let all = try? context.fetch(FetchDescriptor<Account>()),
              let fk = all.first(where: { $0.id == proposal.financeKitAccountID }),
              let old = all.first(where: { $0.id == proposal.simplefinAccountID }) else { return }
        do {
            lastMergeResult = try FinanceKitMerge.merge(fk, into: old, in: context)
            try SyncCoordinator.stageDerivedData(in: context)
            try context.save()
        } catch {
            context.rollback()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func declineMerge() {
        guard let proposal = pendingMerge else { return }
        declined.insert(proposal.financeKitAccountID)
        pendingMerge = nil
    }

    /// Checked after every import (not just first insert) so an unanswered
    /// prompt — app killed mid-sheet — comes back next time.
    private func proposeMergeIfNeeded() {
        guard pendingMerge == nil, let all = try? context.fetch(FetchDescriptor<Account>()) else { return }
        let declined = declined
        for fk in all where fk.source == .financeKit && fk.supersededProviderID == nil
            && !declined.contains(fk.id) {
            if let old = FinanceKitMerge.candidate(for: fk, among: all) {
                pendingMerge = MergeProposal(financeKitAccountID: fk.id, simplefinAccountID: old.id,
                                             financeKitName: fk.displayName, simplefinName: old.displayName)
                return
            }
        }
    }

    private func fetchStart() -> Date {
        let days: Int
        if let last = lastImportDate {
            let elapsed = Calendar.current.dateComponents([.day], from: last, to: now()).day ?? 0
            days = elapsed + SyncCoordinator.resyncOverlapDays
        } else {
            days = SyncCoordinator.initialLookbackDays
        }
        return Calendar.current.date(byAdding: .day, value: -days, to: now()) ?? now()
    }
}
```

- [ ] **Step 4: Run tests — expect PASS.** Then run the full unit suite: `-only-testing:FinAppTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/FinanceKit/FinanceKitCoordinator.swift Tests/FinAppTests/FinanceKitCoordinatorTests.swift FinApp.xcodeproj
git commit -m "feat(financekit): add import coordinator with merge proposals"
```

---

### Task 6: Live FinanceKit client + build flag + entitlement + Info.plist key

**Files:**
- Create: `Sources/FinApp/FinanceKit/FinanceKitClient.swift`
- Create: `FinApp-FinanceKit.entitlements`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `FinanceKitSource`, `FKAccount`, `FKTransaction`, `FinanceKitMapping`, `FKAuthorization`.
- Produces: `LiveFinanceKitSource` (only under `#if FINANCEKIT`), `FinanceKitSources.make() -> any FinanceKitSource`.

No unit tests (FinanceKit doesn't run in the Simulator); verification = both flag states compile.

- [ ] **Step 1: Write the client**

```swift
// Sources/FinApp/FinanceKit/FinanceKitClient.swift
import Foundation
#if FINANCEKIT
import FinanceKit
#endif

enum FinanceKitSources {
    /// Live store when compiled with FINANCEKIT on iOS 17.4+; otherwise a
    /// source that reports unavailable so the UI stays hidden.
    static func make() -> any FinanceKitSource {
        #if FINANCEKIT
        if #available(iOS 17.4, *) { return LiveFinanceKitSource() }
        #endif
        return UnavailableFinanceKitSource()
    }
}

#if FINANCEKIT
@available(iOS 17.4, *)
struct LiveFinanceKitSource: FinanceKitSource {
    private var store: FinanceStore { .shared }

    func isAvailable() -> Bool { FinanceStore.isDataAvailable(.financialData) }

    func authorizationStatus() async throws -> FKAuthorization { mapStatus(try await store.authorizationStatus()) }

    func requestAuthorization() async throws -> FKAuthorization { mapStatus(try await store.requestAuthorization()) }

    func fetch(since: Date) async throws -> [FKAccount] {
        let accounts = try await store.accounts(query: AccountQuery())
        let balances = try await store.accountBalances(query: AccountBalanceQuery())
        let latest = Dictionary(grouping: balances, by: \.accountID).compactMapValues { group in
            group.max { asOf($0) < asOf($1) }
        }
        let txns = try await store.transactions(query: TransactionQuery(
            predicate: #Predicate<FinanceKit.Transaction> { $0.transactionDate >= since }
        ))
        let txnsByAccount = Dictionary(grouping: txns, by: \.accountID)

        return accounts.map { account in
            let isLiability: Bool
            switch account {
            case .liability: isLiability = true
            case .asset: isLiability = false
            @unknown default: isLiability = false
            }
            let (booked, available) = latest[account.id].map(amounts) ?? (nil, nil)
            return FKAccount(
                id: account.id, institutionName: account.institutionName,
                displayName: account.displayName, currency: account.currencyCode,
                isLiability: isLiability, balance: booked ?? available ?? 0,
                availableBalance: available,
                balanceDate: latest[account.id].map(asOf) ?? Date(),
                transactions: (txnsByAccount[account.id] ?? []).map(mapTransaction)
            )
        }
    }

    private func mapStatus(_ status: AuthorizationStatus) -> FKAuthorization {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .denied
        }
    }

    private func mapTransaction(_ t: FinanceKit.Transaction) -> FKTransaction {
        let status: FKTransaction.Status
        switch t.status {
        case .booked: status = .booked
        case .pending, .authorized: status = .pending
        case .rejected: status = .rejected
        case .memo: status = .memo
        @unknown default: status = .memo
        }
        return FKTransaction(
            id: t.id, posted: t.postedDate ?? t.transactionDate,
            amount: FinanceKitMapping.signed(t.transactionAmount.amount, isDebit: t.creditDebitIndicator == .debit),
            detail: t.transactionDescription, payee: t.merchantName, status: status
        )
    }

    private func signed(_ b: Balance) -> Decimal {
        FinanceKitMapping.signed(b.amount.amount, isDebit: b.creditDebitIndicator == .debit)
    }

    /// (booked, available), each signed.
    private func amounts(_ balance: AccountBalance) -> (Decimal?, Decimal?) {
        switch balance.currentBalance {
        case .booked(let b): (signed(b), nil)
        case .available(let a): (nil, signed(a))
        case .availableAndBooked(let a, let b): (signed(b), signed(a))
        @unknown default: (nil, nil)
        }
    }

    private func asOf(_ balance: AccountBalance) -> Date {
        switch balance.currentBalance {
        case .booked(let b), .available(let b): b.asOfDate
        case .availableAndBooked(_, let b): b.asOfDate
        @unknown default: .distantPast
        }
    }
}
#endif
```

- [ ] **Step 2: Entitlements file** — copy of `FinApp.entitlements` plus FinanceKit:

```xml
<!-- FinApp-FinanceKit.entitlements -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.default-data-protection</key>
	<string>NSFileProtectionComplete</string>
	<key>com.apple.developer.financekit</key>
	<array>
		<string>financial-data</string>
	</array>
</dict>
</plist>
```

> Before enabling (post-approval), confirm the entitlement value Apple's portal shows for the managed capability and match it here.

- [ ] **Step 3: `project.yml`** — in `targets.FinApp.settings.base`, add the usage string and a commented flag block directly under `CODE_SIGN_ENTITLEMENTS`:

```yaml
        CODE_SIGN_ENTITLEMENTS: FinApp.entitlements
        # FinanceKit (Apple Card/Cash/Savings). Enable ONLY after Apple grants the
        # managed entitlement (AppStore/financekit-entitlement-request.md):
        # change the line above to FinApp-FinanceKit.entitlements and uncomment:
        # SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) FINANCEKIT"
        INFOPLIST_KEY_NSFinancialDataUsageDescription: "FinApp reads your Apple Card, Apple Cash, and Savings activity to show it alongside your other accounts. It stays on this iPhone."
```

- [ ] **Step 4: Verify both flag states compile**

Run: `xcodegen generate && xcodebuild build -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: BUILD SUCCEEDED (flag off).

Run: `xcodebuild build -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG FINANCEKIT'`
Expected: BUILD SUCCEEDED (flag on; simulator builds don't need the provisioning profile). Fix any API-shape mismatch against `FinanceKit.swiftinterface` (path: `$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/FinanceKit.framework/Modules/FinanceKit.swiftmodule/arm64e-apple-ios.swiftinterface`).

- [ ] **Step 5: Commit**

```bash
git add Sources/FinApp/FinanceKit/FinanceKitClient.swift FinApp-FinanceKit.entitlements project.yml FinApp.xcodeproj
git commit -m "feat(financekit): add live FinanceKit client behind FINANCEKIT flag"
```

---

### Task 7: UI — wiring, Settings section, merge sheet, unlink banner, row tag

**Files:**
- Modify: `Sources/FinApp/App/FinAppApp.swift` (create + inject coordinator, foreground trigger)
- Modify: `Sources/FinApp/App/RootView.swift` (launch trigger, merge sheet, preview env)
- Modify: `Sources/FinApp/Features/Settings/SettingsView.swift` (Apple Wallet card; Sync now also imports)
- Modify: `Sources/FinApp/Features/Accounts/AccountsView.swift` (unlink banner, meta line)
- Create: `Sources/FinApp/FinanceKit/FinanceKitMergeSheet.swift`
- Test: `Tests/FinAppUITests/FinAppUITests.swift`

**Interfaces:**
- Consumes: `FinanceKitCoordinator` (T5), `FinanceKitSources.make()` (T6), `SyncCoordinator.supersededStillLinked` (T2).

- [ ] **Step 1: Write the failing UI test** (append to `FinAppUITests`)

```swift
    func testAppleWalletSectionHiddenWhenUnavailable() {
        let app = launch(tab: 4)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["appleWalletCard"].exists)
        XCTAssertFalse(app.staticTexts["Apple Wallet"].exists)
    }

    func testUnlinkBannerHiddenWithoutSupersededAccounts() {
        let app = launch(tab: 0)
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["unlinkBridgeBanner"].exists)
    }
```

These pass trivially today — they guard that the new UI stays hidden in the default build (Simulator → unavailable). Run to confirm the harness works: `-only-testing:FinAppUITests/FinAppUITests/testAppleWalletSectionHiddenWhenUnavailable`.

- [ ] **Step 2: Wire the coordinator in `FinAppApp`**

Add state: `@State private var financeKit: FinanceKitCoordinator`.
In both `#if DEBUG` and `#else` branches, after `_coordinator = ...`:

```swift
        _financeKit = State(initialValue: FinanceKitCoordinator(
            source: isUITest ? UnavailableFinanceKitSource() : FinanceKitSources.make(),
            context: container.mainContext))
```

(`#else` branch: `source: FinanceKitSources.make()`.)

Inject: `RootView().environment(coordinator).environment(financeKit).environment(lock)`.

In `.onChange(of: scenePhase)`, replace the `.active` branch:

```swift
            } else if phase == .active {
                // Only resync on foreground if it's been over an hour since the last
                // successful sync, instead of hitting SimpleFin on every open.
                if coordinator.isConnected { Task { await coordinator.syncIfStale() } }
                Task { await financeKit.importIfStale() }
            }
```

- [ ] **Step 3: `RootView`** — add `@Environment(FinanceKitCoordinator.self) private var financeKit`. In `.task`:

```swift
            if coordinator.isConnected { await coordinator.syncIfStale() }
            await financeKit.importIfStale()
```

Add after `.fullScreenCover(...)`:

```swift
        .sheet(item: Binding(
            get: { financeKit.pendingMerge },
            set: { if $0 == nil { financeKit.declineMerge() } }
        )) { proposal in
            FinanceKitMergeSheet(proposal: proposal)
                .environment(financeKit)
        }
```

> Swiping the sheet away counts as "Keep separate" (spec: decline is remembered). The sheet's buttons call `confirmMerge()`/`declineMerge()` which nil `pendingMerge` first, so the binding setter's decline is a no-op for them.

Preview: add `.environment(FinanceKitCoordinator(source: UnavailableFinanceKitSource(), context: container.mainContext))`.

- [ ] **Step 4: Merge sheet**

```swift
// Sources/FinApp/FinanceKit/FinanceKitMergeSheet.swift
import SwiftUI

/// Asks before folding the SimpleFin copy of an Apple account into FinanceKit.
struct FinanceKitMergeSheet: View {
    @Environment(FinanceKitCoordinator.self) private var financeKit
    let proposal: MergeProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge accounts?")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("**\(proposal.simplefinName)** (SimpleFin) looks like the same account as **\(proposal.financeKitName)** (Apple Wallet). Merging keeps your history, rename, categories, and notes, and removes duplicate transactions.")
                .font(.system(size: 14))
                .foregroundStyle(Color.textSecondary)
            Button {
                financeKit.confirmMerge()
            } label: {
                Text("Merge")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appBackground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mergeConfirmButton")
            Button("Keep separate") { financeKit.declineMerge() }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("mergeDeclineButton")
        }
        .padding(24)
        .presentationDetents([.medium])
        .background(Color.appBackground)
    }
}
```

- [ ] **Step 5: Settings "Apple Wallet" card**

In `SettingsView`: add `@Environment(FinanceKitCoordinator.self) private var financeKit`. In `body`'s VStack after `noticeCards`:

```swift
                    if financeKit.isAvailable {
                        SectionLabel("Apple Wallet").padding(.horizontal, 4)
                        appleWalletCard
                    }
```

Add `.task { await financeKit.refreshAuthorization() }` on the ScrollView. Make the "Sync now" button also import:

```swift
                Task {
                    await coordinator.sync()
                    await financeKit.importNow()
                }
```

Add (next to `connectionCard`), reusing `tintedCard`:

```swift
    // MARK: Apple Wallet (FinanceKit)

    @ViewBuilder
    private var appleWalletCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch financeKit.authorization {
            case .notDetermined:
                Text("Import Apple Card, Apple Cash, and Savings directly from this iPhone — no bank login or reconnecting.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
                Button {
                    Task { await financeKit.connect() }
                } label: {
                    Text("Connect Apple Wallet")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.appBackground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("connectAppleWalletButton")
            case .authorized:
                Text(appleWalletMeta)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary)
                Text("Manage shared accounts in Settings → Privacy & Security → Wallet.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
            case .denied:
                Text("Apple Wallet access is off. Turn it on in Settings → Privacy & Security → Wallet. Imported accounts keep their last data.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textSecondary)
            }
            if let result = financeKit.lastMergeResult {
                tintedCard("Merged \(result.merged) transactions, removed \(result.removed) duplicates.",
                           icon: "checkmark.circle", tint: .brand)
            }
            if let error = financeKit.errorMessage {
                tintedCard(error, icon: "xmark.octagon", tint: .negative)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appleWalletCard")
    }

    private var appleWalletMeta: String {
        let count = accounts.filter { $0.source == .financeKit }.count
        var parts = ["\(count) \(count == 1 ? "account" : "accounts")"]
        if let last = financeKit.lastImportDate {
            parts.append("imported \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }
```

Update the footer privacy text to also mention Apple Wallet only when `financeKit.isAvailable` — leave it unchanged otherwise (flag off → identical UI).

- [ ] **Step 6: Accounts tab — banner + row tag**

In `AccountsView`, inside `List {` before `netWorthSection`:

```swift
                        if !coordinator.supersededStillLinked.isEmpty { unlinkBannerSection }
```

Add:

```swift
    /// Shown while SimpleFin still returns an account that was merged into
    /// FinanceKit. Not dismissable — it clears once the user unlinks in Bridge.
    private var unlinkBannerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(ListFormatter.localizedString(byJoining: coordinator.supersededStillLinked)) now syncs from Apple Wallet. Remove it from SimpleFin Bridge to stop duplicate syncing.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.textPrimary)
                Link("Open Bridge \u{2192}",
                     destination: URL(string: "https://beta-bridge.simplefin.org/auth/login")!)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.brand)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("unlinkBridgeBanner")
        }
    }
```

(Bridge URL matches the one `SettingsView.noticeCards` already uses.)

Replace `metaLine`:

```swift
    /// Account type, plus a source tag for non-SimpleFin accounts. Per-account
    /// sync time is dropped from the row; the overall "synced" stamp lives in the footer.
    private func metaLine(_ account: Account) -> String {
        let type = account.accountType.displayName
        switch account.source {
        case .manual: return "\(type) · manual"
        case .financeKit: return "\(type) · Apple Wallet"
        case .simplefin: return type
        }
    }
```

- [ ] **Step 7: `xcodegen generate`, build, run full test suite**

Run: `xcodegen generate && xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: all unit + UI tests pass. Also rerun the flag-on build from Task 6 Step 4.

- [ ] **Step 8: Commit**

```bash
git add Sources/FinApp Tests/FinAppUITests/FinAppUITests.swift FinApp.xcodeproj
git commit -m "feat(financekit): add Apple Wallet settings, merge sheet, unlink banner"
```

---

### Task 8: Docs — device checklist + CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`
- Modify: `AppStore/financekit-entitlement-request.md` (link checklist)

- [ ] **Step 1: CLAUDE.md** — add under Architecture, after the Sync pipeline paragraph:

```markdown
**FinanceKit** (`FinanceKit/`, behind the off-by-default `FINANCEKIT` compilation flag —
see `project.yml`): imports Apple Card/Cash/Savings on-device. `FinanceKitCoordinator`
(`@Observable`) → `FinanceKitSource` (live: `LiveFinanceKitSource`, `#if FINANCEKIT`,
iOS 17.4+; Simulator always unavailable) → `FinanceKitImporter` (pure SwiftData upsert,
ids `financekit-<UUID>`). `Account.source` (simplefin/manual/financeKit) scopes each sync
path — **SimpleFin prune only deletes `.simplefin` rows.** `FinanceKitMerge` folds the
SimpleFin copy of an Apple account into the FinanceKit row and records its old id in
`supersededProviderID`; SimpleFin sync skips that id and surfaces
`supersededStillLinked` (Accounts-tab unlink banner).
```

- [ ] **Step 2: Append to `AppStore/financekit-entitlement-request.md`** under "After approval" step 4: "Device checklist: see `docs/superpowers/specs/2026-10-15-financekit-design.md` → Testing → Device checklist. If card balances show positive, flip the liability case in `FinanceKitMapping.signed`."

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md AppStore/financekit-entitlement-request.md
git commit -m "docs(financekit): document FinanceKit architecture and device checks"
```
