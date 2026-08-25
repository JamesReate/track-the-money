# ADR-0001 — Local-first free app with an optional paid cloud tier

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [PLAN.md](../PLAN.md) §1, §1a
- **Related:** [ADR-0002](0002-open-core-repo-boundary.md), [ADR-0004](0004-device-owns-simplefin-sync.md), [ADR-0014](0014-zero-knowledge-cloud-relay.md), [ADR-0017](0017-three-tier-categorization.md)

## Context

Personal finance apps generally require an account, put your data on someone
else's server, and charge for the privilege. We wanted the opposite default: an
app that is fully useful with no account, no server, and no cost to operate —
while still leaving room for a business model.

## Decision

The free tier runs **entirely on-device**: SimpleFIN sync, rules,
categorization, net worth, real estate, interest tracking. No login, no server,
nothing to operate. A paid tier later adds cross-device sync, multi-user
households, and a more capable cloud AI model.

The cloud is an **enhancement, never a requirement** — the free app is complete
without it.

## Consequences

- No server costs for the free tier, so it can stay free indefinitely.
- Every feature must be designed to work offline first; anything requiring a
  server is by definition a paid-tier feature.
- The free/paid line has to be drawn somewhere defensible — that turns out to
  be the repo boundary ([ADR-0002](0002-open-core-repo-boundary.md)).
- The AI-placement element of this decision was later revised: on-device AI
  became a free-tier feature rather than paid-only. See
  [ADR-0017](0017-three-tier-categorization.md).
