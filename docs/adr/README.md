# Architecture Decision Records

One file per decision: the context it was made in, what was decided, and what it
costs. ADRs are **immutable** — when a decision changes, add a new record that
supersedes or amends the old one rather than editing history. That trail is the
point: it shows what was believed at the time and what changed the mind.

New record: copy [`TEMPLATE.md`](TEMPLATE.md), take the next number, add a row here.

## Product & scope

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-local-first-freemium.md) | Local-first free app with an optional paid cloud tier | Accepted |
| [0002](0002-open-core-repo-boundary.md) | Open core: public app repo, private cloud repo | Accepted |
| [0003](0003-simplefin-is-truth.md) | SimpleFIN is authoritative; no competing ledger | Accepted |
| [0004](0004-device-owns-simplefin-sync.md) | The device owns SimpleFIN sync, in both tiers | Accepted |

## Architecture

| ADR | Decision | Status |
|---|---|---|
| [0005](0005-swiftui-ios-macos.md) | SwiftUI for iOS and macOS from one codebase | Accepted |
| [0006](0006-ttmcore-pure-package.md) | TTMCore is a pure, platform-free Swift package | Accepted |
| [0007](0007-corefacade-boundary.md) | CoreFacade is the only app-facing surface | Accepted |
| [0008](0008-defer-rust-core.md) | Defer the Rust core port until Android is scheduled | Deferred, with revisit trigger |
| [0009](0009-sqlite-via-grdb.md) | SQLite via GRDB as the on-device store | Accepted |
| [0021](0021-xcodegen-project-generation.md) | `project.yml` is the source of truth; `.xcodeproj` generated | Accepted |

## Data & correctness

| ADR | Decision | Status |
|---|---|---|
| [0010](0010-money-and-time-conventions.md) | Money is Int64 cents; time is UTC unix seconds | Accepted |
| [0011](0011-idempotent-sync.md) | Idempotent sync keyed on `(account_id, sfin_txn_id)` | Accepted |
| [0012](0012-net-worth-rollup-rules.md) | Liabilities as magnitudes; no double-counted equity | Accepted |
| [0022](0022-sync-never-overwrites-user-edits.md) | Sync and seeding never overwrite user edits | Accepted |

## Security & privacy

| ADR | Decision | Status |
|---|---|---|
| [0013](0013-access-url-keychain-only.md) | The SimpleFIN Access URL lives only in the Keychain | Accepted |
| [0014](0014-zero-knowledge-cloud-relay.md) | The cloud tier is a zero-knowledge E2E relay | Accepted — not yet built |

## Categorization

| ADR | Decision | Status |
|---|---|---|
| [0015](0015-two-level-categories.md) | Two-level categories; transactions on leaves | Accepted |
| [0016](0016-deterministic-category-colors.md) | Category colors are auto-assigned deterministically | Accepted |
| [0017](0017-three-tier-categorization.md) | Rules → on-device AI → cloud AI; never auto-applied | Accepted (amends 0001) |

## Data portability

| ADR | Decision | Status |
|---|---|---|
| [0018](0018-backup-format-sqlite-snapshot.md) | Backups are SQLite snapshots (`.ttmbackup`) | Accepted |
| [0019](0019-restore-replaces-everything.md) | Restore replaces everything, with one undo | Accepted |
| [0020](0020-backups-exclude-secrets.md) | Backups exclude secrets; CSV and auto-backup deferred | Accepted |
| [0023](0023-profiles-one-store-per-data-set.md) | Profiles: one store per data set; secrets stay per connection | Accepted |
| [0024](0024-manual-accounts-and-account-deletion.md) | Manual accounts under a hidden local connection; deleted synced accounts become tombstones; credit-card class; user-entered APR | Accepted |
| [0025](0025-account-status-excluded-and-paused.md) | Whether an account counts or syncs is a status (active / excluded / paused), separate from its class; catch-up windows; hold new accounts | Accepted |
| [0026](0026-credit-card-promo-apr.md) | Credit-card promo rates are user-entered with a last day; payoff risk applies cash to the earliest deadline first | Accepted |
| [0027](0027-expected-expenses.md) | Expected expenses are detected from recent history, deterministically, and removed per merchant | Accepted |

## Known open questions

Not yet decided; recorded in [TECH_DESIGN.md](../TECH_DESIGN.md) §14 rather than
as ADRs, because there's nothing to decide until real usage says so:
SimpleFIN rate limits vs sync cadence · default backfill depth on first sync ·
sync conflict resolution (LWW vs per-field merge) · group-E2E key rotation ·
AI cost ceiling per paid user · multi-currency conversion · pricing.
