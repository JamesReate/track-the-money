// swift-tools-version: 5.9
import PackageDescription

// TTMCore — the pure, UI-independent domain core for Track The Money.
// Hard rule (see TECH_DESIGN.md §3): NO SwiftUI/UIKit/AppKit imports here, and
// the OS is reached only through injected protocols (SecretStore, Clock,
// NetworkClient). This is what keeps the engines testable and the future Rust
// port (TECH_DESIGN.md §13) bounded.
let package = Package(
    name: "TTMCore",
    platforms: [
        .iOS(.v17),     // Observation, modern SwiftUI on the app side; CryptoKit HPKE
        .macOS(.v14),
    ],
    products: [
        .library(name: "TTMCore", targets: ["TTMCore"]),
    ],
    dependencies: [
        // Pin to a known-good range; bump as desired on your Mac.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "TTMCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "TTMCoreTests",
            dependencies: ["TTMCore"]
        ),
    ]
)
