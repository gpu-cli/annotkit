// swift-tools-version: 6.1
import PackageDescription

// AnnotKit: native in-app annotation toolbar for AI coding agents.
//
// macOS 15 / iOS 17 floor. Swift 6 language mode is enforced from day one
// (the plan calls for strict concurrency: the public Element is Sendable,
// the introspection core is MainActor). F0 ships the public API surface
// plus the pure-logic pieces (selector parse/generate/resolve and the
// AX <-> Cocoa coordinate conversion); the platform adapters, overlay,
// and sinks land in F1-F7.
let package = Package(
    name: "AnnotKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
    ],
    products: [
        .library(name: "AnnotKit", targets: ["AnnotKit"]),
        .library(name: "AnnotKitMCP", targets: ["AnnotKitMCP"]),
        .executable(name: "annotkit-mcp", targets: ["annotkit-mcp"])
    ],
    targets: [
        .target(
            name: "AnnotKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Optional agent bridge: a file-backed note store and a clean-room
        // JSON-RPC / MCP dispatcher, plus a thin stdio executable. Kept out of
        // the AnnotKit UI library so hosts that only want the toolbar do not
        // pull it in.
        .target(
            name: "AnnotKitMCP",
            dependencies: ["AnnotKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "annotkit-mcp",
            dependencies: ["AnnotKitMCP"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AnnotKitTests",
            dependencies: ["AnnotKit", "AnnotKitMCP"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // macOS smoke probe: builds an off-screen window with identified
        // controls and exercises the live AX adapter (snapshot / hitTest /
        // selector). Doubles as the seed for the F7 example app.
        .executableTarget(
            name: "AnnotKitProbe",
            dependencies: ["AnnotKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Interactive macOS demo: a window of identified controls with the
        // annotation overlay mounted. `swift run AnnotKitDemo`, click Annotate,
        // click a control, type a note, Save. Writes AGENTATION_NOTES.md in the
        // working directory.
        .executableTarget(
            name: "AnnotKitDemo",
            dependencies: ["AnnotKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
