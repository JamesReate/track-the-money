# TTMCore

The pure, UI-independent domain core for Track The Money (Swift package).

**Hard rule:** no SwiftUI/UIKit/AppKit imports here, and the OS is reached only
through injected protocols (`Clock`, `SecretStore`, `NetworkClient`). This keeps
the engines unit-testable and the future Rust port bounded (see
[`../TECH_DESIGN.md`](../TECH_DESIGN.md) §13).

## Modules

| Module | Status | What |
|---|---|---|
| `Money` | ✅ real | `Money` (Int64 cents), exact decimal-string parsing, formatting |
| `Time` | ✅ real | UTC unix-seconds helpers |
| `Support` | ✅ real | `Clock` / `SecretStore` / `NetworkClient` protocols, errors |
| `Classify` | ✅ real | `AccountClass` + smart-default guesser |
| `Rules` | ✅ real | condition model + matcher (first-match-by-priority) |
| `NetWorth` | ✅ rollup | pure asset/liability rollup helper |
| `SimpleFIN` | ✅ models + client | Codable v1/v2 models, `SimpleFINClient` (live impl) |
| `Persistence` | ✅ real | GRDB `Database` + v1 migration, `Store` (DAO), records, seed data |
| `Sync` | ✅ real | on-device sync engine — idempotent upsert, snapshots, reconcile |
| `Classify/Categorizer` | ✅ real | rules pipeline at sync time + backfill/rerun |
| `Facade` | ✅ contract + impl | `CoreFacade` + `LocalCore` (free on-device implementation) |
| `Interest` | ✅ real | detection rule + payment splits + debt-cost rollups |
| `NetWorth` series | ✅ real | over-time reconstruction from balance_snapshots |
| `Transactions` | ✅ real | `TxnQuery` listing + FTS5 search + transfer detection |
| `Property` | ✅ real | properties, value history, linked-debt equity |
| `Crypto` | ⬜ stub | HPKE/CryptoKit record sealing for paid relay (TODO M2) |
| `SyncClient` | ⬜ stub | device-side client for the zero-knowledge relay (TODO M2) |

## Build & test

```bash
cd TTMCore
swift build
swift test          # Money, Rules, Classify, NetWorth have real tests
```

Requires a Swift toolchain (Xcode on macOS). GRDB is fetched via SPM on first
build; bump its version in `Package.swift` as desired.

## Working end-to-end now

`LocalCore` wires DB + on-device SimpleFIN sync + rules. `SyncTests` drives the
full path with fakes (no network): claim → sync → idempotent re-sync → rule
applied at sync time → net worth from synced data.

## Next implementation steps (Milestone 1)

1. Transaction list + FTS search queries; transfer auto-detection.
2. Interest rollups (detect + payment splits) → debt/interest view.
3. Property CRUD + value history + linked-debt equity in `netWorthSummary`.
4. Net-worth over-time series from `balance_snapshots`.
5. Wire `LocalCore` into the SwiftUI app (replace `NetWorthView`'s static data).
