# ADR-0003 — SimpleFIN is the authoritative source; we never keep a competing ledger

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [PLAN.md](../PLAN.md) guiding principles, §2
- **Related:** [ADR-0011](0011-idempotent-sync.md), [ADR-0022](0022-sync-never-overwrites-user-edits.md)

## Context

A tracker that computes its own balances becomes a bookkeeping system: it has to
be reconciled, it can disagree with the bank, and the user ends up trusting
neither. The interesting problems here aren't arithmetic — they're
classification, categorization, and insight.

## Decision

**SimpleFIN is truth.** We never compute a balance ourselves and present it as
authoritative. The app layers *meaning* on top of the bank's numbers —
account classes, categories, rules, interest attribution — but never a competing
ledger. We consume the API read-only and never write back.

## Consequences

- No reconciliation feature, no manual balance adjustments, no double-entry.
- Manually-valued assets (real estate) are modeled explicitly as a separate
  concept precisely *because* they are the exception that SimpleFIN can't supply.
- If the bank is wrong, the fix is at the bank; the app shows what SimpleFIN says.
- Balance history is ours to accumulate, though: SimpleFIN reports current
  balances, so the time series exists only because we snapshot it on every sync
  ([ADR-0011](0011-idempotent-sync.md)). That data is irreplaceable, which is
  what later motivated backups ([ADR-0018](0018-backup-format-sqlite-snapshot.md)).
