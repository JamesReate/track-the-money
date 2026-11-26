# ADR-0026 — Credit-card promo rates are user-entered with a last day; payoff risk is cash applied earliest-deadline first

- **Status:** Accepted
- **Date:** 2026-11-26
- **Source:** [plans/PROMO_APR_PLAN.md](../plans/PROMO_APR_PLAN.md) §3
- **Related:** [ADR-0010](0010-money-and-time-conventions.md), [ADR-0012](0012-net-worth-rollup-rules.md),
  [ADR-0024](0024-manual-accounts-and-account-deletion.md), [ADR-0025](0025-account-status-excluded-and-paused.md)

## Context

Credit cards often carry a temporary promotional APR (intro or balance
transfer, commonly 0%) that reverts to the regular rate on a date. The user
wants to record it, and to know whether the cash they hold could clear those
balances before the rates jump. SimpleFIN reports neither rates nor promos, so
both are user-entered, like the regular APR (ADR-0024).

## Decision

- **Storage:** migration v6 adds `accounts.promo_apr_bps` and
  `accounts.promo_ends_on` (start of the promo's last local day, supplied by
  the app; TTMCore stays time-zone free). Credit cards only, 0–100%, end day
  not in the past; nil clears. Sync never writes them.
- **Effective rate:** an active promo's rate replaces the regular APR wherever
  a debt's current rate is used (`AccountSummary.effectiveAprBps`: Debt &
  Interest order and weighted average). An ended promo stays stored and is
  ignored.
- **Payoff outlook** (`PromoMath.outlook`, pure): counting credit cards with an
  active promo and a balance, earliest end first; counting liquid cash (≥ 0) is
  applied to them in that order. Each card reports days and months left, the
  equal monthly payment that clears it (rounded up), the cumulative amount due
  by its end day, the shortfall, and simple post-promo monthly interest.
- The promo is assumed to cover the whole card balance; other bills, buffers,
  income and deferred interest aren't modelled.

## Consequences

- No new tables, and the facade stays the only way in (ADR-0007).
- "Covered" means "today's liquid cash could pay it", not "affordable": it
  would empty checking/savings for other bills. The UI says so; a buffer
  setting and income-aware coverage are the natural next steps.
- Balance-transfer promos that cover only part of a card overstate the amount
  at stake; a per-card promo balance would fix that at the cost of going stale.
- A backup with a v6 store is refused by older builds, as for any schema
  change.
