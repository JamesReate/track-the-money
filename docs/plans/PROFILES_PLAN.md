# Profiles Plan — Switchable data sets, with an optional portable connection

> Companion to [DATA_PORTABILITY_PLAN.md](DATA_PORTABILITY_PLAN.md) (backup &
> restore, shipped) and [TECH_DESIGN.md](../TECH_DESIGN.md).
> Scope: keep several independent data sets ("profiles") on one device and switch
> between them instantly; let a `.ttmbackup` file be **loaded as a profile**; and
> let that file **optionally** carry its SimpleFIN connection so loading it is
> enough to keep syncing.
>
> **Status:** ✅ Shipped 2026-11-25 — layers A + B plus connection visibility
> (§4.7); **layer C (portable connection) dropped**, so ADR-0013 and ADR-0020
> stand unchanged. Decisions recorded in ADR-0023; see §8 for what
> implementation changed.
> **Last updated:** 2026-11-25

---

## 1. Goal & non-goals

**Goal.** Make it cheap to move between finance data sets and setups, most often
**test vs. real**: a real-bank profile, a SimpleFIN-demo profile, a sample-data
profile, a scratch copy for trying out rules. Loading a file should leave you
ready to keep working. If the file carries a connection, sync works right away.
If it doesn't (a test file usually won't), the profile still opens fine and
simply has no connection, or one that needs re-linking.

**Non-goals:**

- **Merge between profiles.** Each profile is a separate database, and loading a
  file never merges (ADR-0019 still holds).
- **Running two profiles at once.** One profile is active; the others sit
  closed on disk.
- **Cross-device sync.** That's Milestone 2. A portable file is a one-shot
  handoff, not sync.
- **Automatic or scheduled backups** (still deferred by ADR-0020).

---

## 2. Current-state findings (from the code)

- **One fixed store path.** `AppModel.databasePath()` hard-codes
  `Application Support/TrackTheMoney/ttm.db`. `-resetStore` deletes that file and
  its `-wal`/`-shm`.
- **`LocalCore` can already rebind to a new file in place.**
  `rebuildInternals()` (added for restore) rebuilds `Store`/`SyncEngine`/
  `Categorizer` behind the unchanged facade. Switching profiles is the same
  operation pointed at a different path. The only change is that `dbPath` must
  become mutable (it's a `let` today), guarded by the existing `internalsLock`.
- **Secrets are keyed per connection, not per store.**
  `claimSetupToken` writes the Access URL under `conn-<UUID>` and the DB stores
  only that `keychain_ref`. Restore never touches the Keychain. So on the **same
  device**, a profile's connection keeps working however many times you switch
  away and back, with no secret in any file. That covers most of test-vs-real.
- **The only gap the file has to fill is a new device or a fresh install**, where
  the `keychain_ref` points at nothing. That's the one case that needs the secret
  in the file (§4.4).
- **No facade method lists connections.** That's why the post-restore "reconnect
  SimpleFIN" notice shows unconditionally (DATA_PORTABILITY_PLAN §9, known gap).
  Profiles need this method anyway to show each profile's connection state, so
  this plan closes that gap.
- **Backup validation tolerates extra tables.** `BackupManager.inspect` checks
  that `requiredTables` are present, not that nothing else is, so an extra
  bundle table in the file (§4.4) won't trip the validation steps.

---

## 3. Shape of the solution

Three layers, each useful without the next:

| Layer | What it gives you | Secrets in a file? |
|---|---|---|
| **A. Profiles** | Several named data sets on this device; one-tap switch; each keeps its own working connection | No |
| **B. Load file as profile** | Open any `.ttmbackup` as a *new* profile instead of replacing the current one | No |
| **C. Portable connection (opt-in)** | Export can include the connection, sealed under a passphrase; loading the file restores the connection into the Keychain | Yes, encrypted and opt-in |

A + B already cover "switch between test and real accounts" on one device. C is
what makes "load your file and you're ready" true on another device.

---

## 4. Design

### 4.1 On-disk layout & registry

```
Application Support/TrackTheMoney/
  profiles.json                 # registry: [{id, name, kind, createdAt, lastOpenedAt}], activeId
  profiles/<id>/ttm.db          # + -wal/-shm, + ttm.db.pre-restore (undo is per profile)
```

- `kind` is a display hint only: `real | demo | sample | other`. It drives a
  badge, never behavior.
- **Legacy migration:** on first launch with the new code, an existing top-level
  `ttm.db` (+ sidecars + `.pre-restore`) is **moved** into
  `profiles/<new-id>/` as a profile named "My data". The move happens before
  the DB is opened, so the files are cleanly closed. It's idempotent: if no
  legacy file exists, it does nothing.
- The registry is a plain file, not a table in any profile DB. It has to be
  readable before any profile is open.

### 4.2 Where the code lands (CoreFacade boundary, TTMCore purity)

- **`TTMCore/Persistence/ProfileManager.swift` (new):** pure Foundation file
  operations, like `BackupManager`. It handles: registry read/write (atomic
  replace), create, rename, delete, legacy migration, and path resolution.
  Takes a root directory, so tests use a temp dir.
- **`LocalCore`:** `dbPath` becomes lock-guarded mutable state. `switchProfile`
  closes the live DB, updates the path, then calls `rebuildInternals()`.
  Restore and undo keep working unchanged against the *active* profile's path.
- **`CoreFacade` additions:**
  - `profiles() -> [ProfileSummary]`, `activeProfile() -> ProfileSummary`
  - `createProfile(name:kind:) -> ProfileSummary` (empty DB, seeded by `DefaultData`)
  - `switchProfile(id:)`
  - `renameProfile(id:name:)`, `deleteProfile(id:)`. The active profile can't be
    deleted, and neither can the last one.
  - `importProfile(from: URL, name:, passphrase: String?) -> ImportResult` (§4.3/§4.4)
  - `exportBackup(includeConnection: Bool, passphrase: String?) -> URL`. Extends
    the existing method; the default stays connection-free.
  - `connections() -> [ConnectionSummary]` with `{id, name, status,
    lastSyncedAt, hasSecret}`. `hasSecret` is a Keychain read through
    `SecretStore`. This closes the restore-notice gap.
- **App layer:** a profile switcher in Settings plus an **always-visible
  active-profile badge** (§4.5). The app only calls the facade; it never touches
  `ProfileManager` directly (ADR-0007).

### 4.3 Loading a file as a profile

1. Run the existing validation steps (`BackupManager.inspect`) on the file.
   Nothing is touched before this passes.
2. Copy the file into `profiles/<new-id>/ttm.db`.
3. If the file has a sealed-connection section and a passphrase was given:
   unseal (§4.4), write each Access URL to the Keychain, then **drop the bundle
   table from the copied file** before it is ever opened as a live store. The
   secret never sits in a live DB, even encrypted (ADR-0013).
4. **Re-key connections:** every `connections.keychain_ref` in the new profile
   is rewritten to a fresh `conn-<UUID>`. If an Access URL is available, it gets
   copied to the new ref: either from the file, or, when the old ref resolves on
   this device, from the Keychain. This way **each profile owns its Keychain
   items exclusively**, so deleting a profile can safely delete its secrets
   without breaking a sibling loaded from the same file.
5. Register the profile and switch to it, then call `AppModel.refresh()`.
6. Return `ImportResult {profile, connectionsRestored, connectionsNeedingReconnect}`
   so the UI can say exactly what happened.

A file with **no** connection section (any of today's `.ttmbackup` files, and
any test file) loads in steps 1, 2, 4 and 5 only. It just works. Its connections
either resolve on this device or show as "needs reconnect".

"Replace current profile" (today's restore, with its undo) stays as a second
option on the same file picker.

### 4.4 Optional portable connection (layer C)

- **Where:** a table written **only into the exported copy**, after
  `VACUUM INTO`, never into the live DB, and not a migration:
  `ttm_bundle_secrets(keychain_ref TEXT PRIMARY KEY, sealed BLOB)` plus
  `ttm_bundle_meta(format INT, kdf TEXT, salt BLOB, iterations INT)`. It stays a
  single file, so the existing format, UTType and validation all carry over.
- **Sealing:** passphrase → **PBKDF2-HMAC-SHA256** (≥600k iterations, random
  16-byte salt) → 256-bit key → **AES-256-GCM** per Access URL, with the
  `keychain_ref` as associated data, so a blob can't be moved onto another
  connection row. Both algorithms have mainstream Rust crates (`pbkdf2`,
  `aes-gcm`), which keeps the TECH_DESIGN §13 port bounded. Lives in
  `TTMCore/Crypto/`. CryptoKit for AES-GCM and CommonCrypto for PBKDF2; neither
  is UI, ML, Keychain or network, so ADR-0006 holds (see D4).
- **UX:**
  - Export sheet: an "Include SimpleFIN connection" toggle, **off by default**.
    Turning it on requires a passphrase, entered twice, and shows a one-line
    warning: "Anyone with this file and the passphrase can read your bank
    accounts."
  - Import: if the file has a sealed section, prompt for the passphrase, with a
    **"Skip — load without connection"** button. A wrong passphrase gets an
    inline error and a retry. It never fails the whole import.
  - The restore summary sheet shows "Includes connection (encrypted)" when present.
- **Older app versions** opening such a file through today's restore would keep
  the bundle table as an orphan: encrypted, unused, harmless. The new code
  always strips it.

### 4.5 Test vs. real safety

The main risk of profiles is thinking you're in the demo profile when you're in
the real one, or the other way round.
- The active profile's name and `kind` badge are always visible: in the
  navigation title area on macOS, and at the top of Settings and Net Worth on iOS.
- `demo`/`sample` profiles get a distinct badge color (clay or slate, not
  evergreen).
- **One-tap "New SimpleFIN demo profile":** this creates a profile whose
  connection is the public demo bridge Access URL (`demo:demo`), with no setup
  token needed. Because that credential is public, it's the one connection that
  may also be exported unsealed (D3).
- "Load sample data" moves into the profile flow: it creates a `sample`
  profile rather than mixing demo rows into whatever profile is open.

### 4.7 Connection visibility (added at sign-off)

- `connections() -> [ConnectionSummary]` reports, per connection in the active
  profile: name, org, account count, last synced, last error, and a **state**:
  `connected` (credential in the Keychain, last sync fine), `missingCredential`
  (the row exists but this device's Keychain has nothing under its ref: a
  restored or imported file from elsewhere), `needsAuth` (the bridge refused,
  HTTP 403), `error`, or `sample` (sample-data rows, which have no credential
  by design and are skipped by sync).
- Settings leads with the active profile and a **Connection** section listing
  those states. If there's no connection: "No SimpleFIN connection in this
  profile" plus the setup-token field.
- **Reconnect in place:** `reconnect(connectionId:setupToken:)` claims a fresh
  Access URL and attaches it to the *existing* connection row under a fresh
  Keychain ref. Accounts are matched by `(connection_id, sfin_account_id)`, so
  history continues instead of duplicating every account under a new
  connection, which is what "Add connection" would do.
- The post-restore "add your connection again" notice is shown only when a
  connection is actually `missingCredential` (closes DATA_PORTABILITY_PLAN §9's
  known gap).

### 4.6 Launch arguments & tests

- `-profile <name>` selects or creates a profile by name at launch.
- `-resetStore` wipes `profiles/` and `profiles.json`, plus any legacy `ttm.db`.
- Existing `-sampleData` keeps working: it loads into the active profile, so
  UI tests are unchanged.

---

## 5. Decisions (RESOLVED 2026-11-25)

**Resolved:** D1 → A + B only, **C dropped** (not deferred: a file never carries
the connection; ADR-0020 stands). In its place, **connection visibility** is a
first-class requirement: the active profile's connections, and whether each one
has a working credential in this device's Keychain, must be obvious, and a
missing one must be fixable in place by re-linking (§4.7). D2–D4 are moot. D5a,
D6a adopted. Profile kinds simplified to **real | test** (§4.5).

**D1. Scope of the first cut**
- a) ★ Layers A + B first (profiles plus load-file-as-profile), then C as its
  own phase. A and B need no ADR change and cover test vs. real.
- b) All three together.

**D2. Must a file with a connection be passphrase-sealed?**
- a) ★ Yes, always, except the public demo-bridge credential (D3).
- b) Allow plaintext with a scary warning. Not recommended: the file then
  equals a bank password sitting in iCloud Drive.

**D3. Demo-bridge credential in plaintext**
- a) ★ Allowed. It's public (`demo:demo`), and this makes shareable test files
  zero-friction.
- b) Treat it like any other credential.

**D4. Crypto placement**
- a) ★ In `TTMCore/Crypto/` using CryptoKit + CommonCrypto. Pure (deterministic
  given inputs, testable), and it's where the M2 sealer already lives.
- b) Behind an injected `SecretSealer` protocol with the implementation in
  `app/Platform/`. Stricter purity, but more plumbing for no testability gain.

**D5. Legacy store**
- a) ★ Move it into `profiles/<id>/` as "My data".
- b) Leave it in place and point the registry at it. Avoids a move, but leaves
  two layouts forever.

**D6. Deleting a profile**
- a) ★ Deletes its DB files **and** its Keychain items. Safe because of
  re-keying (§4.3 step 4). Confirmation required.
- b) Leave Keychain items behind (orphans accumulate).

---

## 6. Implementation phases

### Phase 1 — Engine: profiles (TTMCore)
- `ProfileManager` (registry, create/rename/delete, legacy migration).
- `LocalCore`: mutable `dbPath`, `switchProfile`, per-profile restore/undo.
- Facade: profile CRUD, `connections()`, `importProfile` without sealed
  secrets, with re-keying.
- Tests (`ProfileTests`): create/switch round-trip keeps data isolated; legacy
  migration is idempotent; import validates before copying; re-keying gives
  each profile distinct refs and copies resolvable secrets; deleting one
  profile leaves a sibling's connection working; restore and undo stay scoped
  to the active profile; `connections().hasSecret` is accurate.

### Phase 2 — App: switcher + badge
- Settings "Profiles" section: list, switch, new (empty / SimpleFIN demo /
  sample data), rename, delete, "Open file as new profile…".
- Active-profile badge; `-profile` launch argument; the reconnect notice is
  now conditional on `connections()`.
- UI tests: switch profiles and see different data; open a file as a profile.

### Phase 3 — Portable connection (layer C)
- `Crypto/ConnectionSealer` (PBKDF2 + AES-GCM); export with
  `includeConnection`; import unseal, write to Keychain, strip the table.
- Tests: seal→unseal round-trip; wrong passphrase gives a typed error and
  imports nothing secret; tampered blob or swapped AAD is rejected; the
  imported live DB has no bundle table; a plaintext demo credential is
  accepted only for the demo host.
- ADRs on ship: **new ADR** for profiles; **new ADR amending 0013 and
  superseding 0020's secrets bullet** ("a user-initiated export may carry the
  Access URL sealed under a passphrase"). Update the 0013/0020 status lines to
  point at it.

---

## 7. Risks

| Risk | Mitigation |
|---|---|
| Confusing test and real data | Always-visible badge (§4.5); demo/sample kinds colored differently |
| Shared Keychain refs across profiles → deleting one breaks another | Re-key on import (§4.3) |
| Weak passphrase on a portable file | Minimum length; high-iteration KDF; off by default; explicit warning |
| Switching mid-sync | `switchProfile` waits for or cancels the in-flight sync before closing the DB (same constraint restore already has) |
| Legacy move fails halfway | Move files in a fixed order and write the registry last; if a retry finds files already moved, it finishes the job |

---

## 8. Implementation notes (2026-11-25)

- **Kinds are `real | test`** (not demo/sample/other). Demo and sample are
  *starting points* in the New-profile sheet (Empty / SimpleFIN demo bank /
  Sample data), not kinds; both default to `test`.
- **Settings → "Load sample data" is gone**; sample data is a starting point
  for a new profile, so demo rows never land in a real profile. The
  `-sampleData` launch argument still loads into the active profile.
- **The demo bank is claimed, not hard-coded:** `SimpleFINDemo.setupToken` is
  SimpleFIN's published reusable claim token, so the one-tap demo profile goes
  through the real claim → Keychain → sync path.
- **Secret cleanup also counts undo copies** (`ttm.db.pre-restore`) and reads
  stores with a plain query (no migrations on an undo copy). If any store can't
  be read, nothing is deleted.
- **Presentations moved to the Form.** `.sheet`/`.alert`/`.fileImporter`
  attached to a `Section` inside a `Form` didn't present (the New-profile sheet
  never opened under XCUITest). Profiles, Reconnect and Backup now keep their
  presentation state in `SettingsView` and attach via view modifiers on the Form.
- **Banner placement:** a `safeAreaInset` on the `TabView` let iOS 26's floating
  nav bars draw underneath it; the banner is stacked above the `TabView` instead.
- **Found along the way — letterboxing:** the Info.plist had no
  `UILaunchScreen`, so the iOS 26+ SDK ran the app in a 320×480 compatibility
  window. `INFOPLIST_KEY_UILaunchScreen_Generation: YES` in `project.yml` fixes
  it, and with it the previously "flaky" `CategorizeUITests` (rows were simply
  under the tab bar).
