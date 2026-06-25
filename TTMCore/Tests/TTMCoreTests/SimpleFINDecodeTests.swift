import XCTest
@testable import TTMCore

/// Decodes the real beta-bridge.simplefin.org demo response shape (captured
/// live) — guards against field-name drift like errlist vs errors, and the
/// presence of holdings/extra fields we don't model.
final class SimpleFINDecodeTests: XCTestCase {
    private let demoJSON = """
    {
      "errors": [],
      "accounts": [
        {
          "id": "Demo Savings",
          "name": "SimpleFIN Savings",
          "currency": "USD",
          "balance": "113985.51",
          "available-balance": "113985.51",
          "balance-date": 1782432000,
          "transactions": [
            { "id": "1782374400", "posted": 1782374400, "amount": "-125.50",
              "description": "Fishing bait", "payee": "John's Fishin Shack",
              "memo": "JOHNS FISHIN SHACK BAIT", "transacted_at": 1782374400 },
            { "id": "1782403200", "posted": 1782403200, "amount": "-15.50",
              "description": "Grocery store", "payee": "Grocery store",
              "memo": "LOCAL GROCER STORE #1133", "transacted_at": 1782403200 }
          ],
          "holdings": [
            { "id": "h1", "description": "Acme Corp", "market_value": "1000.00" }
          ]
        }
      ]
    }
    """

    func testDecodesRealBridgeShape() throws {
        let set = try JSONDecoder().decode(SFAccountSet.self, from: Data(demoJSON.utf8))
        XCTAssertEqual(set.errors, [])
        XCTAssertEqual(set.accounts.count, 1)
        let acct = set.accounts[0]
        XCTAssertEqual(acct.name, "SimpleFIN Savings")
        XCTAssertEqual(acct.balanceCents?.cents, 11_398_551)       // "113985.51" → cents
        XCTAssertEqual(acct.availableCents?.cents, 11_398_551)
        XCTAssertEqual(acct.balanceDate, 1782432000)
        XCTAssertEqual(acct.transactions?.count, 2)
        let txn = acct.transactions![0]
        XCTAssertEqual(txn.amountCents?.cents, -12_550)            // "-125.50" → cents
        XCTAssertEqual(txn.payee, "John's Fishin Shack")
        XCTAssertEqual(txn.transactedAt, 1782374400)
        XCTAssertFalse(txn.isPending)                              // posted present
    }
}
