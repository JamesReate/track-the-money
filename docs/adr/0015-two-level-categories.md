# ADR-0015 — Two-level categories; transactions always live on leaves

- **Status:** Accepted
- **Date:** 2026-06-26
- **Source:** [plans/CATEGORIZATION_PLAN.md](../plans/CATEGORIZATION_PLAN.md) §1, §8
- **Related:** [ADR-0016](0016-deterministic-category-colors.md), [ADR-0017](0017-three-tier-categorization.md)

## Context

`PLAN.md` §4.1 called for hierarchical categories. Arbitrary depth invites trees
nobody can navigate and makes every rollup question ambiguous ("does Food include
transactions filed directly on Food?"). A flat list, meanwhile, doesn't survive
contact with real spending.

## Decision

**Flexible two levels: groups → leaves. Transactions are always assigned to a
leaf.** A category with children is a group header and is not itself assignable.
Each transaction has **exactly one** category.

System categories (`income`, `transfer`, `interest`, `uncategorized`) stay flat
and are guarded — they cannot be deleted or regrouped.

**Tags are out of scope** — a deliberate rejection of the second axis floated in
`PLAN.md` §4.1, not an oversight.

## Consequences

- Rollups are unambiguous: a group's total is the sum of its leaves, always.
- Deleting or merging a category must repoint transactions *and* rules in
  app-mediated code — never by relying on the FK cascade, which would silently
  delete history.
- Promoting a leaf that already holds transactions into a group needs an explicit
  migration path, so the app prompts to move them into a new subcategory or an
  auto-created "<Parent> · General" leaf.
- One category per transaction keeps v1 simple at the cost of cross-cutting
  labels; tags remain available as a future addition if the need proves real.
