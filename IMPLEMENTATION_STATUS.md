# Implementation Status

Resume pointer for Track The Money. See [PLAN.md](PLAN.md) (product) and
[TECH_DESIGN.md](TECH_DESIGN.md) (architecture). Verified on macOS with the
Swift 6.3 toolchain.

**Build & test:**
- Core: `cd TTMCore && swift build && swift test` — **25 tests passing, 0 warnings**.
- App: `cd app && swift build` (or `swift run TrackTheMoney` on macOS) — builds clean.

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

### Next up (resume here)
1. ⏭️ Scheduled background refresh (`BGAppRefreshTask` iOS / timer macOS) +
   per-connection sync status surfacing (needs_auth/error) in Settings.
2. Categories CRUD UI; rule priority editing; "apply mode" choice on rule create.
3. Local CSV/JSON export.
4. Run live on Simulator/device with a real SimpleFIN token; fix runtime issues.
5. **Milestone 2** — paid cloud (`track-the-money-cloud`): Go relay + AI proxy +
   auth/billing; device-side `Crypto` (HPKE/CryptoKit) + `SyncClient`.

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
