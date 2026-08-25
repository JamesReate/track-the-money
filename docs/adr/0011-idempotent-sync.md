# ADR-0011 — Idempotent sync keyed on (account_id, sfin_txn_id), with balance snapshots

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [PLAN.md](../PLAN.md) §2.3, [TECH_DESIGN.md](../TECH_DESIGN.md) §6
- **Related:** [ADR-0003](0003-simplefin-is-truth.md), [ADR-0022](0022-sync-never-overwrites-user-edits.md)

## Context

Sync windows have to overlap — pending transactions post later, institutions
backfill, and a missed sync shouldn't leave a hole. Overlapping windows mean the
same transaction arrives repeatedly. Any duplicate is a corrupted history the
user can see.

## Decision

- **Upsert keyed on `(account_id, sfin_txn_id)`**, enforced by a UNIQUE
  constraint. Re-syncing the same window is a no-op.
- **Pending → posted reconciliation** rides the same key: a pending transaction
  keeps its id when it posts, so the upsert handles the transition. Pending rows
  are flagged, shown in the UI, and excluded from "final" totals.
- **Every sync writes a balance snapshot** per account into a time-series table.
- **Per-connection errors are surfaced, never swallowed** — a bank needing
  re-auth is shown prominently.

## Consequences

- Re-syncing is always safe, which makes sync cadence a tuning question rather
  than a correctness one.
- The snapshot table is the *only* source of net-worth history: SimpleFIN reports
  current balances, not past ones. That history accumulates locally and cannot be
  re-fetched, which is what makes it irreplaceable
  ([ADR-0018](0018-backup-format-sqlite-snapshot.md)).
- Transfer detection and rule application run at sync time, so the classification
  layer stays in step with incoming data.
