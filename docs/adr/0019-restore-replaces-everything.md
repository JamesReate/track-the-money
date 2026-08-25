# ADR-0019 — Restore replaces everything, rebuilds in place, and keeps one undo

- **Status:** Accepted
- **Date:** 2026-08-24
- **Source:** [plans/DATA_PORTABILITY_PLAN.md](../plans/DATA_PORTABILITY_PLAN.md) §1, §4.2–4.4, §5 D3/D4/D5
- **Related:** [ADR-0007](0007-corefacade-boundary.md), [ADR-0018](0018-backup-format-sqlite-snapshot.md)

## Context

Restoring could either replace the store or merge into it. Merging two databases
means deduplicating transactions, reconciling two edited category trees, and
resolving conflicting manual categorizations — genuinely hard, and of little
value to a single-user local app.

Replacing, meanwhile, is destructive, so it needs to be safe to get wrong.

## Decision

- **Restore replaces everything. Merge is explicitly out of scope.**
- Sequence: **validate → close → set the current store aside → swap → reopen →
  rebuild**. Validation (SQLite magic header → `quick_check` → required tables →
  migration identifiers) runs *before anything is touched*.
- A **newer-schema backup is refused**, not migrated backwards; older ones
  upgrade on reopen.
- **`LocalCore` rebuilds its internals in place** behind the unchanged facade
  ([ADR-0007](0007-corefacade-boundary.md)), so no relaunch and no view state reset.
- The replaced store is kept as **one generation of undo** (`ttm.db.pre-restore`),
  surfaced as "Undo last restore". Any failure — including a failure to reopen —
  rolls back to it.
- The confirmation sheet **summarizes the file first** (counts, data-through date,
  size) rather than asking the user to confirm blind.

## Consequences

- The destructive path is reversible in one tap, and never leaves the app without
  a database.
- Two devices editing independently cannot be reconciled by restore; that's what
  the paid sync tier is for ([ADR-0014](0014-zero-knowledge-cloud-relay.md)).
- Rebuilding internals in place means they can't be `let` constants bound at init
  — the facade holds a swappable, lock-guarded container.
- Undo is one generation deep and consumed when used, bounding disk cost.
