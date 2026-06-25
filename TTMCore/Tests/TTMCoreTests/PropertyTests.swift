import XCTest
@testable import TTMCore

final class PropertyTests: XCTestCase {
    private func store() throws -> Store {
        let s = Store(try Database.inMemory())
        try DefaultData.seedIfEmpty(s, now: 1)
        try s.saveConnection(ConnectionRecord(id: "c", name: "n", keychainRef: "r", sfinOrg: nil,
                                              status: "ok", lastError: nil, lastSyncedAt: nil, createdAt: 1))
        // Mortgage account: owe $300,000 (reported negative).
        try s.saveAccount(AccountRecord(id: "mortgage", connectionId: "c", sfinAccountId: "m1",
                                        name: "Home Mortgage", currency: "USD",
                                        accountClass: AccountClass.securedDebt.rawValue, subclass: nil, aprBps: nil,
                                        balanceCents: -30_000_000, availableCents: nil, balanceDate: 100,
                                        archived: false, createdAt: 1))
        return s
    }

    func testEquityFromValueMinusLinkedDebt() throws {
        let s = try store()
        try s.saveProperty(PropertyRecord(id: "home", name: "Main House", kind: "real_estate", createdAt: 1))
        try s.addPropertyValue(PropertyValueRecord(id: nil, propertyId: "home", valueCents: 40_000_000,
                                                   asOf: 100, note: nil, createdAt: 1))
        try s.linkDebt(PropertyDebtRecord(propertyId: "home", accountId: "mortgage", role: "mortgage"))

        let summaries = try s.propertySummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].valueCents, 40_000_000)
        XCTAssertEqual(summaries[0].debtCents, 30_000_000)   // abs of mortgage balance
        XCTAssertEqual(try s.linkedDebtTotalCents(), 30_000_000)
    }

    func testLatestValueWins() throws {
        let s = try store()
        try s.saveProperty(PropertyRecord(id: "home", name: "Main House", kind: "real_estate", createdAt: 1))
        try s.addPropertyValue(PropertyValueRecord(id: nil, propertyId: "home", valueCents: 38_000_000, asOf: 100, note: nil, createdAt: 1))
        try s.addPropertyValue(PropertyValueRecord(id: nil, propertyId: "home", valueCents: 41_000_000, asOf: 200, note: "reassessed", createdAt: 2))
        XCTAssertEqual(try s.propertySummaries()[0].valueCents, 41_000_000)
        XCTAssertEqual(try s.latestPropertyValuesCents(), [41_000_000])
    }
}
