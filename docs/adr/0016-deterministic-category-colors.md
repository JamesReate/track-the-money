# ADR-0016 — Category colors are auto-assigned deterministically

- **Status:** Accepted
- **Date:** 2026-06-26
- **Source:** [plans/CATEGORIZATION_PLAN.md](../plans/CATEGORIZATION_PLAN.md) §3
- **Related:** [ADR-0015](0015-two-level-categories.md)

## Context

Charts and transaction rows need per-category color to be readable at a glance.
Asking users to pick a color for every category is friction at exactly the wrong
moment (mid-categorization), and random assignment produces adjacent
near-identical hues and a different palette on every install.

## Decision

Colors come from a fixed brand palette (`CategoryPalette`) and are assigned
**deterministically: the least-used hue wins, ties broken by palette order.** No
RNG. Palette order is therefore part of the contract and must stay stable.

Leaves get **distinct hues rather than tinted shades of their group** — a
deliberate simplification of the original design, chosen for chart separation.

Users can always recolor manually; the automatic choice is a good default, not a
constraint.

## Consequences

- Every category has a sensible color immediately, with no user decision required.
- The same category tree yields the same colors on every device and install,
  which makes screenshots and support conversations reproducible.
- Reordering the palette would silently recolor existing installs — the array is
  effectively append-only.
- Group membership isn't conveyed by hue; grouping is carried by layout instead.
