import XCTest

/// This Month's expected expenses (docs/plans/EXPECTED_EXPENSES_PLAN.md).
/// Detection rules live in TTMCore's ExpectedExpensesTests; this drives the
/// screen. Sample bills are 30 days apart, so whether one shows as paid or
/// coming up depends on today's date — the tests accept either.
final class ExpectedExpensesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStore", "-sampleData", "-tab", "month"]
        app.launch()
        return app
    }

    /// A bill's row, whichever section it's in.
    private func bill(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["expected-\(name)", "paid-\(name)"])).firstMatch
    }

    /// Scroll until on screen and clear of iOS 26's floating tab bar.
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

    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<4 { app.collectionViews.firstMatch.swipeDown(velocity: .fast) }
    }

    func testSampleBillsAreExpectedAndCanBeRemovedAndRestored() {
        let app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["expected-total"].waitForExistence(timeout: 15),
                      "no total on This Month")
        for name in ["ROCKET MORTGAGE", "BRIGHT HORIZONS", "STATE FARM INSURANCE"] {
            XCTAssertTrue(bill(name, in: app).waitForExistence(timeout: 5), "\(name) not expected")
        }
        XCTAssertFalse(bill("WHOLE FOODS MARKET", in: app).exists, "groceries aren't a bill")

        let toyota = bill("TOYOTA FINANCIAL", in: app)
        XCTAssertTrue(reveal(toyota, in: app), "Toyota not on screen")
        // Swipe the list cell itself; swiping the row's content doesn't open its actions.
        let cell = app.cells.containing(NSPredicate(format: "identifier IN %@",
                                                    ["expected-TOYOTA FINANCIAL", "paid-TOYOTA FINANCIAL"])).firstMatch
        (cell.exists ? cell : toyota).swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "no Remove swipe action")
        remove.tap()

        let restore = app.buttons["restore-TOYOTA FINANCIAL"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "removed bill not listed under Removed")
        XCTAssertFalse(bill("TOYOTA FINANCIAL", in: app).exists, "removed bill still expected")
        XCTAssertTrue(reveal(restore, in: app))
        restore.tap()
        XCTAssertTrue(bill("TOYOTA FINANCIAL", in: app).waitForExistence(timeout: 5), "restore didn't bring it back")
        XCTAssertFalse(app.buttons["restore-TOYOTA FINANCIAL"].exists)
    }

    func testRaisingTheMinimumDropsSmallerBills() {
        let app = launch()
        XCTAssertTrue(bill("STATE FARM INSURANCE", in: app).waitForExistence(timeout: 15))
        scrollToTop(app)
        let options = app.buttons["expected-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5), "no options menu")
        options.tap()
        let fiveHundred = app.buttons["$500 or more"]
        XCTAssertTrue(fiveHundred.waitForExistence(timeout: 5), "no minimum choices")
        fiveHundred.tap()

        XCTAssertTrue(bill("ROCKET MORTGAGE", in: app).waitForExistence(timeout: 5), "mortgage dropped")
        let stateFarmGone = NSPredicate(format: "exists == false")
        expectation(for: stateFarmGone, evaluatedWith: bill("STATE FARM INSURANCE", in: app))
        waitForExpectations(timeout: 5)
        XCTAssertFalse(bill("TOYOTA FINANCIAL", in: app).exists)
    }
}
