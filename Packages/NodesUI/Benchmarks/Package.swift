// swift-tools-version: 6.0
import PackageDescription

// A layout pass while the demo's screen scrolls over its lazy lists.
// Run: `swift run -c release ScrollBench`. `Sources/ScrollBench/DemoScreen.swift` links to the
// demo's screen, so the benchmark measures the screen the demo shows.
let package = Package(
    name: "NodesBenchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "NodesUI", path: ".."),
        .package(path: "../../Layout"),
        .package(path: "../../Basics"),
    ],
    targets: [
        .executableTarget(
            name: "ScrollBench",
            dependencies: [
                .product(name: "FlexEngine", package: "Layout"),
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "ThemeCore", package: "Layout"),
                .product(name: "StateCore", package: "Basics"),
                .product(name: "Nodes", package: "NodesUI"),
                .product(name: "NodesRender", package: "NodesUI"),
                .product(name: "AppShell", package: "NodesUI"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
