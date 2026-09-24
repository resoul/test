// swift-tools-version: 6.0
import PackageDescription

// A window showing a screen built from nodes: text, appearance, state and a breakpoint.
// Run on a Mac: `swift run` in this folder. Resize the window to cross the breakpoint.
let package = Package(
    name: "LayoutDemo",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "Layout", path: "..")],
    targets: [
        .executableTarget(
            name: "LayoutDemo",
            dependencies: [
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "StateCore", package: "Layout"),
                .product(name: "Nodes", package: "Layout"),
                .product(name: "NodesRender", package: "Layout"),
                .product(name: "NodesAppKit", package: "Layout"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
