# ADR-0007 — CoreFacade is the only app-facing surface

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [TECH_DESIGN.md](../TECH_DESIGN.md) §13.3, `TTMCore/Sources/TTMCore/Facade/CoreFacade.swift`
- **Related:** [ADR-0006](0006-ttmcore-pure-package.md), [ADR-0008](0008-defer-rust-core.md)

## Context

Even with a pure core, a UI that reaches into GRDB, the sync engine, or the rules
engine directly spreads the implementation across every screen. Replacing the
implementation later would then mean touching every call site.

## Decision

The app talks **only** to the `CoreFacade` protocol — never to GRDB, `Store`,
`SyncEngine`, or the rules engine. `LocalCore` is the free on-device
implementation. This contract is deliberately **frozen**: it is the seam a future
Rust core would be swapped in behind.

## Consequences

- The UI is insulated from storage and engine changes. When backup/restore needed
  to rebuild `Store`, `SyncEngine`, and `Categorizer` on a new database file, it
  happened entirely behind the facade — no view knew
  ([ADR-0019](0019-restore-replaces-everything.md)).
- Every new capability costs a facade method, which is a useful forcing function:
  it keeps the app-visible surface deliberate and small.
- Facade methods are `async` regardless of whether today's implementation needs
  it, so an out-of-process or FFI implementation stays possible.
