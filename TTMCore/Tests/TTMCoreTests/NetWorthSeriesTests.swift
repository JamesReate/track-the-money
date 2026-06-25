import XCTest
@testable import TTMCore

final class NetWorthSeriesTests: XCTestCase {
    func testStepFunctionReconstruction() {
        let snaps = [
            // checking (asset): 100 at t=10, 150 at t=30
            SeriesSnapshot(accountId: "chk", contribution: .asset, balanceCents: 100, balanceDate: 10),
            SeriesSnapshot(accountId: "chk", contribution: .asset, balanceCents: 150, balanceDate: 30),
            // card (liability) reported negative: owe 40 at t=20
            SeriesSnapshot(accountId: "card", contribution: .liability, balanceCents: -40, balanceDate: 20),
        ]
        let series = NetWorth.series(snapshots: snaps, propertyValues: [])
        XCTAssertEqual(series.map(\.asOf), [10, 20, 30])
        // t=10: 100 ; t=20: 100 - 40 = 60 ; t=30: 150 - 40 = 110
        XCTAssertEqual(series.map { $0.netWorth.cents }, [100, 60, 110])
    }

    func testWindowFilterAndProperty() {
        let snaps = [SeriesSnapshot(accountId: "chk", contribution: .asset, balanceCents: 100, balanceDate: 10)]
        let props = [SeriesPropertyValue(propertyId: "home", valueCents: 500, asOf: 25)]
        let series = NetWorth.series(snapshots: snaps, propertyValues: props, from: 20, to: nil)
        // t=10 filtered out; t=25: 100 (carried) + 500 = 600
        XCTAssertEqual(series.map(\.asOf), [25])
        XCTAssertEqual(series.first?.netWorth.cents, 600)
    }
}
