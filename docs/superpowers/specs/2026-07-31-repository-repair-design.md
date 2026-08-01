# Repository Repair Design

## Goal

Repair every issue from the July 31 repository review except mixed-currency aggregation, because the product guarantees USD-only data. Preserve existing accounts, transaction notes and categories, recurring history, and balance history while correcting SimpleFIN identity scope.

## Constraints

- Keep the deployment target at iOS 17 and Swift 6.
- Add no third-party dependencies.
- Keep manual account identifiers and user-owned fields unchanged.
- Use test-first changes for observable behavior and a failing clean build as the regression check for compiler-only refactors.
- Do not redesign unrelated screens or financial calculations.

## Persistence and SimpleFIN Sync

`Account` and `Transaction` will retain `id` as their unique internal storage key and gain optional, defaulted provider identity fields so the existing SwiftData store can migrate lightly. An account provider key will combine a stable organization URL/domain decoded from SimpleFIN with the raw account ID using an unambiguous length-prefixed format. Responses without a stable organization scope will fail decoding rather than using mutable display text as identity. A transaction provider key will combine its account provider key with the raw transaction ID.

During the first post-upgrade sync, reconciliation will prefer the new scoped key. If none exists, it may claim exactly one legacy row whose `id` equals the incoming raw ID and whose provider fields are unset. It will mutate that same object to the scoped key instead of replacing it, preserving relationships, custom account names/types, notes, categories, and transaction history. When an account ID changes, its `AccountBalanceSnapshot.accountId` values will be rewritten in the same save. Later syncs use only scoped identity. Collision tests will cover duplicate raw account IDs across organizations and duplicate raw transaction IDs across accounts.

The accounts request will include `pending=1`. Sync operations will carry a connection-generation token, cancel or invalidate old work on disconnect/reconnect, and revalidate the credential immediately before persistence. Pipeline stages will propagate fetch/save failures and update `lastSyncDate` only after the whole pipeline saves. A failed pipeline will roll back unsaved context changes.

## Locking and Privacy

`AppLock` will increment a generation whenever it locks or is disabled. Authentication captures that generation before suspension and applies its result only if the generation and enabled/locked state still match.

A window-level privacy/lock host will sit above SwiftUI presentations. It will show an opaque privacy cover as soon as the scene becomes inactive and an interactive lock screen after background locking. This makes sheets and full-screen covers unable to remain above protected content. Existing per-screen dismissal hooks may remain where they serve normal UX, but security will not depend on enumerating presentations.

## Recurring, Categorization, and Triage

- Recurring anchors will use `RecurringSchedule.advance`, including month-end and leap-year behavior.
- Dedupe will use explicit state precedence: an active confirmed bill cannot inherit dismissal from a stale candidate.
- Price-change state will remain until the new price establishes a stable cluster; it will not revert after the second changed charge.
- Refresh will delete only stale, unconfirmed, non-dismissed candidates. Confirmed bills and dismissed tombstones remain.
- Category rules will rank deterministically by user-learned status, priority, keyword specificity, and a stable final key. Learning will replace the prior learned rule for the normalized merchant rather than accumulate conflicting rules.
- Triage undo expiry will return on cancellation and clear only the token that scheduled it. Filing actions will be guarded while their exit animation completes so repeated taps cannot advance twice.

## UI and Build Repairs

- Split the transaction section/row expression into smaller concrete SwiftUI views until a default clean build succeeds.
- Annotate keyboard UIKit access and notification mutations with correct main-actor hops; annotate UI-test interaction code where needed.
- Replace the eager pager stack with a lazy paging stack while preserving router and tab behavior.
- Require confirmation before deleting a manual account and cover cancel/confirm paths in UI tests.
- Provide an iOS 17 chart-overlay dismissal/positioning path instead of leaving the iOS 18 behavior as a no-op.
- Remove the unused custom certificate-pinning path and its malformed P-384 implementation, retaining standard ATS validation. This avoids shipping a security control that production never invokes and avoids enabling unvalidated pins that could lock users out of third-party SimpleFIN bridges.

## Error Handling

Network, decoding, persistence, categorization, recurring, and snapshot failures will reach `SyncCoordinator`. User-visible errors will clear at the start of a new attempt and after success. Rollback will prevent a failed sync from appearing partially successful. Expected authentication cancellation remains silent.

## Verification

Focused tests will first reproduce identity collisions/migration, stale authentication and sync completions, recurring date/state transitions, deterministic category relearning, Triage timer/action races, pending URL generation, and persistence failure behavior. UI tests will cover privacy above a presentation and manual-delete confirmation where the test harness permits reliable scene transitions.

Completion requires:

1. A fresh default simulator build succeeds without the previous type-check error.
2. All unit tests pass under the normal signed simulator configuration.
3. The full UI-test suite is launched asynchronously with an `.xcresult` bundle and log file under `/private/tmp`.
4. The final report identifies any UI failures still running or observed; it does not claim an asynchronous suite passed before it finishes.
