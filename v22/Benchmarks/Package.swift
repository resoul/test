// swift-tools-version: 6.0
import PackageDescription

// Speed of the layout engine, next to the previous one on the same trees. A separate package
// so that the library never depends on the engine it is compared with.
// Run: `swift run -c release LayoutBench` (options: `--only <fixture>`, `--iterations <n>`,
// `--engine previous|current`).
let package = Package(
    name: "LayoutBenchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Layout", path: ".."),
        .package(name: "Trellis", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "LayoutBench",
            dependencies: [
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "TrellisCore", package: "Trellis"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
