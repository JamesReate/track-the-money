import XCTest

/// Manual accounts, delete, interest rates and the credit-card class
/// (docs/plans/ACCOUNT_MANAGEMENT_PLAN.md). Engine rules live in TTMCore's
/// AccountManagementTests; this drives what the user taps.
final class AccountsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(tab: String, sample: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStore"] + (sample ? ["-sampleData"] : []) + ["-tab", tab]
        app.launch()
        return app
    }

    /// Scroll until on screen and not under iOS 26's floating tab bar
    /// (`isHittable` is true for rows it covers — see ProfilesUITests.isClear).
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if isClear(element, in: app) { return true }
            list.swipeUp(velocity: .slow)
        }
        return isClear(element, in: app)
    }

    private func isClear(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let tabBar = app.tabBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY : app.windows.firstMatch.frame.maxY
        return element.frame.maxY <= bottom
    }

    private func cell(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.collectionViews.cells.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func text(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testAddUpdateAndDeleteAManualAccount() {
        let app = launch(tab: "accounts", sample: false)
        let add = app.buttons["addManualAccount"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "no add button on Accounts")
        add.tap()

        let name = app.textFields["manualName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "add sheet didn't open")
        name.tap(); name.typeText("Car")
        let value = app.textFields["manualValue"]
        value.tap(); value.typeText("15,000")
        app.buttons["manualSave"].tap()

        let row = cell("Car", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5), "manual account not listed")
        XCTAssertTrue(text("$15,000.00", in: app).exists, "value not shown")
        XCTAssertTrue(text("Updated", in: app).exists, "as-of date not shown")

        // Tap the row to record a new value.
        text("Car", in: app).tap()
        let newValue = app.textFields["manualValue"]
        XCTAssertTrue(newValue.waitForExistence(timeout: 5), "update sheet didn't open")
        newValue.tap(); newValue.typeText("14000")
        app.buttons["manualSave"].tap()
        XCTAssertTrue(text("$14,000.00", in: app).waitForExistence(timeout: 5), "updated value not shown")

        // Swipe to delete, then confirm.
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.buttons.matching(identifier: "Delete")
        let deadline = Date().addingTimeInterval(5)
        while confirm.count == 0 && Date() < deadline { usleep(200_000) }
        confirm.element(boundBy: confirm.count - 1).tap()
        XCTAssertTrue(text("No accounts", in: app).waitForExistence(timeout: 5), "account wasn't deleted")
    }

    func testCreditCardClassAndInterestRates() {
        let app = launch(tab: "accounts", sample: true)
        XCTAssertTrue(cell("Sapphire Visa", in: app).waitForExistence(timeout: 15))
        XCTAssertTrue(text("CREDIT CARD", in: app).exists, "Visa should be classed as a credit card")
        XCTAssertTrue(text("22.99% APR", in: app).exists, "debt rows show their APR")

        // Debt & Interest lists rates highest first, and a tap edits one.
        let relaunched = launch(tab: "debt", sample: true)
        let mortgage = relaunched.buttons["rate-Home Mortgage"]
        _ = mortgage.waitForExistence(timeout: 15)
        XCTAssertTrue(reveal(mortgage, in: relaunched), "no rate row for the mortgage")
        mortgage.tap()
        let field = relaunched.textFields["aprField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rate sheet didn't open")
        field.tap()
        field.press(forDuration: 1.0)
        if relaunched.menuItems["Select All"].waitForExistence(timeout: 2) { relaunched.menuItems["Select All"].tap() }
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("7.25")
        relaunched.buttons["aprSave"].tap()
        XCTAssertTrue(text("7.25%", in: relaunched).waitForExistence(timeout: 5), "new rate not shown")
        // $3,420.77 @ 22.99% and $382,000 @ 7.25% → 7.39% balance-weighted.
        XCTAssertTrue(text("Weighted average", in: relaunched).exists)
        XCTAssertTrue(text("7.39%", in: relaunched).exists, "weighted average APR is wrong")
    }
}
