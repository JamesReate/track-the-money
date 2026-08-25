# ADR-0012 — Net worth: liabilities as magnitudes, no double-counting property equity

- **Status:** Accepted
- **Date:** 2026-06-25 (debt split refined 2026-08-24)
- **Source:** [PLAN.md](../PLAN.md) §3, [TECH_DESIGN.md](../TECH_DESIGN.md) §5
- **Related:** [ADR-0003](0003-simplefin-is-truth.md), [ADR-0010](0010-money-and-time-conventions.md)

## Context

Institutions disagree about the sign of debt: some report a credit-card balance
as `-500`, others as `500`. And a mortgaged house is two facts — an asset worth
its market value and a liability worth the loan — that are trivially
double-counted into a wrong number.

## Decision

- **Stored balances keep the bank's sign** (SimpleFIN is truth,
  [ADR-0003](0003-simplefin-is-truth.md)). Debt-class balances are turned into
  **positive magnitudes at read time** via `abs()`, in `LocalCore` and the series
  builders — never by rewriting what was synced.
- **Property equity = market value − linked debt balances.** The property value
  counts as an asset and the linked loans as liabilities, so the equity figure is
  presented without being added again.
- **Debt is split secured vs unsecured** throughout — rollups, the balance bar,
  and the over-time chart.
- **Series are step functions:** each account or property holds its last known
  value between snapshots, and a point is emitted at every change date.

## Consequences

- Net worth is correct regardless of institutional sign conventions, and the
  normalization lives in one place rather than being sprinkled through views.
- Step-function reconstruction means a chart is well-defined even though accounts
  are snapshotted at different times.
- The `abs()`-at-read-time rule is easy to violate by accident; it's recorded in
  CLAUDE.md as a standing constraint.
- Real-world sign handling per institution is still unvalidated against live data
  and remains a watch-item.
