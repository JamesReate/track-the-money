# ADR-0020 — Backups never contain secrets; CSV export and auto-backup deferred

- **Status:** Accepted
- **Date:** 2026-08-24
- **Source:** [plans/DATA_PORTABILITY_PLAN.md](../plans/DATA_PORTABILITY_PLAN.md) §4.5, §5 D6/D7/D8
- **Related:** [ADR-0013](0013-access-url-keychain-only.md), [ADR-0018](0018-backup-format-sqlite-snapshot.md)

## Context

A backup file is designed to be moved around — into Files, iCloud Drive, a
shared folder, someone's Downloads. Whatever it contains should be safe sitting
at rest in all of those places.

Embedding the SimpleFIN Access URL, optionally passphrase-encrypted, was
considered: it would make a backup a complete one-file device migration.

## Decision

- **Secrets are never in a backup.** The Access URL grants read access to every
  linked bank account; a file left in iCloud must not carry it. Because the
  secret already lives only in the Keychain
  ([ADR-0013](0013-access-url-keychain-only.md)), this holds by construction.
- **Manual pickers only** for this phase. The user can already choose iCloud
  Drive as a destination; automatic scheduled backup — with its entitlements,
  bookmarks, and retention policy — is its own project.
- **CSV/spreadsheet export deferred**, not rejected. It's small and independent
  and can land on its own later.

## Consequences

- A backup file is safe to store and share around; the worst case is disclosure
  of financial history, not of bank access.
- **Cost:** restoring on a new device brings all data but no working connection.
  The user must re-paste a SimpleFIN setup token to resume syncing, and the app
  says so after a restore.
- No passphrase UX and no crypto surface in the backup path.
- Users who want their data in a spreadsheet have no path yet — the most likely
  reason to revisit this.
