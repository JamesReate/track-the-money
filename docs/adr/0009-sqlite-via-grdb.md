# ADR-0009 — SQLite via GRDB as the on-device store

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [TECH_DESIGN.md](../TECH_DESIGN.md) §2, §5
- **Related:** [ADR-0008](0008-defer-rust-core.md), [ADR-0018](0018-backup-format-sqlite-snapshot.md)

## Context

The device case is single-writer, single-user, offline-capable, and needs real
queries (full-text search over transactions, aggregate rollups, time series).
Core Data would bind the schema to Apple frameworks; a document store would make
the aggregate queries awkward.

## Decision

**SQLite, accessed through GRDB.** WAL journaling, `STRICT` tables, FTS5 for
transaction search, foreign keys on, and GRDB's `DatabaseMigrator` for schema
evolution. Migrations are written as **plain SQL rather than a Swift DSL**, and
are strictly **append-only**.

## Consequences

- Single-writer on device is SQLite's sweet spot; GRDB adds migrations, typed
  rows, and change observation without hiding SQL.
- Plain-SQL migrations port verbatim to `rusqlite`/`sqlx`
  ([ADR-0008](0008-defer-rust-core.md)).
- Append-only migrations mean an older database always upgrades forward, and
  never backward — which is exactly what makes restoring an old backup free, and
  restoring a *newer* one impossible ([ADR-0019](0019-restore-replaces-everything.md)).
- The whole store is one file, which later made the backup format almost
  trivial ([ADR-0018](0018-backup-format-sqlite-snapshot.md)).
- Seed data (the category tree) is deliberately *not* a migration: it's
  reconciled idempotently at startup so it can add structure to existing installs
  without clobbering user edits ([ADR-0022](0022-sync-never-overwrites-user-edits.md)).
