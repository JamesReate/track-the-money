# ADR-0018 — Backups are SQLite snapshots (`.ttmbackup`) via VACUUM INTO

- **Status:** Accepted
- **Date:** 2026-08-24
- **Source:** [plans/DATA_PORTABILITY_PLAN.md](../plans/DATA_PORTABILITY_PLAN.md) §3, §5 D1/D2
- **Related:** [ADR-0009](0009-sqlite-via-grdb.md), [ADR-0019](0019-restore-replaces-everything.md), [ADR-0020](0020-backups-exclude-secrets.md)

## Context

Almost nothing in the store is re-syncable. SimpleFIN returns a limited
transaction window, and balance history exists **only** as locally accumulated
snapshots ([ADR-0011](0011-idempotent-sync.md)). Add manual categorizations,
rules, the edited category tree, nicknames, and property values, and the whole
database is effectively irreplaceable. Losing a device meant losing all of it.

The alternative considered seriously was a schema-versioned JSON export.

## Decision

A backup is a **single SQLite file produced by `VACUUM INTO`** through the live
connection — consistent, checkpointed, WAL-free, carrying every table, the FTS
shadow tables, and `grdb_migrations`. Extension **`.ttmbackup`**, with an exported
UTType `money.trackthe.backup` so Files and Finder recognize it.

JSON was rejected: it must be maintained in lockstep with every migration, and
forgetting one table produces silently incomplete backups.

## Consequences

- **Fidelity is structural, not maintained.** Future migrations need no
  backup-code changes — the format is whatever the schema is.
- Restoring an older backup is free: reopening runs the normal append-only
  migrations ([ADR-0009](0009-sqlite-via-grdb.md)).
- The file is opaque to users, and no spreadsheet interop comes with it
  ([ADR-0020](0020-backups-exclude-secrets.md) records the CSV deferral).
- Validation must be by **content, not extension**, since a hand-copied `ttm.db`
  is equally valid and users will try it.
- A discovered subtlety: a cleanly-closed store still carries `journal_mode=WAL`
  and SQLite refuses a read-only open without its `-shm`, so inspection falls
  back to validating a private copy. A copy taken while the app was running keeps
  its content in the `-wal` and is correctly refused rather than restored empty.
