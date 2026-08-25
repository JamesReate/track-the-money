# Categorization Improvement Plan

> Companion to [PLAN.md](../PLAN.md) §4 and [TECH_DESIGN.md](../TECH_DESIGN.md) §5/§7/§8.
> Scope: upgrade the categorization experience — two-level categories, create-on-the-fly,
> auto-assigned colors, and a categorized/uncategorized filter — without disturbing the
> deterministic rules engine or the SimpleFIN-is-truth contract.
>
> **Status:** ✅ Implemented (all 6 phases). 35 core tests pass; macOS + iOS Simulator
> builds succeed. See [IMPLEMENTATION_STATUS.md](../IMPLEMENTATION_STATUS.md).
> **Last updated:** 2026-06-26

---

## 0. Why now / what's already true

The data layer is **ahead of the UI**. The `categories` table already ships with the two
columns this plan needs:

```sql
CREATE TABLE categories (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  parent_id TEXT REFERENCES categories(id) ON DELETE CASCADE,   -- hierarchy: UNUSED today
  kind TEXT NOT NULL DEFAULT 'expense',
  color TEXT,                                                   -- color:     UNUSED today
  sort INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE (parent_id, name)
) STRICT;
```

So this is mostly **unlocking designed-in capability**, not re-architecting. The gaps are:

| Layer | Today | Needed |
|---|---|---|
| Schema | `parent_id` + `color` exist, unused | Data migration to seed groups + colors (additive) |
| Store DAO | `saveCategory`, `allCategories`, `spendingByCategory` | add `delete`, `reassign/merge`, tree fetch, uncategorized query |
| Facade | `categories()` → `CategorySummary{id,name,kind}` | full CRUD + tree; expose `parentId`, `color`, `sort`, txn counts |
| `TxnQuery` | filters by `categoryId` (exact) | add tri-state **categorization status** (all / categorized / uncategorized) |
| SwiftUI | flat `CategorizeSheet`, no mgmt screen | grouped picker w/ inline create, Categories manager, status filter |
| Theme | fixed brand palette, all chart bars one color | per-category color palette + assignment |

PLAN.md §4.1 already commits to: *hierarchical categories, user-editable (add/rename/merge/
delete with re-mapping), exactly one category per transaction, system categories
(Transfer/Income/Interest/Uncategorized).* This plan is the concrete UX for that.

---

## 1. The category model (the key decision)

### Recommendation: **flexible two-level, transactions always live on leaves**

Researched the dominant patterns: Copilot uses **Groups → Categories** (transactions on the
leaf, groups are rollup + budgeting containers); Simplifi goes three levels; PocketGuard is
flat. Two levels is the sweet spot — enough structure for `Kids > Childcare`, not so much
that categorizing becomes a decision tree.

**The model:**

- A category has an optional `parent_id` (already in schema).
- **A category with no children is a *leaf* — it is assignable to transactions.**
- **A category with children is a *group header* — not directly assignable;** it exists to
  organize and to roll up spending.
- This handles both spec examples uniformly:
  - `Groceries` → a standalone top-level leaf (no parent, no children) → assignable.
  - `Kids > Childcare` → `Kids` is a group header, `Childcare` is the assignable leaf.
- Promotion is graceful: when a user adds the first child to a leaf that already has
  transactions, prompt to either move those transactions to the new child or to a
  `Kids > General` auto-leaf. (Avoids the "parent holds transactions *and* has children"
  ambiguity that makes rollups lie.)

Why "transactions on leaves only" beats "assign to either level":
- Spending rollups are unambiguous (sum leaves → group total; never double-count).
- The categorize picker has one clear answer per transaction.
- Matches Copilot/Monarch mental model users already know.

**Rejected alternatives:**
- *Strict groups (top level never assignable, everything must be 2 levels deep)* — forces a
  subcategory for simple things like `Groceries`; more friction than value.
- *Three levels (Simplifi)* — over-structured for a household tool; deferrable forever.

### System categories
`Transfer`, `Income`, `Interest`, `Uncategorized` stay flat top-level leaves with
`kind != expense`. They are not groupable and not deletable (guard in the facade). They keep
their semantic roles (Transfer/Interest excluded from spend totals per PLAN §4.1/§5).

### Tags (cross-cutting) — **deferred (confirmed)**
PLAN §4.1 mentions optional free-form tags as a second axis. **Decision: out of scope, no
near-term interest.** It would need its own table + UI and isn't required for the asks here.
Noted so the category UI doesn't accidentally grow a tag-shaped appendage.

---

## 2. Create-on-the-fly UX

The principle from the research: **let users create + apply a category in the same gesture as
categorizing — never send them to a separate management screen mid-flow.**

### In the Categorize sheet (the primary path)
Today `CategorizeSheet` is a flat scrolling list. New design:

1. **Search field at top.** Typing filters the grouped list live.
2. **Grouped, collapsible list** — group headers (color dot + name) with their leaves indented
   beneath; recently-used / most-used floated to a "Suggested" section at top.
3. **No match → a `＋ Create "Coffee Shops"` row** appears inline. Tapping it:
   - creates a **leaf** category (auto-colored, see §3),
   - assigns it to the transaction,
   - dismisses — one tap, zero detours.
4. **Create as subcategory:** the create row has a secondary affordance ("in group… ▾") to
   drop the new leaf under a chosen group instead of top-level. Default = top-level/ungrouped;
   power users can nest.
5. The existing **"Also create a rule"** toggle stays — create-category + create-rule in one
   confirm is the canonical *"all CHEWY.COM → Pets/Dog"* flow from PLAN §4.2.

### In the Categories manager (the deliberate path)
A dedicated screen (new) for structural edits:
- Add group / add category, rename, recolor, **reorder** (drag → writes `sort`).
- **Move** a category between groups (regroup).
- **Merge** A → B (repoint transactions *and* rules, then delete A) — fulfills PLAN §4.1
  "merge with re-mapping."
- **Delete with reassign:** never silently null transactions. Deleting a leaf asks "move N
  transactions to…"; deleting a group asks where its children/transactions go. (Today's raw FK
  is `ON DELETE CASCADE` for children + `SET NULL` for txns — destructive; the app must mediate
  this with an explicit reassign step rather than relying on the FK.)
- Guard system categories (no delete/regroup).

---

## 3. Auto-assigned colors

### Palette
Define a **curated palette of ~14 hues** that live alongside the existing "Statement" design
system (`Theme.swift` Brand colors stay as semantic anchors: evergreen=assets, clay=debts).
The category palette is a separate, harmonious set — muted, paper-friendly tones, not saturated
defaults — so the app keeps its editorial feel.

### Assignment rule (deterministic, not random)
On category create with no color chosen:
- pick the **least-used hue** in the palette (ties broken by palette order). Deterministic
  matters: it's reproducible, test-friendly, and avoids the `Math.random` ban in the workflow
  tooling / keeps parity-port behavior stable.
- **Group children inherit the group's hue** as tints/shades by default (e.g. `Kids` =
  indigo; `Childcare`/`School` = lighter indigos). Reads as a family at a glance.
- Always overridable via a color picker in the manager.

Store the resolved hex in the existing `categories.color` column.

### Where color shows up (payoff)
- **Transaction rows:** a small color dot / chip next to the category name (replaces today's
  evergreen-vs-slate text-only cue).
- **Spending screen:** chart slices/bars colored per category instead of all-clay; group view
  uses the group hue, expandable to tinted children.
- **Categorize sheet & manager:** color dots on every row.

Requires exposing `color` (and `parentId`, `sort`) on `CategorySummary`, which the UI currently
doesn't receive.

---

## 4. Categorized vs. uncategorized filter

The research is unanimous (Lunch Money especially): **make uncategorized visible and
filterable, and nudge toward zero.**

### Data
`TxnQuery` gains a tri-state:

```
enum CategorizationStatus { case all, categorized, uncategorized }
```

- `uncategorized` → `WHERE category_id IS NULL` — already backed by the partial index
  `idx_txn_uncat ON transactions(category_id) WHERE category_id IS NULL`. Free performance.
- `categorized` → `WHERE category_id IS NOT NULL`.
- (Optional, later) filter by `category_source` — manual vs `rule:<id>` vs transfer — useful
  for auditing the "why" trail, but not required now.

### UI on the Transactions screen
- **Segmented control / filter chips:** `All · Uncategorized · Categorized`.
- **A review nudge:** show the uncategorized count as a badge ("12 to review").
- **Review mode (in scope):** a one-tap mode that walks uncategorized transactions one at a
  time — each card shows the transaction + the grouped picker (with inline create), and
  categorizing advances to the next. A progress indicator ("3 of 12") and a "skip" action.
  This is the highest-leverage way to drive uncategorized toward zero after a sync.
- **Visual cue:** render the "Uncategorized" label in a warning tone (clay) — mirrors Lunch
  Money's red — so it reads as a to-do, not a resting state.

---

## 5. API / engine changes (TTMCore)

All additive; no change to the rules-engine contract or sync.

**`CoreFacade` / `LocalCore`:**
- `categoryTree()` → groups with nested leaves, each carrying `color`, `sort`, and a
  `transactionCount` (for the manager + reassign dialogs).
- `createCategory(name:parentId:kind:color?)` → returns the new `CategorySummary` (auto-color
  if `color == nil`).
- `updateCategory(id:name?:parentId?:color?:sort?)` — rename / recolor / regroup / reorder.
- `deleteCategory(id:reassignTo:)` — repoint transactions + rules, then delete.
- `mergeCategory(from:into:)` — repoint transactions + rules, delete source.
- Extend `CategorySummary` with `parentId`, `color`, `sort`.

**`Store` (DAO):**
- `deleteCategory`, `reassignTransactions(from:to:)`, `repointRules(from:to:)`,
  `categoryTree`, `transactionCountByCategory`, `uncategorizedCount`.
- `transactions(query:)` honors the new `CategorizationStatus`.

**Migration:**
- **v4 — data only (no DDL):** organize the existing 8 expense seeds into the starter groups
  (§8), create the new `Entertainment` leaves (`Streaming`, `Concerts`, `Going Out`), assign
  default colors, and set `sort`. Keep it additive and idempotent (only touches rows it
  seeded — must not clobber a user who already renamed/recolored). No constraint changes
  needed because `parent_id`/`color` already exist.
- Delete/merge destructiveness is handled in app code (reassign-first), **not** by changing the
  FK actions — keeps the SQL schema portable for the future Rust move (TECH_DESIGN §13).

**Rules interplay:** rules already point at `category_id`. Merge/delete must update
`rules.category_id` (or disable orphaned rules) — covered by `repointRules`. Create-on-the-fly
+ "also create a rule" keeps working unchanged.

---

## 6. Screen-by-screen summary

| Screen | Change |
|---|---|
| **Transactions** | Status filter chips (All/Uncategorized/Categorized) + count badge; color dot on rows; optional Review mode. |
| **Categorize sheet** | Search; grouped collapsible picker; inline `＋ Create "…"`; create-as-subcategory; keep "also create rule." |
| **Categories (new)** | Manager: add/rename/recolor/reorder/regroup; merge; delete-with-reassign; system-category guards. |
| **Spending** | Per-category colors; group totals expandable to tinted children; transfers/interest excluded as today. |
| **Rules** | Unchanged behavior; benefits from merge/delete repointing so rule targets never dangle. |
| **Theme** | Add category palette + color helpers (separate from semantic Brand anchors). |

---

## 7. Phasing (delivered)

1. ✅ **Foundation (TTMCore):** `CategoryPalette`; grouped seed tree + colors via idempotent
   `DefaultData.ensureCategories` (replaces the one-shot data migration — adds structure to
   existing installs without clobbering edits); extended `CategorySummary`
   (parentId/color/sort/isSystem); Store reassign/repoint/reparent + counts + uncategorized
   query; facade `createCategory`/`rename`/`recolor`/`move`/`reorder`/`delete`/`merge`;
   `TxnQuery.categorization`; migration **v4** = the `idx_txn_uncat` partial index.
   9 new `CategoryTests` (auto-color determinism, two-level guards, merge repoints
   rules+txns, delete reparents children, system guard, uncategorized filter/count).
2. ✅ **Color system:** `Color(categoryHex:)` + `CategoryDot` in Theme; AppModel color/tree
   helpers; dots on transaction rows; per-category Spending chart + list.
3. ✅ **Uncategorized filter:** `TxnQuery` status wired through Store; Transactions chips
   (All/Uncategorized/Categorized) + count badge.
4. ✅ **Create-on-the-fly:** reusable grouped, searchable `CategoryPicker` with inline
   `Create "…"` (+ in-group selector); rebuilt `CategorizeSheet`.
5. ✅ **Review mode:** `ReviewView` — guided one-at-a-time pass with progress + skip, reusing
   the picker; launched from the Transactions "Review" action.
6. ✅ **Categories manager:** `CategoriesView` + `CategoryEditSheet` — add/rename/recolor/
   reorder/regroup/merge/delete-with-reassign; system-category guards; new Categories tab.

### On-device AI suggestions (added 2026-06-27)
The model strategy shifted: **on-device AI is now the default free suggestion engine** (not
paid-only). Three tiers — deterministic rules → on-device AI on a rule miss → paid cloud
Claude for the most capable model.
- **Seam:** `OnDeviceCategorizer` protocol in `TTMCore` (pure, injected like `SecretStore`),
  returning a `CategorySuggestion` (category id + confidence + suggested rule). Reached only
  when rules miss; never auto-applied.
- **Implementations (app layer):** `FoundationModelsCategorizer` — Apple's on-device LLM via
  guided generation (`@Generable`), `#if canImport(FoundationModels)` + `@available(iOS/macOS
  26)`-gated; `HeuristicOnDeviceCategorizer` — a merchant-keyword baseline that runs on every
  device. `AppModel.live()` injects the best available.
- **Monetization:** the free on-device AI is gated behind a **one-time unlock purchase**
  (StoreKit — TODO); cloud subscription swaps in Claude. (Open-source ⇒ bypassable; accepted.)
- **UX:** the **Review modal** fetches `suggestCategory` per transaction and shows a badged
  "✦ AI suggested" banner with one-tap **Approve** (and marks the suggested leaf in the
  picker). Covered by `testReviewShowsAndApprovesAISuggestion` (UI) + the seam unit tests.

**Open fast-follows (optional):** same suggestion banner in the tap-to-categorize sheet; the
StoreKit unlock gate; `category_source` filter (audit the rule/manual/transfer "why" trail).
*(Tags remain out of scope.)*

### Known follow-ups / deltas from the original design
- **Picker structure (bugfix):** the category picker **owns its own `List`** and the host
  sheets stack a compact header above it. An earlier version vended `Section`s from the
  picker into the host's `List`, which rendered fine but **silently swallowed row taps** —
  categories looked un-pickable. Groups are also always-expanded in the picker (no collapse)
  so every leaf is one tap away. Covered by the `TrackTheMoneyUITests` XCUITest target
  (apply-leaf, create-on-the-fly, review-applies).
- **Color inheritance:** leaves get distinct palette hues (better chart separation) rather
  than tinted shades of the group hue — a deliberate simplification of §3.
- **Group promotion (done):** adding a subcategory to a leaf that already holds transactions
  promotes it to a group and now prompts to move those transactions — into the new
  subcategory or an auto-created "<Parent> · General" leaf (or keep them). Core move:
  `reassignCategoryContents` (moves transactions + repoints rules, both categories kept);
  detection in `AppModel.createSubcategory`; prompt in `CategoriesView`. Covered by
  `testReassignContents...` (unit) and `testGracefulPromotionPrompt` (UI).

---

## 8. Decisions (locked 2026-06-26)

1. ✅ **Hierarchy model** — flexible two-level, transactions always on leaves.
2. ✅ **Starter group tree** (the v4 seed):

   | Group | Leaf categories |
   |---|---|
   | **Food** | Groceries, Dining |
   | **Home** | Home, Utilities |
   | **Family** | Kids, Pets |
   | **Entertainment** *(new)* | Streaming, Concerts, Going Out |
   | **Auto** | *(standalone leaf — no children)* |
   | **Health** | *(standalone leaf — no children)* |

   `Streaming` is where a `Netflix`-style merchant rule lands (e.g. *description contains
   `NETFLIX` → Streaming*) — captured via the existing "also create a rule" flow, not as its
   own category. System categories (Transfer/Income/Interest/Uncategorized) stay flat.
3. ✅ **Tags** — out of scope; no near-term interest.
4. ✅ **Review mode** — build now (phase 5).
</content>
</invoke>
