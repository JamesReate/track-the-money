// swift-tools-version: 5.9
import PackageDescription

// SwiftUI app, structured as an SPM package so it builds headlessly (swift build)
// and in Xcode. The eventual iOS/macOS App Store targets are thin Xcode shells
// that import this same code; see app/README.md.
let package = Package(
    name: "TrackTheMoneyApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(path: "../TTMCore"),
    ],
    targets: [
        .executableTarget(
            name: "TrackTheMoney",
            dependencies: [.product(name: "TTMCore", package: "TTMCore")]
        ),
    ]
)
