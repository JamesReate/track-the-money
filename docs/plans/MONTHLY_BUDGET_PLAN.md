# Monthly budget: category plans, splurge room, "Can I afford it?"

- **Status:** Shipped (2026-11-26), first cut. Decided in [ADR-0028](../adr/0028-monthly-budget.md)
- **Design:** [MONTHLY_BUDGET_DESIGN.html](MONTHLY_BUDGET_DESIGN.html), a
  standalone export of the design canvas. Open it in a browser.
- **Builds on:** [EXPECTED_EXPENSES_PLAN.md](EXPECTED_EXPENSES_PLAN.md) and
  ADR-0027.

## 1. Ask

> The objective is to help you see what your monthly budget is shaping up to
> be, tied to how much you should spend on certain categories for the month:
> can you splurge on something like a gift, or spend more on going out or trips
> this month?

The design was reviewed and accepted, and these answers to its open questions
were given:

1. The budget runs on the **calendar month**.
2. Unspent plan money **carries** into next month.
3. Card spending counts **when charged**, not when the card is paid.
4. A splurge check can be **saved**. It is **tentative** at first and
   **confirmed** later; a confirmed one counts as planned.
5. Expected income **counts before it lands**, because contract pay can arrive
   a few days late. Anything expected that hasn't landed must be **visible**.

On income: W-2 salary is detected automatically. Contract or irregular work
needs a per-payer setting.

## 2. What exists

- **This Month** (`ThisMonthView`, tag `month`) lists big recurring bills:
  expected, then knocked off as they arrive. `ExpectedExpenses.compute` is
  pure, and the app supplies local month boundaries.
- **Income** is one system category (kind `income`). Subcategories can't be
  created under system categories (`LocalCore.createCategory`), so a category
  alone can't separate salary from contract work.
- **Spending** (`Store.spendingByCategory`) sums outflows by leaf category,
  posted transactions only. It leaves out transfers and excluded accounts.
- **Categories** have two levels: transactions sit on leaves, and groups are
  headers.
- **Settings** is a key/value table with `Store.setting` / `setSetting`.

## 3. Decisions

### D1: The month's arithmetic

```
Expected income (D2)
− Big bills this month          (ExpectedMonth.total: paid + still to come)
− Savings goal                  (a setting, $0 until set)
= Everyday budget

Committed = Σ over plan rows of max(plan + carry, spent)  +  open confirmed purchases (D6)
Splurge room     = Everyday budget − Committed
Left this month  = Everyday budget − everyday spent − open confirmed purchases
Pace (per row)   = (plan + carry) × days gone ÷ days in month
```

Using `max(plan, spent)` means overspending a category comes out of splurge
room as it happens. Splurge room can go **negative**; that shows as "over
plan by $X" in clay, not as a clamped $0.

**Everyday spending** is outflows on counting accounts, excluding:
- transfers;
- income- and transfer-kind categories;
- charges matched to an expected bill this month, so bills are not counted
  twice.

It is dated by `COALESCE(posted_at, transacted_at)`, so pending card charges
count as soon as they appear (answer 3). This differs from the Spending tab,
which uses `posted_at` only. That's deliberate: the budget looks forward.

A card payment that isn't paired as a transfer (its card isn't linked) would
look like spending. That's the same caveat as expected expenses; the fix is to
link the card or categorize the payment as a transfer.

### D2: Expected income: category gate plus per-payer mode

1. **Only inflows categorized as Income count.** Refunds, reimbursements and
   transfers are already outside it.
2. **Group by payer** using `MerchantKey`. Each payer has a mode:

| Mode | Counts as | Set by |
|---|---|---|
| **Regular** | Each expected deposit, with amount and date, counted before it lands | Default for payers the detector finds (salary) |
| **Variable** | One monthly estimate: the lowest monthly total of the last 3 complete months, or an amount the user types | User, for contract or irregular work |
| **Not budgeted** | Nothing up front. Once it lands it adds to this month's income, so splurge room grows | Default for anything else (bonuses, one-offs) |

**Regular detection** reuses the bill detector's grouping and similarity
(±35% of the median, in at least 2 of the last 3 months). It is
**interval-based, not day-of-month**, because salary is often biweekly (two
deposits in most months, three in some):
- The interval is the median gap between similar deposits.
- Expected dates this month are found by stepping from the last deposit by
  that interval.
- Semimonthly and monthly pay fall out of the same rule.

**Arrival** matches the bill rule: a deposit from the payer of at least half
the expected amount, within 5 days before the expected date.

**Not in yet (answer 5)** is shown when an expected deposit is past its date
by the grace period. The grace is 2 days for regular income and 7 days for a
variable payer whose month-to-date total is still short of its estimate.
Overdue income is flagged in two places:
- the Income section, shown first in red: "Expected ~Nov 15 · not in yet";
- a line under the hero: "$4,800 of expected income hasn't landed".

At month end, unlanded income simply drops out of the next month's history.
The next month starts fresh.

Storage is a new table `income_sources(merchant_key PK, name, mode,
estimate_cents NULL)`. A payer with no row takes its default from detection.

### D3: Category plans

- **Plans are set on leaf categories** (Groceries, Dining, Going Out), as
  the design shows. (A first draft put them on top-level groups. The default
  tree puts Going Out inside Entertainment, though, and Going Out is exactly
  the category the ask names.)
- **Default plan** is the median of the category's everyday spending
  (D1, so bills are excluded) over the last 3 complete months, rounded up to
  the nearest $10. The budget therefore works on day one with no setup.
- **Everything else:**
  - categories whose default is under $25 roll into one "Everything else" row,
    as does Uncategorized;
  - that row's plan is the sum of their defaults;
  - giving any such category its own plan pulls it out into its own row.
- **Storage:** `budget_plans(month TEXT 'YYYY-MM', category_id, plan_cents,
  PK(month, category_id))`. A month with no row inherits the latest earlier
  row; failing that, it uses the default. Changing a plan writes this month's
  row only, so past months keep what they were.
- The **"Use $X" suggestion** on the category screen is always the current
  3-month median.

### D4: Carry-over (answer 2)

- **What carries:** `carry(m) = plan(m−1) + carry(m−1) − spent(m−1)`, per plan
  row. It is **signed**, so overspending carries forward as a smaller budget
  next month, the same way leftovers carry as a bigger one. Without that,
  carry-over would only ever inflate the budget.
- **Where it starts:** carry begins from the first month budgeting was used
  (`settings.budget_started_month`, written on the first plan edit or the
  first visit to This Month). Earlier months carry nothing.
- **Opting out:** a per-category switch turns carry off, for example for
  Groceries. It's stored in `budget_category_settings(category_id PK,
  carry INTEGER)`, default on.
- **Splurge room does not carry.** Unplanned money left at month end is simply
  saved.

### D5: Calendar month (answer 1)

The app passes local calendar-month boundaries, as it does for expected
expenses. Pay-cycle budgeting isn't planned. Interval-based income (D2)
already copes with biweekly pay landing 2 or 3 times in a month.

### D6: "Can I afford it?" and saved purchases (answer 4)

**The check** takes an amount and, optionally, a category, and draws in this
order:
1. that category's remaining plan;
2. splurge room;
3. this month's savings goal.

**The verdict** follows from where it stops:

| Stops at | Verdict |
|---|---|
| Category plan or splurge room | **Yes, go for it** |
| Savings goal | **Only by trimming savings** |
| Runs past savings | **Not this month**, with a split-over-two-months suggestion |

The check is a pure function in TTMCore.

**Saving a purchase:** "Plan it this month" saves a row in
`planned_purchases(id, month, label, amount_cents, category_id NULL, status,
transaction_id NULL, created_at)`. Its status moves through these values:

| Status | Effect |
|---|---|
| `tentative` | Shown on This Month with a dashed outline and "if you buy it: $1,551 left". Doesn't reduce splurge room. |
| `confirmed` | Counts in Committed (D1): splurge room shrinks now, before the money is spent. |
| `bought` | Linked to the real transaction. Its spending now counts through the category, so it leaves Committed. Nothing is counted twice. |
| `dropped` | Removed from the month. |

- **Linking:** the app suggests an everyday charge this month within ±20% of
  the amount, in the purchase's category if one was set. The user confirms the
  link; it is never automatic (same principle as ADR-0017).
- **Month end:** an unbought confirmed purchase stays in its month. Next month
  offers "Move to December?".

### D7: Screens

These follow the design file:
- **This Month (iPhone):** hero "Left this month", the month bar, splurge room
  with "Can I afford…?", everyday spending with pace ticks, a Big Bills
  summary row, an Income section and planned purchases. The current bills list
  becomes the Big Bills detail screen, unchanged.
- **Category plan:** spent against plan with pace, the plan stepper with
  "Use $X", the last three months against the plan, the carry switch and this
  month's transactions.
- **Can I afford it?:** a sheet, as in the design, adding "Save as tentative"
  and "Plan it" (confirmed).
- **Options menu:** savings goal, income sources (mode and estimate per payer)
  and the existing bill settings (minimum, lookback).
- **Mac:** two columns as in the design. Bills, income, savings and planned
  purchases go in the side column.

### D8: Engine shape

- `Budget.compute(...)` is pure. Its inputs are the expected-bills month,
  income deposits, everyday charges by category, plans, carry settings,
  planned purchases, the savings goal, the month boundaries and `now`. It
  returns a `BudgetMonth`.
- Income detection lives beside `ExpectedExpenses` in `Recurring/`, sharing
  `MerchantKey`, the similarity window and the arrival rules.
- Carry is computed by walking the stored months from `budget_started_month`,
  with the app supplying each month's boundaries. That's a handful of months,
  each one aggregate query.
- **Migration v8** adds `income_sources`, `budget_plans`,
  `budget_category_settings` and `planned_purchases`. All are per profile and
  travel with backups.
- **New `CoreFacade` methods:** `budgetMonth(current:previous:history:)`,
  `setCategoryPlan`, `setCarry`, `setSavingsGoal`, `setIncomeMode`,
  `affordCheck`, `savePlannedPurchase`, `setPurchaseStatus`, `linkPurchase`.

## 4. Sample data

- **Payroll:** change the single deposit to biweekly ($2,400 every 14 days),
  so detection meets the 2-or-3-a-month case.
- **Contract client:** add irregular deposits ("NORTHWIND LLC", $900–$2,100 on
  scattered days) to exercise variable mode.
- **Going Out:** spread enough charges over three months that its median lands
  near the design's $310.

## 5. Phases

1. **Engine:**
   - migration v8;
   - income detection (interval-based) with modes;
   - `Budget.compute`, carry, the afford check;
   - Store and facade methods.

   Tests cover:
   - biweekly vs semimonthly income;
   - a late variable payer;
   - overspend into splurge room;
   - signed carry;
   - purchase status transitions;
   - no double count of bills or bought purchases.
2. **This Month UI:**
   - hero and bar, the category list with pace;
   - the Big Bills detail (current screen) and the Income section with "not in
     yet";
   - the options menu (savings goal, income sources).
3. **Category plan screen** with the stepper, "Use $X", history bars and the
   carry switch.
4. **Afford sheet and planned purchases:** tentative, confirmed, linking a
   transaction, moving to next month.
5. **Mac layout and finish:**
   - UI tests on the iPhone simulator;
   - a Mac visual pass on a throwaway profile;
   - an ADR;
   - CLAUDE.md and IMPLEMENTATION_STATUS updates.

## 6. Open (smaller, with defaults)

- **Splurge room for "Not budgeted" income:** once it lands it adds to splurge
  room (D2). Should a big one-off (a bonus) offer "send to savings" instead?
  Default: no prompt in the first cut.
- **Group-level plans** (one plan for all of Food). Default: leaves only.
- **Quarterly and annual bills** remain outside the budget until expected
  expenses learns cadence (EXPECTED_EXPENSES_PLAN §5). Until then, they land
  as everyday spending in their month.

## 7. Implementation notes (first cut)

- **Engine:**
  - `Recurring/ExpectedIncome.swift` and `Budget/Budget.swift`, both pure;
  - Store methods, and migration v8 with the four tables;
  - facade: `budgetMonth(periods:)`, `setCategoryPlan`, `setCategoryCarry`,
    `setSavingsGoal`, `setIncomeMode`, `savePlannedPurchase`,
    `updatePlannedPurchase`;
  - the afford check (`BudgetMonth.afford`) and purchase matching
    (`BudgetMonth.matches`) are value methods.
- **Plans are pinned on first compute:** `budgetMonth` writes the default plans
  for a month that has none, and sets `budget_started_month`. So "starting to
  budget" means opening the app in a month with no plans. It waits until the
  defaults have something in them: the Mac pass caught an empty store (opened
  before its first sync) pinning $0 plans that every later month inherited.
- **App:**
  - `ThisMonthView` is the budget. The old bills list moved unchanged to
    `BigBillsView`, behind the Big Bills row.
  - `CategoryPlanView` and `BudgetSheets` hold the afford check, the savings
    goal, income sources and "Mark bought".
  - One column on iPhone, two on a wide Mac window (`ViewThatFits`).
- **This Month moved to fourth tab, ahead of Spending.**
  - The reason: under iPhone's More tab its NavigationStack nested inside
    More's, and pushes showed two back buttons.
  - Tab tags are unchanged, so `-tab month` still works.
- **Sample data:**
  - biweekly payroll ($3,900);
  - a contract client (NORTHWIND LLC), stored as variable;
  - a $300 savings goal;
  - about 4 months of everyday spending on payees the hand-written rows don't
    use, starting 17 days back.
