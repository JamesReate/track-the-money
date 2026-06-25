import XCTest
@testable import TTMCore

final class RulesTests: XCTestCase {
    private func txn(desc: String, amount: Int64 = -2599, account: String = "acct-1") -> TxnView {
        TxnView(description: desc, payee: desc, memo: nil, accountId: account, amountCents: amount, currency: "USD")
    }

    private func rule(_ id: String, priority: Int, clause: Clause, op: Condition.LogicOp = .and) -> Rule {
        Rule(id: id, name: id, categoryId: "cat-\(id)", priority: priority, enabled: true,
             condition: Condition(op: op, clauses: [clause]))
    }

    func testContainsMatchesCaseInsensitive() {
        let r = rule("dog", priority: 10, clause: Clause(field: .description, match: .contains, value: "chewy"))
        let match = RulesEngine.firstMatch(txn(desc: "CHEWY.COM ORDER"), rules: [r])
        XCTAssertEqual(match?.id, "dog")
    }

    func testFirstMatchWinsByPriority() {
        let general = rule("general", priority: 100, clause: Clause(field: .description, match: .contains, value: "amazon"))
        let specific = rule("specific", priority: 10, clause: Clause(field: .description, match: .contains, value: "amazon"))
        let match = RulesEngine.firstMatch(txn(desc: "AMAZON MARKETPLACE"), rules: [general, specific])
        XCTAssertEqual(match?.id, "specific")
    }

    func testAmountAndDescriptionAnd() {
        let r = Rule(id: "big", name: "big", categoryId: "c", priority: 5, enabled: true,
                     condition: Condition(op: .and, clauses: [
                        Clause(field: .description, match: .contains, value: "home depot"),
                        Clause(field: .amountCents, match: .lt, value: "0"),
                     ]))
        XCTAssertNotNil(RulesEngine.firstMatch(txn(desc: "HOME DEPOT #123", amount: -8000), rules: [r]))
        XCTAssertNil(RulesEngine.firstMatch(txn(desc: "HOME DEPOT REFUND", amount: 8000), rules: [r]))
    }

    func testDisabledRuleSkipped() {
        var r = rule("x", priority: 1, clause: Clause(field: .description, match: .contains, value: "netflix"))
        r = Rule(id: r.id, name: r.name, categoryId: r.categoryId, priority: r.priority, enabled: false, condition: r.condition)
        XCTAssertNil(RulesEngine.firstMatch(txn(desc: "NETFLIX.COM"), rules: [r]))
    }

    func testConditionRoundTripsThroughJSON() throws {
        let cond = Condition(op: .or, clauses: [Clause(field: .payee, match: .eq, value: "Costco", ci: false)])
        let data = try JSONEncoder().encode(cond)
        let back = try JSONDecoder().decode(Condition.self, from: data)
        XCTAssertEqual(cond, back)
    }
}

final class ClassifyTests: XCTestCase {
    func testGuessesDebtAndLiquid() {
        XCTAssertEqual(AccountClassifier.guess(name: "VISA Signature"), .unsecuredDebt)
        XCTAssertEqual(AccountClassifier.guess(name: "Home Mortgage"), .securedDebt)
        XCTAssertEqual(AccountClassifier.guess(name: "Everyday Checking"), .liquid)
        XCTAssertEqual(AccountClassifier.guess(name: "Fidelity Roth IRA"), .investment)
        XCTAssertEqual(AccountClassifier.guess(name: "Mystery Account"), .unclassified)
    }
}

final class NetWorthTests: XCTestCase {
    func testRollupSignsAndEquity() {
        let accounts = [
            AccountBalance(accountClass: .liquid, balance: Money(cents: 500_000)),
            AccountBalance(accountClass: .investment, balance: Money(cents: 1_000_000)),
            AccountBalance(accountClass: .securedDebt, balance: Money(cents: 30_000_000)),
            AccountBalance(accountClass: .unsecuredDebt, balance: Money(cents: 250_000)),
        ]
        let summary = NetWorth.summary(accounts: accounts, propertyValues: [Money(cents: 40_000_000)], asOf: 0)
        XCTAssertEqual(summary.liquid.cents, 500_000)
        XCTAssertEqual(summary.securedDebt.cents, 30_000_000)
        XCTAssertEqual(summary.assets.cents, 500_000 + 1_000_000 + 40_000_000)
        XCTAssertEqual(summary.liabilities.cents, 30_000_000 + 250_000)
        XCTAssertEqual(summary.netWorth.cents, summary.assets.cents - summary.liabilities.cents)
    }
}
