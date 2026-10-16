// swift-tools-version: 6.0

import PackageDescription

// Small libraries that depend on Foundation only and on nothing else in the repository.
// StateCore is synchronous main-actor state with dependency tracking. RichTextCore is styled
// text as a value — blocks, runs, marks — with the operations an editor needs.
// LocalizationCore is texts looked up by key for the reader's language — catalogs, plural
// forms, pseudo-localization. Tracing marks the stretches of work that decide smoothness as
// signposts for Instruments.
let package = Package(
    name: "Basics",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "StateCore", targets: ["StateCore"]),
        .library(name: "RichTextCore", targets: ["RichTextCore"]),
        .library(name: "LocalizationCore", targets: ["LocalizationCore"]),
        .library(name: "Tracing", targets: ["Tracing"]),
    ],
    targets: [
        .target(name: "StateCore"),
        .target(name: "RichTextCore"),
        .target(name: "LocalizationCore"),
        .target(name: "Tracing"),
        .testTarget(name: "StateCoreTests", dependencies: ["StateCore"]),
        .testTarget(name: "RichTextCoreTests", dependencies: ["RichTextCore"]),
        .testTarget(name: "LocalizationCoreTests", dependencies: ["LocalizationCore"]),
        .testTarget(name: "TracingTests", dependencies: ["Tracing"]),
    ]
)
