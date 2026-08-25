# ADR-0008 — Defer the Rust core port until Android is scheduled

- **Status:** Accepted (deferred, with a revisit trigger)
- **Date:** 2026-06-25
- **Source:** [TECH_DESIGN.md](../TECH_DESIGN.md) §2 "The Rust-core deferral", §13
- **Related:** [ADR-0006](0006-ttmcore-pure-package.md), [ADR-0007](0007-corefacade-boundary.md)

## Context

A Rust core (via UniFFI) would let one implementation serve Apple, Android, and
Windows. But the payoff is *only* for Android/Windows — secondary and later — and
for a Rust backend, which we aren't building (the cloud is Go). The FFI cost
would be paid now, on the primary Apple platforms, for a benefit that arrives
much later.

## Decision

**Keep `TTMCore` in Swift. Do not port to Rust now.** Record the deferral
explicitly rather than leaving it as an unexamined default.

**Revisit trigger:** when Android is actually scheduled. At that point, port
`TTMCore`'s pure domain logic to a `ttm-core` Rust crate (UniFFI → Swift/Kotlin
bindings) or Kotlin Multiplatform. The SQL schema and migrations move verbatim to
`rusqlite`/`sqlx`; only the binding layer changes. Platform services stay native
per-platform and are injected via traits.

## Consequences

- No FFI complexity, no cross-language debugging, no build-system tax today.
- The deferral is only affordable because of the constraints already in place:
  no UI imports in core ([ADR-0006](0006-ttmcore-pure-package.md)), a frozen
  facade ([ADR-0007](0007-corefacade-boundary.md)), and schema-as-plain-SQL
  ([ADR-0009](0009-sqlite-via-grdb.md)). Those rules are what keep the future
  port bounded — relaxing them silently raises the cost of this decision.
