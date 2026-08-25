# Building Track The Money

Three ways to build, by purpose. All share the same source — `TTMCore` (logic)
and `app/Sources/TrackTheMoney` (SwiftUI).

## 1. Fast iteration / tests (headless, no Xcode UI)
```bash
cd TTMCore && swift build && swift test     # core logic + 25 tests
cd app && swift build                       # SwiftUI compiles for the host (macOS)
cd app && swift run TrackTheMoney           # launch the Mac app
```

## 2. The shipping app (Xcode, multiplatform)
The Xcode project is generated from `project.yml` (not committed — regenerate):
```bash
brew install xcodegen        # one-time
xcodegen generate            # creates TrackTheMoney.xcodeproj
open TrackTheMoney.xcodeproj
```
Then in Xcode set your **Team** under Signing & Capabilities (needed once to run
on a device / submit).

## 3. Command-line builds (CI-style)
```bash
# macOS
xcodebuild -scheme TrackTheMoney -destination 'platform=macOS' build
# iOS Simulator
xcodebuild -scheme TrackTheMoney -destination 'generic/platform=iOS Simulator' build
```
(Add `CODE_SIGNING_ALLOWED=NO` to compile-check without a signing team.)

---

## Desktop vs iPad vs iPhone — how one project targets all three

`project.yml` defines **one application target** with
`supportedDestinations: [iOS, macOS]`. From that single target + single codebase:

| Destination | Platform | Notes |
|---|---|---|
| **iPhone** | iOS | The "mobile" build. Compact size class → `TabView` + stacked navigation. |
| **iPad** | iOS | **Same iOS binary** as iPhone — there is no separate iPad target. Layout adapts at runtime by size class (e.g. `NavigationSplitView` shows a sidebar on the larger canvas). Universal app. |
| **Mac** | macOS | A **native AppKit-backed SwiftUI** app (not Mac Catalyst; `SUPPORTS_MACCATALYST: NO`). Same SwiftUI views, compiled for macOS, with menu-bar/window behavior. |

Key points:
- **iPhone and iPad are the same platform (iOS)** and the same compiled app — "build for iPad" and "build for iPhone" select different *destinations* of one iOS product. Adaptivity is a runtime layout concern (size classes, `NavigationSplitView`), not separate code.
- **Mac is a second platform (macOS)** built from the same sources. Platform-specific code, if ever needed, is gated with `#if os(iOS)` / `#if os(macOS)`. Today there is none — the screens are platform-agnostic SwiftUI.
- **App Store submission** is per-platform: you archive an **iOS** build (serves both iPhone and iPad) and a **macOS** build from the same project/scheme. Two store listings can share one codebase.
- Our priority order (iOS primary, macOS primary; iPad covered free via iOS) is satisfied by this single multiplatform target. Android/Windows would be separate front-ends on a future Rust core (see TECH_DESIGN §13).
