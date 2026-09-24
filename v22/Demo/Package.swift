// swift-tools-version: 6.0
import PackageDescription

// A screen built from nodes — text, appearance, state, taps and a breakpoint — and a Mac
// window showing it: `swift run` in this folder. The iOS app in `../DemoiOS.swiftpm` shows
// the same screen (`DemoScreens`).
let package = Package(
    name: "LayoutDemo",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "DemoScreens", targets: ["DemoScreens"])
    ],
    dependencies: [.package(name: "Layout", path: "..")],
    targets: [
        .target(
            name: "DemoScreens",
            dependencies: [
                .product(name: "LayoutCore", package: "Layout"),
                .product(name: "StateCore", package: "Layout"),
                .product(name: "Nodes", package: "Layout"),
                .product(name: "NodesRender", package: "Layout"),
            ]
        ),
        .executableTarget(
            name: "LayoutDemo",
            dependencies: [
                "DemoScreens",
                .product(name: "Nodes", package: "Layout"),
                .product(name: "NodesAppKit", package: "Layout"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
