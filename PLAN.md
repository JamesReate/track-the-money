# Track The Money — Product Plan & Feature Spec

> A **local-first**, native personal/family financial tracker. SimpleFIN is the **authoritative source** of account balances and transactions. The app's job is not bookkeeping — it's **classification, categorization, and insight**: realtime net worth, expense buckets, and "how much am I paying in interest." Free on-device; optional paid cloud tier for sync, multi-user, and AI.

**Status:** Spec / planning. On-device stack (Swift `TTMCore` + SwiftUI + GRDB/SQLite) and cloud backend (Go, private repo) detailed in [TECH_DESIGN.md](TECH_DESIGN.md).
**Last updated:** 2026-06-25

---

## 1. Product Decisions (locked)

| Decision | Choice | Implication |
|---|---|---|
| Product shape | **Local-first, native app** (free) + **optional paid cloud** | Free tier runs entirely on-device. Paid tier adds cloud sync, multi-user, and AI. See §1a. |
| Frontend | **SwiftUI** (iOS primary, macOS primary), Android/Windows later | Native Apple feel from one SwiftUI codebase across iOS + Mac. Charts via Swift Charts. |
| Shared core | **Swift `TTMCore`** — pure, UI-independent module | Holds SimpleFIN client, sync, rules, net-worth/interest math, persistence. No SwiftUI/UIKit deps → unit-testable and **portable to Rust/KMP at the Android milestone** without a tangle. |
| On-device store | **SQLite via GRDB** | Single-writer on device fits SQLite. Type-safe queries, migrations, change observation. |
| Users & auth | **Free: single on-device profile** · **Paid: multi-user cloud accounts** | No login needed for the free local app. Accounts/auth live in the paid backend only. |
| AI categorization | **Rules-first (free, on-device)** · **AI fallback (paid, server-side)** | Deterministic rules ship in the free app. AI categorization is a paid-tier perk run on the backend (prompts/keys private). |
| Cloud backend | **Separate private repo** (`track-the-money-cloud`, Go + Postgres) | Open-core: the moat (sync relay, AI, billing, infra) stays private. Free app is complete without it. |
| First milestone | **On-device: sync foundation → net worth + categorization (equal weight)** | Ship the free local app first; cloud/AI tier follows. |

### 1a. Business Model & Tiers

**Free (local-first, open source, app stores):**
- Runs entirely on-device. SimpleFIN sync, deterministic rules, categorization, net worth, real estate, interest tracking — all local.
- Access URL stored in OS secure storage (Keychain). No account, no server, **no cost to operate**.
- Platforms: iOS primary, macOS primary (Android/Windows later).

**Paid (low yearly fee):**
- **Cloud sync** across devices + **multi-user** (family members on their own devices).
- **AI auto-categorization** (server-side Claude) for transactions rules didn't match.
- **End-to-end encrypted:** the backend stores opaque ciphertext and cannot read user financial data — a core selling point.

The free/paid line *is* the public/private repo line (see [TECH_DESIGN.md](TECH_DESIGN.md) §Repo Boundary).

### Guiding principles
- **SimpleFIN is truth.** We never compute a balance ourselves and present it as authoritative. We layer *meaning* on top (classification, categories), not a competing ledger.
- **Local-first.** The free app is fully functional offline/on-device. The cloud is an enhancement, never a requirement.
- **Rules are deterministic and inspectable.** A user must always see *why* a transaction landed in a category. AI is a paid assistant that proposes rules, never an opaque black box that silently moves money.
- **Idempotent sync.** Re-syncing the same window must never duplicate transactions or corrupt history.
- **Privacy by default.** On-device by default; cloud sync is end-to-end encrypted; the only plaintext that leaves the device is the minimal, bounded payload sent to the AI service (descriptions/payees/amounts — never balances or credentials).

---

## 2. SimpleFIN Integration (the foundation)

SimpleFIN Bridge (`https://beta-bridge.simplefin.org`) connects to financial institutions and exposes a simple read-only API. We consume it; we never write back.

### 2.1 Connection / claim flow
1. User generates a **Setup Token** from the SimpleFIN Bridge (`/create`, base64-encoded URL).
2. App decodes the token and `POST /claim/:token` to exchange it for an **Access URL** that embeds HTTP Basic Auth credentials.
3. App stores the Access URL in **OS secure storage (Keychain)** — it is a long-lived credential and never leaves the device (not even to the paid cloud tier).
4. All data fetches use `GET {access-url}/accounts` with Basic Auth.

> The setup token is single-use; the resulting Access URL is the durable secret. Losing it means re-claiming. Treat it like a password.

### 2.2 Data model returned (fields we rely on)
- **AccountSet**: `errlist`, `accounts[]` (and v2 `connections[]`).
- **Account**: `id`, `name`, `currency` (ISO 4217), `balance` (numeric string), `available-balance` (optional), `balance-date` (unix ts), `org`/`conn_id` (institution), `transactions[]`.
- **Transaction**: `id` (unique within account), `posted` (unix ts; 0 if pending), `amount` (numeric string, positive = deposit/credit), `description`, `payee`/`memo` (v1) or `transacted_at`/`extra` (v2), `pending` (bool).
- **Org / Connection**: institution `name`, `domain`/`org_url`, `sfin-url`.

### 2.3 Sync engine requirements
- **Money is stored as integer minor units** (cents) parsed from the numeric string — never floats.
- **Query window**: `start-date` / `end-date` (unix ts), `pending=1` to include pending. Use overlapping windows with idempotent upsert keyed on `(account_id, simplefin_txn_id)`.
- **Balance snapshots**: each sync records `(account_id, balance, available_balance, balance_date)` into a time-series table → this is what powers net-worth-over-time charts.
- **Pending → posted reconciliation**: a pending txn that later posts keeps the same id; upsert handles the transition. Pending txns are flagged and excluded from "final" interest/expense totals but shown in the UI.
- **Sync triggers**: manual ("Sync now") + scheduled (configurable cron, default a few times/day). SimpleFIN rate limits apply — be conservative.
- **Error surface**: `errlist` and per-connection failures (e.g. bank needs re-auth) are shown prominently, not swallowed.
- **Multiple connections**: a household may claim more than one Access URL (e.g. different banks). Each is a Connection with its own accounts.

---

## 3. Account Classification → Net Worth

The user assigns each synced account (and manual asset) to a **class** that determines how it rolls up into net worth.

### 3.1 Account classes
| Class | Sign in net worth | Examples |
|---|---|---|
| **Cash / Liquid** | + asset | Checking, savings, money market |
| **Investment** | + asset | Brokerage, retirement (401k/IRA), HSA |
| **Secured debt** | − liability | Mortgage, auto loan, HELOC |
| **Unsecured debt** | − liability | Credit cards, personal loans, student loans |
| **Real estate / Physical asset** | + asset (manual value) | Home, vehicle, valuables — see §3.2 |
| **Income source** | tracked, not a balance | Paycheck origin accounts (tagging, not net worth) |
| **Excluded / Other** | ignored | Accounts you don't want in the picture |

- Classification is user-controlled with a **smart default guess** based on account name/type (e.g. "VISA" → unsecured debt) that the user can override.
- Sub-classification / grouping (e.g. "Retirement" vs "Taxable") for nicer dashboards.

### 3.2 Real estate & manually-valued assets
Real estate isn't in SimpleFIN, so it's modeled explicitly:
- A **Property** has: name, **estimated market value** (manually entered, with date + history of value edits), optional auto-value source later (e.g. Zillow-style estimate — out of scope v1).
- A property **links to its debt accounts**: the mortgage (secured) and any HELOC (secured) that are *real* SimpleFIN accounts.
- **Property equity = market value − (mortgage balance + HELOC balance)**, where the debt balances come live from SimpleFIN.
- Net worth treats the property value as an asset and the linked loans as liabilities (avoiding double counting — the loan is the liability, the home value is the asset).

### 3.3 Net worth dashboard
- **Realtime total net worth** = Σ assets − Σ liabilities, using the latest SimpleFIN balances + manual asset values.
- Breakdown cards: liquid, investments, real estate equity, secured debt, unsecured debt.
- **Net worth over time** chart from balance snapshots (§2.3).
- **Debt view**: total secured vs unsecured, with per-account balances and (where derivable) rates.

---

## 4. Expense Categorization

### 4.1 Categories
- **Hierarchical categories** (e.g. `Kids > Childcare`, `Home > Repairs`, `Pets/Dog`, `Groceries`, `Auto`, `Dining`).
- Ships with a sensible default set; fully user-editable (add/rename/merge/delete with re-mapping).
- Each transaction has **exactly one category** (keep v1 simple); optional free-form **tags** for cross-cutting labels.
- Special system categories: **Transfer** (between own accounts — excluded from spend totals), **Income**, **Interest** (see §5), **Uncategorized**.

### 4.2 Rules engine (deterministic, first line)
- A **rule** matches transactions and assigns a category. Match conditions:
  - Payee/description **contains / equals / regex**
  - Specific **account**
  - **Amount** range or sign
  - (composable AND/OR)
- Rules have **priority order**; first match wins, with a clear "why" trail shown on each transaction.
- **"Apply going forward" + "apply to past":** when a rule is created, choose whether to backfill existing matching transactions or only categorize future ones.
- The canonical workflow: *"All charges from `CHEWY.COM` → Pets/Dog"* becomes a one-click rule from any transaction.
- Rules are **inspectable and editable** in one place; user can re-run all rules.

### 4.3 AI fallback (assistant, second line — **paid tier, server-side**)
- **Free tier is rules-only.** AI categorization is a **paid-tier feature**: the device sends unmatched transactions to the cloud backend, which calls Claude. Prompts, API key, and eval live in the private backend repo — never on-device.
- Runs **only on transactions no rule matched** (Uncategorized).
- For each, the AI proposes: a **category** + **confidence** + optionally a **suggested reusable rule** ("looks like all `TST* DOG GROOMER` are Pets/Dog — make a rule?").
- **Human-in-the-loop**: suggestions land in a review queue. Confirming a suggestion can (a) categorize the one txn, or (b) promote it to a permanent **local** rule so it's deterministic forever after (and works offline/free from then on).
- **Privacy boundary** (enforced server-side, not just UI): only `description` / `payee` / `amount` / category list are sent — **never account numbers, balances, or SimpleFIN credentials**. Batched to limit calls/cost.
- AI **never auto-commits** a category without confirmation (a confidence threshold could auto-apply later).

---

## 5. Interest & Debt Cost Tracking

A first-class question: **"How much am I paying in interest?"**

- **Interest detection**: transactions that represent interest charges (credit card finance charges, loan interest portions, mortgage interest) are categorized as **Interest** — via rules (e.g. description contains `INTEREST CHARGE`, `FINANCE CHARGE`) and AI assist.
- **Interest by account & by period**: "$X in credit card interest this month / YTD," "$Y mortgage interest YTD," totals across all debt.
- **Per-account rate (where available)**: store an APR per debt account (manually entered or detected) to estimate cost and to sanity-check charges.
- **Mortgage/loan payment split**: a single payment is principal + interest (+ escrow). Where SimpleFIN gives only the lump payment, allow a **manual or rule-based split** so the interest portion feeds interest totals while principal reduces the loan balance (which SimpleFIN already reflects authoritatively).
- **Debt cost dashboard**: total monthly/annual interest burden, ranked by account, trend over time.

---

## 6. Core Dashboards & Views (UI surface)

1. **Home / Net Worth** — headline number, asset/liability breakdown, net-worth-over-time, recent sync status.
2. **Accounts** — all connections & accounts, class, latest balance, "needs re-auth" flags, classification controls.
3. **Real Estate** — properties, value vs (mortgage + HELOC), equity, value-edit history.
4. **Transactions** — searchable/filterable feed; quick-categorize; "create rule from this txn"; pending badges.
5. **Categories & Rules** — manage hierarchy; manage rule list & priority; re-run rules; AI review queue.
6. **Spending** — category breakdown by period, trends, transfers excluded, income vs spend.
7. **Debt & Interest** — secured vs unsecured, balances, APRs, interest paid by account/period.
8. **Settings** — SimpleFIN connections (claim/re-auth/remove), sync schedule, AI config & privacy, category defaults, backup/export.

---

## 7. MVP Scope (Milestone 1)

**Goal:** ship the **free, local-first SwiftUI app** (iOS + Mac) with a working realtime net-worth + categorized-spending picture — fully on-device.

**In scope (free, on-device)**
- SimpleFIN claim flow + Access URL in Keychain (multi-connection).
- Idempotent sync engine: accounts, transactions, balance snapshots, pending handling.
- Account classification + smart defaults → **net worth dashboard** (with over-time chart via Swift Charts).
- Real estate properties with manual value + linked mortgage/HELOC → equity.
- Category hierarchy + **deterministic rules engine** (apply-forward & backfill).
- Interest categorization + basic **debt/interest dashboard**.
- Manual + scheduled sync; single on-device profile (no login).

**Deferred to the paid tier (Milestone 2, private backend repo)**
- Cloud sync (multi-device) + multi-user accounts.
- **AI auto-categorization** with human-in-the-loop review queue → promote to local rules.

**Explicitly out of scope (v1)**
- Budgets / goals / forecasting / alerts.
- Automated property valuation (Zillow-style).
- Investment holdings-level detail (securities/lots) — account-level balance only.
- Writing back to institutions, bill pay, payments.
- Android / Windows apps (Apple-first; `TTMCore` kept portable for later).

---

## 8. Cross-Cutting Requirements

- **Money:** integer minor units (cents) everywhere — never floats; currency-aware (multi-currency support deferred but schema-ready).
- **Idempotency & auditability:** every sync and every rule application is traceable; transactions show their categorization source (rule id / AI / manual).
- **Security:** Access URL in Keychain on-device; cloud sync is end-to-end encrypted (server holds only ciphertext); AI key lives server-side only.
- **Backup/Export:** local DB export + CSV/JSON export of transactions and net-worth history (paid tier adds cloud backup).
- **Resilience:** a failed connection (bank needs re-auth) degrades gracefully — other accounts still sync and display.
- **Time zones:** store UTC; display in the household's configured local time.

---

## 9. Open Questions (for the tech-stack pass)

1. **SimpleFIN protocol version** — confirm whether beta-bridge returns v1 (`payee`/`memo`, `org`) or v2 (`connections`, `transacted_at`); support both defensively.
2. **Sync cadence vs rate limits** — confirm SimpleFIN Bridge rate limits to set safe scheduler defaults.
3. **AI cost ceiling** — batch size, monthly cap, and whether to auto-apply above a confidence threshold.
4. **Transfer detection** — auto-pair transfers between own accounts (matching amount/date across two accounts) vs manual tagging.
5. **Historical depth** — how far back to backfill transactions on first sync (institution-dependent).
6. **Multi-currency** — needed at launch or schema-ready only?

---

## 10. Technical Design

See **[TECH_DESIGN.md](TECH_DESIGN.md)** for the on-device architecture (Swift `TTMCore` + SwiftUI + GRDB/SQLite — sync, rules, net-worth engines), the SQLite schema, the repo boundary (public app vs private `track-the-money-cloud` backend), and the E2E-encrypted sync + AI contract (`/contract/openapi.yaml`).
