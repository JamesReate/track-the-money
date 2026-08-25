# ADR-0010 — Money is Int64 cents; time is UTC unix seconds

- **Status:** Accepted
- **Date:** 2026-06-25
- **Source:** [TECH_DESIGN.md](../TECH_DESIGN.md) §4
- **Related:** [ADR-0003](0003-simplefin-is-truth.md), [ADR-0012](0012-net-worth-rollup-rules.md)

## Context

SimpleFIN sends amounts as decimal **strings** (`"-42.07"`) and timestamps as
unix seconds. Parsing money through `Double` introduces representation error that
compounds across thousands of transactions and shows up as cents that don't add
up. Storing local time makes date arithmetic depend on where the user was standing.

## Decision

- **Money is `Int64` minor units (cents)**, never `Double`. Decimal strings are
  parsed via `Decimal` with bankers rounding into a `Money` value type. Currency
  is formatted explicitly at the edge.
- **Timestamps are `INTEGER` unix seconds in UTC.** Rendering into the user's
  timezone happens at the SwiftUI layer, never in storage or math.

## Consequences

- Totals are exact and reproducible; no floating-point drift in net worth,
  spending, or interest math.
- Every boundary that touches money must convert deliberately — there is no
  implicit path from a `Double` into the store.
- Date-bucketing (monthly spending windows) works on integers in UTC and is
  rendered locally, so a spending month means one thing everywhere.
