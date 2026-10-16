// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sttspike",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "sttspike",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]),
    ]
)
