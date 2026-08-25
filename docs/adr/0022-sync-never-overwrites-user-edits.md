# ADR-0022 — Sync and seeding never overwrite user edits

- **Status:** Accepted
- **Date:** 2026-06-26 (nickname), reaffirmed 2026-06-27
- **Source:** `Database.swift` v3 migration, `DefaultData.ensureCategories`, [plans/CATEGORIZATION_PLAN.md](../plans/CATEGORIZATION_PLAN.md)
- **Related:** [ADR-0003](0003-simplefin-is-truth.md), [ADR-0011](0011-idempotent-sync.md), [ADR-0015](0015-two-level-categories.md)

## Context

Two processes run repeatedly over data the user has already touched: SimpleFIN
sync (every refresh) and default-data seeding (every launch, to add structure to
existing installs). Both have an obvious naive implementation that quietly
destroys user work — renaming an account back to the bank's name, or resetting an
edited category tree.

The user's edits are the part of the store that can't be recovered
([ADR-0018](0018-backup-format-sqlite-snapshot.md)).

## Decision

**User-authored data is never overwritten by an automated process.**

- **Account renaming is display-only.** A user's name is stored in a separate
  `nickname` column (migration v3); sync only ever updates `name` from SimpleFIN.
  The UI prefers the nickname when present.
- **Category seeding reconciles, it doesn't reset.** `DefaultData.ensureCategories`
  runs idempotently at startup and may *add* structure to an existing install,
  but never clobbers renames, recolors, regroupings, or deletions.
- **Manual categorization outranks re-runs.** `category_source` records why a
  transaction landed where it did, and re-applying rules respects a manual choice.

## Consequences

- Sync and startup are safe to run arbitrarily often — which is what makes
  idempotency ([ADR-0011](0011-idempotent-sync.md)) actually usable rather than
  just technically true.
- Every automated writer needs an explicit story for colliding with user intent;
  "last writer wins" is not acceptable in this codebase.
- The cost is schema surface (a parallel `nickname` column, a `category_source`
  discriminator) and reconcile logic that is more subtle than an overwrite.
