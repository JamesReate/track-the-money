# ADR-0028: The monthly budget is derived from history, with plans pinned per month, signed carry and income counted per payer

- **Status:** Accepted
- **Date:** 2026-11-26
- **Source:** [plans/MONTHLY_BUDGET_PLAN.md](../plans/MONTHLY_BUDGET_PLAN.md) §3
- **Related:** [ADR-0027](0027-expected-expenses.md), [ADR-0010](0010-money-and-time-conventions.md),
  [ADR-0017](0017-three-tier-categorization.md), [ADR-0025](0025-account-status-excluded-and-paused.md)

## Context

The user wants to know what they can still spend this month, per category and
on a splurge ("can I buy a gift, go out more, take a trip?"). The app already
knows the month's big bills (ADR-0027) but not income or plans.

The alternatives considered:
- **Envelope budgeting with the user funding each category by hand:** precise,
  but it needs setup before it shows anything.
- **Pay-cycle months:** rejected by the user in favour of calendar months.
- **Income as a category checkbox:** one Income category holds both salary and
  contract pay, and a checkbox says nothing about amount or timing.

## Decision

- **The month's arithmetic.**
  - Everyday budget = expected income − big bills − savings goal ± carry-over.
  - Splurge room = everyday budget − Σ max(plan + carry, spent + reserved) −
    confirmed purchases with no category.
  - Left this month = everyday budget − everyday spent − confirmed purchases.
  - Overspending comes out of splurge room immediately, and splurge room may be
    negative.
- **Everyday spending:**
  - It is outflows on counting accounts, excluding transfers, income/transfer
    categories and big-bill merchants.
  - It is dated by when the charge happened (`COALESCE(posted_at,
    transacted_at)`), so card spending counts when charged.
- **Income is gated by category and counted per payer (`MerchantKey`).**
  - **Regular:** a steady payer (similar deposits in 2 of the last 3 months,
    at least 80% of its deposits) gets expected deposits, which count before
    they land. Every gap of 13–15 days means biweekly pay, stepped by 14 days;
    otherwise deposits are slotted by their usual day of the month.
  - **Variable:** counts the lowest of the last 3 months, or a typed estimate.
  - **Not budgeted:** counts once it lands.
  - **Defaults and storage:** detection sets the default; the user overrides it
    per payer (`income_sources`).
  - **Overdue:** income past its date (2 days of grace, 7 for variable) is
    flagged.
- **Plans live on leaf categories, pinned per month.**
  - The first time a month with no stored plans is computed and there's
    spending history, default plans are written for it (an empty store isn't
    pinned). Each default is the 3-month median of everyday spending,
    rounded up to $10; anything under $25 pools into an "Everything else" row.
  - A month with no rows of its own inherits the latest earlier ones, so a past
    month's plans never drift.
  - Storage is `budget_plans(month, category_id, plan_cents)`.
- **Carry-over is signed and on by default.**
  - Next month's carry = plan + carry − spent, from the first budgeted month
    (`settings.budget_started_month`).
  - It can be turned off per category (`budget_category_settings`).
  - Unplanned splurge room doesn't carry.
- **Saved purchases have a status: `tentative`, `confirmed`, `bought` or
  `dropped`.**
  - Only `confirmed` reduces splurge room. A purchase with a category folds
    into that row's committed spend, so it isn't counted twice.
  - `bought` links the real charge, and the money then counts through its
    category. The link is suggested (±20%) and the user confirms it, never
    automatic (as in ADR-0017).
- **Everything is pure and testable.** `ExpectedIncome.compute` and
  `Budget.compute` take every input. The app supplies local month boundaries
  and their `yyyy-MM` keys, keeping TTMCore free of time zones (ADR-0010).
  Migration v8 holds the four tables.

## Consequences

- The budget works on day one with no setup, and every number is explainable
  ("your typical month", "seen in 3 of 3 months").
- Plans follow habits rather than intent until the user edits them. A month
  with a one-off (a flight) shows Everything else over plan; that's honest.
- **Carry walks every month since budgeting started**, one aggregate pass each.
  The app passes 24 earlier months; carry older than that is dropped.
- **Category deletes or merges leave orphaned plan rows.** They're ignored, not
  cleaned up.
- **`MerchantKey` is now a data format for two tables** (removals and income
  sources), as ADR-0027 warned.
- **Quarterly and annual bills still land as everyday spending** in their
  month, until expected expenses learns cadence.
