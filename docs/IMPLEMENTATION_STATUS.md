# Implementation Status

Resume pointer for Track The Money. See [PLAN.md](PLAN.md) (product) and
[TECH_DESIGN.md](TECH_DESIGN.md) (architecture). Verified on macOS with the
Swift 6.3 toolchain.

**Build & test:**
- Core: `cd TTMCore && swift build && swift test` — **39 tests passing, 0 warnings**.
- App: `cd app && swift build` (or `swift run TrackTheMoney` on macOS) — builds clean.
- UI tests: `xcodebuild test -scheme TrackTheMoney -only-testing:TrackTheMoneyUITests`
  (XCUITest target `app/UITests`) — drives the categorize/create/review/promotion + AI
  suggestion flows on the Simulator; **5 passing**. (Launch args: `-resetStore` for a clean
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

### Next up (resume here)
1. ⏭️ Run live on Simulator/device with a real SimpleFIN token (Settings → paste
   setup token). The network path is verified; this is the end-to-end proof.
2. Scheduled background refresh (`BGAppRefreshTask` iOS / timer macOS) +
   per-connection sync status surfacing (needs_auth/error) in Settings.
3. Rule priority editing; "apply mode" choice on rule create. (Categories CRUD UI ✅ done.)
4. Local CSV/JSON export (deferred by D7a in DATA_PORTABILITY_PLAN; backup/restore shipped).
5. **Milestone 2** — paid cloud (`track-the-money-cloud`): Go relay + AI proxy +
   auth/billing; device-side `Crypto` (HPKE/CryptoKit) + `SyncClient`.

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
- ⚠️ `CategorizeUITests/testSearchFiltersCategoryList` fails (category picker not
  rendering in time). Pre-existing — confirmed failing before the backup work.
