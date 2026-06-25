# Track The Money — App (SwiftUI)

The iOS/iPadOS/macOS app target. These are **drop-in source files** for an Xcode
app target that depends on the local `TTMCore` package — there is intentionally
no `.xcodeproj` committed yet (generate it on your Mac).

## Create the Xcode project

1. Xcode → **New → Project → Multiplatform → App**, name **TrackTheMoney**.
2. **File → Add Package Dependencies → Add Local…** → select the `TTMCore`
   folder in this repo. Add the `TTMCore` library to the app target.
3. Delete Xcode's generated `ContentView.swift` / `App.swift` and add the files
   in this `App/` folder to the target (keep the folder structure).
4. Capabilities: enable **Keychain Sharing** (and later **iCloud → Keychain**
   for the paid tier's E2E key sync).
5. Build & run.

## Layout

```
App/
├── TrackTheMoneyApp.swift      // @main entry; dependency wiring
├── Platform/
│   ├── KeychainSecretStore.swift   // SecretStore via Security framework
│   └── URLSessionNetworkClient.swift // NetworkClient via URLSession
└── Features/
    └── NetWorthView.swift      // starter screen
```

`Platform/` holds the native implementations of TTMCore's injected protocols —
the only place OS APIs (Keychain, URLSession) are touched. Everything else flows
through `CoreFacade`.
