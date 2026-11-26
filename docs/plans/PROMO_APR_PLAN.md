# Promotional APRs on credit cards, and paying them off in time

- **Status:** Shipped (2026-11-26) — first cut of the payoff outlook
- **Decided in:** [ADR-0026](../adr/0026-credit-card-promo-apr.md)

## 1. Ask

> When an account is marked as credit card, let's add a feature to be able to
> put a promotional APR, and when it expires, so you can set a date for when
> that promo expires. And then ideally something to think further about is like
> a risk of being able to pay that off by the expiration date with the
> liquidity cash that we have.

## 2. What exists

- `accounts.apr_bps` holds a user-entered regular APR on debt classes
  (ADR-0024); `creditCard` is its own class.
- Debt & Interest lists debts highest rate first with a balance-weighted
  average.
- `NetWorthSummary.liquid` is the counting (non-excluded) liquid-class balance.

## 3. Decisions

### D1 — A promo is a rate plus its last day, on credit cards only

Migration v6 adds `promo_apr_bps` and `promo_ends_on`. `promo_ends_on` is the
start of the promo's last *local* day, sent by the app (TTMCore stays time-zone
free, ADR-0010); the promo applies until that day ends. Credit cards only (as
asked); 0–100%; the end day can't be in the past; nil clears it. Sync never
touches it. Reclassifying a card hides the promo, like APR on a non-debt class.

### D2 — The effective rate is the promo's while it lasts

`AccountSummary.effectiveAprBps` = an active promo's rate, else the regular
APR. Debt & Interest sorts and averages by it, so a 0% card drops to the bottom
of the payoff order until its promo ends. An ended promo stays stored (the
rate sheet says when it ended) but no longer applies anywhere.

### D3 — Payoff outlook: earliest deadline first, against liquid cash

`promoOutlook()` takes every counting credit card with an active promo and a
balance, sorted by end day, and applies counting liquid cash (floored at zero)
to them in that order. Per card:

- **Days left** (today through the end day) and **months left** (one per
  started month after today, at least one).
- **Monthly payment to clear** = balance ÷ months, rounded up.
- **Due by then** = this balance plus every promo balance ending on or before
  it; **shortfall** = how much of that cash can't cover. Covered ⇔ zero.
- **Interest after** ≈ balance × regular APR ÷ 12, nil without a regular rate.

The section footer says either "cash covers every promo, using $X of $Y,
before any other bills" or "cash falls $Z short".

Assumptions, stated rather than modelled:

- The promo covers the whole card balance. Real promos often cover only a
  balance transfer while new purchases accrue at the regular rate; a separate
  promo balance would go stale as payments land, so it's left out.
- All liquid cash is available for payoff. Other bills, an emergency buffer and
  income before the deadline aren't modelled.
- Interest after is simple monthly interest on today's balance — a size
  signal, not a statement forecast. Deferred-interest promos (back-charging
  interest from the purchase date) aren't modelled.

## 4. Surface

`CoreFacade`: `setPromoAPR(accountId:promo:)`, `promoOutlook() -> PromoOutlook`;
`AccountSummary.promo` / `effectiveAprBps`. Pure math in
`Interest/PromoPayoff.swift` (`PromoRate`, `PromoPayoff`, `PromoOutlook`,
`PromoMath`).

App: the rate sheet for a credit card gets a **Promotion** section (toggle,
rate, end date; defaults 0% for a year). Accounts rows show "0% until <date>".
Debt & Interest's rate rows show "until <date>, then <regular>", and a new
**Promo payoffs** section shows cash on hand and, per card, the end date and
days left, covered / short, the monthly amount to clear, and the interest
after.

## 5. Next (to think further about)

- A **cash buffer** setting (keep N months of spending or a fixed amount) so
  "covered" means covered without emptying checking. The spending history to
  size it already exists.
- **Income-aware** coverage: count expected paychecks (recurring income
  transactions) before each deadline, not just today's cash.
- An optional **promo balance** per card for balance-transfer promos, and
  **deferred interest** flagging.
- A reminder ahead of each end date (needs notifications, which the app
  doesn't use yet).
