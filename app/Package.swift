// swift-tools-version: 6.0
import PackageDescription

// macOS 14.4, not the 14.0 the plan's Task 2 skeleton wrote. The original
// reason was one symbol, `TableColumnForEach` (annotated `macOS 14.4`),
// which built the pane's SwiftUI `Table` columns from `PaneStore` rather
// than a hard-coded list. Task 10 (2b-ii) removed `Table` itself — measured
// there to floor its row height at the platform default regardless of cell
// content, which made §8's dense row unreachable inside it — in favour of a
// `Grid` in a `ScrollView`, so nothing in the package now needs 14.4
// specifically. The target stays here rather than dropping back to 14.0
// anyway: lowering it is a separate decision from a row-height fix, wants
// its own verification that nothing else drifted onto 14.4 in the
// meantime, and costs nothing to defer — this app is not distributed to an
// OS between the two versions.
let package = Package(
    name: "Wakil",
    platforms: [.macOS("14.4")],
    dependencies: [
        // WakilKit's FIRST external dependency, taken by Decision 23 and
        // pinned to the version `scripts/probe/termspike` measured
        // (1.20.0, Package.resolved there). Only the HEADLESS engine is
        // used: OSC 133 parsing, OSC 7 host-directory tracking, the
        // alternate-screen notification, the search engine and the
        // Unicode width tables. Its AppKit terminal view is deliberately
        // NOT used — its SwiftUI wrapper is iOS-only, and adopting the
        // AppKit one would put Terminal.app inside Wakil: no blocks, no
        // per-block affordances, nothing from design-language.md. The
        // grid is drawn in SwiftUI.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
    ],
    targets: [
        .target(
            name: "WakilKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .executableTarget(
            name: "WakilApp",
            // NOT SwiftTerm. WakilApp keeps only the drawing, exactly as
            // for every other pane; the engine lives one target down,
            // where it can be tested.
            dependencies: ["WakilKit"],
            resources: [
                .copy("default.metallib"),
                .copy("monaco-host.html"),
                .copy("../../Resources/monaco"),
                // The Seti icon font (3b-iv-b): VS Code's single-colour file icons, MIT.
                .copy("../../Resources/seti"),
            ]),
        .testTarget(name: "WakilKitTests", dependencies: ["WakilKit"], exclude: ["Fixtures"]),
    ]
)
