# ADR-0014 — The cloud tier is a zero-knowledge E2E relay, not a sync engine

- **Status:** Accepted — not yet built (Milestone 2)
- **Date:** 2026-06-25
- **Source:** [TECH_DESIGN.md](../TECH_DESIGN.md) §2, §9, §11; [PLAN.md](../PLAN.md) §1a
- **Related:** [ADR-0001](0001-local-first-freemium.md), [ADR-0004](0004-device-owns-simplefin-sync.md), [ADR-0013](0013-access-url-keychain-only.md)

## Context

Cross-device and multi-user sync normally means a server that can read everything
it stores. Having just decided the device owns bank access
([ADR-0004](0004-device-owns-simplefin-sync.md)), a server that could read the
synced records would give back exactly the trust we'd avoided giving away.

## Decision

The paid cloud is a **zero-knowledge encrypted relay**. Records are sealed
on-device (HPKE/CryptoKit) to the household members' public keys; the backend
stores **ciphertext it cannot read** and holds no private key. Private keys live
in the Secure Enclave and iCloud Keychain, with an Argon2id passphrase for
recovery. No key escrow.

AI egress is separately minimized: only an allow-listed set of fields
(description, payee, amount — never balances or credentials) reaches the proxy,
and the server persists nothing.

## Consequences

- The server cannot read financial data even if compromised or compelled.
- **Freshness is bounded by device activity** — no server-side cron can refresh a
  household ([ADR-0004](0004-device-owns-simplefin-sync.md)).
- Server-side features that need plaintext (search, analytics, alerting) are off
  the table by construction.
- Open questions remain: group key rotation on member join/leave, and whether an
  Access URL should be shared across a user's own devices.
- **Status caveat:** `Crypto/` and `SyncClient/` are stubs in `TTMCore`. This
  records an accepted design, not shipped code.
