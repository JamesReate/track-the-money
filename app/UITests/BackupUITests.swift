import XCTest

/// Smoke coverage for the Settings backup surface. The system save/open panels
/// aren't automatable, so this verifies what is ours: the section renders, and
/// the disclosure about secrets is actually on screen. The real guarantees are
/// unit-tested in TTMCore's BackupTests.
final class BackupUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launchSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStore", "-sampleData", "-tab", "settings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15), "Settings didn't open")
        return app
    }

    /// Form rows render lazily, so anything below the fold has to be scrolled
    /// into existence. Swipe the Form itself — swiping the app window doesn't
    /// reach it inside the tab bar's More stack.
    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
        let form = app.collectionViews.firstMatch
        for _ in 0..<swipes {
            if element.exists { return true }
            form.swipeUp()
        }
        return element.exists
    }

    func testBackupSectionIsPresent() {
        let app = launchSettings()
        let export = app.buttons["Export backup…"]
        XCTAssertTrue(scrollTo(export, in: app), "Export row missing from Settings")
        XCTAssertTrue(scrollTo(app.buttons["Restore from backup…"], in: app), "Restore row missing from Settings")
        // Undo only appears once a restore has actually happened.
        XCTAssertFalse(app.buttons["Undo last restore"].exists, "Undo offered with nothing to undo")
    }

    func testBackupDisclosesThatSecretsAreExcluded() {
        let app = launchSettings()
        let note = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'stays in the Keychain'")).firstMatch
        XCTAssertTrue(scrollTo(note, in: app),
                      "the section must say the SimpleFIN connection isn't in the backup")
    }
}
