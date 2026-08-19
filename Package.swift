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
        // Interactive macOS demo: a small settings screen of identified
        // controls with the annotation overlay mounted. `swift run
        // AnnotKitDemo`, click Annotate, click a control (or drag a frame
        // around a stat card), type a note, Save. Writes AGENTATION_NOTES.md
        // in the working directory. Also serves as the on-camera demo app.
        .executableTarget(
            name: "AnnotKitDemo",
            dependencies: ["AnnotKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // One isolated embedding host, configured from its environment alone and
        // driven in code: mounts via `Annotation.install`, captures a note with
        // host world context, and exports to whatever destinations the launch env
        // named. `AgentLoopE2ETests` runs two of these side by side to assert an
        // agent can reproduce the world, find the notes, and be woken by them.
        .executableTarget(
            name: "AnnotKitEnvProbe",
            dependencies: ["AnnotKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // Off-screen overlay diagnostic harness. Unlike AnnotKitProbe (which only
        // exercises the IDLE corner panel), this one calls `Annotation.install()`
        // then `Annotation.start()` so the child panel EXPANDS to the full host
        // window, then inspects the AX snapshot and the raw
        // `AXUIElementCopyElementAtPosition` result THROUGH the expanded overlay.
        // It exists to confirm/refute the "expanded panel shadows the host in the
        // AX point query" hypothesis (issue 2). Reusable regression asset.
        .executableTarget(
            name: "AnnotKitOverlayProbe",
            dependencies: ["AnnotKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
