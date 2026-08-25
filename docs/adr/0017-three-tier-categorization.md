# ADR-0017 — Three-tier categorization: rules → on-device AI → cloud AI; never auto-applied

- **Status:** Accepted
- **Date:** 2026-06-27
- **Amends:** [ADR-0001](0001-local-first-freemium.md) (the AI-placement element)
- **Source:** [plans/CATEGORIZATION_PLAN.md](../plans/CATEGORIZATION_PLAN.md) §7 "On-device AI suggestions"
- **Related:** [ADR-0006](0006-ttmcore-pure-package.md), [ADR-0015](0015-two-level-categories.md)

## Context

`PLAN.md` §1 originally placed **all** AI categorization in the paid tier, run
server-side, because that was where a model could run and where the API key could
be protected. Apple's on-device Foundation Models changed the premise: a capable
model can now run locally, for free, with nothing leaving the device.

## Decision

Categorization runs in **three tiers**:

1. **Deterministic rules** — free, on-device, first and authoritative.
2. **On-device AI** — free, reached only when rules miss. `FoundationModelsCategorizer`
   (Apple's on-device LLM via `@Generable` guided generation, availability-gated)
   with `HeuristicOnDeviceCategorizer`, a merchant-keyword baseline, as the
   fallback that runs on every device.
3. **Cloud AI** — paid, for the most capable model.

**AI suggestions are never auto-applied.** A suggestion is surfaced with a badge
and requires an explicit tap to accept.

The seam is an `OnDeviceCategorizer` protocol in `TTMCore`, injected like
`SecretStore` ([ADR-0006](0006-ttmcore-pure-package.md)) — core imports no Apple
ML framework.

## Consequences

- The free tier gets meaningfully better without any server or operating cost,
  and the paid tier's pitch narrows to "a more capable model" plus sync.
- The guiding principle that a user can always see *why* a transaction landed in a
  category survives: rules stay deterministic and inspectable, and AI only ever
  proposes.
- Monetization of the free on-device AI was intended as a one-time StoreKit
  unlock. **Not built.** Since the app is open source, such a gate is bypassable
  by anyone building from source — accepted deliberately
  ([ADR-0002](0002-open-core-repo-boundary.md)).
- The tier-2 implementation is availability-gated, so behavior legitimately
  differs across devices; the heuristic keeps the feature present everywhere.
