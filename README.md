# Track The Money

**An opinionated personal finance tracker for iOS and macOS.** Your accounts, your
transactions, your net worth — on your device, and nowhere else.

- **Live bank data via [SimpleFIN](https://www.simplefin.org/)** — you claim your own
  access token; no screen-scraping aggregator sits between you and your banks, and the
  app never sees your bank credentials.
- **Local-first, actually.** Everything lives in a local SQLite database (GRDB,
  WAL + STRICT tables, FTS5 search). The SimpleFIN access URL is the only secret,
  and it lives in the Keychain — never in the database, never on a server.
- **On-device AI categorization.** Deterministic rules run first; when they miss,
  Apple's Foundation Models on-device LLM proposes a category (with a
  merchant-keyword heuristic as the fallback on every device). Suggestions are
  never auto-applied, and no cloud LLM is ever called.
- **Net worth that understands real life** — real-estate value history with linked
  mortgages/HELOCs for true equity, and debt tracked as secured vs. unsecured over time.
- **Native SwiftUI, one codebase** — iPhone, iPad, and a real AppKit-backed Mac app
  (not Catalyst), with a deliberate editorial design ("The Statement": serif numerals,
  paper surfaces, evergreen = assets, clay = debts).

## What's inside

- **Net Worth** — headline rollup plus an over-time chart rebuilt from balance snapshots.
- **Accounts** — class picker (liquid / investment / secured debt / unsecured debt),
  display nicknames that sync never overwrites.
- **Transactions** — full-text search (FTS5), categorized/uncategorized filter chips
  with a review-count badge, tap-to-categorize with instant apply.
- **Spending** — per-category colored chart with a month selector (last 6 months + all time).
- **Categories** — two-level tree (groups → leaves, transactions always on leaves),
  deterministic auto-assigned colors, full manager: rename, recolor, reorder, regroup,
  merge, delete-with-reassign.
- **Rules** — condition-tree matcher applied at sync time; "all CHEWY.COM → Pets" in
  one gesture from the categorize sheet.
- **Review mode** — a guided one-at-a-time pass over uncategorized transactions, with
  AI suggestions and one-tap approve.
- **Real Estate** — properties, value history, linked debt, computed equity.
- **Debt & Interest** — interest detection, payment splits, cost-of-debt rollups.

## Architecture at a glance

Two layers with a hard boundary:

```
track-the-money
├── TTMCore/                  Pure Swift package — no SwiftUI/UIKit/AppKit
│   └── Sources/TTMCore/
│       ├── Money/            Int64 cents, exact Decimal parsing
│       ├── Persistence/      GRDB database, migrations, Store DAO, seed data
│       ├── SimpleFIN/        Protocol models + live client
│       ├── Sync/             Idempotent sync engine, transfer detection
│       ├── Rules/            Condition tree + first-match rule engine
│       ├── Classify/         Categorizer pipeline, palette, AI seam
│       ├── NetWorth/         Rollup + step-function series math
│       ├── Interest/         Interest detection + debt cost
│       └── Facade/           CoreFacade protocol + LocalCore implementation
└── app/                      SwiftUI app (also an SPM package)
    └── Sources/TrackTheMoney/
        ├── Features/         One view per screen
        ├── Platform/         Keychain, URLSession, Foundation Models adapters
        ├── AppModel.swift    @Observable view model over CoreFacade
        └── Theme.swift       "The Statement" design system
```

The app talks only to the `CoreFacade` protocol. `TTMCore` reaches the OS only
through injected protocols (`SecretStore`, `NetworkClient`, `Clock`,
`OnDeviceCategorizer`), so the whole engine is unit-testable headlessly — 39 tests
and counting. The platform implementations (Keychain, URLSession, Apple's
Foundation Models) live in the app layer and are injected at launch.

## Running locally

Prerequisites: Xcode with the iOS 17 / macOS 14 SDKs, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen        # one-time
xcodegen generate            # project.yml → TrackTheMoney.xcodeproj (gitignored)
open TrackTheMoney.xcodeproj
```

Pick the **TrackTheMoney** scheme and any destination — iPhone/iPad Simulator or
My Mac. Set your Team under Signing & Capabilities to run on a device.

Headless iteration, no Xcode UI needed:

```bash
cd TTMCore && swift test          # the whole engine, 39 tests
cd app && swift run TrackTheMoney # launch the Mac app from the CLI
```

See [BUILD.md](docs/BUILD.md) for CI-style `xcodebuild` invocations and how one
multiplatform target covers iPhone, iPad, and Mac.

## Sample data

Explore without connecting a bank — two equivalent paths:

- In the app: **Settings → Try it → Load sample data**.
- At launch: pass the `-sampleData` launch argument (in Xcode: scheme → Run →
  Arguments). Add `-tab transactions` to land on a specific tab, or `-resetStore`
  to start from a clean database — the same arguments the UI tests use.

Sample data seeds demo accounts, ~8 months of balance history, categorized
transactions, and a house with a linked mortgage.

## Connecting real accounts

Get a setup token from your SimpleFIN bridge (e.g. the
[SimpleFIN Bridge](https://bridge.simplefin.org/)), then in the app:
**Settings → Add SimpleFIN connection → paste setup token → Add connection**.
The app claims the token, stores the resulting access URL in your Keychain, and
**Sync now** pulls accounts and transactions. Rules run at sync time; transfers
are auto-detected.

## Project docs

All documentation lives in [`docs/`](docs/); feature plans live in
[`docs/plans/`](docs/plans/).

- [PLAN.md](docs/PLAN.md) — product plan
- [TECH_DESIGN.md](docs/TECH_DESIGN.md) — architecture
- [IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) — running status / resume pointer
- [BUILD.md](docs/BUILD.md) — build matrix
- [plans/CATEGORIZATION_PLAN.md](docs/plans/CATEGORIZATION_PLAN.md) — categorization design (shipped)
- [plans/DATA_PORTABILITY_PLAN.md](docs/plans/DATA_PORTABILITY_PLAN.md) — backup & restore (approved, not yet built)
