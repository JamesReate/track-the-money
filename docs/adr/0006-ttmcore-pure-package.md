# ADR-0006 — TTMCore is a pure, platform-free Swift package

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [TECH_DESIGN.md](../TECH_DESIGN.md) §3
- **Related:** [ADR-0007](0007-corefacade-boundary.md), [ADR-0008](0008-defer-rust-core.md)

## Context

Domain logic tangled into view code can't be unit-tested without a simulator,
can't be reasoned about in isolation, and can't be ported. The intent from the
start was that the engine outlive the current UI framework and eventually the
current language.

## Decision

`TTMCore` is a Swift package that **imports no SwiftUI, UIKit, or AppKit** and
touches no device-only API directly. It holds the SimpleFIN client, sync, rules,
categorization, net-worth and interest math, and persistence.

The OS is reached only through **injected protocol seams**: `Clock`,
`SecretStore`, `NetworkClient`, and later `OnDeviceCategorizer`. Their platform
implementations (Keychain, URLSession, Apple Foundation Models) live in the app
layer and are injected at launch.

## Consequences

- The whole engine is testable headlessly, with no simulator and no device APIs —
  which is why the test suite runs in well under a second.
- Every new platform capability arrives as a protocol, not an import. Adding
  on-device AI later required no change to this rule.
- A future Rust port is a contained job rather than an archaeology project
  ([ADR-0008](0008-defer-rust-core.md)).
- The cost is indirection: reaching a platform API from core logic always means
  defining a seam and wiring it in the app layer.
