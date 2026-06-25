# Track The Money — Technical Design

> Companion to [PLAN.md](PLAN.md). Covers the on-device app (this public repo), the cloud backend (private repo), the boundary between them, the data schema, and the engines. Targets the locked decisions: local-first freemium, SwiftUI (iOS/Mac primary), Swift `TTMCore` shared core, rules-free + AI-paid, SQLite on device.

**Last updated:** 2026-06-25

---

## 1. Two Tiers, Two Repos

```
┌───────────────────────────── FREE / LOCAL-FIRST ─────────────────────────────┐
│  JamesReate/track-the-money  (PUBLIC, this repo)                              │
│                                                                              │
│   SwiftUI app (iOS · iPadOS · macOS)                                         │
│        │ depends on                                                          │
│        ▼                                                                     │
│   TTMCore  (pure Swift package — no UI deps)                                 │
│     ├─ SimpleFIN client   ──HTTPS──▶ beta-bridge.simplefin.org               │
│     ├─ Sync engine                                                           │
│     ├─ Rules engine (deterministic)                                          │
│     ├─ Net-worth / interest math                                             │
│     ├─ Persistence (GRDB / SQLite)                                           │
│     └─ Crypto (E2E for paid sync) + SyncClient (talks to backend)            │
│                                                                              │
│   Keychain ← SimpleFIN Access URL (never leaves device)                      │
│   /contract/openapi.yaml ← source of truth for the backend wire protocol     │
└──────────────────────────────────────┬───────────────────────────────────────┘
                                        │ E2E-encrypted sync + AI (paid users only)
┌───────────────────────────── PAID / CLOUD ───────────┴───────────────────────┐
│  JamesReate/track-the-money-cloud  (PRIVATE)                                  │
│   Go + Postgres                                                              │
│     ├─ Sync relay (stores opaque ciphertext blobs)                           │
│     ├─ AI service ──HTTPS──▶ Claude  (prompts + key, server-side only)       │
│     ├─ Auth / accounts / device registration                                 │
│     └─ Billing / entitlements                                                │
└──────────────────────────────────────────────────────────────────────────────┘
```

**The free app is complete on its own.** Everything in the public repo runs with no backend. The private repo is purely additive (sync, AI, multi-user) and is the open-core moat.

---

## 2. Why this shape (decisions recap)

| Decision | Choice | Rationale |
|---|---|---|
| Frontend | **SwiftUI** | iOS + macOS (both *primary*) from one native codebase; Swift Charts for net-worth graphs. |
| Shared core | **Swift `TTMCore`**, pure module | Swift already covers both Apple platforms with no FFI. Kept UI-independent so Android/Windows can port it to **Rust/KMP at that milestone** — bounded, deferred cost. |
| On-device store | **SQLite via GRDB** | Single-writer on device = SQLite's sweet spot. GRDB gives migrations, type-safe rows, change observation. |
| Cloud store | **Postgres** (private repo) | Cloud tier is genuinely multi-tenant / multi-writer — opposite of the device case. |
| AI | **Server-side, paid** | Prompts + Claude key stay private; free app is rules-only. |
| Sync | **E2E-encrypted** | Server stores ciphertext only; protocol can be public (see `/contract`). |

### The Rust-core deferral (recorded)
`TTMCore` is Swift today. The Rust payoff is *only* for Android/Windows (secondary, later) and a Rust backend (we use Go) — while its FFI cost would be paid now on the primary Apple platforms. **Revisit trigger:** when Android is scheduled, port `TTMCore`'s pure domain logic to a Rust crate (UniFFI → Swift/Kotlin bindings) or Kotlin Multiplatform. The "no SwiftUI/UIKit in `TTMCore`" rule below is what keeps that port bounded.

---

## 3. `TTMCore` — Pure Swift Package

```
TTMCore/
├── Package.swift
├── Sources/TTMCore/
│   ├── Money.swift            // Cents (Int64) + decimal-string parse/format (no Double)
│   ├── Time.swift             // UTC unix-seconds helpers
│   ├── SimpleFIN/             // client: claim flow, /accounts fetch, v1+v2 decoding
│   ├── Sync/                  // window calc, idempotent upsert, snapshots, reconcile
│   ├── Rules/                 // condition tree, priority eval, apply engine
│   ├── Classify/             // account classes + smart-default guesser
│   ├── Interest/              // detection, payment splits, debt-cost rollups
│   ├── NetWorth/             // asset/liability rollup, property equity, time series
│   ├── Persistence/          // GRDB: schema migrations, record types, queries
│   ├── Crypto/               // AES-GCM record encryption for paid sync
│   └── SyncClient/           // HTTP client implementing /contract (paid only)
└── Tests/TTMCoreTests/        // engines unit-tested with no UI / no device APIs
```

**Hard rule:** `TTMCore` imports **no SwiftUI/UIKit/AppKit** and touches no device-only APIs directly. Keychain and background-refresh live in the app layer and are injected into `TTMCore` via protocols (`SecretStore`, `Clock`, `Networking`). This is what makes the engines testable *and* the future Rust port a contained job.

---

## 4. Money & Time Conventions

- **`Money.Cents = Int64`.** SimpleFIN amounts arrive as decimal strings (`"-42.07"`); parse to cents via a string/`Decimal` parser — **never `Double`**. Format back with explicit currency.
- **Timestamps:** SimpleFIN gives unix seconds; store `INTEGER` unix seconds, **UTC**; render in the user's TZ at the SwiftUI layer.

---

## 5. On-Device SQLite Schema (GRDB)

GRDB opens the DB in WAL mode with `foreign_keys=ON`, `busy_timeout`, `synchronous=NORMAL`. Migrations are registered in `Persistence/`. The schema below is the device-local store; for paid users, rows are encrypted per-record before leaving the device (see §9).

```sql
-- Connections (one per claimed SimpleFIN Access URL; the URL itself is in Keychain) --
CREATE TABLE connections (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  keychain_ref    TEXT NOT NULL,               -- handle to the Access URL in Keychain
  sfin_org        TEXT,
  status          TEXT NOT NULL DEFAULT 'ok',   -- ok | needs_auth | error
  last_error      TEXT,
  last_synced_at  INTEGER,
  created_at      INTEGER NOT NULL
) STRICT;

CREATE TABLE accounts (
  id                 TEXT PRIMARY KEY,
  connection_id      TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  sfin_account_id    TEXT NOT NULL,
  name               TEXT NOT NULL,
  currency           TEXT NOT NULL DEFAULT 'USD',
  class              TEXT NOT NULL DEFAULT 'unclassified',
                     -- liquid | investment | secured_debt | unsecured_debt
                     -- | real_estate | income | excluded | unclassified
  subclass           TEXT,
  apr_bps            INTEGER,                  -- optional APR in basis points
  balance_cents      INTEGER NOT NULL DEFAULT 0,
  available_cents    INTEGER,
  balance_date       INTEGER,
  archived           INTEGER NOT NULL DEFAULT 0,
  created_at         INTEGER NOT NULL,
  UNIQUE (connection_id, sfin_account_id)
) STRICT;

CREATE TABLE balance_snapshots (              -- time series → net-worth-over-time
  id            INTEGER PRIMARY KEY,
  account_id    TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  balance_cents INTEGER NOT NULL,
  available_cents INTEGER,
  balance_date  INTEGER NOT NULL,
  recorded_at   INTEGER NOT NULL,
  UNIQUE (account_id, balance_date)           -- idempotent
) STRICT;

CREATE TABLE transactions (
  id                 TEXT PRIMARY KEY,
  account_id         TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sfin_txn_id        TEXT NOT NULL,
  posted_at          INTEGER,                  -- NULL/0 if pending
  transacted_at      INTEGER,
  amount_cents       INTEGER NOT NULL,         -- positive = credit/deposit
  description        TEXT NOT NULL DEFAULT '',
  payee              TEXT,
  memo               TEXT,
  pending            INTEGER NOT NULL DEFAULT 0,
  category_id        TEXT REFERENCES categories(id) ON DELETE SET NULL,
  category_source    TEXT,                     -- rule:<id> | ai | manual | NULL
  is_transfer        INTEGER NOT NULL DEFAULT 0,
  transfer_group_id  TEXT,
  extra_json         TEXT,
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL,
  UNIQUE (account_id, sfin_txn_id)             -- idempotency key for upsert
) STRICT;
CREATE INDEX idx_txn_acct_posted ON transactions(account_id, posted_at);
CREATE INDEX idx_txn_uncat ON transactions(category_id) WHERE category_id IS NULL;

-- FTS for transaction search (GRDB FTS5)
CREATE VIRTUAL TABLE transactions_fts USING fts5(
  description, payee, memo, content='transactions', content_rowid='rowid'
);

CREATE TABLE categories (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  parent_id TEXT REFERENCES categories(id) ON DELETE CASCADE,
  kind TEXT NOT NULL DEFAULT 'expense',        -- expense|income|transfer|interest|system
  color TEXT, sort INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
  UNIQUE (parent_id, name)
) STRICT;

CREATE TABLE rules (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  category_id TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  priority INTEGER NOT NULL DEFAULT 100,        -- lower = first
  enabled INTEGER NOT NULL DEFAULT 1,
  conditions TEXT NOT NULL,                     -- JSON match tree (§7)
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE properties (
  id TEXT PRIMARY KEY, name TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'real_estate',     -- real_estate|vehicle|other
  created_at INTEGER NOT NULL
) STRICT;
CREATE TABLE property_values (
  id INTEGER PRIMARY KEY,
  property_id TEXT NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  value_cents INTEGER NOT NULL, as_of INTEGER NOT NULL, note TEXT, created_at INTEGER NOT NULL
) STRICT;
CREATE TABLE property_debts (
  property_id TEXT NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  account_id  TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  role TEXT NOT NULL DEFAULT 'mortgage',         -- mortgage|heloc|other
  PRIMARY KEY (property_id, account_id)
) STRICT;

CREATE TABLE payment_splits (                    -- mortgage/loan principal vs interest vs escrow
  id INTEGER PRIMARY KEY,
  transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  principal_cents INTEGER NOT NULL DEFAULT 0,
  interest_cents  INTEGER NOT NULL DEFAULT 0,
  escrow_cents    INTEGER NOT NULL DEFAULT 0,
  source TEXT NOT NULL DEFAULT 'manual', created_at INTEGER NOT NULL
) STRICT;

-- ai_suggestions: populated from the PAID backend's responses, reviewed locally
CREATE TABLE ai_suggestions (
  id TEXT PRIMARY KEY,
  transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  suggested_cat_id TEXT REFERENCES categories(id) ON DELETE SET NULL,
  confidence REAL, suggested_rule TEXT, rationale TEXT,
  status TEXT NOT NULL DEFAULT 'pending',         -- pending|accepted|rejected
  created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE settings ( key TEXT PRIMARY KEY, value TEXT NOT NULL ) STRICT;
```

> No `auth`/`sessions` tables on-device — the free app has no login. Accounts/auth live exclusively in the private backend.

---

## 6. Sync Engine (`TTMCore/Sync`)

Runs on-device. Trigger: manual ("Sync now") + scheduled (iOS `BGAppRefreshTask` / macOS timer).

**Per connection, per run:**
1. Read Access URL from Keychain (via injected `SecretStore`).
2. Window: `start-date = min(last_synced_at − overlap, default_backfill)`, `end-date = now`, `pending=1`. Overlap (~7d) re-pulls recent txns to catch late posts/edits.
3. `GET {access_url}/accounts?start-date=…&end-date=…&pending=1`. Decode defensively for **v1** (`payee`/`memo`, `org`) and **v2** (`connections`, `transacted_at`).
4. Per account: upsert account + latest balance; insert balance snapshot (`ON CONFLICT(account_id, balance_date) DO NOTHING`); smart-default class **on first sight only**; upsert each txn on `(account_id, sfin_txn_id)`:
   - new → insert, run categorization pipeline (§8)
   - existing → update amount/description/pending (handles **pending→posted**, stable id); never clobber a `manual` category.
5. Record `last_synced_at`; on failure set `status` + `last_error`. **One failing connection never blocks others.** Surface `errlist` to UI.

**Idempotency:** unique constraints on `(account_id, sfin_txn_id)` and `(account_id, balance_date)`; per-connection writes in one GRDB transaction.

---

## 7. Rules Engine (`TTMCore/Rules`)

`rules.conditions` is a small composable JSON tree:

```json
{ "op": "and", "clauses": [
  { "field": "description", "match": "contains", "value": "CHEWY", "ci": true },
  { "field": "amount_cents", "match": "lt", "value": 0 }
] }
```

- **Fields:** `description`, `payee`, `memo`, `account_id`, `amount_cents`, `currency`.
- **Ops:** `contains`, `eq`, `regex`, `lt/lte/gt/gte`, `between`; `op`: `and`|`or`.
- **Eval:** sort by `priority ASC`, **first match wins**, write `category_source='rule:<id>'` → the inspectable "why" trail.
- **Apply modes:** *forward-only*, *backfill* (never overwrites `manual` unless asked), *re-run all*.
- **"Create rule from transaction"** pre-fills a `contains payee` clause → one tap to persist + optionally backfill.

---

## 8. Categorization Pipeline (`TTMCore/Classify`)

```
txn ──▶ Rules.match(txn)
          ├─ hit  ─▶ set category, source = rule:<id>     ✅ deterministic, FREE, offline
          └─ miss ─▶ if (paid && aiEnabled && !transfer):
                        SyncClient.aiCategorize([...])  ──▶ backend ──▶ Claude
                        store ai_suggestions (pending)
                     else: leave Uncategorized
```

- **Free tier stops at rules.** AI is reached only for **paid, signed-in** users via `SyncClient` → backend (`/v1/ai/categorize`).
- Backend returns category + confidence + optional **suggested rule** + rationale → `ai_suggestions` (pending).
- **Human-in-the-loop review queue** in the app: accepting either categorizes the one txn or **promotes the suggested rule to a local `rules` row** — deterministic and free forever after.
- **Privacy boundary** (mirrored in `/contract`): only description/payee/amount/category-list leave the device — never balances, account numbers, or the Access URL.
- **Transfer detection** runs before AI: pairs opposite-sign equal-magnitude txns across two own accounts within a date window → `is_transfer=1`, shared `transfer_group_id`, excluded from spend.

---

## 9. Cloud Backend (private repo — contract-level view)

Implemented in **`JamesReate/track-the-money-cloud`** (Go + Postgres). The public repo only contains the **contract** (`/contract/openapi.yaml`) and the device-side `SyncClient`. Backend responsibilities:

- **Sync relay:** `POST /v1/sync/push`, `GET /v1/sync/pull`. Stores `EncryptedRecord` blobs keyed by `(user, type, id)`; resolves by `updated_at`. **Server never decrypts** — it sees ciphertext + minimal routing metadata only.
- **AI service:** `POST /v1/ai/categorize`. Holds the Claude key + prompts + eval; batches; enforces the privacy field-set server-side.
- **Auth/accounts/devices:** `POST /v1/auth/login`, device registration, multi-user household membership.
- **Billing:** subscription entitlement gating for sync + AI.

**E2E crypto (`TTMCore/Crypto`):** each syncable record is AES-GCM encrypted on-device with a key derived from the user's passphrase (never sent to the server). Losing the passphrase = unrecoverable cloud data (documented; the local copy is unaffected). This is what lets the protocol be public.

---

## 10. App Layer (SwiftUI)

```
TrackTheMoney/ (Xcode app target; depends on TTMCore)
├── App.swift                  // scene, DI wiring (SecretStore=Keychain, etc.)
├── Sync/BackgroundRefresh.swift
├── Features/
│   ├── NetWorth/              // headline + breakdown + Swift Charts over-time
│   ├── Accounts/              // classification controls
│   ├── RealEstate/            // value vs mortgage+heloc, equity, value history
│   ├── Transactions/          // FTS search, quick-categorize, create-rule
│   ├── Rules/                 // rule list, priority, AI review queue (paid)
│   ├── Spending/              // category breakdown by period
│   ├── DebtInterest/          // secured/unsecured, interest paid
│   └── Settings/              // SimpleFIN connections, sync schedule, account/upgrade
└── Shared/                    // design system, formatters (money/date in user TZ)
```

- **One codebase, iOS + iPadOS + macOS** via SwiftUI with size-class/platform adaptation (`NavigationSplitView`, `.menuBar` commands on Mac).
- **Swift Charts** for net-worth and interest trends.
- Money rendered from `Cents` via a shared formatter; times in the user's TZ.
- Paywall surfaces (sync, AI) gated by entitlement from the backend; the rest works offline.

---

## 11. Security

- **Access URL** in Keychain, device-only; never synced, never sent to backend or AI.
- **Cloud sync** is E2E-encrypted; the server is zero-knowledge of financial data.
- **AI egress** minimized + server-enforced field allow-list; only for paid users.
- **TLS** everywhere; certificate handling standard for Apple platforms.
- **Public-repo hygiene:** no secrets, prompts, or keys in the open app — those live in the private backend. (Recommend a secret-scanning pre-commit/CI guard.)

---

## 12. Build Order

**Milestone 1 — Free on-device app (public repo):**
1. `TTMCore` skeleton + GRDB schema/migrations + Money/Time + DI protocols.
2. SimpleFIN client (claim flow, v1/v2 decode) + Keychain Access URL storage.
3. Sync engine (idempotent upsert, snapshots, pending reconcile, error surfacing).
4. Classification + net worth (latest + over-time) + Accounts/NetWorth SwiftUI.
5. Properties (value history, debt links, equity) + RealEstate view.
6. Categories + rules engine (forward/backfill/rerun) + Transactions/Rules views.
7. Interest detection + payment splits + DebtInterest view.
8. Polish: FTS search, transfer detection, local export, scheduled refresh.

**Milestone 2 — Paid cloud (private repo + device glue):**
9. Backend sync relay (Postgres, E2E blobs) + `SyncClient` + `Crypto`.
10. Auth/accounts/multi-user + billing/entitlements + paywall surfaces.
11. AI service (Claude, prompts, eval) + device review-queue wiring.

---

## 13. Rust Port Strategy (Android/Windows milestone)

The Swift-core-now decision is only safe because the port path is concrete and bounded. This section is the plan, written now so the architecture stays port-ready.

### 13.1 What ports, what doesn't

| Layer | Today (Apple) | After port | Notes |
|---|---|---|---|
| Domain logic (SimpleFIN decode, sync, rules, net-worth/interest math, crypto) | `TTMCore` Swift | **`ttm-core` Rust crate** | The whole point — write once, run on all platforms. |
| Persistence | GRDB (Swift) | **`rusqlite`/`sqlx` in Rust** | Same SQL schema/migrations move verbatim; only the binding layer changes. |
| Platform services (Keychain, background refresh, networking trust) | Swift app | **stays native per-platform** | Injected into core via traits — never inside the portable core. |
| UI | SwiftUI | SwiftUI (Apple) · **Compose (Android)** · Win UI later | UI never ports; it calls the core. |

The discipline that makes this work is already in place: `TTMCore` has **no SwiftUI/UIKit/AppKit imports** and reaches the OS only through injected protocols (`SecretStore`, `Clock`, `Networking`). Those protocols become **Rust traits** with native implementations per platform.

### 13.2 Binding mechanism — UniFFI

Expose the Rust crate through **Mozilla UniFFI**, which generates idiomatic bindings from a single interface definition:

```
ttm-core (Rust crate)
  ├── src/lib.rs            // engines + #[uniffi::export] surface
  ├── ttm_core.udl         // or proc-macro exports: the FFI interface
  └── bindings/
       ├── swift/           // generated → drop-in replacement for TTMCore's API
       └── kotlin/          // generated → consumed by the Compose app
```

- iOS/macOS: build the crate as an **XCFramework** (arm64 device + simulator + macOS), ship generated Swift bindings. The SwiftUI app's call sites stay nearly identical because we mirror the current `TTMCore` public API in the `#[uniffi::export]` surface (see §13.4).
- Android: build `.so` per ABI (`arm64-v8a`, `x86_64`) via `cargo-ndk`, ship generated Kotlin bindings, load via JNI (UniFFI handles the glue).
- Windows: the same crate compiles natively; bind via UniFFI (or C ABI) to whatever Windows UI stack is chosen.

UniFFI handles records, enums, `Result`/errors, and **async** (`async fn` → Swift `async` / Kotlin `suspend`), which covers our sync/network calls.

### 13.3 Crossing the FFI cleanly

Keep the boundary **coarse-grained** — pass whole operations and DTOs, not chatty per-field getters (FFI calls have overhead; design around it):

- **Inputs/outputs are plain value types** (`Codable`/`uniffi::Record`): `SyncResult`, `NetWorthSnapshot`, `RuleDTO`, `CategorizeRequest/Response`.
- **The core owns the SQLite connection.** The app never touches the DB directly post-port; it calls `core.sync()`, `core.netWorth(range:)`, `core.applyRule(...)`. (We should route through this façade *now*, even in Swift, so the call sites don't change later.)
- **Reactive updates:** GRDB's change-observation is Apple-only. Replace with a core-emitted change signal — a callback/listener interface (`CoreObserver`) the core invokes after writes, which each UI maps to its reactive primitive (Swift `@Observable`, Kotlin `StateFlow`). Designing this façade now is the single most important port-readiness step.

### 13.4 Migration sequence (incremental, test-guarded)

1. **Freeze the `TTMCore` public API behind a façade** (`CoreFacade`) the app already uses. This is the contract the Rust port must satisfy.
2. **Port module-by-module**, lowest-dependency first: `Money`/`Time` → `SimpleFIN` decode → `Rules` → `NetWorth`/`Interest` → `Sync` → `Crypto`/`SyncClient`. Persistence comes with whichever module first needs it.
3. **Parity testing:** the existing `TTMCoreTests` become **golden vectors** — same inputs (recorded SimpleFIN payloads, rule sets) must produce byte-identical outputs from the Rust crate. Run both implementations against the fixture corpus until they match.
4. **Swap under the façade:** replace the Swift `TTMCore` with the UniFFI-generated Swift package implementing the same `CoreFacade`. The SwiftUI app ideally changes only its import + DI wiring.
5. **Light up Android:** Compose UI on the Kotlin bindings, native `SecretStore`/networking impls.

### 13.5 What this costs / de-risks

- **Cost:** a Rust crate + UniFFI build pipeline (CI matrix for XCFramework + Android `.so`), and re-implementing tested logic against golden vectors. Bounded because the logic is already specified, isolated, and test-covered.
- **De-risked by doing now:** (a) the no-UI-deps rule in `TTMCore`, (b) the `CoreFacade` choke-point so UI call sites are stable, (c) the core-owns-DB rule, (d) keeping the SQL schema/migrations as plain SQL (not Swift-DSL-only) so they move verbatim, (e) the `CoreObserver` change-signal abstraction instead of leaning on GRDB observation.
- **Crypto note:** standardize on algorithms with first-class Rust crates now (AES-GCM via `aes-gcm`/`ring`, HKDF) so E2E records encrypted by the Swift build decrypt identically in the Rust build — cloud data survives the port.

---

## 14. Resolved vs Open

**Resolved:** product shape (local-first freemium), frontend (SwiftUI), core (Swift `TTMCore`, Rust-deferred), device store (GRDB/SQLite), cloud store (Postgres, private), AI placement (paid/server), sync model (E2E-encrypted, public contract), repo boundary, money (Int64 cents), idempotency keys, no-double-count net worth.

**Open (validate during build):**
- SimpleFIN Bridge **rate limits** → sync cadence + overlap defaults.
- **Default backfill depth** on first sync (institution-dependent).
- Cloud sync **conflict resolution** detail (last-writer-wins vs per-field merge) — `updated_at` cursor is the starting point.
- **AI monthly cost ceiling** per paid user + optional high-confidence auto-apply.
- Multi-currency: schema is ready (`currency` columns); conversion/display deferred.
- Pricing: the actual "low yearly fee" number and any device/seat limits.
```
