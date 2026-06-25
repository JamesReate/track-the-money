# Track The Money — Technical Design

> Companion to [PLAN.md](PLAN.md). This doc covers the stack, code layout, SQLite schema, the sync/rules/AI engines, the HTTP API, and the frontend. Targets the locked decisions: single-household shared login, self-hosted, rules-first + AI-fallback, SQLite.

**Last updated:** 2026-06-24

---

## 1. Architecture at a Glance

```
                         ┌──────────────────────────────────────────┐
                         │            Single Go binary                │
                         │                                            │
   Browser (Lit SPA) ───▶│  HTTP API (chi)  ──┐                      │
                         │                     ├─▶ Services layer ───┐│
   SimpleFIN Bridge ◀────│  Sync worker ──────┘   (net worth,       ││
   (HTTPS, Basic Auth)   │  (scheduler/cron)       rules, interest)  ││
                         │                                           ▼│
   Claude API ◀──────────│  AI client (categorization)      sqlc queries
   (HTTPS, opt-in)       │                                           │ │
                         │                                    ┌──────▼─────┐
                         │   Embedded static SPA assets       │ SQLite WAL │
                         └────────────────────────────────────┴────────────┘
                                                              tttm.db (one file)
```

- **One process.** The Go binary serves the API, serves the embedded SPA (`go:embed`), runs the scheduled sync worker, and opens the SQLite file in-process. No external services to run except outbound HTTPS to SimpleFIN and (optionally) Claude.
- **One writer.** Only the sync worker and API request handlers write; serialized through a single `*sql.DB` with `busy_timeout`. SQLite WAL lets reads proceed concurrently.
- **Deploy = copy two things:** the binary and the `.db` file (plus a config/env). Backup = `VACUUM INTO` a timestamped copy.

---

## 2. Stack & Key Libraries

| Concern | Choice | Notes |
|---|---|---|
| Language | **Go 1.23+** | single static binary, `go:embed` for SPA |
| HTTP router | **chi** | stdlib-compatible, middleware-friendly |
| DB driver | **`modernc.org/sqlite`** | pure-Go, no CGO → trivial cross-compile for NAS/ARM |
| Query layer | **sqlc** | typed Go from SQL; keeps queries portable toward Postgres |
| Migrations | **goose** (embedded) | versioned, runs on startup |
| Scheduler | **robfig/cron v3** | configurable sync cadence |
| Config | **env + small TOML** | see §10 |
| AI | **Anthropic Go SDK** (Claude) | pluggable `Categorizer` interface |
| Frontend | **Lit + Vite + TypeScript** | SPA, built to static assets, embedded in binary |
| Charts | **uPlot** (or Chart.js) | net-worth-over-time, lightweight |
| Auth | **session cookie + argon2id** | single shared credential; pluggable |

---

## 3. Repository Layout

```
track-the-money/
├── cmd/
│   └── ttm/                 main(): wires config, db, router, scheduler
├── internal/
│   ├── config/              load env/TOML, validate
│   ├── db/
│   │   ├── migrations/      goose .sql files (embedded)
│   │   ├── queries/         .sql for sqlc
│   │   └── sqlc/            generated code
│   ├── simplefin/           client: claim flow, /accounts fetch, v1/v2 parsing
│   ├── sync/                sync worker: window calc, upsert, snapshots, reconcile
│   ├── money/               Cents type (int64) + parse/format helpers
│   ├── classify/            account classes + smart-default guesser
│   ├── rules/               rule model, matcher, priority eval, apply engine
│   ├── categorize/          orchestrates rules → AI fallback → review queue
│   ├── ai/                  Categorizer interface + claude impl + noop impl
│   ├── interest/            interest detection, payment split, debt-cost rollups
│   ├── networth/            asset/liability rollup, property equity, time series
│   ├── property/            real estate CRUD + value history
│   ├── api/                 HTTP handlers, DTOs, auth middleware
│   └── crypto/              encrypt/decrypt secrets at rest (Access URLs, AI key)
├── web/                     Lit + Vite + TS frontend (built into internal/api/assets)
├── PLAN.md
├── TECH_DESIGN.md
└── go.mod
```

---

## 4. Money & Time Conventions

- **`money.Cents = int64`.** SimpleFIN amounts arrive as decimal strings (e.g. `"-42.07"`); parse to cents with a string/big.Rat-based parser — **never `float64`**. Format back with explicit currency.
- **Timestamps:** SimpleFIN gives unix seconds. Store as `INTEGER` unix seconds, **UTC**. Display in the household's configured TZ (frontend).
- **STRICT tables** enforce column types; money columns are `INTEGER`.

---

## 5. SQLite Schema

PRAGMAs set on every connection: `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=5000`, `synchronous=NORMAL`.

```sql
-- ── Connections (one per claimed SimpleFIN Access URL) ───────────────────────
CREATE TABLE connections (
  id              TEXT PRIMARY KEY,            -- uuid
  name            TEXT NOT NULL,               -- institution / connection label
  access_url_enc  BLOB NOT NULL,               -- encrypted SimpleFIN Access URL
  sfin_org        TEXT,                        -- org name/domain if provided
  status          TEXT NOT NULL DEFAULT 'ok',  -- ok | needs_auth | error
  last_error      TEXT,
  last_synced_at  INTEGER,                     -- unix seconds
  created_at      INTEGER NOT NULL
) STRICT;

-- ── Accounts (mirror of SimpleFIN accounts + our classification) ─────────────
CREATE TABLE accounts (
  id                 TEXT PRIMARY KEY,         -- our uuid
  connection_id      TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
  sfin_account_id    TEXT NOT NULL,            -- SimpleFIN id (unique within connection)
  name               TEXT NOT NULL,
  currency           TEXT NOT NULL DEFAULT 'USD',
  class              TEXT NOT NULL DEFAULT 'unclassified',
                     -- liquid | investment | secured_debt | unsecured_debt
                     -- | real_estate | income | excluded | unclassified
  subclass           TEXT,                     -- e.g. 'retirement', 'checking'
  apr_bps            INTEGER,                  -- optional APR in basis points (debt accts)
  balance_cents      INTEGER NOT NULL DEFAULT 0,    -- latest authoritative balance
  available_cents    INTEGER,
  balance_date       INTEGER,                  -- unix seconds from SimpleFIN
  archived           INTEGER NOT NULL DEFAULT 0,
  created_at         INTEGER NOT NULL,
  UNIQUE (connection_id, sfin_account_id)
) STRICT;

-- ── Balance snapshots (time series → net-worth-over-time) ─────────────────────
CREATE TABLE balance_snapshots (
  id            INTEGER PRIMARY KEY,
  account_id    TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  balance_cents INTEGER NOT NULL,
  available_cents INTEGER,
  balance_date  INTEGER NOT NULL,             -- unix seconds (SimpleFIN's balance-date)
  recorded_at   INTEGER NOT NULL,             -- when we wrote it
  UNIQUE (account_id, balance_date)           -- idempotent: one snapshot per balance-date
) STRICT;
CREATE INDEX idx_snap_acct_date ON balance_snapshots(account_id, balance_date);

-- ── Transactions (authoritative from SimpleFIN; we add categorization) ───────
CREATE TABLE transactions (
  id                 TEXT PRIMARY KEY,         -- our uuid
  account_id         TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sfin_txn_id        TEXT NOT NULL,            -- SimpleFIN id (unique within account)
  posted_at          INTEGER,                  -- unix seconds; NULL/0 if pending
  transacted_at      INTEGER,                  -- optional (v2)
  amount_cents       INTEGER NOT NULL,         -- positive = credit/deposit
  description        TEXT NOT NULL DEFAULT '',
  payee              TEXT,                     -- v1 payee, or derived
  memo               TEXT,
  pending            INTEGER NOT NULL DEFAULT 0,
  category_id        TEXT REFERENCES categories(id) ON DELETE SET NULL,
  category_source    TEXT,                     -- rule:<id> | ai | manual | NULL
  is_transfer        INTEGER NOT NULL DEFAULT 0,
  transfer_group_id  TEXT,                     -- pairs the two legs of a transfer
  extra_json         TEXT,                     -- raw SimpleFIN 'extra' (JSON1)
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL,
  UNIQUE (account_id, sfin_txn_id)             -- idempotency key for upsert
) STRICT;
CREATE INDEX idx_txn_acct_posted ON transactions(account_id, posted_at);
CREATE INDEX idx_txn_category    ON transactions(category_id);
CREATE INDEX idx_txn_uncat       ON transactions(category_id) WHERE category_id IS NULL;

-- Full-text search over description/payee/memo
CREATE VIRTUAL TABLE transactions_fts USING fts5(
  description, payee, memo, content='transactions', content_rowid='rowid'
);

-- ── Categories (hierarchical) ────────────────────────────────────────────────
CREATE TABLE categories (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  parent_id  TEXT REFERENCES categories(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL DEFAULT 'expense', -- expense | income | transfer | interest | system
  color      TEXT,
  sort       INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE (parent_id, name)
) STRICT;

-- ── Rules (deterministic categorization) ─────────────────────────────────────
CREATE TABLE rules (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  category_id  TEXT NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  priority     INTEGER NOT NULL DEFAULT 100,  -- lower = evaluated first
  enabled      INTEGER NOT NULL DEFAULT 1,
  conditions   TEXT NOT NULL,                 -- JSON: composable match tree (see §7)
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
) STRICT;
CREATE INDEX idx_rules_priority ON rules(enabled, priority);

-- ── Properties (real estate / manually valued assets) ────────────────────────
CREATE TABLE properties (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'real_estate', -- real_estate | vehicle | other
  created_at  INTEGER NOT NULL
) STRICT;

CREATE TABLE property_values (                  -- value history (manual edits)
  id            INTEGER PRIMARY KEY,
  property_id   TEXT NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  value_cents   INTEGER NOT NULL,
  as_of         INTEGER NOT NULL,              -- unix seconds
  note          TEXT,
  created_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE property_debts (                   -- links a property to its loan accounts
  property_id  TEXT NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
  account_id   TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  role         TEXT NOT NULL DEFAULT 'mortgage', -- mortgage | heloc | other
  PRIMARY KEY (property_id, account_id)
) STRICT;

-- ── AI suggestions (review queue; human-in-the-loop) ─────────────────────────
CREATE TABLE ai_suggestions (
  id                TEXT PRIMARY KEY,
  transaction_id    TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  suggested_cat_id  TEXT REFERENCES categories(id) ON DELETE SET NULL,
  confidence        REAL,                       -- 0..1
  suggested_rule    TEXT,                       -- JSON rule proposal (optional)
  rationale         TEXT,
  status            TEXT NOT NULL DEFAULT 'pending', -- pending | accepted | rejected
  created_at        INTEGER NOT NULL
) STRICT;

-- ── Payment splits (mortgage/loan principal vs interest vs escrow) ──────────
CREATE TABLE payment_splits (
  id              INTEGER PRIMARY KEY,
  transaction_id  TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
  principal_cents INTEGER NOT NULL DEFAULT 0,
  interest_cents  INTEGER NOT NULL DEFAULT 0,
  escrow_cents    INTEGER NOT NULL DEFAULT 0,
  source          TEXT NOT NULL DEFAULT 'manual', -- manual | rule
  created_at      INTEGER NOT NULL
) STRICT;

-- ── Settings & auth (single shared household login) ──────────────────────────
CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;                                       -- ai_enabled, sync_cron, timezone, etc.

CREATE TABLE auth (
  id            INTEGER PRIMARY KEY CHECK (id = 1), -- single row
  password_hash TEXT NOT NULL,                  -- argon2id
  updated_at    INTEGER NOT NULL
) STRICT;

CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
) STRICT;
```

**Postgres-portability note:** `STRICT`, `INTEGER PRIMARY KEY`, and FTS5 are SQLite-specific. They're isolated to schema/migrations; sqlc queries stay standard SQL. A Postgres port swaps the migration files and the FTS approach — not the app code.

---

## 6. Sync Engine (`internal/sync`)

**Trigger:** cron (`sync_cron` setting, default e.g. `0 */6 * * *`) + manual `POST /api/sync`.

**Per connection, per run:**
1. Decrypt Access URL.
2. Compute window: `start-date = min(last_synced_at − overlap, default_backfill)`, `end-date = now`, `pending=1`. Overlap (e.g. 7 days) re-pulls recent txns so late-posting/edits are caught.
3. `GET {access_url}/accounts?start-date=…&end-date=…&pending=1`. Parse defensively for **v1 (`payee`/`memo`, `org`) and v2 (`connections`, `transacted_at`)**.
4. For each account:
   - Upsert account row; update `balance_cents`, `available_cents`, `balance_date`.
   - Insert a **balance snapshot** (`ON CONFLICT(account_id, balance_date) DO NOTHING`) → idempotent time series.
   - **Smart-default class** on first sight only (never overwrite a user's classification).
   - Upsert each transaction on `(account_id, sfin_txn_id)`:
     - New → insert, then run categorization pipeline (§8).
     - Existing → update amount/description/pending (handles **pending→posted**, where id is stable). Don't clobber a `manual` category.
5. Record `last_synced_at`; on HTTP/auth failure set `status='needs_auth'|'error'` + `last_error`. **One connection failing never blocks others.**
6. Surface `errlist` entries to the UI.

**Idempotency guarantees:** unique constraints on `(account_id, sfin_txn_id)` and `(account_id, balance_date)` make re-runs safe. All writes for a connection wrapped in a transaction.

---

## 7. Rules Engine (`internal/rules`)

**Condition model** (`rules.conditions` JSON) — a small composable tree:

```json
{
  "op": "and",
  "clauses": [
    { "field": "description", "match": "contains", "value": "CHEWY", "ci": true },
    { "field": "account_id",  "match": "eq",       "value": "acct-uuid" },
    { "field": "amount_cents","match": "lt",        "value": 0 }
  ]
}
```

- **Fields:** `description`, `payee`, `memo`, `account_id`, `amount_cents`, `currency`.
- **Match ops:** `contains`, `eq`, `regex`, `lt/lte/gt/gte`, `between`. `op`: `and` | `or`.
- **Evaluation:** rules sorted by `priority ASC`; **first match wins**; the matched rule id is written to `transactions.category_source = 'rule:<id>'`, giving the inspectable "why" trail.
- **Apply modes:**
  - *Forward only* — new rule affects only future/uncategorized txns.
  - *Backfill* — re-evaluate existing txns; a backfill **never overwrites `manual`** categorizations (configurable to include them).
  - *Re-run all* — recompute every non-manual txn against the full rule set (e.g. after editing priorities).
- **"Create rule from transaction"** — UI pre-fills a `contains payee` condition; one click to persist + optionally backfill.

---

## 8. Categorization Pipeline (`internal/categorize`)

Runs on each new/uncategorized transaction:

```
txn ──▶ rules.Match(txn)
          ├─ hit  ─▶ set category, source = rule:<id>   ✅ done (deterministic)
          └─ miss ─▶ if ai_enabled and not transfer:
                        enqueue for AI batch
                     else: leave Uncategorized
```

**AI fallback (`internal/ai`):**
- Interface: `Categorizer.Suggest(ctx, []TxnContext, []Category) ([]Suggestion, error)`.
- Implementations: `claude` (Anthropic SDK) and `noop` (when disabled).
- **Batched** (N txns/request) to control cost; respects a monthly cap setting.
- **Privacy:** sends only `description`, `payee`, `amount_cents`, `currency`, and the category list. **Never** account numbers, balances, or the Access URL. Field set is configurable.
- Output → `ai_suggestions` rows (category + confidence + optional **suggested rule** + rationale), **status=pending**. AI never writes a category directly in v1.
- **Human-in-the-loop:** review queue UI. Accepting a suggestion either categorizes that one txn (`source='ai'`→ effectively manual once confirmed) or **promotes the suggested rule** to a permanent `rules` row (then deterministic forever).

**Transfer detection:** before AI, a heuristic pairs opposite-sign, equal-magnitude txns across two of the household's own accounts within a small date window → marks both `is_transfer=1`, shared `transfer_group_id`, category kind `transfer` (excluded from spend totals). Manual override available.

---

## 9. Interest, Net Worth, Property (`internal/interest`, `internal/networth`, `internal/property`)

**Interest detection:**
- Rules with kind `interest` (seeded defaults match `INTEREST CHARGE`, `FINANCE CHARGE`, etc.) categorize charges into the system **Interest** category.
- **Payment splits:** for mortgage/loan payments that are a single lump, a `payment_splits` row (manual or rule-derived) attributes principal/interest/escrow. The **interest portion** feeds interest rollups; principal is informational (the loan balance itself stays authoritative from SimpleFIN).
- **Debt-cost rollups:** interest paid by account and by period (month/YTD), ranked; uses categorized interest txns + split interest portions. Optional `apr_bps` per account for estimates/sanity checks.

**Net worth (`internal/networth`):**
- `assets = Σ liquid + Σ investment + Σ property_latest_value`
- `liabilities = Σ secured_debt + Σ unsecured_debt` (loan account balances)
- `net_worth = assets − liabilities` using **latest authoritative balances** + latest `property_values`.
- **No double counting:** a property contributes its market value as an asset; its linked mortgage/HELOC accounts contribute as liabilities (not subtracted twice). `property_equity = value − Σ(linked debt balances)` is a derived display metric.
- **Over-time series:** built from `balance_snapshots` joined to (class at query time) + step-interpolated `property_values`. Computed on read; cached if needed.

---

## 10. Configuration (`internal/config`)

Env vars (12-factor) with a small optional TOML for non-secrets:

```
TTM_DB_PATH=/data/ttm.db
TTM_LISTEN_ADDR=:8080
TTM_SECRET_KEY=...            # 32-byte key for crypto (Access URLs, AI key) — required
TTM_SESSION_TTL=720h
ANTHROPIC_API_KEY=...         # optional; AI disabled if absent
```

DB-backed `settings` (editable in UI): `ai_enabled`, `ai_monthly_cap`, `ai_fields`, `sync_cron`, `sync_overlap_days`, `default_backfill_days`, `timezone`.

---

## 11. HTTP API Surface (`internal/api`)

JSON REST under `/api`, session-cookie auth on all but `/auth/login`. Representative endpoints:

```
POST   /api/auth/login                 password → session cookie
POST   /api/auth/logout

GET    /api/networth                   totals + breakdown (latest)
GET    /api/networth/series?from&to    over-time points

GET    /api/connections                list + status
POST   /api/connections/claim          { setup_token } → claim flow → store
DELETE /api/connections/{id}
POST   /api/sync                        trigger sync (all or ?connection=)

GET    /api/accounts                    list with class/balance
PATCH  /api/accounts/{id}               set class/subclass/apr_bps/archived

GET    /api/transactions?...            filter: account, category, date, q (FTS), pending
PATCH  /api/transactions/{id}           set category (manual), transfer flag
POST   /api/transactions/{id}/split     create/update payment_split

GET    /api/categories                  tree
POST   /api/categories  PATCH/DELETE
GET    /api/rules
POST   /api/rules  PATCH/DELETE
POST   /api/rules/run                   { mode: forward|backfill|rerun, rule_id? }
POST   /api/rules/from-transaction      { transaction_id } → prefilled rule

GET    /api/ai/suggestions?status=pending
POST   /api/ai/suggestions/{id}/accept  { promote_rule: bool }
POST   /api/ai/suggestions/{id}/reject

GET    /api/properties                  with latest value + linked debts + equity
POST   /api/properties  PATCH/DELETE
POST   /api/properties/{id}/value       add value history point
POST   /api/properties/{id}/debts       link/unlink account

GET    /api/interest?from&to            interest-by-account/period rollup
GET    /api/settings    PATCH /api/settings
```

---

## 12. Frontend (`web/` — Lit + Vite + TS)

```
web/
├── index.html
├── vite.config.ts                # builds to ../internal/api/assets
├── src/
│   ├── main.ts                   # router init, app shell
│   ├── api/client.ts             # typed fetch wrapper (shares DTO types)
│   ├── state/                    # lightweight reactive store (signals/context)
│   ├── components/               # reusable Lit elements (cards, tables, chart)
│   └── views/
│       ├── networth-view.ts      # headline + breakdown + over-time chart
│       ├── accounts-view.ts      # classification controls
│       ├── real-estate-view.ts   # value vs mortgage+heloc, equity, value history
│       ├── transactions-view.ts  # FTS search, quick-categorize, create-rule
│       ├── rules-view.ts         # rule list, priority, AI review queue
│       ├── spending-view.ts      # category breakdown by period
│       ├── debt-interest-view.ts # secured/unsecured, interest paid
│       └── settings-view.ts      # connections, sync, AI/privacy config
```

- **LitElement** components, `@lit/context` for app state, native Web Components routing (or `@lit-labs/router`).
- **Typed API client** mirrors Go DTOs (hand-kept or generated). All money rendered from integer cents with a shared formatter; all times rendered in the household TZ.
- **Charts** via uPlot for the net-worth series and interest trends.
- Built by Vite to static assets, **embedded into the binary** with `go:embed` and served by chi.

---

## 13. Security

- **Single shared credential**, argon2id-hashed in `auth`; session tokens stored hashed in `sessions`; `HttpOnly`, `SameSite=Lax`, `Secure` cookies.
- **Secrets at rest** (Access URLs, AI key if DB-stored) encrypted with AES-GCM via `TTM_SECRET_KEY` (`internal/crypto`).
- **HTTPS expected** even self-hosted (reverse proxy or built-in TLS); document a Caddy/Traefik example.
- **AI egress minimized** and opt-in; field allow-list enforced server-side, not just UI.
- **Backups:** `VACUUM INTO` endpoint/CLI for a consistent file copy; document restore.

---

## 14. Milestone-1 Build Order

1. **Skeleton:** config, SQLite open + PRAGMAs + goose migrations, chi server, embedded SPA shell, login.
2. **SimpleFIN client + claim flow** + encrypted connection storage.
3. **Sync engine:** accounts, transactions (idempotent upsert), balance snapshots, pending reconcile, error surfacing.
4. **Classification + net worth** (latest + over-time) + accounts view.
5. **Properties** (value history, debt links, equity) + real-estate view.
6. **Categories + rules engine** (forward/backfill/rerun) + transactions/rules views.
7. **AI fallback** (Claude `Categorizer`, batch, review queue, promote-to-rule) + privacy config.
8. **Interest** detection + payment splits + debt/interest dashboard.
9. **Polish:** FTS search, transfer detection, backup/export, scheduler defaults.

---

## 15. Resolved vs Still-Open

**Resolved by this design:** store (SQLite/WAL/STRICT), money (int64 cents), idempotency keys, v1/v2 defensive parsing, AI privacy boundary, no-double-count net worth.

**Still open (validate during build):**
- SimpleFIN Bridge **rate limits** → final `sync_cron` + overlap defaults.
- **Default backfill depth** on first sync (institution-dependent).
- AI **monthly cap** value + whether to allow high-confidence **auto-apply** later.
- Multi-currency: schema is ready (`currency` columns); conversion/display deferred.
```
