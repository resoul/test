// swift-tools-version: 6.0
import PackageDescription

// Speed of the layout engine, next to the previous one on the same trees. A separate package
// so that the library never depends on the engine it is compared with.
// Run: `swift run -c release LayoutBench` (options: `--only <fixture>`, `--iterations <n>`,
// `--engine previous|current`). The previous engine is a frozen copy of its sources in
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
    ],
    swiftLanguageModes: [.v6]
)
