# Data Portability Plan — Backup & Restore

> Companion to [PLAN.md](../PLAN.md) and [TECH_DESIGN.md](../TECH_DESIGN.md) §5/§13.
> Scope: let the user **save** their data to a file they own (export/backup) and
> **load** it back (import/restore) — on the same device or a new one — without
> breaking the CoreFacade boundary or TTMCore purity.
>
> **Status:** ✅ Shipped — Phase 1 (engine) and Phase 2 (Settings UI) implemented
> as specified; all §5 decisions resolved (2026-08-24, James). Phase 3 stays
> deferred by D6a/D7a. See §9 for what the implementation added beyond the plan.
> **Last updated:** 2026-08-25

---

## 1. Goal & non-goals

**Goal.** A user with months of irreplaceable local data (categorizations, rules,
snapshots, properties) can produce a single backup file via the Files app / save
panel, and later restore it — replacing the current store — including on a fresh
install on a new device.

**Non-goals (this phase):**

- **Merge on import.** Restore is replace-everything. Merging two databases
  (dedupe by `(account_id, sfin_txn_id)`, reconcile category trees, resolve
  conflicting manual categorizations) is a genuinely hard problem with little
  payoff for a single-user local app. Out of scope; the plan keeps the door open
  (see §3, option B rationale).
- **Continuous sync between devices** (that's Milestone 2's cloud relay).
- **Scheduled/automatic background backups** (candidate later phase — see D6).
- **Spreadsheet interop (CSV)** — deferrable, see D7.

---

## 2. Current-state findings (from the code)

### 2.1 The database is the whole state (minus one secret)

- Opened by `Database.init(path:)` —
  `TTMCore/Sources/TTMCore/Persistence/Database.swift:13-24`: GRDB 6.x
  `DatabaseQueue` (fully serialized access), `busyMode: .timeout(5)`,
  `foreignKeysEnabled`, `PRAGMA journal_mode = WAL`, `synchronous = NORMAL`.
  So on disk there are up to three files: `ttm.db`, `ttm.db-wal`, `ttm.db-shm`.
- Path: `Application Support/TrackTheMoney/ttm.db`, built in
  `AppModel.databasePath()` — `app/Sources/TrackTheMoney/AppModel.swift:363-377`.
  The same function honors `-resetStore` by deleting all three files before open
  — the existing precedent for "swap the store by manipulating files while no
  connection is open."
- Migrations (append-only): `v1_schema`, `v2_fts`, `v3_account_nickname`,
  `v4_uncat_index` — `Database.swift:34,160,184,191`. GRDB's `DatabaseMigrator`
  records applied identifiers in its own `grdb_migrations` table — that table
  travels with the file and is our schema-version marker (better than
  `PRAGMA user_version`, which GRDB's migrator does not use).
- Tables (all STRICT): `connections`, `accounts`, `balance_snapshots`,
  `categories`, `transactions`, `rules`, `properties`, `property_values`,
  `property_debts`, `payment_splits`, `settings` (currently unused), plus the
  FTS5 external-content table `transactions_fts` + 3 triggers (v2). FTS shadow
  tables are ordinary tables inside the same file — any whole-file copy carries
  them intact.
- `Database.inMemory()` (`Database.swift:26`) + temp-path DBs are the existing
  test idiom (`TTMCore/Tests/TTMCoreTests/`).

### 2.2 What is precious vs. re-syncable

"Just re-sync it" is **not** a recovery strategy here. SimpleFIN bridges return a
limited transaction window (often 90 days), and balance history exists only as
locally accumulated `balance_snapshots`. Practically **everything is precious**:

| Data | Re-syncable? | Notes |
|---|---|---|
| `transactions` older than the bridge window | ❌ | gone forever without backup |
| manual categorizations (`category_id`, `category_source`) | ❌ | user labor |
| `rules` | ❌ | user-authored |
| `categories` tree, colors, sort | ❌ | user-edited; `DefaultData.ensureCategories` only reconciles the default seed, never user edits |
| `accounts.class/nickname/apr_bps/archived` | ❌ | user-set (sync never touches nickname) |
| `balance_snapshots` (net-worth history) | ❌ | accumulated over time, drives every chart |
| `properties`, `property_values`, `property_debts` | ❌ | fully manual |
| `payment_splits` | ❌ | manual principal/interest splits |
| recent `transactions` + current balances | ✅ | next sync repopulates |
| `connections` rows | ⚠️ | rows restore, but `keychain_ref` points at a Keychain item that does not exist on a new device — see §2.3 |

### 2.3 The one secret is outside the DB (by design)

The SimpleFIN access URL lives only in the Keychain
(`KeychainSecretStore` in `app/Sources/TrackTheMoney/Platform/`), referenced by
`connections.keychain_ref` (written in `LocalCore.claimSetupToken`,
`TTMCore/Sources/TTMCore/Facade/LocalCore.swift:34-62`). A backup restored on a
new device therefore has all accounts/transactions/history but **no working
connection** — `SyncEngine.run()` will fail to read the secret for each
connection. The restore UX must say so and route the user to "paste a new
SimpleFIN setup token" (SimpleFIN tokens are re-issuable; claiming a new one
creates a new connection — see §5 Phase 2 for how restored orphan connections
are handled).

### 2.4 App lifecycle facts that shape restore

- `App.swift:6` creates the model once: `@State private var model: AppModel? =
  try? AppModel.live()`. `AppModel` (`@MainActor @Observable`) holds one
  `LocalCore`, which owns the `DatabaseQueue` for the process lifetime. There is
  no close/reopen path today.
- `LocalCore.init` (`LocalCore.swift:19-30`) wires `Store`, `SyncEngine`,
  `Categorizer` around the `Database` as `let` properties — a restore that swaps
  the DB file must either rebuild these internals or rebuild `LocalCore` itself.
- There is **no background sync or timer** anywhere in the app (the Settings
  copy "Auto-sync runs weekly" is aspirational). All writes happen inside
  explicit user actions, and `DatabaseQueue` serializes everything — so a
  consistent snapshot only has to queue behind any in-flight write; no
  app-level write-freeze is needed.
- Settings UI lives in `app/Sources/TrackTheMoney/Features/SettingsView.swift`
  (Form with sections; the natural home for a "Backup" section).
- `project.yml` uses `GENERATE_INFOPLIST_FILE: YES` with `INFOPLIST_KEY_*`
  settings only — declaring a custom document type (UTType) requires adding an
  `info:` properties block (XcodeGen supports this) for
  `UTExportedTypeDeclarations` + `CFBundleDocumentTypes`.

### 2.5 GRDB / SQLite snapshot mechanics (verify exact API names at impl time)

Three candidate mechanisms for "one consistent file from a live WAL database":

1. **`VACUUM INTO '<path>'`** (SQLite ≥ 3.27; the system SQLite on iOS 17/macOS
   14 is well past that). Run through the queue, it produces a single,
   checkpointed, defragmented, WAL-free copy — FTS shadow tables included — while
   holding only a read snapshot. Caveat: VACUUM cannot run inside a transaction,
   so it must go through `writeWithoutTransaction` (or GRDB's `vacuum(into:)`
   convenience if present in 6.29 — verify).
2. **GRDB `backup(to:)`** (SQLite Online Backup API): `sourceQueue.backup(to:
   destQueue)`. Works, but requires opening a destination connection and still
   copies WAL layout; more moving parts than (1) for zero benefit here.
3. **Checkpoint + file copy** (`PRAGMA wal_checkpoint(TRUNCATE)` then copy
   `ttm.db`): racy unless writes are externally blocked; strictly worse than (1).

**Use (1).** One SQL statement, atomic result, smallest output file.

---

## 3. Format options

### A. Raw SQLite snapshot (`VACUUM INTO`), custom extension — **recommended**

- ✅ Perfect fidelity by construction: every table, every column, FTS index,
  `grdb_migrations` — nothing can be "forgotten" per migration.
- ✅ Trivial, fast restore: validate → swap file → reopen → migrations re-run
  (older backups upgrade themselves via the exact same migrator that upgrades
  the live DB on app update — zero extra code).
- ✅ ~Zero maintenance: future migrations v5, v6… need no export-code changes.
- ✅ Matches the Rust-port constraint: rusqlite reads the same file verbatim.
- ❌ Opaque to the user (not human-readable) — mitigated by D7 (CSV later).
- ❌ Newer-schema backup into an older app cannot be migrated backwards — must
  detect and refuse (see §4.3). This exists for JSON too; SQLite just makes it
  explicit.

### B. Schema-versioned JSON export

- ✅ Inspectable/diffable; could later power selective import or merge.
- ❌ Must exhaustively enumerate every table/column and be updated **in
  lockstep with every migration** — the classic silent-data-loss trap (forget
  `payment_splits` once and backups are quietly incomplete).
- ❌ Restore requires a full re-serialization path (ordering for FK integrity,
  FTS rebuild) — several times the code of option A for a worse guarantee.
- ❌ Larger files, slower for years of transactions.
- Verdict: wrong tool for *backup*. Right tool for *interop*, later (D7).

### C. Both (SQLite backup now + CSV/JSON interop later)

- The pragmatic combination: A is the backup format this phase; a read-only
  transactions CSV export is a small, independent later phase. Recommended
  sequencing, gated by D7.

### D. Zip container (manifest.json + ttm.db)

- ✅ Room for a manifest (app version, date, device name) and future extras.
- ❌ Adds an archive dependency (no zip API in Foundation proper on iOS),
  double the code, and the manifest duplicates what `grdb_migrations` +
  `PRAGMA` queries already tell us from the SQLite file itself.
- Verdict: not worth it now. The format can evolve to a container later —
  restore already sniffs the file type (SQLite magic header), so a future
  container format is detectable and backward compatibility is preservable.

**Recommendation: A** (single SQLite file via `VACUUM INTO`, `.ttmbackup`
extension), with C's CSV as a deferred follow-up.

---

## 4. Cross-cutting design

### 4.1 Consistency during export

`VACUUM INTO` runs on the `DatabaseQueue` → it serializes behind any in-flight
sync write and produces a point-in-time snapshot. No app-level coordination
needed. Export writes to a temp file in the app container
(`Application Support/TrackTheMoney/export-<timestamp>.ttmbackup` or
`FileManager.temporaryDirectory`), then the app layer hands that URL to
`fileExporter`/`ShareLink` and deletes the temp after completion/cancel.

### 4.2 Restore semantics (replace-everything)

Sequence (all inside TTMCore except the picker):

1. **Validate** the incoming file (§4.4) by opening it read-only at a temp path.
2. **Safety copy** the current store: move `ttm.db` (+`-wal`/`-shm`) to
   `ttm.db.pre-restore` (overwrite any previous one — keep exactly one undo
   generation; see D5).
3. **Close** the live connection (GRDB `DatabaseQueue.close()` — verify name in
   6.29; fallback: tear down the `LocalCore` internals so the queue deinits).
4. **Swap**: copy the validated file to `ttm.db`; ensure no stale `-wal`/`-shm`
   remain (the backup is WAL-free by construction).
5. **Reopen** via `Database(path:)` — migrations re-run, upgrading an older
   backup to current schema; `DefaultData.seedIfEmpty` reconciles system
   categories as on any launch.
6. **Rebuild** engine internals on the new DB and let the app `refresh()`.

In-memory state: `AppModel.refresh()` (`AppModel.swift:70-88`) already reloads
every published property from the facade — after restore the app calls it and
every screen updates. No relaunch required *if* the facade can rebuild its
internals (D3 decides the mechanism).

Failure handling: any error after step 3 restores the safety copy back to
`ttm.db` and reopens, so the user never ends up with no database.

### 4.3 Schema-version compatibility

- **Older backup → current app:** supported automatically. Migrations re-run on
  reopen (append-only guarantee, `Database.swift:34-196`).
- **Newer backup → older app:** must refuse. Detection: read the incoming
  file's `grdb_migrations` identifiers and reject if any identifier is unknown
  to the running migrator. GRDB 6 has `DatabaseMigrator.hasBeenSuperseded(_:)`
  for exactly this (verify availability in 6.29; a manual
  `SELECT identifier FROM grdb_migrations` set-difference is a trivial
  fallback). Error copy: "This backup was made by a newer version of Track The
  Money. Update the app, then restore."

### 4.4 Import validation (never blindly swap a file in)

Checks, in order, against the picked file copied to a temp path:

1. Size sanity (> 0, < some generous cap) and SQLite magic header
   (`SQLite format 3\0` — first 16 bytes).
2. Opens with GRDB read-only, `PRAGMA quick_check` returns `ok`.
3. Expected tables present (`sqlite_master` contains `accounts`,
   `transactions`, `categories`, `grdb_migrations`, …).
4. Migration identifiers are a subset of the known list (§4.3).

Failures produce specific, user-readable errors ("not a Track The Money
backup", "backup is damaged", "backup requires a newer app").

### 4.5 Secrets policy

The backup **never contains the SimpleFIN access URL** (it isn't in the DB, so
option A gets this for free — and we keep it that way; see D8). Consequences:

- Same-device restore: Keychain items survive, `keychain_ref`s still resolve —
  sync keeps working. Nice.
- New-device restore: connections exist but their secrets don't. Post-restore
  UX: if any connection's secret is unreadable, show "Reconnect SimpleFIN"
  guidance in Settings status. Claiming a new token creates a new connection;
  the old orphaned connection's accounts keep their history. (Deduping a
  re-claimed connection onto orphaned accounts is a merge-shaped problem —
  explicitly deferred; the simple story is acceptable: history preserved,
  reconnect to resume syncing.)

### 4.6 Where the code lands (CoreFacade boundary)

- **TTMCore** (pure — file I/O via Foundation is fine, no platform imports):
  - `CoreFacade` gains:
    ```swift
    /// Write a consistent single-file snapshot of the store; returns its URL.
    func exportBackup() async throws -> URL
    /// Inspect a candidate backup without touching the live store.
    func inspectBackup(at url: URL) async throws -> BackupInfo   // counts, dates, schema verdict
    /// Replace the store with the validated backup (keeps a one-level undo copy).
    func restoreBackup(from url: URL) async throws
    ```
  - `LocalCore` implements them; the DB-swap mechanics live in a small
    `Persistence/BackupManager.swift` (validate / safety-copy / swap / reopen).
  - `BackupInfo` (new value type): account/transaction/rule counts, newest
    transaction date, schema compatibility verdict — powers the confirm sheet.
- **App layer** (`SettingsView` + `AppModel`): pickers only.
  `fileExporter`/`ShareLink` for save, `fileImporter` for load, confirmation
  dialog rendering `BackupInfo`, post-restore `await model.refresh()`.
  (On iOS 17/macOS 14, `fileExporter(isPresented:item:contentTypes:defaultFilename:)`
  with a `Transferable` `FileRepresentation` of the exported URL avoids loading
  the file into memory; a `FileDocument` wrapper is the fallback. Verify the
  exact overload at impl time.)
- **`project.yml`**: `info:` block declaring the exported UTType (D2) so Files
  app/Finder associate the extension. Caveat: the headless `swift run` app has
  no Info.plist — the custom UTType only fully registers in the XcodeGen build;
  the code paths must not depend on registration succeeding.

---

## 5. Decisions (RESOLVED 2026-08-24)

All eight resolved by James to the starred defaults — implement exactly these:
**D1a** SQLite `VACUUM INTO` · **D2a** `.ttmbackup` UTType · **D3a** in-place
`LocalCore` rebuild · **D4a** inspect-and-summarize sheet · **D5a** keep
`ttm.db.pre-restore` + "Undo last restore" row · **D6a** manual pickers only ·
**D7a** CSV deferred · **D8a** secrets never in backup.

Original options preserved below for rationale; recommended default marked ★.

**D1. Backup format**
- a) ★ Raw SQLite snapshot via `VACUUM INTO` (§3A) — perfect fidelity, near-zero
  maintenance, restore = file swap + re-migrate.
- b) Schema-versioned JSON (§3B) — inspectable, but per-migration maintenance
  and silent-omission risk.
- c) Zip container (manifest + db) (§3D) — extensible, but adds an archive
  dependency for metadata the DB already carries.

**D2. File extension / UTType**
- a) ★ `.ttmbackup`, exported UTType `money.trackthe.backup` conforming to
  `public.data` (+ `public.database`) — discourages users (and other apps) from
  opening it casually; clean Files-app identity.
- b) `.sqlite`/`.db` — power users can open it in any SQLite tool directly, but
  it invites accidental edits and generic-handler confusion.
- (Either way, import validation is by content, not extension — §4.4.)

**D3. Restore mechanism (how the live connection gets replaced)**
- a) ★ In-place: `LocalCore` rebuilds its internals (`Database`/`Store`/
  `SyncEngine`/`Categorizer` become a swappable inner container behind the same
  facade instance); the app just calls `refresh()`. Seamless UX; touches
  `LocalCore`'s `let` wiring (`LocalCore.swift:5-30`).
- b) App-level rebuild: facade only swaps files; `App.swift` re-runs
  `AppModel.live()` and reassigns the `@State` model. Keeps LocalCore immutable,
  but restore logic leaks into the app layer and every view's identity resets.
- c) Prompt "restart the app to finish restoring" — simplest code, worst UX;
  also awkward on iOS (apps can't quit themselves gracefully).

**D4. Restore confirmation UX**
- a) ★ Show a summary sheet from `inspectBackup` ("Backup from Aug 12, 2026 —
  5 accounts, 1,204 transactions. This replaces all current data.") with an
  explicit destructive-style confirm.
- b) Plain confirmation dialog, no file inspection first (less code, less trust).

**D5. Automatic safety copy before restore**
- a) ★ Always keep one `ttm.db.pre-restore` (silent, auto-overwritten each
  restore) + a Settings "Undo last restore" row that appears only when it
  exists. Bounded disk cost, real undo.
- b) Safety copy used only for mid-restore failure rollback, deleted on
  success — no user-facing undo.
- c) Prompt "export current data first?" before restoring — explicit but naggy.

**D6. iCloud / Files integration scope (this phase)**
- a) ★ Manual export/import via system pickers only — the user can already
  choose iCloud Drive as the destination in the picker; no entitlement or
  scheduling work.
- b) Also add periodic automatic backup to an app-chosen location
  (security-scoped bookmark or iCloud container) — real value, but scheduling,
  entitlements, and retention policy make it its own phase. Defer.

**D7. CSV/JSON interop export (spreadsheets)**
- a) ★ Defer to a later phase (transactions CSV is small and independent —
  `Store.transactions` already returns everything needed).
- b) Include a transactions-CSV export alongside backup in this phase.

**D8. Secrets in the backup**
- a) ★ Never. The access URL grants read access to all linked bank accounts;
  a backup file at rest in Files/iCloud must not carry it. New-device cost is
  one re-pasted SimpleFIN token (§4.5).
- b) Optionally embed secrets encrypted under a user passphrase — full
  one-file migration, but adds a crypto surface, passphrase UX, and a reason
  the backup file becomes sensitive. Not recommended for a v1.

---

## 6. Implementation phases

### Phase 1 — Engine: export/import in TTMCore

- `TTMCore/Sources/TTMCore/Persistence/BackupManager.swift` (new):
  - `export(db:to:)` → `VACUUM INTO` through the queue (verify
    `writeWithoutTransaction` vs `vacuum(into:)` in GRDB 6.29).
  - `inspect(at:)` → §4.4 checks + counts → `BackupInfo`.
  - `restore(from:into path:)` → safety-copy, swap, reopen, rollback-on-error.
- `Database.swift`: expose whatever close/reopen hook D3a needs (e.g.
  `close()` passthrough); add the known-migration-identifiers list for §4.3.
- `Facade/CoreFacade.swift`: add `exportBackup()`, `inspectBackup(at:)`,
  `restoreBackup(from:)` + `BackupInfo`.
- `Facade/LocalCore.swift`: implement per D3 (a: internal engine container
  rebuilt after swap).
- Tests (`TTMCore/Tests/TTMCoreTests/BackupTests.swift`, new):
  - Round-trip: seed temp DB → export → restore into second path → row-for-row
    equality on every table.
  - Export is WAL-free and passes `quick_check`.
  - Restore of a "v1-only" fixture re-migrates to v4 (build fixture by running
    a truncated migrator).
  - Reject: garbage file, valid-SQLite-wrong-schema, unknown migration
    identifier (newer-app simulation).
  - Mid-restore failure rolls back to the safety copy.

### Phase 2 — App: Settings UI + pickers

- `SettingsView.swift`: new "Backup" section — "Export backup…" and
  "Restore from backup…" rows, D4 confirm sheet, D5 undo row, post-restore
  status line (including the reconnect-SimpleFIN notice when a restored
  connection's secret is unreadable).
- `AppModel.swift`: `exportBackup()`, `restoreBackup(from:)` wrappers
  (set `statusMessage`, call `refresh()` after restore).
- `project.yml`: `info:` block with `UTExportedTypeDeclarations` /
  `CFBundleDocumentTypes` for D2; regenerate with `xcodegen generate`.
- Temp-file hygiene: delete exported temp after the exporter completes/cancels.

### Phase 3 (deferred, gated on D6/D7)

- Transactions CSV export (`ShareLink`, no import path).
- Automatic periodic backup + retention.

---

## 7. Test plan

- **Unit (TTMCore)**: everything in Phase 1's list — this is where the real
  guarantees live; all pure/temp-path per repo convention.
- **UI (XCUITest, `app/UITests/`)**: optional smoke — launch with
  `-resetStore -sampleData`, export via a test-only launch-arg path that skips
  the system save panel (system pickers aren't automatable), restore the same
  file, assert an account row still shows. If picker-skipping hooks feel like
  test-only surface creep, skip UI tests and rely on unit coverage (the picker
  code is thin).
- **Manual matrix**: macOS save/open panels; iOS Files app + iCloud Drive
  destination; same-device restore (sync still works — Keychain intact);
  simulated new-device restore (delete Keychain item → verify reconnect
  messaging); restore-of-newer-backup refusal (hand-edit `grdb_migrations` in
  a copy).

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Data loss during restore (crash mid-swap) | Safety copy before swap; rollback path; atomic `FileManager` replace; never delete the incoming file |
| Restoring an arbitrary/corrupt file | §4.4 validation gauntlet; content sniffing, `quick_check`, schema/table checks |
| Newer-schema backup silently misbehaving in older app | Migration-identifier check refuses with actionable copy (§4.3) |
| GRDB API drift (`vacuum(into:)`, `close()`, `hasBeenSuperseded`) | All flagged "verify at implementation time"; each has a plain-SQL/deinit fallback |
| Live connection not fully closed before swap (macOS file locks) | Explicit close + reopen sequencing owned by `BackupManager`; test on both platforms |
| `LocalCore` internal rebuild (D3a) introduces a torn state | Rebuild is atomic behind the facade's async method; the queue is closed first so no concurrent reads can hit the old store |
| User expects backup to restore bank *connection* on new device | Explicit post-restore messaging (§4.5); Settings copy on the export row: "Backups don't include your SimpleFIN connection" |
| Backup file left in temp dir | Delete on exporter completion/cancel; temp dir is OS-purged anyway |
| Future container/format change | Restore sniffs content (§4.4), so a later zip/manifest format is detectable and old `.ttmbackup` files stay restorable |

---

## 9. Implementation notes (2026-08-25)

Built as specified. Three things the plan didn't anticipate, all test-driven:

- **Read-only opens can fail on a valid store.** A cleanly-closed database still
  carries `journal_mode=WAL` in its header, and SQLite refuses a read-only open
  when the `-shm` sidecar is absent. Our own exports are WAL-free so the fast
  path holds, but a store copied by hand hit this. `inspect` now falls back to
  validating a private copy rather than reporting a good file as damaged
  (`BackupManager.openForReading`).
- **A copy taken from a running app is refused.** Grabbing `ttm.db` while the
  app is open leaves its contents behind in the `-wal`; the copy looks
  schema-less. The table check catches it, so the user gets "not a Track The
  Money backup" instead of a silently empty restore.
- **`Database.migrator` is now built through a `register` helper** so tests can
  truncate it (`migrator(through:)`) and build a genuine v1-era fixture to
  restore. This replaced the plan's vaguer "build fixture by running a truncated
  migrator".

GRDB 6.29.3 API names were all verified against the vendored source before use:
`vacuum(into:)`, `DatabaseQueue.close()`, `DatabaseMigrator.migrations` /
`appliedIdentifiers(_:)`. `hasBeenSuperseded(_:)` exists too, but `inspect`
computes the unknown-identifier set directly so the error can name the offending
migrations.

Phase 2 declares the UTType through an `info:` block in `project.yml`; the
generated partial plist merges with `GENERATE_INFOPLIST_FILE`, verified by
reading `UTExportedTypeDeclarations` back out of the built app bundle.

**Not built (unchanged decisions):** CSV export (D7a), automatic/scheduled
backups (D6a), merge-on-import (§1 non-goal). One known gap: the post-restore
"reconnect SimpleFIN" guidance is shown unconditionally rather than only when a
restored connection's secret is actually missing — the facade has no
connection-listing method to check against, and adding one wasn't in scope.

