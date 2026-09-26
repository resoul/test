// swift-tools-version: 6.0
import PackageDescription

// Speed of the layout engine, next to the previous one on the same trees. A separate package
// so that the library never depends on the engine it is compared with.
// Run: `swift run -c release LayoutBench` (options: `--only <fixture>`, `--iterations <n>`,
// `--engine previous|current`); `swift run -c release ScrollBench` for a scroll of the demo. The previous engine is a frozen copy of its sources in
// `Sources/PreviousLayoutEngine`, so the comparison does not move under the numbers and needs
// nothing outside this folder.
let package = Package(
    name: "LayoutBenchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Espalier", path: "..")
    ],
    targets: [
        .target(name: "PreviousLayoutEngine"),
        .executableTarget(
            name: "LayoutBench",
            dependencies: [
                .product(name: "LayoutCore", package: "Espalier"),
                "PreviousLayoutEngine",
            ]
        ),
        // The demo's screen (`Sources/ScrollBench/DemoScreen.swift` links to it) scrolled
        // over its lazy lists.
        .executableTarget(
            name: "ScrollBench",
            dependencies: [
                .product(name: "LayoutCore", package: "Espalier"),
                .product(name: "StateCore", package: "Espalier"),
                .product(name: "Nodes", package: "Espalier"),
                .product(name: "NodesRender", package: "Espalier"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
