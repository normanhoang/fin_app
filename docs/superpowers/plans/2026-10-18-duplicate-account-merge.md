# Duplicate Account Detection & History Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flag likely duplicate accounts (banner + row badge), and let the user delete one with "merge", so net-worth history and the kept account's sparkline stay continuous. Then repair the owner's existing dip once.

**Architecture:** A pure `DuplicateDetector` runs over `[Account]` + first-snapshot days + dismissed pair keys, and is evaluated reactively in the Accounts UI. `AccountMerge` rewrites `AccountBalanceSnapshot`/`NetWorthSnapshot` rows (overlap days corrected, pre-existence rows reassigned), then deletes. Dismissals persist as a tiny `@Model`. A DEBUG-only env-gated `OrphanRepair` reuses the merge for already-deleted accounts.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest/XCUITest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-18-duplicate-account-merge-design.md`

## Global Constraints

- New source files → run `xcodegen generate` before building.
- Any new `@Model` goes in `AppSchema.models`; new stored properties optional or defaulted.
- Tests: qualify `FinApp.Category`; use `AppSchema.makeInMemoryContainer()`; UTC gregorian calendar like `LoanUpdaterTests`.
- Sheet title is exactly **"Delete Duplicate Account"**.
- Balance tolerance **5%** (magnitudes, both non-zero); at least one account in a pair is `source == .manual`; same `accountType`.
- Unflagged accounts keep the existing delete `confirmationDialog` unchanged.
- Keep `AccountDetailView`'s pop-then-delete ordering (delete in `onDisappear` after `dismiss()`).
- Accessibility ids: `duplicateAccountBanner`, `duplicateBadge-<accountId>`, plus `duplicateReviewButton`, `duplicateDismissButton`, `duplicateMergeDeleteButton`, `duplicateTarget-<accountId>`, `duplicateTarget-none` (our call).
- Repair code is `#if DEBUG` only.
- Build: `xcodebuild build -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17'`. Unit test: `xcodebuild test -scheme FinApp -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FinAppTests/<Class>`.

## Review Focus

1. **Debt accounts in the merge:** subtracting a negative loan balance on an overlap day must *raise* the total (the owner's actual case). Pinned in Task 2 (`testOverlapDayDebtRaisesNetWorth`).
2. **Zero balances:** two $0 manual credit cards must not match on balance alone (names differ). Pinned in Task 1 (`testZeroBalancesDoNotMatchOnBalance`).
3. **Two bank-synced look-alikes** (same type, close balance, same bank) must never be flagged. Pinned in Task 1 (`testTwoSyncedAccountsNeverFlagged`).
4. **Old account with no snapshot rows** (manual account just added, never snapshotted): merge must just delete, with totals untouched. Pinned in Task 2 (`testOldWithoutSnapshotsJustDeletes`).
5. **Overlap day with no `NetWorthSnapshot` row:** the old account's row is still deleted and no total is created. Pinned in Task 2 (`testOverlapWithoutNetWorthRowCreatesNone`).

---

### Task 1: DuplicateDetector (pure)

**Files:**
- Create: `Sources/FinApp/Accounts/DuplicateDetector.swift` (new folder; our call. It sits beside `Loans/` and `Recurring/` as pure logic)
- Test: `Tests/FinAppTests/DuplicateDetectorTests.swift`

**Interfaces:**
- Produces:
  - `struct DuplicateSuggestion: Equatable, Identifiable { let flaggedID: String; let matchID: String; var id: String { flaggedID } }`
  - `enum DuplicateDetector`
    - `static let balanceTolerance: Decimal = 0.05`
    - `static func pairKey(_ a: String, _ b: String) -> String`: ids sorted, joined by `"|"`.
    - `static func isLikelyDuplicate(_ a: Account, _ b: Account) -> Bool`: rules 1–3 of spec Detection (no dismissal check).
    - `static func firstSnapshotDays(_ snapshots: [AccountBalanceSnapshot]) -> [String: Date]`
    - `static func suggestions(accounts: [Account], firstSnapshotDay: [String: Date], dismissed: Set<String>) -> [DuplicateSuggestion]`: at most one per flagged account, sorted by `flaggedID`.
    - `static func candidates(for account: Account, among accounts: [Account]) -> [Account]`: other accounts of the same type, best (closest balance magnitude) first. Used by the sheet's radio list.

- [ ] **Step 1: Write failing tests.** Helper `acct(id:name:type:balance:manual:)` sets `isManual` and `source` (`.manual` / `.simplefin`). Tests:
  - `testMortgageAndAutoMortgageMatchByName`: manual "Mortgage" −412300 vs manual "Mortgage (Auto)" −380000 (outside 5%) → `isLikelyDuplicate == true`.
  - `testCloseBalancesMatch`: manual "Old Checking" 4812 vs simplefin "Chase Total" 4950 (cash) → true.
  - `testDifferentTypesNeverMatch`: manual loan vs manual creditCard with the same name and balance → false.
  - `testTwoSyncedAccountsNeverFlagged`: two simplefin cash accounts "Chase Checking" 4812 / "Chase Checking 2" 4813 → false.
  - `testZeroBalancesDoNotMatchOnBalance`: manual creditCard "Amex" 0 vs manual creditCard "Visa" 0 → false.
  - `testDisjointNamesFarBalancesNoMatch`: manual "Checking" 100 vs manual "Savings" 9000 (cash) → false.
  - `testFlagsManualOverSynced`: manual + simplefin pair → `flaggedID` is the manual id.
  - `testFlagsOlderWhenBothManual`: both manual; `firstSnapshotDay` a = 2026-07-25, b = 2026-10-14 → flagged a, match b. An account missing from the map counts as newest.
  - `testTieBreaksByID`: both manual, neither in map → flagged is the lexicographically smaller id.
  - `testDismissedPairSuppressed`: `dismissed = [pairKey(a,b)]` → `[]`.
  - `testOneSuggestionPerFlaggedPicksClosestBalance`: manual "Mortgage" −412300 (oldest) vs "Mortgage (Auto)" −411950 and "Mortgage 2" −300000, both newer manual → single suggestion, `matchID` = "Mortgage (Auto)" id.
  - `testPairKeyIsOrderIndependent`: `pairKey("b","a") == pairKey("a","b") == "a|b"`.
- [ ] **Step 2: Run.** `-only-testing:FinAppTests/DuplicateDetectorTests` → FAIL (type not found).
- [ ] **Step 3: Implement.** Name rule: significant words = lowercased alphanumeric tokens of `displayName` with length ≥ 3, minus stopwords `["the", "and", "account", "auto", "manual", "old", "new"]`. Names overlap when one set is non-empty and a subset of the other. Balance rule: both non-zero, `|a| − |b|` magnitude ≤ `balanceTolerance × max(|a|, |b|)`. Flag side: manual over non-manual; otherwise the earlier `firstSnapshotDay` (missing = `.distantFuture`); tie → smaller id. Group likely, undismissed pairs by flagged id and keep the match with the smallest balance-magnitude difference (tie → smaller id).
- [ ] **Step 4: `xcodegen generate`, run tests** → PASS.
- [ ] **Step 5: Commit** `feat(accounts): detect likely duplicate accounts`.

### Task 2: AccountMerge (history merge + delete)

**Files:**
- Create: `Sources/FinApp/Accounts/AccountMerge.swift`
- Test: `Tests/FinAppTests/AccountMergeTests.swift`

**Interfaces:**
- Produces: `enum AccountMerge`
  - `struct Result: Equatable { let overlapDays: Int; let movedRows: Int }`
  - `@MainActor static func mergeHistory(from oldID: String, into keptID: String, in context: ModelContext, calendar: Calendar = .current) throws -> Result`. Stages only, no save. Overlap day = calendar day on which both ids have an `AccountBalanceSnapshot`. On each one: subtract old's balance from that day's `NetWorthSnapshot.value` if a row exists, and delete old's row. Other old rows: `accountId = keptID`.
  - `@MainActor static func delete(_ old: Account, mergingInto kept: Account?, in context: ModelContext, calendar: Calendar = .current) throws -> Result?`: `mergeHistory` when `kept != nil`, then `context.delete(old)`, then one `context.save()`. On a throw, `context.rollback()` and rethrow. Returns nil when not merging.

- [ ] **Step 1: Write failing tests.** Seed with `AccountBalanceSnapshotService`-shaped rows inserted directly. Days below are 2026-10-12…16, UTC calendar.
  - `testOverlapDayCorrectedOthersUntouched`: old cash rows 10-12..10-14 = 100; kept rows 10-14..10-16 = 100; net worth rows each day = 1000 except 10-14 = 1100. After `delete(old, mergingInto: kept)`: net worth 10-14 = 1000, all other days unchanged; `Result(overlapDays: 1, movedRows: 2)`.
  - `testPreExistenceRowsMovedToKept`: same seed → kept now has rows 10-12..10-16 (5 rows, one per day); no rows remain with old's id.
  - `testKeptRowsUntouched`: kept's 10-14 balance stays 100 (old's overlap row deleted, not kept's).
  - `testOverlapDayDebtRaisesNetWorth`: old loan −412300 and kept loan −411950 both on 10-14; net worth 10-14 = 120000 → after merge = 532300.
  - `testDontMergeLeavesTotals`: `delete(old, mergingInto: nil)` → returns nil; net-worth rows and old's snapshot rows unchanged; old account gone.
  - `testOldWithoutSnapshotsJustDeletes`: old has no rows → `Result(overlapDays: 0, movedRows: 0)`, account deleted, totals unchanged.
  - `testOverlapWithoutNetWorthRowCreatesNone`: overlap day with no net-worth row → old's row on that day deleted, `NetWorthSnapshot` count unchanged.
- [ ] **Step 2: Run** `-only-testing:FinAppTests/AccountMergeTests` → FAIL.
- [ ] **Step 3: Implement** per Interfaces (fetch all snapshots once; match days with `calendar.isDate(_:inSameDayAs:)`, as `NetWorthSnapshotService` does).
- [ ] **Step 4: `xcodegen generate`, run** → PASS.
- [ ] **Step 5: Commit** `feat(accounts): merge balance history when deleting a duplicate`.

### Task 3: Persisted dismissals

**Files:**
- Create: `Sources/FinApp/Models/DismissedDuplicate.swift`
- Modify: `Sources/FinApp/Models/AppSchema.swift` (add `DismissedDuplicate.self`)
- Test: `Tests/FinAppTests/DuplicateDetectorTests.swift` (append)

**Interfaces:**
- Consumes: `DuplicateDetector.pairKey`.
- Produces:
  - `@Model final class DismissedDuplicate { @Attribute(.unique) var key: String; init(key: String) }`
  - `extension DismissedDuplicate { @MainActor static func dismiss(_ a: String, _ b: String, in context: ModelContext) }`: idempotent insert + save.

- [ ] **Step 1: Failing test** `testDismissPersistsOnceAndSuppresses`: dismiss (a,b) twice, then (b,a) → one `DismissedDuplicate` row; `suggestions(…, dismissed: Set(rows.map(\.key)))` is empty for that pair.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** model + `AppSchema.models` entry + `dismiss`.
- [ ] **Step 4: `xcodegen generate`, run `FinAppTests`** (full unit suite, since the schema changed) → PASS.
- [ ] **Step 5: Commit** `feat(accounts): persist "not a duplicate" dismissals`.

### Task 4: Banner, badge, and Delete Duplicate Account sheet

**Files:**
- Create: `Sources/FinApp/Features/Accounts/DuplicateDeleteSheet.swift`
- Modify: `Sources/FinApp/Features/Accounts/AccountsView.swift`: banner section (next to `unlinkBannerSection`, line ~90), badge in `row(_:)` (line ~351), delete routing in `AccountDetailView` (lines ~479–549).
- Modify: `Sources/FinApp/Support/SampleData.swift` and `Sources/FinApp/App/FinAppApp.swift`: demo pair.
- Test: `Tests/FinAppUITests/FinAppUITests.swift`

**Interfaces:**
- Consumes: `DuplicateDetector.suggestions/candidates/firstSnapshotDays`, `DuplicateSuggestion`, `AccountMerge.delete(_:mergingInto:in:)`, `DismissedDuplicate.dismiss`.
- Produces: `struct DuplicateDeleteSheet: View { init(account: Account, candidates: [Account], suggestedID: String?, onConfirm: @escaping (Account?) -> Void) }`. `onConfirm(nil)` = Don't merge. The sheet calls `dismiss()` itself before `onConfirm`. Cancel just dismisses.
- Produces (sample data): `SampleData.injectDuplicateDemo(into:)` inserts manual cash `Account(id: "manual-s-dup", name: "Old Checking", balance: 4300, isManual: true)` with `source = .manual`. Called from `FinAppApp.init` only when `isUITest && env["FINAPP_DUP_DEMO"] == "1"` (our call: narrower than all UI tests, so existing tests and `FINAPP_SAMPLE` screenshots are unaffected).

- [ ] **Step 1: Failing UI tests** (launch with `FINAPP_DUP_DEMO=1`; extend `launch(tab:)` with a `dupDemo: Bool = false` parameter):
  - `testDuplicateBannerReviewMergesAndDeletes`: on the Accounts tab, `duplicateAccountBanner` exists and `duplicateBadge-manual-s-dup` exists. Tap `duplicateReviewButton` → nav/sheet title "Delete Duplicate Account" exists, `duplicateTarget-s-checking` is selected (check `isSelected` or `value`) → tap `duplicateMergeDeleteButton` → `accountRow-manual-s-dup` stops existing, and so does the banner.
  - `testDuplicateDismissHidesBannerAndBadge`: tap `duplicateDismissButton` → banner and badge gone.
  - `testUnflaggedDeleteKeepsDialog`: without the demo flag, open the first account row, tap `deleteAccountButton` → the "Confirm Delete" button exists (old dialog); then cancel.
- [ ] **Step 2: Run** `-only-testing:FinAppUITests/FinAppUITests/testDuplicateBannerReviewMergesAndDeletes` → FAIL.
- [ ] **Step 3: Implement the sheet.** `NavigationStack` + `List`, `.navigationTitle("Delete Duplicate Account")`. Explainer card with "Likely duplicate" pill and the text *“<displayName>” looks like the same account as another one. Merge its history so net worth doesn’t jump.* Section header "Merge history into": rows for `candidates` (name + `MoneyText` balance) and "Don't merge". `@State selection: String?` starts at `suggestedID`. Primary button "Merge & Delete" (or "Delete" when "Don't merge" is chosen), destructive role; Cancel in the toolbar. `.presentationDetents([.medium, .large])`.
- [ ] **Step 4: Implement the banner and badge in `AccountsView`.** Add `@Query private var balanceSnapshots: [AccountBalanceSnapshot]` and `@Query private var dismissedDuplicates: [DismissedDuplicate]`, plus a computed `duplicateSuggestions`. Show one banner Section per suggestion (our call), styled like `unlinkBannerSection`: text *Possible duplicate. “<flagged>” looks like the same account as “<match>”.*, a "Review" button (sets `@State reviewing: DuplicateSuggestion?`) and a "Not a duplicate" button (calls `dismiss`). `.sheet(item: $reviewing)` presents `DuplicateDeleteSheet`; its `onConfirm` calls `AccountMerge.delete`. Badge: in `row(_:)`, a "Duplicate?" capsule after the name when the id is flagged.
- [ ] **Step 5: Implement delete routing in `AccountDetailView`.** Add the same two queries plus `@Query allAccounts`. When `account` is flagged, the Delete button sets `showDuplicateSheet` instead of `showDeleteConfirmation`. The sheet's `onConfirm(target)` stores `pendingMergeTargetID` + `pendingDelete = true` and calls `dismiss()`. Then `onDisappear` runs `AccountMerge.delete(account, mergingInto: target, in: context)` (resolve the target by id from `allAccounts`) in place of today's bare delete. The unflagged path is unchanged.
- [ ] **Step 6: Implement `SampleData.injectDuplicateDemo` and the `FinAppApp` hook.** `xcodegen generate`.
- [ ] **Step 7: Run the three new UI tests, then the full `FinAppUITests`** → PASS (existing tests unaffected).
- [ ] **Step 8: Commit** `feat(accounts): duplicate banner, badge, and merge-on-delete sheet`.

### Task 5: DEBUG orphan repair

**Files:**
- Create: `Sources/FinApp/Accounts/OrphanRepair.swift` (whole file `#if DEBUG`)
- Modify: `Sources/FinApp/App/FinAppApp.swift`: inside the existing `#if DEBUG` block, after the container exists and before `LoanUpdater.refresh`.
- Test: `Tests/FinAppTests/OrphanRepairTests.swift` (`#if DEBUG`)

**Interfaces:**
- Consumes: `AccountMerge.mergeHistory`.
- Produces: `enum OrphanRepair`
  - `struct Orphan: Equatable { let id: String; let rows: Int; let first: Date; let last: Date }`
  - `@MainActor static func orphans(in context: ModelContext) throws -> [Orphan]`: snapshot `accountId`s with no live `Account`, sorted by id.
  - `@MainActor static func run(_ env: String, in context: ModelContext) -> String`: `env == "list"` → one log line per orphan; `env == "<oldID>:<keptID>"` → requires that `oldID` is an orphan and `keptID` is a live account, otherwise returns an error line and changes nothing. Runs `mergeHistory`, saves, and returns `"merged <old> → <kept>: <overlapDays> overlap days, <movedRows> rows moved"`. `FinAppApp` calls it when `FINAPP_REPAIR_ORPHAN` is set and `print`s the result.

- [ ] **Step 1: Failing tests.**
  - `testListsOrphans`: rows for a deleted id → listed with the right count, first, and last.
  - `testRepairMergesOrphanIntoKept`: Task 2's overlap seed, but old has no `Account` → 10-14 net worth corrected, rows moved.
  - `testRepairRefusesLiveOldOrMissingKept`: old id still live → error string, no change; kept id missing → error string, no change.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement + hook.** `xcodegen generate`.
- [ ] **Step 4: Run `OrphanRepairTests`, then the full `FinAppTests`** → PASS. Release build compiles: `xcodebuild build -scheme FinApp -configuration Release -destination 'generic/platform=iOS'` (repair excluded).
- [ ] **Step 5: Commit** `chore(debug): env-gated orphan history repair`.

### Task 6: Repair the owner's dip (operator task, run with the owner)

No code. Phone must be unlocked. Get the device id with `xcrun devicectl list devices`.

- [ ] **Step 1: Back up the app container:** `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.normanhoang.finapp --source Library/Application\ Support --destination build/backup-2026-10-18/`. Check that the `default.store*` files are present.
- [ ] **Step 2: Build and install the Debug build** (CLAUDE.md "Deploy to a physical device").
- [ ] **Step 3: List orphans:** `xcrun devicectl device process launch --device <id> --console --environment-variables '{"FINAPP_REPAIR_ORPHAN":"list"}' com.normanhoang.finapp`. Expect one `manual-<uuid>` with rows up to the dip day. If more than one orphan has rows on the dip day → **stop and ask the owner** which one.
- [ ] **Step 4: Find the kept id** ("Mortgage (Auto)", `manual-<uuid>`). Run the repair: same launch with `"<orphanID>:<keptID>"`. Expect the log line `merged … 1 overlap days` (or a small number).
- [ ] **Step 5: Owner verifies on the phone:** the 6M chart has no dip, and the Mortgage (Auto) sparkline extends back. If wrong → restore the backup with `devicectl device copy to`.
