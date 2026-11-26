# ADR-0025 — Whether an account counts or syncs is a status, separate from its class

- **Status:** Accepted
- **Date:** 2026-11-26
- **Source:** [plans/ACCOUNT_MANAGEMENT_PLAN.md](../plans/ACCOUNT_MANAGEMENT_PLAN.md) §7
- **Related:** [ADR-0011](0011-idempotent-sync.md), [ADR-0012](0012-net-worth-rollup-rules.md),
  [ADR-0024](0024-manual-accounts-and-account-deletion.md) (amends its restore consequence)

## Context

Delete (ADR-0024) was the only way to stop an account affecting the picture,
and it throws the history away. Three cases need something gentler:

- an account to keep syncing but leave out of totals (a joint account, a work
  card);
- an account to stop updating while its history and last balance stay (a
  closed card);
- an account the user newly shares in SimpleFIN Bridge, which the next sync
  imports and counts straight away, unasked.

`excluded` already existed as an `AccountClass`, but a class says what kind of
account something is. Excluding a credit card by reclassifying it loses the
fact that it's a credit card (and its APR's meaning), and including it again
means remembering what it was.

Restoring a deleted account also only resumed from the connection's normal
window (last sync − 7 days), because the fetch window is per connection.

## Decision

- **Migration v5** adds `accounts.status` (`active | excluded | paused`,
  default `active`) and `accounts.resync_from`. Rows with class `excluded` move
  to status `excluded` with class `unclassified`; the `excluded` class is
  removed from `AccountClass`.
- **Excluded** accounts keep syncing but count nowhere: they're left out of
  net worth, both series, spending, interest totals and property equity (an
  excluded mortgage leaves liabilities, so it leaves equity too), and their
  transactions are hidden from the transaction list, search, the review queue,
  the uncategorized count, category counts and transfer matching
  (`Store.visibleTxn`). They are still stored, and rules still categorize them,
  so including the account again restores everything synced meanwhile.
- **Paused** accounts are skipped by sync (no balance, snapshot or
  transactions) and still count at their last balance. Only synced accounts can
  pause.
- **Catch-up window:** resuming sets `resync_from` to the account's last
  balance date − 7 days; restoring a deleted account sets it to now − the
  backfill (120 days). A connection's fetch starts at the earlier of its normal
  start and the earliest pending `resync_from`, never before now − backfill.
  A successful sync clears it (paused accounts keep theirs).
- **Hold new accounts** is a per-store setting (`settings.hold_new_accounts`,
  off by default). When on, an account that first appears on a connection that
  has synced before arrives `excluded`; `SyncOutcome.heldAccounts` reports how
  many. A connection's first sync always takes everything.
- `archived` keeps its ADR-0024 meaning: deleted by the user.

## Consequences

- Excluding or pausing is reversible and keeps history; delete is now the
  last resort, for data the user wants gone.
- Restoring a deleted account brings back up to the full backfill of history,
  superseding ADR-0024's "resumes from the next sync's window" consequence.
- A catch-up refetches the whole connection over the wider window, not just the
  one account. Upserts are idempotent (ADR-0011), so the cost is bandwidth.
- A pause longer than the backfill leaves a gap the bridge can't fill.
- A backup with a v5 store is refused by older builds (unknown migration), as
  for any schema change. An excluded account restored from a pre-v5 backup
  comes back `unclassified`, since its real class was never stored.
- Every new query over `transactions` that feeds something the user sees must
  apply `Store.visibleTxn`.
- Transfer pairs made before an account was excluded stay paired; the visible
  leg keeps its Transfer category.
- Deleting a category whose only transactions are hidden needs no reassignment
  in the UI (its visible count is 0), so those hidden rows become uncategorized.
