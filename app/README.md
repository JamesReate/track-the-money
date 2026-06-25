# Track The Money — App (SwiftUI)

The iOS/iPadOS/macOS app, structured as a **Swift Package** (`TrackTheMoneyApp`)
so it builds headlessly and in Xcode. It depends on the local `TTMCore` package
and talks to it only through `CoreFacade` (via `AppModel`).

## Build / run

```bash
cd app
swift build             # compiles the SwiftUI app for the host (macOS)
swift run TrackTheMoney # launches it on macOS
```

For the **iOS** App Store target, create an Xcode app that adds this package (or
its sources) and the `TTMCore` package; the SwiftUI code is shared verbatim.

## Layout

```
app/
├── Package.swift
└── Sources/TrackTheMoney/
    ├── App.swift              // @main + RootView (TabView)
    ├── AppModel.swift         // @Observable bridge over CoreFacade
    ├── Platform/              // SecretStore (Keychain) + NetworkClient (URLSession)
    └── Features/              // NetWorth, Accounts, Transactions, DebtInterest, Settings
```

`AppModel.live()` wires `LocalCore` to SQLite in Application Support, the
Keychain, and URLSession. Screens read `AppModel`'s observable state and call its
async actions (sync, claim, set class, search).

## Status

Wired screens: **Net Worth** (with Swift Charts over-time), **Accounts** (class
picker), **Transactions** (FTS search), **Debt & Interest**, **Settings** (claim
token + sync). Next: Rules editor, Spending breakdown, Real Estate, AI review
queue (paid).
