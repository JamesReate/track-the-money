# ADR-0004 — The device owns SimpleFIN sync, in both tiers

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [TECH_DESIGN.md](../TECH_DESIGN.md) §2, [PLAN.md](../PLAN.md) §1a
- **Related:** [ADR-0013](0013-access-url-keychain-only.md), [ADR-0014](0014-zero-knowledge-cloud-relay.md)

## Context

The obvious cloud architecture has the server hold the SimpleFIN Access URL and
sync on a cron — fresher data, simpler clients. But the Access URL is a long-lived
read credential for every linked bank account, and a server that holds it is a
server that can read your finances.

## Decision

**The device performs SimpleFIN sync in both the free and paid tiers.** The
server never calls SimpleFIN and never holds an Access URL. In the paid tier the
cloud is a relay for already-encrypted records, not a sync engine.

## Consequences

- The credential never leaves the device ([ADR-0013](0013-access-url-keychain-only.md)),
  which is what makes "we can't see your data" true in both tiers rather than
  marketing.
- **Freshness tradeoff, accepted deliberately:** household data is only as current
  as the most recent sync by one of the household's devices. There is no server
  cron to fall back on.
- Sync cadence and rate-limit behavior are a client concern; SimpleFIN limits
  mean being conservative.
- *Implementation note:* scheduled background sync is not built yet — sync is
  manual ("Sync now") today. The Settings copy promising weekly auto-sync is
  aspirational and should be honored or removed.
