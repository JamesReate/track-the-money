import XCTest
@testable import TTMCore

final class MoneyTests: XCTestCase {
    func testParsesNegativeDecimalString() {
        XCTAssertEqual(Money(decimalString: "-42.07")?.cents, -4207)
    }

    func testParsesPositiveAndWhole() {
        XCTAssertEqual(Money(decimalString: "1000.00")?.cents, 100_000)
        XCTAssertEqual(Money(decimalString: "5")?.cents, 500)
    }

    func testParsesSingleDecimalDigit() {
        XCTAssertEqual(Money(decimalString: "3.5")?.cents, 350)
    }

    func testRejectsGarbage() {
        XCTAssertNil(Money(decimalString: "not-a-number"))
    }

    func testArithmetic() {
        XCTAssertEqual((Money(cents: 500) + Money(cents: 250)).cents, 750)
        XCTAssertEqual((-Money(cents: 250)).cents, -250)
        XCTAssertTrue(Money(cents: 100) < Money(cents: 200))
    }
}
