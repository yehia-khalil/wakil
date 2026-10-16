// swift-tools-version: 6.0
import PackageDescription

// The instrument behind docs/wakil/phase-2c-iii-probe.md.
//
// The deployment target matches the app package (macOS 14.4) deliberately: a
// throughput number measured against a SwiftUI or a SwiftTerm the shipping
// target cannot have is not a measurement of anything.
//
// Swift 5 language mode, not 6. The spike reproduces the shipping chain's
// *shape* — a plain drain thread feeding an unbounded stream — but strict
// concurrency is a compile-time discipline and does not move a throughput
// number. Buying it here would cost iteration and measure nothing.
let package = Package(
    name: "termspike",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "termspike",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
