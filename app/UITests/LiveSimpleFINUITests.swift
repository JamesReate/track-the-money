import XCTest

/// The last mile the engine tests can't reach: a real claim + sync driven
/// through the actual app, ending in synced bank data rendered on screen.
/// Keychain, SwiftUI, and the tab navigation are all real here.
///
/// The network path itself is covered far more thoroughly by
/// `TTMCoreTests/LiveSimpleFINTests` — this exists to prove the UI shows what
/// was synced. Opt-in, so the default suite stays hermetic:
///
///     TEST_RUNNER_TTM_LIVE=1 xcodebuild test -scheme TrackTheMoney \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:TrackTheMoneyUITests/LiveSimpleFINUITests
///
/// Use your own bridge with `TEST_RUNNER_TTM_SETUP_TOKEN=<token>` (single-use).
///
/// **Requires a SIGNED build.** The claim writes the Access URL to the Keychain,
/// and an unsigned app (`CODE_SIGNING_ALLOWED=NO`, no development team) has no
/// keychain access group — `SecItemAdd`/`Update` fails with `-34018`
/// (`errSecMissingEntitlement`), claim throws, and nothing syncs. That is a
/// build-configuration artifact, not a product bug: a signed build is granted
/// its default access group. Set DEVELOPMENT_TEAM (Signing & Capabilities)
/// before running this. The network path itself needs no signing and is fully
/// covered by `TTMCoreTests/LiveSimpleFINTests`, which uses an in-memory
/// SecretStore.
final class LiveSimpleFINUITests: XCTestCase {
    /// SimpleFIN's published demo claim URL, base64'd.
    private static let demoToken =
        "aHR0cHM6Ly9iZXRhLWJyaWRnZS5zaW1wbGVmaW4ub3JnL3NpbXBsZWZpbi9jbGFpbS9ERU1P"

    private var token: String {
        ProcessInfo.processInfo.environment["TTM_SETUP_TOKEN"] ?? Self.demoToken
    }
    private var usingDemoBank: Bool { ProcessInfo.processInfo.environment["TTM_SETUP_TOKEN"] == nil }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TTM_LIVE"] == "1",
                          "live network test — set TEST_RUNNER_TTM_LIVE=1 to run")
        continueAfterFailure = true
    }

    func testClaimSyncAndRenderRealAccounts() throws {
        let app = XCUIApplication()
        // No sample data: everything on screen afterwards came off the wire.
        app.launchArguments = ["-resetStore", "-tab", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings didn't open")

        let field = app.textFields["setupToken"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "setup token field missing")
        field.tap()
        field.typeText(token)
        // The keyboard covers the tab bar and swallows later taps — dismiss it
        // by tapping a non-interactive part of the form.
        app.staticTexts["ADD SIMPLEFIN CONNECTION"].tap()

        let add = app.buttons["Add connection"]
        XCTAssertTrue(add.isEnabled, "Add connection stayed disabled with a token entered")
        add.tap()

        // claim() chains into syncNow(). Rather than race the status line (which
        // sits below the fold in a lazily-rendered Form), assert on the payoff:
        // synced accounts appearing on the Accounts screen.
        app.buttons["Accounts"].tap()

        if usingDemoBank {
            XCTAssertTrue(app.staticTexts["SimpleFIN Savings"].waitForExistence(timeout: 90),
                          "demo savings never rendered — claim or sync didn't complete")
            XCTAssertTrue(app.staticTexts["SimpleFIN Checking"].waitForExistence(timeout: 10),
                          "demo checking never rendered")
        } else {
            let anyAccount = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS '$'")).firstMatch
            XCTAssertTrue(anyAccount.waitForExistence(timeout: 90), "no accounts rendered after a real sync")
        }

        // And the rollup screen reflects the synced balances.
        app.buttons["Net Worth"].tap()
        let total = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '$'")).firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 20), "net worth didn't render after sync")
    }
}
