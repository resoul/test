// swift-tools-version: 6.0
import PackageDescription

// Speed of the layout engine, next to the previous one on the same trees. A separate package
// so that the library never depends on the engine it is compared with.
// Run: `swift run -c release LayoutBench` (options: `--only <fixture>`, `--iterations <n>`,
// `--engine previous|current`). The previous engine is Trellis's, pinned to one revision so the
// comparison does not move under the numbers.
let package = Package(
    name: "LayoutBenchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Espalier", path: ".."),
        .package(
            url: "https://github.com/resoul/test",
            revision: "2d20d678580813855de0f07c22d02c0da90fcce5"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LayoutBench",
            dependencies: [
                .product(name: "LayoutCore", package: "Espalier"),
                .product(name: "TrellisCore", package: "test"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
