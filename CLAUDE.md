# CLAUDE.md

Track The Money: a local-first personal finance app for iOS/macOS (SwiftUI).
Pulls bank data via SimpleFIN, stores everything in a local SQLite database
(GRDB), keeps the SimpleFIN access URL in the Keychain, and categorizes
transactions with deterministic rules plus an on-device AI suggestion seam
(Apple Foundation Models when available, heuristic fallback). No backend exists
yet; Milestone 2 (paid cloud relay) is unstarted — see `contract/openapi.yaml`.

## Repo layout

- `TTMCore/` — pure Swift package, the entire engine. `Sources/TTMCore/`:
  - `Money/` — `Money` value type; `Time/` — UTC unix-seconds helpers.
  - `Persistence/` — `Database` (GRDB, migrations), `Store` (DAO), `Records`,
    `DefaultData` (idempotent seed: categories tree + default interest rule).
  - `SimpleFIN/` — Codable protocol models + `LiveSimpleFINClient`.
  - `Sync/` — `SyncEngine` (idempotent upsert on `(account_id, sfin_txn_id)`,
    balance snapshots, pending→posted reconcile), `Transfers` auto-detection.
  - `Rules/` — condition tree + first-match-by-priority matcher.
  - `Classify/` — `Categorizer` pipeline, `AccountClass`, `CategoryPalette`,
    `OnDeviceCategorizer` protocol (+ `NoOpOnDeviceCategorizer`).
  - `NetWorth/`, `Interest/` — pure rollup/series math.
  - `Facade/` — `CoreFacade` protocol, `LocalCore` implementation,
    `SampleData` (demo seed, `LocalCore.loadSampleData()`).
  - `Crypto/`, `SyncClient/` — Milestone 2 stubs.
- `app/` — SwiftUI app, also an SPM package (headless `swift build`/`swift run`).
  `Sources/TrackTheMoney/`: `App.swift` (tabs + launch args), `AppModel.swift`
  (`@MainActor @Observable` over `CoreFacade`), `Theme.swift` ("The Statement"
  design system), `Features/` (one view per screen), `Platform/`
  (`KeychainSecretStore`, `URLSessionNetworkClient`,
  `FoundationModelsCategorizer`, `HeuristicOnDeviceCategorizer`).
- `app/UITests/` — XCUITest target (`CategorizeUITests.swift`).
- `project.yml` — XcodeGen spec (source of truth for the Xcode project).
- `docs/` — **all documentation lives here**; only `README.md` and `CLAUDE.md`
  stay at the repo root. `docs/IMPLEMENTATION_STATUS.md` (running status doc —
  update it when you land work; it's the resume pointer), `docs/PLAN.md`
  (product), `docs/TECH_DESIGN.md` (architecture), `docs/BUILD.md` (build
  matrix), `docs/README.md` (index of the above).
- `docs/plans/` — one design doc per substantial feature, written before
  implementation and kept as the record of what was decided. New plans go here
  as `<FEATURE>_PLAN.md`; don't put them at the repo root.
  - `CATEGORIZATION_PLAN.md` — shipped.
  - `DATA_PORTABILITY_PLAN.md` — backup/restore, **approved and unbuilt**
    (see "Next up" below).

## Architecture rules (do not break)

- **TTMCore stays pure.** No SwiftUI/UIKit/AppKit imports, no Apple ML
  frameworks, no direct Keychain/URLSession/Date. The OS is reached only through
  injected protocols: `Clock`, `SecretStore`, `NetworkClient`,
  `OnDeviceCategorizer` (all in `Support/Protocols.swift` and
  `Classify/OnDeviceCategorizer.swift`). Platform implementations live in
  `app/Sources/TrackTheMoney/Platform/` and are injected in `AppModel.live()`.
- **The app talks only to `CoreFacade`** — never GRDB, `Store`, `SyncEngine`, or
  the rules engine directly. This boundary is frozen to allow a future Rust core.
- **Money is `Int64` cents** (`Money` in `Money/Money.swift`). Never `Double`;
  parse decimal strings via `Decimal` with bankers rounding.
- **Liabilities are positive magnitudes** inside `NetWorth` math. Stored balances
  keep the bank's sign (some banks report debt negative); `LocalCore` and the
  series builders take `abs()` of debt-class balances at read time.
- **Series are step functions** — each account/property holds its last known
  value between snapshots; points are emitted at every change date.
- **Category model:** two levels, transactions always on leaves; a category with
  children is a group header and not assignable. System categories
  (`income`/`transfer`/`interest`/`uncategorized`) are guarded (no delete/regroup).
  Delete/merge must reassign transactions and repoint rules in app-mediated code
  — never rely on the FK cascade.
- **Colors are deterministic:** `CategoryPalette.nextColor` picks the least-used
  hue, ties by palette order; palette order must stay stable. No RNG.
- **AI suggestions are never auto-applied** — rules first, on-device model only
  on a rule miss, always surfaced for user confirmation.
- **Secrets:** the SimpleFIN access URL goes only in `SecretStore` (Keychain),
  never the DB. Nothing is sent to any backend.

## Build & test

```bash
cd TTMCore && swift test                 # engine tests (39, XCTest)
cd app && swift build                    # SwiftUI compiles headlessly (macOS host)
cd app && swift run TrackTheMoney        # run the Mac app from CLI
xcodegen generate                        # project.yml → TrackTheMoney.xcodeproj
xcodebuild -scheme TrackTheMoney -destination 'platform=macOS' build
xcodebuild test -scheme TrackTheMoney -only-testing:TrackTheMoneyUITests
```

- Scheme/target names: **TrackTheMoney** (app, multiplatform iOS 17+/macOS 14+),
  **TrackTheMoneyUITests**. One scheme, `TrackTheMoney`, builds and tests both.
- `TrackTheMoney.xcodeproj` is **gitignored** — regenerate with `xcodegen
  generate` after editing `project.yml`; never hand-edit the project.
- Launch arguments (read in `App.swift` / `AppModel.swift`):
  - `-sampleData` — load demo data at launch (also: Settings → Load sample data,
    which calls `LocalCore.loadSampleData()`).
  - `-tab <name>` — select a tab; tags: `networth accounts transactions spending
    categories rules realestate debt settings`.
  - `-resetStore` — delete the DB (`Application Support/TrackTheMoney/ttm.db`
    + wal/shm) before opening.
  - `-stubAI` — force `HeuristicOnDeviceCategorizer` (deterministic, for tests);
    `-noAI` — inject `NoOpOnDeviceCategorizer`.

## Testing conventions

- Engine: XCTest in `TTMCore/Tests/TTMCoreTests/` — pure, in-memory/temp-path,
  no UI. Add tests here for any Store/facade/math change.
- UI: XCUITest in `app/UITests/CategorizeUITests.swift`; each test launches with
  `["-resetStore", "-sampleData", "-tab", "transactions"]` (+ `-stubAI` where AI
  determinism matters) and drives real taps on the Simulator or Mac. macOS rows
  can render as single combined-label buttons — match by label substring.

## Next up: backup & restore (planned, not implemented)

`docs/plans/DATA_PORTABILITY_PLAN.md` is approved — all eight decisions
resolved, implement exactly as written. The shape:

- **Format:** single-file SQLite snapshot via `VACUUM INTO` through the live
  `DatabaseQueue` (consistent, WAL-free, carries FTS shadow tables and
  `grdb_migrations`). Extension `.ttmbackup`, exported UTType
  `money.trackthe.backup` declared via an `info:` block in `project.yml`.
- **New `CoreFacade` methods:** `exportBackup() -> URL`,
  `inspectBackup(at:) -> BackupInfo`, `restoreBackup(from:)`; mechanics in a new
  `Persistence/BackupManager.swift`. App layer owns only the pickers
  (`fileExporter`/`fileImporter` in `SettingsView`).
- **Restore = replace everything** (never merge): validate → safety-copy to
  `ttm.db.pre-restore` → close → swap → reopen (migrations re-run, so older
  backups upgrade for free) → `LocalCore` rebuilds its internals in place →
  `AppModel.refresh()`. Errors roll back from the safety copy.
- **Validation gauntlet before any swap:** SQLite magic header → `quick_check`
  → expected tables → migration identifiers are a subset of the known list
  (a newer-schema backup must be refused, not migrated backwards).
- **Secrets never enter the backup.** The SimpleFIN access URL is Keychain-only,
  so a new-device restore has all history but no working connection — the UX
  must route the user to re-paste a setup token.
- Deferred: CSV interop export, automatic/scheduled backups, iCloud beyond what
  the system pickers already offer.

## Gotchas

- Gitignored and regenerated: `*.xcodeproj/`, `Package.resolved`, `.build/`,
  `.build-xcode/`, `*.db`/`*.db-wal`/`*.db-shm`, `.env*`.
- GRDB is pinned `from: 6.29.0`; code uses 6.x APIs (`busyMode`,
  `didInsert(_:)`); `Database` is `@unchecked Sendable`.
- Migrations are append-only: v1 schema, v2 FTS5 (+triggers), v3 account
  nickname, v4 uncategorized partial index. Category tree/color seeding is NOT a
  migration — `DefaultData.ensureCategories` reconciles idempotently at startup
  and must never clobber user edits.
- SimpleFIN error payload key is `errors` (not `errlist`) — guarded by
  `SimpleFINDecodeTests`.
- Account rename is display-only (`nickname`); sync must never overwrite it.
- Test the live SimpleFIN path against `beta-bridge.simplefin.org` demo
  (`demo:demo`).
