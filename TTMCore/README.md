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
| `SimpleFIN` | 🟡 models + client | Codable v1/v2 models, `SimpleFINClient` (live impl) |
| `Persistence` | 🟡 schema | GRDB `Database` + v1 migration (faithful to TECH_DESIGN §5) |
| `Interest` | ⬜ stub | detection patterns + rollups (TODO M1.7) |
| `Sync` | ⬜ stub | on-device sync engine (TODO M1.3) |
| `Crypto` | ⬜ stub | HPKE/CryptoKit record sealing for paid relay (TODO M2.9) |
| `SyncClient` | ⬜ stub | device-side client for the zero-knowledge relay (TODO M2.9+) |
| `Facade` | ✅ contract | `CoreFacade` — the single app-facing API (port choke-point) |

## Build & test

```bash
cd TTMCore
swift build
swift test          # Money, Rules, Classify, NetWorth have real tests
```

Requires a Swift toolchain (Xcode on macOS). GRDB is fetched via SPM on first
build; bump its version in `Package.swift` as desired.

## Next implementation steps (Milestone 1)

1. `Persistence` record types + queries (GRDB `FetchableRecord`/`PersistableRecord`).
2. `Sync.SyncEngine` — idempotent upsert, balance snapshots, pending reconcile.
3. A concrete `CoreFacade` implementation wiring DB + sync + rules.
4. Categorization pipeline (rules → uncategorized), interest rollups.
