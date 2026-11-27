import XCTest

/// This Month's budget (docs/plans/MONTHLY_BUDGET_PLAN.md). The arithmetic
/// lives in TTMCore's BudgetTests; this drives the screens. Sample amounts
/// depend on today's date, so the tests compare before and after instead of
/// asserting figures.
final class BudgetUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStore", "-sampleData", "-tab", "month"]
        app.launch()
        XCTAssertTrue(app.staticTexts["budget-left"].waitForExistence(timeout: 15), "no budget on This Month")
        return app
    }

    private func isClear(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let tabBar = app.tabBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY : app.windows.firstMatch.frame.maxY
        return element.frame.maxY <= bottom
    }

    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<10 where !isClear(element, in: app) { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        return isClear(element, in: app)
    }

    /// "$2,553" / "-$120" → 2553 / -120.
    private func dollars(_ element: XCUIElement) -> Int? {
        let text = element.label
        let negative = text.contains("-") || text.contains("−")
        let digits = text.filter(\.isNumber)
        return Int(digits).map { negative ? -$0 : $0 }
    }

    func testTheMonthShowsLeftSplurgeRoomPlansAndIncome() {
        let app = launch()
        XCTAssertNotNil(dollars(app.staticTexts["budget-left"]))
        XCTAssertTrue(app.staticTexts["budget-splurge"].exists)
        for row in ["Groceries", "Going Out", "Everything else"] {
            XCTAssertTrue(app.buttons["budget-row-\(row)"].exists, "\(row) has no budget row")
        }
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["income-PAYROLL — ACME INC"].exists, "salary not listed under Income")
        XCTAssertTrue(any["income-NORTHWIND LLC"].exists, "contract work not listed under Income")
    }

    func testPlanningAPurchaseComesOutOfWhatsLeft() {
        let app = launch()
        let before = dollars(app.staticTexts["budget-left"])
        app.buttons["afford-open"].tap()

        let amount = app.textFields["afford-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5), "afford sheet didn't open")
        app.buttons["afford-preset-100"].tap()
        let verdict = app.staticTexts["afford-verdict"]
        XCTAssertTrue(verdict.waitForExistence(timeout: 5))
        XCTAssertEqual(verdict.label, "Yes, go for it")

        app.buttons["afford-preset-2500"].tap()
        XCTAssertTrue(["Yes, go for it", "Only by trimming savings", "Not this month"].contains(verdict.label))

        app.buttons["afford-preset-100"].tap()
        let label = app.textFields["afford-label"]
        label.tap()
        label.typeText("Concert")
        let plan = app.buttons["afford-plan"]
        if !plan.isHittable { app.swipeUp() }
        plan.tap()

        let purchase = app.descendants(matching: .any)["purchase-Concert"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 5), "planned purchase not listed")
        let after = dollars(app.staticTexts["budget-left"])
        XCTAssertEqual(after.map { $0 + 100 }, before, "a planned $100 comes out of what's left")
    }

    func testRaisingACategoryPlan() {
        let app = launch()
        let row = app.buttons["budget-row-Going Out"]
        XCTAssertTrue(reveal(row, in: app), "Going Out row not reachable")
        row.tap()
        let amount = app.staticTexts["plan-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5), "category plan didn't open")
        let before = dollars(amount)
        app.buttons["plan-plus"].tap()
        let raised = NSPredicate { _, _ in self.dollars(amount) == before.map { $0 + 10 } }
        expectation(for: raised, evaluatedWith: amount)
        waitForExpectations(timeout: 5)
    }
}
