import XCTest

/// Profiles (docs/plans/PROFILES_PLAN.md): switching data sets in place, the
/// always-visible test-profile banner, and the connection status for the active
/// profile. Engine guarantees (isolation, Keychain ownership) live in TTMCore's
/// ProfileTests; this checks what the user sees.
final class ProfilesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// `-profile Sandbox` creates a *test* profile and switches to it before
    /// `-sampleData` loads, so the sample lands in Sandbox and "My data" stays empty.
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStore"] + extra + ["-tab", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15), "Settings didn't open")
        return app
    }

    /// Form rows render lazily and the floating tab bar covers the bottom of
    /// the screen, so scroll until the element exists *and* can take a tap.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
        let form = app.collectionViews.firstMatch
        _ = form.waitForExistence(timeout: 5)
        for _ in 0..<swipes {
            if isClear(element, in: app) { return true }
            form.swipeUp(velocity: .slow)
        }
        return isClear(element, in: app)
    }

    /// On screen and not under the floating tab bar (`isHittable` says yes to
    /// rows the iOS 26 tab bar is covering).
    private func isClear(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let tabBar = app.tabBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY : app.windows.firstMatch.frame.maxY
        return element.frame.maxY <= bottom && element.frame.minY >= app.collectionViews.firstMatch.frame.minY
    }

    private func scrollToTop(_ app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        for _ in 0..<4 { form.swipeDown(velocity: .fast) }
    }

    private func label(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func profileRow(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    func testSwitchingProfilesTogglesBannerAndConnection() {
        let app = launch(["-profile", "Sandbox", "-sampleData"])

        let banner = app.descendants(matching: .any)["testProfileBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no banner while a test profile is active")
        XCTAssertTrue(label("Test profile · Sandbox", in: app).exists)
        let sampleConn = app.descendants(matching: .any)["connection-sample"]
        XCTAssertTrue(reveal(sampleConn, in: app), "sample connection state not shown for the active profile")

        // Switch to the real (empty) profile: banner goes, connection is absent.
        scrollToTop(app)
        let myData = profileRow("My data", in: app)
        XCTAssertTrue(reveal(myData, in: app), "inactive profile not listed")
        myData.tap()
        let none = app.descendants(matching: .any)["noConnection"]
        XCTAssertTrue(none.waitForExistence(timeout: 3) || reveal(none, in: app),
                      "empty profile should say it has no SimpleFIN connection")
        XCTAssertFalse(banner.exists, "banner still shown on a real profile")

        // And back: Sandbox's sample data is still there.
        scrollToTop(app)
        let sandbox = profileRow("Sandbox", in: app)
        XCTAssertTrue(reveal(sandbox, in: app))
        sandbox.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "banner didn't come back")
        XCTAssertTrue(reveal(sampleConn, in: app), "Sandbox lost its data across a switch")
    }

    func testCreateEmptyProfileFromSheet() {
        let app = launch()
        let new = app.buttons["New profile…"]
        XCTAssertTrue(reveal(new, in: app), "New profile row missing")
        new.tap()

        let name = app.textFields["profileName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "new-profile sheet didn't open")
        name.tap()
        name.typeText("Household")
        app.buttons["Create"].tap()

        let none = app.descendants(matching: .any)["noConnection"]
        XCTAssertTrue(none.waitForExistence(timeout: 10) || reveal(none, in: app),
                      "a new empty profile should show no connection")
        // Created as a real profile (Empty defaults to real) — no banner.
        XCTAssertFalse(app.descendants(matching: .any)["testProfileBanner"].exists)
        scrollToTop(app)
        XCTAssertTrue(label("Household", in: app).exists, "new profile not listed")
        // The previous profile is still there to switch back to.
        XCTAssertTrue(profileRow("My data", in: app).exists)
    }

    /// A bad token must say why, right where it was pasted, and keep the text.
    func testBadSetupTokenShowsInlineErrorAndKeepsToken() {
        let app = launch()
        let field = app.textFields["setupToken"]
        XCTAssertTrue(reveal(field, in: app), "token field missing")
        field.tap()
        field.typeText("not-a-token")
        let add = app.buttons["Add connection"]
        XCTAssertTrue(reveal(add, in: app))
        add.tap()

        // The Label's icon and text both carry the identifier; match the text.
        let message = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "doesn’t look like a SimpleFIN setup token")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10) || reveal(message, in: app),
                      "no inline error after Add connection with a bad token")
        XCTAssertEqual(field.value as? String, "not-a-token", "failed claim cleared the pasted token")
    }
}
