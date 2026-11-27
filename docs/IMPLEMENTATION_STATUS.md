# Implementation Status

Resume pointer for Track The Money. See [PLAN.md](PLAN.md) (product) and
[TECH_DESIGN.md](TECH_DESIGN.md) (architecture). Verified on macOS with the
Swift 6.3 toolchain.

**Build & test:**
- Core: `cd TTMCore && swift build && swift test` — **135 passing + 2 live tests skipped by default**.
- App: `cd app && swift build` (or `swift run TrackTheMoney` on macOS) — builds clean.
- UI tests: `xcodebuild test -scheme TrackTheMoney -only-testing:TrackTheMoneyUITests`
  (XCUITest target `app/UITests`) — drives the categorize/create/review/promotion + AI
  suggestion flows, backup surface, profiles, account management, expected expenses and the budget on the Simulator; **20 passing** (live test excluded). (Launch args: `-resetStore` for a clean
  DB; `-stubAI` forces the deterministic heuristic categorizer; `-noAI` disables it.)
- Xcode (multiplatform): `xcodegen generate && open TrackTheMoney.xcodeproj` — see [BUILD.md](BUILD.md).

## Milestone 1 — Free on-device app

### Done (TTMCore, all tested)
- ✅ **Money** (Int64 cents, exact Decimal parsing), **Time** (UTC), DI protocols
  (`Clock`/`SecretStore`/`NetworkClient`).
- ✅ **Persistence** — GRDB `Database` (WAL/STRICT), migrations **v1 schema** +
  **v2 FTS5** (triggers), `Store` DAO, records, seed categories + default
  interest rule.
- ✅ **SimpleFIN** — v1/v2 Codable models + live client (Basic-Auth split, query
  build).
- ✅ **Sync engine** — idempotent upsert on `(account_id, sfin_txn_id)`, balance
  snapshots, pending→posted reconcile, smart-default class on first sight,
  per-connection failure isolation, rules applied at sync time.
- ✅ **Rules** — condition tree + matcher (first-match-by-priority);
  forward/backfill/rerun reapply.
- ✅ **Net worth** — latest rollup (no double count) + **over-time series** from
  snapshots (step function, windowed).
- ✅ **Interest** — default detection rule + **payment splits** +
  debt-cost rollup (interest by account/period).
- ✅ **Transactions** — `TxnQuery` listing (account/category/date/pending) + **FTS
  search** + **transfer auto-detection** (runs at end of sync).
- ✅ **Real estate** — properties, value history, linked mortgage/HELOC →
  equity; corrected `realEstateEquity` in net worth.
- ✅ **LocalCore** — the free-tier `CoreFacade` implementation wiring all of the
  above (+ `accounts()`/`setAccountClass()` and `AccountSummary`).
- ✅ **SwiftUI app** (`app/`, SPM package) — `AppModel` (`@Observable` over
  `CoreFacade`) + screens: **Net Worth** (Swift Charts over-time), **Accounts**
  (class picker), **Transactions** (FTS search + tap→categorize / create-rule),
  **Spending** (by-category bar chart), **Rules** (toggle/delete), **Real
  Estate** (value/debt/equity, add property + value, link debt), **Debt &
  Interest**, **Settings** (claim token + sync).
- ✅ **Xcode project** — `project.yml` (XcodeGen) → single **multiplatform** app
  target (iOS + iPadOS + macOS) linking `TTMCore`. Verified: **macOS and iOS
  Simulator builds both succeed**. See [BUILD.md](BUILD.md). (`.xcodeproj`
  gitignored; `xcodegen generate` to recreate. Set your Team in Xcode to run on
  device.)
- ✅ **Design pass** ("The Statement") — `Theme.swift` design system: semantic
  palette (evergreen=assets, clay=debts), New York serif hero numerals, Eyebrow
  labels, BalanceBar + Sparkline signature, paper/surface cards across all
  screens. Sample-data loader (Settings → Load sample data, or `-sampleData`
  launch arg) + `-tab <name>` launch arg.
- ✅ **Live SimpleFIN path verified** against beta-bridge.simplefin.org demo:
  claim → `demo:demo` Access URL → `/accounts` decodes. Fixed `errlist`→`errors`
  key; `SimpleFINDecodeTests` guards the real shape. **26 tests pass.**
- ✅ **UX iterations**: account **rename** (display nickname, migration v3 — sync
  never overwrites it, ids unchanged so sync continues); **categorize
  auto-applies** on category tap (+ optional "Also create a rule" toggle); row
  **reflects new category immediately + glows**; **Spending month filter** (last
  6 months + All time chips, defaults to current month).
- ✅ **Categorization upgrade** (see [CATEGORIZATION_PLAN.md](plans/CATEGORIZATION_PLAN.md)) —
  **two-level categories** (groups → leaves; transactions on leaves), seeded grouped
  tree incl. new **Entertainment** group, reconciled idempotently by
  `DefaultData.ensureCategories` (adds structure to existing installs, never clobbers
  user edits); **auto-assigned colors** (`CategoryPalette`, deterministic least-used
  hue) shown as dots on txn rows + per-category Spending chart; **categorized /
  uncategorized filter** on Transactions (`TxnQuery.categorization`, backed by new
  `idx_txn_uncat`, migration **v4**) with count badge; **create-on-the-fly** in a
  grouped searchable categorize sheet; **Review mode** (guided one-at-a-time pass);
  **Categories manager** (rename/recolor/reorder/regroup/merge/delete-with-reassign,
  system-category guards). Facade gained full category CRUD + merge/reassign. +9 tests
  (`CategoryTests`).

- ✅ **Backup & restore** (see [DATA_PORTABILITY_PLAN.md](plans/DATA_PORTABILITY_PLAN.md)) —
  single-file `.ttmbackup` snapshots via `VACUUM INTO` (consistent, WAL-free,
  carries FTS + `grdb_migrations`); **replace-everything restore** behind a
  validation gauntlet (SQLite magic header → `quick_check` → required tables →
  migration-identifier subset check, so a newer-schema backup is refused rather
  than migrated backwards); **one generation of undo** (`ttm.db.pre-restore` +
  an "Undo last restore" row) and rollback if the swap or reopen fails; older
  backups re-migrate forward on reopen. `LocalCore` now holds its DB-bound
  internals in a swappable container so restore rebinds `Store`/`SyncEngine`/
  `Categorizer` in place — no relaunch. Settings gets Export/Restore rows with a
  summarize-before-you-replace sheet; UTType `money.trackthe.backup` declared via
  an `info:` block in `project.yml`. Secrets stay in the Keychain, so a backup
  never carries the SimpleFIN access URL. **12 new engine tests (51 total)** +
  2 UI smoke tests.

- ✅ **Profiles** (see [PROFILES_PLAN.md](plans/PROFILES_PLAN.md), ADR-0023) — several
  independent data sets on one device (`profiles/<id>/ttm.db` + `profiles.json`),
  switched in place from Settings; the pre-profiles store is adopted as "My data".
  New profile starts **Empty**, from **SimpleFIN's demo bank** (real claim + sync),
  or from **Sample data**; `test` profiles show a banner on every tab. A backup can
  be **opened as a new profile** (non-destructive) or replace the current one.
  **Connection status per profile:** connected / not linked on this device /
  needs re-auth / error / sample, with **Reconnect…** that re-links the *existing*
  connection (no duplicate accounts). Each profile owns its Keychain items (re-key on
  import; delete removes only unreferenced secrets). The SimpleFIN connection is
  still never in a file (ADR-0020 stands). `-profile <name>` launch arg.
  **14 new engine tests** (`ProfileTests`) + 2 UI tests (`ProfilesUITests`).
- ✅ **Full-screen on iOS 26+** — the Info.plist lacked `UILaunchScreen`, so the
  app ran letterboxed at 320×480; fixed in `project.yml`. This was the cause of the
  "flaky" `testSearchFiltersCategoryList` — all categorize UI tests now pass.

- ✅ **Account management** (see [ACCOUNT_MANAGEMENT_PLAN.md](plans/ACCOUNT_MANAGEMENT_PLAN.md),
  ADR-0024) — **manually tracked accounts** (Accounts → **+**: name, type, value,
  as-of date; tap to record a new value, with history you can prune), held under a
  hidden per-store "manual" connection that sync skips; values are balance
  snapshots so they feed the net-worth and debt charts. **Delete** for every
  account: manual/sample go outright; a synced one becomes a hidden tombstone
  (data removed, sync skips it) listed under "Deleted bank accounts" with *Sync
  again*. **Credit card** class (rolls up as unsecured debt; the guesser uses it
  for card names). **Interest rate (APR)** on debt accounts — shown on Accounts,
  editable from Accounts or Debt & Interest, whose new *Interest rates* section
  lists debts highest-rate first with a balance-weighted average. No migration
  (`apr_bps` and `archived` were already in v1). **14 new engine tests**
  (`AccountManagementTests`) + 2 UI tests (`AccountsUITests`).
- ✅ **Excluded and paused accounts** (ACCOUNT_MANAGEMENT_PLAN §7, ADR-0025) —
  migration **v5** adds `accounts.status` (`active | excluded | paused`) and
  `resync_from`; the old `excluded` *class* became the status. **Excluded**
  keeps syncing but leaves net worth, both series, spending, interest and
  property equity, and its transactions are hidden from every list, search,
  count and transfer match. **Paused** stops syncing and holds its last balance. Resuming
  or restoring a deleted account widens the next fetch (last balance − 7 days /
  the full 120-day backfill), so "Sync again" now brings history back. Opt-in
  **Hold new accounts for review** (Settings → SimpleFIN connection) makes
  accounts that appear later arrive excluded. Accounts groups *Paused* and
  *Excluded from totals*; swipe left / context menu toggles them. **10 new engine
  tests** (`AccountStatusTests`) + 1 UI test.
- ✅ **Credit-card promo APRs** ([PROMO_APR_PLAN.md](plans/PROMO_APR_PLAN.md),
  ADR-0026) — migration **v6** (`promo_apr_bps`, `promo_ends_on`). The rate sheet
  for a credit card takes a promo rate and its last day; while it lasts it is the
  card's effective rate (Accounts "0% until …", Debt & Interest order and
  weighted average). New **Promo payoffs** section on Debt & Interest: liquid cash
  applied to promos earliest-deadline first → covered / short by $X, the monthly
  payment to clear by the end date, and rough interest after. Pure math in
  `Interest/PromoPayoff.swift`. Next ideas (buffer, income-aware coverage, promo
  balance) in the plan's §5. **6 new engine tests** (`PromoAPRTests`) + 1 UI test.
- ✅ **Expected expenses (2026-11-26)** — new **This Month** tab
  (`docs/plans/EXPECTED_EXPENSES_PLAN.md`, ADR-0027). Big recurring bills
  (≥ $150 by default, seen in 2 of the last 3 months, at most ~1 charge a month)
  are expected on their usual day, knocked off when a charge from that merchant
  lands (including up to 5 days early), and flagged "not in yet" 2 days after
  their day. Totals: paid, still to come, all big bills this month. Remove an
  item per merchant (swipe / right-click), restore it from "Removed"; minimum
  and lookback in the toolbar menu. Pure engine in `Recurring/`; migration v7
  stores removals. Sample data gained four monthly bills and a stopped one.
  **20 new engine tests** (`ExpectedExpensesTests`) + 2 UI tests (iPhone).
  Mac: visual pass done on a throwaway profile (layout, right-click "Remove
  from expected", Removed section + Restore all behave; profile deleted after).
- ✅ **Monthly budget (2026-11-26)**: This Month is now the budget
  (`docs/plans/MONTHLY_BUDGET_PLAN.md`, ADR-0028).
  - **The month:** "Left this month", a split bar, splurge room, and "Can I
    afford it?", which draws on the category plan, then splurge room, then
    savings.
  - **Everyday spending:** per-category plans (3-month medians, pinned per
    month), a pace tick, and signed carry-over (on by default, per-category
    switch).
  - **Big bills** sit behind a row. The old list is now `BigBillsView`.
  - **Income per payer:** regular (biweekly, semimonthly or monthly detected),
    variable (lowest month or a typed estimate) or not budgeted. Late income is
    flagged.
  - **Saved purchases:** maybe, planned, bought (linked to its charge) or
    dropped, and they can be moved to next month.
  - **Plumbing:** migration v8; This Month moved to the 4th tab.
  - **Tests:** 20 new engine tests (`ExpectedIncomeTests`, `BudgetTests`,
    `BudgetFacadeTests`) and 3 UI tests (iPhone). The full iPhone suite passes
    (21, 1 live skipped).
  - **Mac pass (2026-11-27)** on a throwaway profile, since deleted. It found
    a real bug: the first compute pinned $0 plans when the store had no
    history yet (a profile opened before sample data loaded, or before a
    first sync), and every later month inherited them. Plans now pin only
    once the defaults have something in them (regression test in
    `BudgetFacadeTests`). Also fixed: the plan line in the history chart
    struck through the bar labels, and the carry card didn't fill the column.
- ✅ **Mac pass (2026-11-26)** of excluded/paused/hold and promos, run by hand-held
  XCUITest against a real store (demo profile + a throwaway profile on SimpleFIN's
  demo bank). It found two Mac-only bugs, both fixed: Debt & Interest reused
  account ids across List sections, so the macOS List showed a card's
  interest-paid row in place of its rate row (rows are now keyed per section);
  and a card with a promo but no regular rate couldn't save with the promo
  turned off.

### Next up (resume here)
1. 🟡 **Live SimpleFIN verification — engine done, app run remaining.**
   `TTMCoreTests/LiveSimpleFINTests` (opt-in, `TTM_LIVE=1`) now proves the whole
   path against a **real bridge over the real network**: claim a setup token →
   Access URL held outside the DB → `/accounts` with Basic auth → v2 decode →
   sync → snapshots → facade queries, plus exact decimal→cents on every real
   balance and amount, and no duplicate `(account_id, sfin_txn_id)` across
   re-syncs. Green on 3 consecutive runs.
   **Still to do:** run the actual app with a *signed* build and a real
   institution token. `LiveSimpleFINUITests` drives that flow but needs
   DEVELOPMENT_TEAM set — unsigned builds fail the Keychain write with `-34018`
   (`errSecMissingEntitlement`), so the claim never persists. Real-bank data is
   also what settles the per-institution debt-sign question (ADR-0012).
2. Scheduled background refresh (`BGAppRefreshTask` iOS / timer macOS) +
   per-connection sync status surfacing (needs_auth/error) in Settings.
3. Rule priority editing; "apply mode" choice on rule create. (Categories CRUD UI ✅ done.)
4. Local CSV/JSON export (deferred by D7a in DATA_PORTABILITY_PLAN; backup/restore shipped).
5. **Milestone 2** — paid cloud (`track-the-money-cloud`): Go relay + AI proxy +
   auth/billing; device-side `Crypto` (HPKE/CryptoKit) + `SyncClient`.
6. **Agent access** (planned, not started) — `ttm` CLI + `ttm mcp` local MCP
   server on TTMCore: read-only SQL over curated views plus computed tools.
   See `docs/plans/AGENT_ACCESS_PLAN.md`.

> Note: headless iOS Simulator screen capture went black mid-session (GPU/display
> state — app process confirmed running, no crash); Net Worth + Accounts shots
> rendered fine earlier. Build/test are the source of truth here.

## Milestone 2 — Paid cloud (private repo `track-the-money-cloud`)
Not started. Zero-knowledge encrypted relay (Go + Postgres): sync relay, public
-key directory, AI proxy, auth/billing. Device side: `Crypto` (HPKE/CryptoKit)
and `SyncClient` are stubs in TTMCore. Contract: `contract/openapi.yaml`.

## Notes / watch-items
- Debt-class balances: net worth takes `abs()` of liability balances (some
  institutions report debt negative). Verify against real SimpleFIN data.
- GRDB pinned `from: 6.29.0`; APIs used are 6.x (`busyMode`, `didInsert(_:)`,
  `MutablePersistableRecord`). `Database` is `@unchecked Sendable`.
- `App/` has no `.xcodeproj` (generate in Xcode, add local `TTMCore` package).
- A cleanly-closed store keeps `journal_mode=WAL` in its header and can't be
  opened read-only without its `-shm`; `BackupManager.inspect` falls back to a
  private copy. A copy taken while the app is running (content still in the
  `-wal`) is refused, not restored as empty.
- `CategorizeUITests/testSearchFiltersCategoryList` used to fail: the app was
  letterboxed (no `UILaunchScreen`) and rows sat under the tab bar. Passes since
  the launch-screen fix.
- Switching profiles mid-sync is blocked in `AppModel`, not the engine — revisit
  when background refresh (Next up #2) lands.
