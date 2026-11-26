# Expected expenses for the current month

- **Status:** Shipped (2026-11-26) — first cut
- **Decided in:** [ADR-0027](../adr/0027-expected-expenses.md)

## 1. Ask

> On one of the existing screens or maybe a new screen, I want to add expected
> expenses for the current month. If you're at day 5 in the month, you would see
> the next expected expenses coming in for the rest of the month, and as those
> expenses come in, knock them off the list. Only focus on the big expenses that
> seem to recur, over $150 or $200, analyzing the last 2 or 3 months of data.
> Have a way to remove items that get flagged but won't happen again. The
> objective is to help you see what your monthly budget is shaping up to be,
> which will tie in with a later feature: how much you can spend on categories
> this month (can you splurge on a gift, go out more, take a trip).

## 2. What exists

- Spending is backward-looking: totals by category for a chosen month.
- Transactions carry `is_transfer`. Excluded accounts' transactions are hidden
  everywhere (`Store.visibleTxn`, ADR-0025).
- There's no notion of recurrence or of a budget yet.

## 3. Decisions

### D1: A new "This Month" tab

The screen looks forward, and the category budget it leads to will live in the
same place. That's why it isn't a section of Spending. Its tag is `month`, and it
sits after Spending. On iPhone it lands under More with the other later tabs.

### D2: What counts as a recurring big expense

The input is outflows (`amount_cents < 0`) on counting accounts. It leaves out
transfers and anything categorized as income or transfer. Pending charges are
included, dated by `transacted_at`.

1. **Group by merchant.** `MerchantKey` normalizes the payee, falling back to
   the description:
   - convert to upper case;
   - split on anything that isn't a letter or digit;
   - drop tokens containing digits (store numbers, dates, reference numbers);
   - drop leading noise words (`POS`, `ACH`, `DEBIT`, `PURCHASE`, `SQ`, …);
   - drop web and corporate suffixes (`COM`, `INC`, `LLC`, …);
   - keep the first three tokens.

   For example, "HOME DEPOT #412" becomes `HOME DEPOT`, and "ACH DEBIT STATE
   FARM 0042" becomes `STATE FARM`.
2. **Look back** over the last *N* complete months: N = 3 by default, or 2 as a
   setting.
3. **A merchant qualifies when:**
   - its typical charge (the median) is at least the **minimum**: $150 by
     default, with choices of $100, $150, $200, $250 or $500;
   - the charges within ±35% of that median fall in **at least 2 of the
     lookback months**, so one odd charge doesn't break a steady bill;
   - it averages **at most 1.5 charges per month it appears in**. Frequent
     shopping (groceries, Amazon) is everyday spending, which the category
     budget will handle, not a bill.
4. **The expected amount** is the latest similar charge, since bills change.
5. **The expected day** is the median position within the month of the similar
   charges, carried into this month and capped at the month's last day.

### D3: Knocking items off

A charge from the same merchant, at least half the expected amount, marks the
item **paid**. It counts if it lands this month, or up to 5 days before the
expected day: a bill due on the 1st is often paid on the 30th or 31st. It moves to "Paid this month" with the actual amount and
date. An item still waiting more than two days after its expected day is marked
**not in yet**.

The totals are paid so far, still to come, and their sum: the big bills this
month.

### D4: Removing items is per merchant and can be undone

Removing an item stores its merchant key in a new table (migration v7,
`expected_expense_dismissals`), and the item stops being expected. A "Removed"
section lists what was removed, with **Restore**. Removals are per profile and
travel with backups.

### D5: The engine is pure; the app supplies the months

`ExpectedExpenses.compute` takes charges, the current month's boundaries, the
previous months' boundaries, `now`, the minimum and the dismissed keys. The app
computes local month boundaries with `Calendar.current`, as it does for Spending
periods. TTMCore stays free of time zones (ADR-0010).

## 4. Sample data

The demo profile gains four steady monthly bills on checking, each with four
payments 30 days apart:
- Rocket Mortgage, $2,450;
- Toyota Financial, $412;
- State Farm, $186;
- Bright Horizons, $1,650.

It also gains two payments from an orthodontist ($250) that stopped. Whether that
one qualifies depends on the day of the month, which makes it a useful candidate
for Remove. The 30-day spacing means which bills show as paid and which as
coming up depends on today's date. UI tests therefore assert that an item is on
the screen, not which section it's in.

## 5. Next (not in this cut)

- **Category budgets**, the stated goal. This screen's total of big bills, plus
  typical category spending, against expected income gives "what's left to
  spend". That answers "can I splurge this month?".
- **Expected income** (payroll) using the same detection on inflows.
- **Quarterly and annual bills** (insurance, subscriptions): they need a longer
  lookback and cadence detection.
- **Editing an item's amount or day**, and adding one by hand.
- **Credit-card payments.** When the card's account isn't linked and the
  payment isn't paired as a transfer, it can look like a recurring bill. For
  now that's what Remove is for.
