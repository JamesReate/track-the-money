# ADR-0027 — Expected expenses are detected from recent history, deterministically, and removed per merchant

- **Status:** Accepted
- **Date:** 2026-11-26
- **Source:** [plans/EXPECTED_EXPENSES_PLAN.md](../plans/EXPECTED_EXPENSES_PLAN.md) §3
- **Related:** [ADR-0010](0010-money-and-time-conventions.md), [ADR-0017](0017-three-tier-categorization.md),
  [ADR-0025](0025-account-status-excluded-and-paused.md)

## Context

The user wants to see, part way through a month, which big recurring bills are
still to come, with each one knocked off as it arrives, as the first step towards
a monthly budget. SimpleFIN reports no schedules or bill metadata, so recurrence
has to be inferred from transactions. The serious alternatives were:

- user-entered bills only: accurate, but nobody keeps them up to date;
- an AI classifier: not deterministic, can't be tested, and would need user
  confirmation anyway (ADR-0017);
- cadence detection over long history: it handles quarterly and annual bills,
  but needs more history than a new user has.

## Decision

- **Detection is a pure, deterministic heuristic**
  (`ExpectedExpenses.compute`). Outflows on counting accounts, excluding
  transfers and income- or transfer-categorized rows, are grouped by
  `MerchantKey`, a normalized payee or description. A merchant is expected this
  month when:
  - its median charge is at least the minimum ($150 by default);
  - charges within ±35% of that median fall in at least 2 of the last N
    complete months (N = 3, or 2);
  - it averages at most 1.5 charges per month it appears in.

  The expected amount is the latest similar charge. The expected day is the
  median position within the month of the similar charges.
- **Arrival:** a charge from the same merchant, at least half the expected
  amount, marks the item paid. It counts if it lands this month, or up to 5
  days before the expected day, which catches a bill due on the 1st and paid
  on the 31st.
- **Removal is by merchant key**, persisted in `expected_expense_dismissals`
  (migration v7), and can be undone. It's per profile and included in backups.
  The minimum and lookback live in `settings` (`expected_min_cents`,
  `expected_lookback_months`).
- **The app supplies the month boundaries** in local time. TTMCore stays free
  of time zones.

## Consequences

- It works from two months of history, is explainable ("seen in 3 of 3
  months"), and is fully unit-testable.
- It misses quarterly and annual bills, and bills whose merchant text changes
  every month beyond what normalization absorbs. Two distinct merchants that
  normalize to the same three tokens merge.
- An unpaired credit-card payment can be flagged as a bill. For now, removal is
  the answer.
- Changing the normalization rules changes keys, which orphans stored removals.
  Treat `MerchantKey` as stable. Changing it needs a migration that rewrites
  the stored keys, or a superseding ADR.
