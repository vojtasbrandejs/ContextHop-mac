// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextHop",
    platforms: [.macOS(.v14)],
    targets: [
        // Core logic: session parsers, detection, prompt building
        .target(name: "ContextHopKit"),
        // Menu bar app
        .executableTarget(
            name: "ContextHop",
            dependencies: ["ContextHopKit"]
        ),
        // Headless debug CLI for testing without GUI
        .executableTarget(
            name: "contexthop-cli",
            dependencies: ["ContextHopKit"]
        ),
        // Test harness as a plain executable: this machine has Command Line Tools
        // only (no Xcode.app), so `swift test` cannot execute XCTest/Swift Testing
        // bundles — it silently reports success. Run with `swift run contexthop-tests`.
        .executableTarget(
            name: "contexthop-tests",
            dependencies: ["ContextHopKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
