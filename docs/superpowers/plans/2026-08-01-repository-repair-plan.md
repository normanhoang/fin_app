# Repository Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair all confirmed review findings except mixed-currency aggregation while preserving existing user data.

**Architecture:** Apply backward-compatible SwiftData fields and in-place identity migration, add generation guards around suspended security/network work, and isolate UI lifecycle behavior behind small testable helpers. Each subsystem receives focused regression tests before its minimal implementation.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, XCTest/XCUITest, LocalAuthentication, URLSession.

## Global Constraints

- Deployment target remains iOS 17.
- No third-party dependencies.
- Existing accounts, notes, categories, recurring data, and balance history must survive migration.
- Financial aggregation remains USD-only by product contract.
- Production changes follow a failing regression test or, for compiler refactors, the already-failing clean build.

---

### Task 1: Restore clean compilation and concurrency correctness

**Files:**
- Modify: `Sources/FinApp/Features/Transactions/TransactionsView.swift`
- Modify: `Sources/FinApp/Support/KeyboardDismiss.swift`
- Modify: `Tests/FinAppUITests/FinAppUITests.swift`

**Interfaces:**
- Produces: smaller concrete transaction section/row builders with unchanged UI behavior.
- Produces: `@MainActor` UIKit keyboard interaction.

- [ ] Run a fresh default build and retain the type-check failure as the red check.
- [ ] Extract the nested transaction section expression into concrete `View` helpers without changing filtering or navigation.
- [ ] Move keyboard notification mutations explicitly onto `MainActor` and mark UI-test automation code main-actor isolated.
- [ ] Run a fresh default build and require exit code 0 with no app-target actor warnings.

### Task 2: Add scoped SimpleFIN identity with in-place migration

**Files:**
- Modify: `Sources/FinApp/Models/Account.swift`
- Modify: `Sources/FinApp/Models/Transaction.swift`
- Modify: `Sources/FinApp/SimpleFin/SimpleFinDTO.swift`
- Modify: `Sources/FinApp/SimpleFin/SyncService.swift`
- Modify: `Tests/FinAppTests/SimpleFinDecodingTests.swift`
- Modify: `Tests/FinAppTests/SyncServiceTests.swift`

**Interfaces:**
- Produces: `AccountDTO.providerScope: String` from organization `sfin-url`, domain, or name.
- Produces: collision-safe length-prefixed scoped account and transaction keys.

- [ ] Add failing decoding and sync tests for organization scope, repeated account IDs across organizations, repeated transaction IDs across accounts, and legacy-row migration preserving notes/categories/snapshots.
- [ ] Add optional defaulted provider fields to persisted models for lightweight migration.
- [ ] Decode a stable organization scope and reconcile new/scoped and legacy rows with mutable maps.
- [ ] Rewrite account balance snapshot IDs when a legacy account row is migrated.
- [ ] Run decoding and sync service tests until green.

### Task 3: Make network requests and sync lifecycle safe

**Files:**
- Modify: `Sources/FinApp/SimpleFin/SimpleFinClient.swift`
- Modify: `Sources/FinApp/SimpleFin/SyncCoordinator.swift`
- Modify: persistence pipeline service files under `Analytics`, `Categorization`, and `Recurring` only where errors are swallowed.
- Modify/Create: focused tests under `Tests/FinAppTests`.

**Interfaces:**
- Produces: `accountsURL(accessURL:since:)` with `pending=1`.
- Produces: sync generation validation before persistence and success stamping.
- Produces: throwing pipeline operations and rollback on failure.

- [ ] Add a failing URL test proving pending transactions are requested.
- [ ] Add delayed-client coordinator tests proving disconnect/reconnect invalidates stale responses and a failed stage cannot update `lastSyncDate`.
- [ ] Add `pending=1`, clear stale errors on attempts/success, and introduce cancellation/generation validation.
- [ ] Stop swallowing persistence failures in the sync pipeline; roll back unsaved changes and stamp success only after completion.
- [ ] Run the focused client/coordinator/persistence tests until green.

### Task 4: Harden authentication and presentation privacy

**Files:**
- Modify: `Sources/FinApp/Support/AppLock.swift`
- Modify: `Sources/FinApp/App/FinAppApp.swift`
- Create: `Sources/FinApp/Support/PrivacyShieldHost.swift`
- Modify: `Tests/FinAppTests/AppLockTests.swift`
- Modify: `Tests/FinAppUITests/FinAppUITests.swift`

**Interfaces:**
- Produces: generation-checked `AppLock.authenticate()`.
- Produces: window-level shield state driven by scene phase and lock state.

- [ ] Add a failing suspended-authentication test showing a later lock rejects the old success.
- [ ] Add the generation guard and verify existing authentication tests remain green.
- [ ] Add the window-level privacy/lock host above presented controllers.
- [ ] Add a representative presented-sheet background/reactivation UI test.

### Task 5: Correct recurring reconciliation

**Files:**
- Modify: `Sources/FinApp/Recurring/RecurringDetector.swift`
- Modify: `Sources/FinApp/Recurring/RecurringStore.swift`
- Modify: recurring tests under `Tests/FinAppTests`.

**Interfaces:**
- Consumes: `RecurringSchedule.advance(from:cadence:)` for all calendar anchors.
- Produces: explicit confirmed/dismissed merge precedence and stale-candidate retirement.

- [ ] Add failing month-end, dedupe-state, price-transition, and detected-then-stale tests.
- [ ] Replace fixed-day anchors with calendar schedule advancement.
- [ ] Preserve active confirmed state during dedupe and retire only stale active candidates.
- [ ] Retain price-change state until the latest amount cluster is stable.
- [ ] Run all recurring and analytics tests until green.

### Task 6: Make categorization and Triage deterministic

**Files:**
- Modify: `Sources/FinApp/Categorization/CategorizationEngine.swift`
- Modify: `Sources/FinApp/Features/Transactions/TriageView.swift`
- Modify/Create: focused categorization and Triage tests.

**Interfaces:**
- Produces: deterministic rule ranking and learned-rule upsert.
- Produces: cancellation-aware undo expiry and an action-processing gate.

- [ ] Add failing equal-priority, repeated-relearning, cancelled-undo, and repeated-action tests.
- [ ] Implement explicit rule ordering and update an existing learned merchant rule.
- [ ] Extract the undo/action state transitions into a small testable main-actor state type used by `TriageView`.
- [ ] Run focused tests until green.

### Task 7: Resolve remaining UI and transport findings

**Files:**
- Modify: `Sources/FinApp/App/RootView.swift`
- Modify: `Sources/FinApp/Features/Accounts/AccountsView.swift`
- Modify: `Sources/FinApp/Features/Dashboard/DashboardView.swift`
- Modify/Delete: `Sources/FinApp/SimpleFin/CertificatePinner.swift` and its tests/configuration references.
- Modify: `Tests/FinAppUITests/FinAppUITests.swift`

**Interfaces:**
- Produces: lazy page construction, confirmed manual deletion, and an iOS 17 chart-overlay dismissal path.
- Produces: standard ATS-only `URLSession.shared` transport without dormant custom pinning.

- [ ] Replace the pager `HStack` with `LazyHStack` and retain page identifiers/scroll targeting.
- [ ] Add a destructive confirmation dialog before manual-account deletion and update cancel/confirm UI coverage.
- [ ] Implement the iOS 17 trend-overlay dismissal fallback and expose the category filter with a labeled accessibility control if absent.
- [ ] Remove unused custom certificate pinning and its now-dead tests/references.
- [ ] Run focused UI/unit checks and a clean build.

### Task 8: Full verification and asynchronous UI suite

**Files:**
- No production files.
- Output: `/private/tmp/fin_app-ui-tests.log`
- Output: `/private/tmp/fin_app-ui-tests.xcresult`

**Interfaces:**
- Consumes: the complete app and test targets.

- [ ] Regenerate the Xcode project if `project.yml` source membership requires it.
- [ ] Run a fresh default clean simulator build.
- [ ] Run every signed unit test and extract the exact pass/fail count from the result bundle.
- [ ] Start every UI test asynchronously with durable log/result paths and record the PID.
- [ ] Report changed files, verification evidence, and the background UI-test monitoring command without claiming unfinished tests passed.
