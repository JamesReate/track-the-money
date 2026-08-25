# ADR-0013 — The SimpleFIN Access URL lives only in the Keychain

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [PLAN.md](../PLAN.md) §2.1, [TECH_DESIGN.md](../TECH_DESIGN.md) §11
- **Related:** [ADR-0004](0004-device-owns-simplefin-sync.md), [ADR-0020](0020-backups-exclude-secrets.md)

## Context

The SimpleFIN claim flow exchanges a single-use setup token for a long-lived
**Access URL** with HTTP Basic credentials embedded. That URL is a durable
read credential for every linked account — effectively a password.

## Decision

The Access URL is written to the **OS Keychain and nowhere else**. It is never
stored in the database, never sent to the backend or the AI proxy, and never
leaves the device — in the free tier *or* the paid one. The database holds only a
`keychain_ref` pointing at it.

## Consequences

- "We can't see your data" holds in both tiers, structurally rather than by policy.
- The secret is outside the database by construction, so anything that copies the
  database — a backup — cannot leak it
  ([ADR-0020](0020-backups-exclude-secrets.md)). This fell out of the design for
  free rather than needing to be engineered.
- The cost lands on device migration: restoring a backup on a new device brings
  all history but no working connection, and the user must re-claim a setup token.
  Accepted as the right trade.
- Losing the Keychain item means re-claiming from the bridge; the setup token is
  single-use, so the Access URL is the thing that matters.
