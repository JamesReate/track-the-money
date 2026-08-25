# ADR-0005 — SwiftUI for iOS and macOS from one codebase

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [PLAN.md](../PLAN.md) §1, [TECH_DESIGN.md](../TECH_DESIGN.md) §2
- **Related:** [ADR-0006](0006-ttmcore-pure-package.md), [ADR-0008](0008-defer-rust-core.md)

## Context

iOS and macOS are both primary targets, not one-plus-an-afterthought. Android and
Windows are wanted eventually but are secondary and later. A cross-platform
framework would tax the platforms we care about most to subsidize the ones we
don't ship yet.

## Decision

**SwiftUI, one codebase, both Apple platforms** — a multiplatform target that
builds iPhone, iPad, and a native AppKit-backed Mac app (explicitly *not*
Catalyst). Charts via Swift Charts.

## Consequences

- Native feel and full platform API access on the platforms that matter now.
- Some per-platform divergence is unavoidable and accepted (macOS list rows
  render differently, `Form` layout differs, the iPhone tab bar collapses
  overflow tabs into "More").
- Android/Windows will need a real port. The cost is contained by keeping all
  logic out of the UI layer ([ADR-0006](0006-ttmcore-pure-package.md)) and is
  deliberately deferred ([ADR-0008](0008-defer-rust-core.md)).
