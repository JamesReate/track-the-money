# ADR-0002 — Open core: public app repo, private cloud repo

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [PLAN.md](../PLAN.md) §1, [TECH_DESIGN.md](../TECH_DESIGN.md) §1
- **Related:** [ADR-0001](0001-local-first-freemium.md), [ADR-0014](0014-zero-knowledge-cloud-relay.md)

## Context

An open-source local-first app and a paid cloud service need a boundary that is
obvious to contributors and defensible as a business. Drawing it feature-by-feature
inside one repo invites constant re-litigation of what is free.

## Decision

**The free/paid line is the public/private repo line.** This repo is the whole
free app. The cloud backend (`track-the-money-cloud`, Go + Postgres) lives in a
separate private repo and holds the parts that constitute the moat: the sync
relay, the AI proxy and its prompts/keys, auth, and billing.

## Consequences

- Anything in this repo is free, forever, and readable. No feature flags gating
  paid functionality inside the open app.
- Prompts, API keys, and server logic never appear in the public repo — public-repo
  hygiene becomes a hard rule (a secret-scanning CI guard is recommended).
- The contract between them is versioned openly at `contract/openapi.yaml` so the
  free app can be built and reasoned about without access to the backend.
- Because the app is open source, any client-side purchase gate is bypassable by
  someone building from source. Accepted deliberately — see
  [ADR-0017](0017-three-tier-categorization.md).
