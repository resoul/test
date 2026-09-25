// swift-tools-version: 6.0
import PackageDescription

// A screen built from nodes — text, appearance, state, taps and a breakpoint — and a Mac
// window showing it: `swift run` in this folder. The iOS app in `../DemoiOS.swiftpm` shows
// the same screen (`DemoScreens`), and so does the Apple TV app in `../DemotvOS`.
let package = Package(
    name: "LayoutDemo",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "DemoScreens", targets: ["DemoScreens"])
    ],
    dependencies: [.package(name: "Espalier", path: "..")],
    targets: [
        .target(
            name: "DemoScreens",
            dependencies: [
                .product(name: "LayoutCore", package: "Espalier"),
                .product(name: "StateCore", package: "Espalier"),
                .product(name: "Nodes", package: "Espalier"),
                .product(name: "NodesRender", package: "Espalier"),
            ]
        ),
        .executableTarget(
            name: "LayoutDemo",
            dependencies: [
                "DemoScreens",
                .product(name: "Nodes", package: "Espalier"),
                .product(name: "NodesAppKit", package: "Espalier"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
