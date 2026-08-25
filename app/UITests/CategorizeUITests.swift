import XCTest

/// Drives the real categorize/review flow on the simulator to verify that tapping
/// a transaction's category picker actually applies. Leaves are always visible
/// (no collapse), so every category is an immediately-hittable Button.
final class CategorizeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStore", "-sampleData", "-tab", "transactions"]
        app.launch()
        return app
    }

    func testApplyLeafCategory() {
        let app = launch()
        let row = app.staticTexts["WHOLE FOODS MARKET"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "transaction row not found")
        row.tap()
        XCTAssertTrue(app.navigationBars["Categorize"].waitForExistence(timeout: 5), "sheet did not open")

        let dining = app.buttons["Dining"]
        XCTAssertTrue(dining.waitForExistence(timeout: 5), "Dining leaf not present")
        XCTAssertTrue(dining.isHittable, "Dining leaf not hittable — buried/off-screen")
        dining.tap()

        XCTAssertTrue(app.navigationBars["Categorize"].waitForNonExistence(timeout: 5),
                      "sheet did not dismiss after tapping leaf — taps not applying")
        XCTAssertTrue(app.staticTexts["Dining"].waitForExistence(timeout: 3),
                      "transaction not recategorized to Dining")
    }

    func testCreateOnTheFly() {
        let app = launch()
        app.staticTexts["WHOLE FOODS MARKET"].tap()
        XCTAssertTrue(app.navigationBars["Categorize"].waitForExistence(timeout: 5))
        // Let the picker fully render so the search field is focusable.
        XCTAssertTrue(app.buttons["Dining"].waitForExistence(timeout: 5), "picker not rendered")

        let search = app.textFields["categorySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "sheet search field missing")
        search.tap()
        app.typeText("Coffee Shops")
        // The create row's a11y label is "Create “Coffee Shops”" — match by prefix.
        let create = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Create'")).firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5), "Create row did not appear")
        create.tap()
        XCTAssertTrue(app.navigationBars["Categorize"].waitForNonExistence(timeout: 5),
                      "create-on-the-fly did not apply + dismiss")
        XCTAssertTrue(app.staticTexts["Coffee Shops"].waitForExistence(timeout: 3),
                      "transaction not categorized to the new category")
    }

    /// Guards the search-filter LOGIC: text in the field → the list narrows to
    /// matches (the match survives, non-matches drop out).
    ///
    /// NOTE: this does NOT catch the macOS focus bug it was born from. XCUITest's
    /// text input is injected straight into the field, bypassing the real
    /// first-responder routing (the List's macOS type-select) that eats a user's
    /// hardware keystrokes — so this passes with or without the focus fix. It's a
    /// regression guard for filtering, not for focus. The focus fix is verified
    /// by hand on a real keyboard.
    func testSearchFiltersCategoryList() {
        let app = launch()
        // On macOS a transaction row is one Button with a combined label
        // ("WHOLE FOODS MARKET, Jun 25, Groceries, -$87.32"); match by substring.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'WHOLE FOODS MARKET'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "transaction row not found")
        row.tap()

        // Leaf rows carry a stable accessibilityIdentifier == name, so these match
        // by identifier (unaffected by the parent-group subtitle search mode adds)
        // and never collide with the transaction rows behind the sheet.
        let dining = app.buttons["Dining"]
        let utilities = app.buttons["Utilities"]
        XCTAssertTrue(dining.waitForExistence(timeout: 5), "picker not rendered (Dining leaf missing)")
        XCTAssertTrue(utilities.exists, "expected Utilities leaf before searching")

        let search = app.textFields["categorySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "search field missing")
        app.typeText("Dining")

        // Filtering worked: the match survives, non-matches drop out.
        XCTAssertTrue(dining.waitForExistence(timeout: 3), "matching leaf vanished after search")
        XCTAssertTrue(utilities.waitForNonExistence(timeout: 3),
                      "list did not filter — 'Utilities' still present (type-ahead broken)")
    }

    /// Adding a subcategory to a leaf that has transactions ("Auto" holds one in
    /// the sample data) must run the real detect→prompt path and offer to move
    /// those transactions. The `-debugPromote` hook fires that path on Auto so the
    /// test needn't scroll a deep List (which the More-tab nav wrapper resists).
    func testGracefulPromotionPrompt() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStore", "-sampleData", "-tab", "categories", "-debugPromote"]
        app.launch()

        // Detection produced the prompt → the move action is on screen.
        // (confirmationDialog buttons don't expose accessibilityIdentifier, so match by label.)
        let move = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Move 1 to'")).firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 12), "promotion prompt did not appear")
        move.tap()
        XCTAssertTrue(move.waitForNonExistence(timeout: 5), "prompt did not dismiss after Move (action didn't fire)")
    }

    /// The Review modal surfaces a clearly-badged on-device AI suggestion that can
    /// be approved in one tap. `-stubAI` forces the deterministic heuristic, which
    /// suggests Dining for the sample "STARBUCKS" transaction.
    func testReviewShowsAndApprovesAISuggestion() {
        let app = XCUIApplication()
        app.launchArguments = ["-resetStore", "-sampleData", "-stubAI", "-tab", "transactions"]
        app.launch()

        let review = app.buttons["Review"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), "Review button missing")
        review.tap()
        XCTAssertTrue(app.navigationBars["Review"].waitForExistence(timeout: 5), "Review modal did not open")

        // The AI suggestion banner + Approve action.
        let approve = app.buttons["Approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 6), "AI suggestion did not appear")
        approve.tap()
        // Approving categorizes the item and advances to the next one.
        XCTAssertTrue(app.staticTexts["DELTA AIR LINES"].waitForExistence(timeout: 5),
                      "did not advance after approving the suggestion")
    }

    func testReviewModalApplies() {
        let app = launch()
        let reviewBtn = app.buttons["Review"]
        XCTAssertTrue(reviewBtn.waitForExistence(timeout: 8), "Review button never appeared")
        reviewBtn.tap()
        XCTAssertTrue(app.navigationBars["Review"].waitForExistence(timeout: 5), "Review modal did not open")

        let dining = app.buttons["Dining"]
        XCTAssertTrue(dining.waitForExistence(timeout: 5), "Review picker has no visible Dining leaf")
        XCTAssertTrue(dining.isHittable, "Review leaf not hittable")
        dining.tap()
        // Applying advances to the next item — the modal stays up.
        XCTAssertTrue(app.navigationBars["Review"].exists, "Review modal closed unexpectedly")
    }
}
