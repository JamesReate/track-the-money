# ADR-0024 — Manual accounts live under a hidden local connection; deleted synced accounts become tombstones

- **Status:** Accepted
- **Date:** 2026-11-25
- **Source:** [plans/ACCOUNT_MANAGEMENT_PLAN.md](../plans/ACCOUNT_MANAGEMENT_PLAN.md) §3, §5
- **Related:** [ADR-0007](0007-corefacade-boundary.md), [ADR-0010](0010-money-and-time-conventions.md),
  [ADR-0012](0012-net-worth-rollup-rules.md), [ADR-0013](0013-access-url-keychain-only.md),
  [ADR-0023](0023-profiles-one-store-per-data-set.md)

## Context

Users want to track accounts SimpleFIN can't reach (a car, a 401(k) at an
unsupported provider, cash) by typing a value and its date, and to delete
accounts they no longer want. The schema ties every account to a connection
(`accounts.connection_id NOT NULL`), and sync re-creates any account the bridge
still shares — so a plain row delete of a synced account is undone by the next
sync, with its full history.

## Decision

- **Manual accounts are ordinary `accounts` rows** under one hidden, lazily
  created connection per store (`id = keychain_ref = "manual"`). No schema
  change. `Store.localKeychainRefs` (`demo`, `manual`) is the single list sync,
  import re-keying and Keychain cleanup skip; `connections()` hides the manual
  holder.
- **A manual value is a balance snapshot** keyed by the chosen local day (the app
  sends start-of-day; TTMCore stays time-zone free). The account's balance is
  the latest-dated snapshot, so back-filling never overwrites the current value;
  re-entering a day replaces it. Debts are entered as positive magnitudes.
- **Delete depends on source.** Manual and sample accounts are deleted outright.
  A synced account is reduced to a **tombstone**: its transactions, snapshots and
  property links are removed, and the row stays with `archived = 1`, which sync
  now skips entirely. Restoring un-archives it. The surviving leg of any transfer
  pair is un-paired.
- **Credit card is its own class** (`creditCard`) that rolls up as unsecured
  debt everywhere (net worth, debt chart), so totals and ADR-0012 are unchanged.
  The name guesser maps card names to it and now checks secured-debt patterns
  before the generic "loan".
- **APR is user-entered** in the existing `accounts.apr_bps` (basis points),
  allowed on debt classes only, 0–100%. Sync never reports rates and never
  touches the column.

## Consequences

- Everything downstream of `accounts` (net worth, debt chart, property-debt
  links, class picker) works for manual accounts with no special cases.
- A deleted synced account leaves an empty row behind for as long as the bridge
  shares it; to be rid of it entirely the user stops sharing it in SimpleFIN
  Bridge. Restoring resumes from the next sync's window, not the full backfill.
- An older build reading a store with `creditCard` falls back to `unclassified`
  for that account (raw values decode leniently), which is acceptable for a
  backup opened on an old version.
- Revisit the hidden connection if manual accounts ever need per-account
  provenance beyond "manual" (e.g. manual transactions or imports).
