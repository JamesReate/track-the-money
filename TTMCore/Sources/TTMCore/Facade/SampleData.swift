import Foundation

// Demo content so the UI is explorable (and screenshot-able) without a live
// SimpleFIN connection. Inserts accounts, ~8 months of balance snapshots (for
// the net-worth trend), categorized transactions, and a property with a linked
// mortgage. Invoked by LocalCore.loadSampleData().
extension LocalCore {
    public func loadSampleData() async throws {
        try store.loadSample(now: clock.now())
    }
}

extension Store {
    func loadSample(now: Int64) throws {
        let day: Int64 = 86_400
        let conn = "demo-conn"
        try saveConnection(ConnectionRecord(id: conn, name: "Demo (sample data)", keychainRef: "demo",
                                            sfinOrg: "Demo Bank", status: "ok", lastError: nil,
                                            lastSyncedAt: now, createdAt: now))

        // (sfinId, name, class, currentCents)
        let accounts: [(String, String, AccountClass, Int64)] = [
            ("chk", "Everyday Checking", .liquid, 842_055),
            ("sav", "High-Yield Savings", .liquid, 2_418_000),
            ("brk", "Brokerage", .investment, 14_230_018),
            ("visa", "Sapphire Visa", .unsecuredDebt, -342_077),
            ("mtg", "Home Mortgage", .securedDebt, -38_200_000),
        ]
        var localId: [String: String] = [:]
        for (sfin, name, cls, bal) in accounts {
            let id = "acct-\(sfin)"
            localId[sfin] = id
            try saveAccount(AccountRecord(id: id, connectionId: conn, sfinAccountId: sfin, name: name,
                                          currency: "USD", accountClass: cls.rawValue, subclass: nil, aprBps: nil,
                                          balanceCents: bal, availableCents: nil, balanceDate: now,
                                          archived: false, createdAt: now))
            // 8 monthly snapshots: assets ramp up, mortgage pays down.
            for i in 0..<8 {
                let date = now - Int64(7 - i) * 30 * day
                let factor = cls.contribution == .liability ? (1.04 - 0.006 * Double(i)) : (0.90 + 0.0143 * Double(i))
                try insertSnapshotIfAbsent(BalanceSnapshotRecord(
                    id: nil, accountId: id, balanceCents: Int64(Double(bal) * factor),
                    availableCents: nil, balanceDate: date, recordedAt: now))
            }
        }

        // (account, sfinTxnId, payee, cents, daysAgo, categoryId?)
        let txns: [(String, String, String, Int64, Int64, String?)] = [
            ("chk", "t1", "WHOLE FOODS MARKET", -8_732, 2, "groceries"),
            ("chk", "t2", "CHEWY.COM", -5_410, 3, "pets"),
            ("chk", "t3", "SHELL OIL 45271", -6_300, 4, "auto"),
            ("chk", "t4", "BLUE BOTTLE COFFEE", -575, 4, "dining"),
            ("chk", "t5", "PG&E UTILITY", -14_210, 6, "utilities"),
            ("chk", "t6", "TRADER JOES", -6_120, 7, "groceries"),
            ("chk", "t7", "HOME DEPOT #412", -15_800, 9, "home"),
            ("chk", "t8", "THE DOG GROOMER", -7_500, 11, "pets"),
            ("chk", "t9", "PAYROLL — ACME INC", 480_000, 14, "income"),
            ("chk", "t10", "NETFLIX.COM", -1_599, 15, nil),
            ("chk", "t11", "AMAZON MKTPL", -4_299, 16, nil),
            ("visa", "t12", "INTEREST CHARGE", -3_812, 5, "interest"),
            ("visa", "t13", "DELTA AIR LINES", -42_180, 8, nil),
        ]
        for (acct, sfin, payee, cents, daysAgo, cat) in txns {
            guard let aid = localId[acct] else { continue }
            let id = "txn-\(sfin)"
            let posted = now - daysAgo * day
            try saveTransaction(TransactionRecord(
                id: id, accountId: aid, sfinTxnId: sfin, postedAt: posted, transactedAt: nil,
                amountCents: cents, description: payee, payee: payee, memo: nil, pending: false,
                categoryId: cat, categorySource: cat == nil ? nil : "manual",
                isTransfer: false, transferGroupId: nil, extraJson: nil, createdAt: now, updatedAt: now))
        }

        // Property: Main House, value vs the linked mortgage → equity.
        try saveProperty(PropertyRecord(id: "prop-home", name: "Main House", kind: "real_estate", createdAt: now))
        try addPropertyValue(PropertyValueRecord(id: nil, propertyId: "prop-home", valueCents: 52_000_000,
                                                 asOf: now, note: "Estimate", createdAt: now))
        if let mtg = localId["mtg"] {
            try linkDebt(PropertyDebtRecord(propertyId: "prop-home", accountId: mtg, role: "mortgage"))
        }
    }
}
