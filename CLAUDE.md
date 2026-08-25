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
    `DefaultData` (idempotent seed: categories tree + default interest rule),
    `BackupManager` (.ttmbackup export/validate/restore).
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
- `app/UITests/` — XCUITest target (`CategorizeUITests`, `BackupUITests`).
- `project.yml` — XcodeGen spec (source of truth for the Xcode project).
- `docs/` — **all documentation lives here**; only `README.md` and `CLAUDE.md`
  stay at the repo root. `docs/IMPLEMENTATION_STATUS.md` (running status doc —
  update it when you land work; it's the resume pointer), `docs/PLAN.md`
  (product), `docs/TECH_DESIGN.md` (architecture), `docs/BUILD.md` (build
  matrix), `docs/README.md` (index of the above).
- `docs/adr/` — **one Architecture Decision Record per decision** (`NNNN-slug.md`,
  indexed in `docs/adr/README.md`). Read these first for *why* the code is shaped
  the way it is; the "Architecture rules" below are the enforcement, the ADRs are
  the reasoning. **Records are immutable** — when a decision changes, add a new
  ADR that supersedes or amends the old one; never rewrite one. Copy
  `docs/adr/TEMPLATE.md` and take the next number.
- `docs/plans/` — one design doc per substantial feature, written before
  implementation and kept as the record of what was decided. New plans go here
  as `<FEATURE>_PLAN.md`; don't put them at the repo root. A plan's locked
  decisions should graduate into ADRs once the feature ships.
  - `CATEGORIZATION_PLAN.md` — shipped.
  - `DATA_PORTABILITY_PLAN.md` — backup/restore, shipped (see below); its §9
    records what implementation turned up that the plan didn't foresee.

## Architecture rules (do not break)

Each rule below is the enforcement of a recorded decision — the bracketed ADR has
the reasoning and the cost. If a rule seems wrong, read its ADR before changing
anything; if it *is* wrong, write a superseding ADR rather than quietly breaking it.

- **TTMCore stays pure.** [[ADR-0006](docs/adr/0006-ttmcore-pure-package.md)] No SwiftUI/UIKit/AppKit imports, no Apple ML
  frameworks, no direct Keychain/URLSession/Date. The OS is reached only through
  injected protocols: `Clock`, `SecretStore`, `NetworkClient`,
  `OnDeviceCategorizer` (all in `Support/Protocols.swift` and
  `Classify/OnDeviceCategorizer.swift`). Platform implementations live in
  `app/Sources/TrackTheMoney/Platform/` and are injected in `AppModel.live()`.
- **The app talks only to `CoreFacade`** [[ADR-0007](docs/adr/0007-corefacade-boundary.md)] — never GRDB, `Store`, `SyncEngine`, or
  the rules engine directly. This boundary is frozen to allow a future Rust core.
- **Money is `Int64` cents** [[ADR-0010](docs/adr/0010-money-and-time-conventions.md)] (`Money` in `Money/Money.swift`). Never `Double`;
  parse decimal strings via `Decimal` with bankers rounding.
- **Liabilities are positive magnitudes** [[ADR-0012](docs/adr/0012-net-worth-rollup-rules.md)] inside `NetWorth` math. Stored balances
  keep the bank's sign (some banks report debt negative); `LocalCore` and the
  series builders take `abs()` of debt-class balances at read time.
- **Series are step functions** — each account/property holds its last known
  value between snapshots; points are emitted at every change date.
- **Category model:** [[ADR-0015](docs/adr/0015-two-level-categories.md)] two levels, transactions always on leaves; a category with
  children is a group header and not assignable. System categories
  (`income`/`transfer`/`interest`/`uncategorized`) are guarded (no delete/regroup).
  Delete/merge must reassign transactions and repoint rules in app-mediated code
  — never rely on the FK cascade.
- **Colors are deterministic:** [[ADR-0016](docs/adr/0016-deterministic-category-colors.md)] `CategoryPalette.nextColor` picks the least-used
  hue, ties by palette order; palette order must stay stable. No RNG.
- **AI suggestions are never auto-applied** [[ADR-0017](docs/adr/0017-three-tier-categorization.md)] — rules first, on-device model only
  on a rule miss, always surfaced for user confirmation.
- **Secrets:** [[ADR-0013](docs/adr/0013-access-url-keychain-only.md)] the SimpleFIN access URL goes only in `SecretStore` (Keychain),
  never the DB. Nothing is sent to any backend.

## Build & test

```bash
cd TTMCore && swift test                 # engine tests (51, XCTest)
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
- UI: XCUITest in `app/UITests/`; each test launches with
  `["-resetStore", "-sampleData", "-tab", "<tab>"]` (+ `-stubAI` where AI
  determinism matters) and drives real taps on the Simulator or Mac. macOS rows
  can render as single combined-label buttons — match by label substring. On
  iPhone the app's 9 tabs collapse into "More", and `Form` rows render lazily —
  scroll `app.collectionViews.firstMatch`, not the app window, to reach rows
  below the fold (see `BackupUITests.scrollTo`).
- Known-flaky before this work: `CategorizeUITests/testSearchFiltersCategoryList`
  fails on the category picker not rendering in time. Unrelated to backup.

## Backup & restore (shipped)

Per `docs/plans/DATA_PORTABILITY_PLAN.md`; phases 1–2 implemented. The shape:

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
- Gotcha found in testing: a cleanly-closed store is still WAL-mode and can't be
  opened read-only without its `-shm`, so `inspect` falls back to a private copy.
  A copy taken while the app was running (content still in the `-wal`) is
  correctly refused rather than restored as empty.

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
