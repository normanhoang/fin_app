# Duplicate Account Detection & History Merge — Design

Date: 2026-10-18
Status: Approved in conversation (pending written-spec review)

## Problem

Net worth history is one frozen total per day (`NetWorthSnapshot`). When a user adds
an account that duplicates one they already track (e.g. a new scheduled "Mortgage
(Auto)" while the old manual "Mortgage" still exists), every snapshot recorded while
both exist counts the balance twice. Deleting the old account fixes totals going
forward but leaves the bad days in place: the 6M chart shows a ~$400k one-day
cliff. Deleting also strands the old account's `AccountBalanceSnapshot` rows (no
account references them any more), so its sparkline history is lost rather than
carried over to the account that replaced it.

This can happen to any user, with any account type, whenever one account replaces
another (manual → scheduled loan, manual → SimpleFin, etc.).

## Goals

- The app notices likely duplicate accounts on its own, whenever an account
  appears by any path: manual add (plain or scheduled loan), SimpleFin sync,
  FinanceKit import. All account types.
- It tells the user (banner + row badge), and the user confirms at delete time.
- Deleting with "merge" leaves a continuous net-worth line and a continuous
  balance history on the kept account: no dip, no jump.
- One-time cleanup of the owner's existing dip (see "One-time cleanup").

## Non-goals

- A user-facing "repair" for accounts deleted before this ships. Forward-only.
- Automatic merging without confirmation.
- Changing the existing FinanceKit ↔ SimpleFin auto-merge (`FinanceKitMerge`);
  that path already handles its own duplicates.
- Merging transactions between the two accounts. The deleted account's
  transactions are deleted as today.
- Rebuilding the whole net-worth chart from per-account rows. Per-account
  history only exists from 2026-07-25 while totals go back to 2026-06-23, so
  totals stay the source of truth and are corrected in place.

## Anti-goals

- Nagging: a pair the user marks "Not a duplicate" must never be flagged again.
- Flagging two real, separate bank accounts (e.g. two checking accounts at the
  same bank). Hence the "at least one manual" rule below.
- Changing net-worth totals on any day other than overlap days.

## Detection

A pair of live accounts is a **likely duplicate** when all hold:

1. Same `accountType`.
2. At least one of the two is manual (`isManual`; a just-added manual account
   keeps the default `source` until the launch migration runs). (SimpleFin dedupes itself;
   FinanceKit ↔ SimpleFin is `FinanceKitMerge`'s job.)
3. Either balances are within 5% of each other (compare magnitudes; both
   non-zero), or the display names clearly overlap (case-insensitive, one
   contains the other's significant words, e.g. "Mortgage" / "Mortgage (Auto)").
   Words that only name the type ("checking", "savings", "card", "credit",
   "loan", …) aren't significant, so a manual "Savings" doesn't match "Ally Savings"
   on name alone.
4. The pair hasn't been dismissed.

*Our call:* detection is a pure function over the current `[Account]` plus the
dismissed set, evaluated reactively where the Accounts tab renders. It doesn't
hook each add path. Because it reruns whenever the account list changes, it
covers manual adds, sync, and FinanceKit imports without touching those code
paths. The exact name-overlap rule and the 5% threshold are tunable. Keep them as
constants in the detector and unit-test the cases above.

**Which account is flagged (the one to delete), our call:**
- If exactly one of the pair is manual and the other isn't, flag the manual one.
- Otherwise (both manual), flag the **older** one: earlier `Account.createdAt`
  (stamped on insert by manual add, SimpleFin sync and FinanceKit import; nil =
  created before the field existed, so oldest). If that ties, the earliest
  `AccountBalanceSnapshot.day` decides (no snapshots = newer), then the smaller id.

An account in several likely pairs gets one suggestion: the best match (the
closest balance) is pre-selected in the sheet; the others are listed as
alternatives.

**Dismissed pairs** persist across launches, keyed by the unordered pair of
account ids. Storage mechanism is the builder's call (a small `@Model` added to
`AppSchema.models`, or a stored set). If an id in a dismissed pair is later
deleted, the entry is harmless.

*Our call:* ids can change in two existing paths: the SimpleFin provider-scope
rekey in `SyncService.sync`, and the `FinanceKitMerge` rekey to `financekit-<UUID>`.
Both are rare one-off events, so a dismissed pair may be flagged once more after
one. That's accepted. Don't hook the rekey paths for this.

*Our call:* detection takes the earliest snapshot day per account id as a second
input next to `[Account]`, which it needs to pick the older account. When one
account sits in pairs that disagree about which side to flag, resolve it
deterministically.

## UI

Mockups: `.superpowers/brainstorm/59112-1792340297/content/notify-options.html`
(option D) and `delete-sheet-v2.html`.

### Accounts tab: banner + badge (option D)

- **Banner** at the top of the Accounts list, in the same spot and styled like the
  existing `unlinkBannerSection`. One banner per flagged pair (or one banner
  listing them; builder's call if several). Text: *"Possible duplicate. “Mortgage”
  looks like the same account as “Mortgage (Auto)”."* Actions: **Review**
  (opens the delete sheet for the flagged account) and **Not a duplicate**
  (dismisses the pair; banner and badge disappear).
  Accessibility id: `duplicateAccountBanner`.
- **Badge** on the flagged account's row: a small "Duplicate?" tag next to the
  name. Accessibility id on the tag: `duplicateBadge-<accountId>`.

### Delete flow

- Deleting a **flagged** account (from the account detail's Delete, or banner
  Review) shows the **Delete Duplicate Account** sheet instead of the current
  confirmation dialog.
- Deleting an **unflagged** account keeps today's confirmation dialog unchanged.

### Delete Duplicate Account sheet

- Title: **Delete Duplicate Account**.
- Explainer card: "Likely duplicate". *“<name>” looks like the same account as
  another one. Merge its history so net worth doesn’t jump.*
- Section "Merge history into": radio list. The suggested match is pre-selected,
  followed by other same-type accounts, then **Don't merge**.
- Buttons: **Merge & Delete** (primary; reads "Delete" when "Don't merge" is
  chosen) and **Cancel**.
- Delete must keep the existing pop-then-delete ordering in `AccountsView`
  (delete after the detail view disappears) so the detail never re-renders
  against a deleted model.

## Merge semantics

Given `old` (being deleted) and `kept`:

1. **Overlap days** = days on which both `old` and `kept` have an
   `AccountBalanceSnapshot`. For each overlap day:
   - subtract `old`'s balance that day from that day's `NetWorthSnapshot.value`,
     but only if a snapshot exists for that day **and** it still includes the old
     balance (it equals the sum of that day's balance rows, old included, within
     $0.01). Otherwise skip the day. A row left by an account deleted mid-day
     would make an unconditional subtraction overcorrect and spike the chart.
     Skipping never makes history worse;
   - delete `old`'s `AccountBalanceSnapshot` for that day.
2. **Pre-existence days** = days with an `old` snapshot and no `kept` snapshot.
   Reassign those rows to `kept.id`, so `kept`'s sparkline continues back.
   Net-worth totals on these days are already right (only one copy was counted)
   and are not touched.
3. Delete `old` (cascade-deletes its transactions and loan schedule as today).
4. Single save at the end. If anything throws, nothing is written.

This must be a pure-ish service (e.g. `AccountMerge.mergeHistory(from:into:in:)`)
under `Analytics/` or alongside `FinanceKitMerge`. It's unit-tested with an
in-memory container:
- overlap day corrected, non-overlap days untouched;
- pre-existence rows moved to `kept.id`;
- `kept`'s own rows untouched;
- "Don't merge" path = today's delete, totals untouched.

Note: `old`'s balance on an overlap day is subtracted even for a debt account
(stored negative). Subtracting a negative raises the total, which is the
intended fix.

## One-time cleanup (owner's data only)

The owner already deleted the old manual mortgage, so its history is stranded:
`AccountBalanceSnapshot` rows with an `accountId` matching no live account.

*Our call:* a **DEBUG-only**, env-gated repair, matching the existing DEBUG
launch-variable convention: `FINAPP_REPAIR_ORPHAN=<orphanAccountId>=><keptAccountId>`.
It runs the same merge semantics (steps 1–2 above) with the orphan id as `old`,
then logs what changed. It isn't compiled into Release, and no user-facing UI.
Run on device via
`xcrun devicectl device process launch --environment-variables '{"FINAPP_REPAIR_ORPHAN":"…"}' …`.
The owner's phone runs an Xcode development install (Debug), so no build swap is
needed: install the build that has the repair, launch it once with the env var,
verify. Before running it:
- back up the app container (`xcrun devicectl device copy from …`);
- identify the orphan id by listing distinct `AccountBalanceSnapshot.accountId`
  values not in `Account.id`. A DEBUG log line on launch is fine. Expect the
  old mortgage id (`manual-<uuid>`). Confirm with the owner before running if
  more than one orphan has rows on the dip day.

Verify afterwards: the 6M chart has no dip, and the "Mortgage (Auto)" sparkline
extends back to the old account's history.

## Constraints

- SwiftData lightweight migrations only: any new stored property is optional or
  defaulted; any new `@Model` goes in `AppSchema.models`.
- `Category` must be qualified as `FinApp.Category` in tests.
- New source files require `xcodegen generate`.
- UI tests drive via accessibility ids (above). Add a duplicate pair to sample
  data **only under `FINAPP_UITEST=1`**, so App Store screenshots taken with
  `FINAPP_SAMPLE=1` show no banner and the sample net worth doesn't change.

## Left to the builder

- Name-overlap algorithm details and threshold constants (keep them testable).
- Storage for dismissed pairs.
- Banner layout when several pairs are flagged.
- Exact copy polish, as long as the sheet title stays "Delete Duplicate Account".
