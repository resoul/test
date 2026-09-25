// swift-tools-version: 6.0

// The demo screen on iPhone and iPad. Open this folder in Xcode and run it on a simulator.
// Portrait on a phone is narrower than the card's breakpoint, so cards are columns there
// and rows in landscape.

import AppleProductTypes
import PackageDescription

let package = Package(
    name: "LayoutDemoiOS",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "LayoutDemo",
            targets: ["AppModule"],
            bundleIdentifier: "dev.layout.demo",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad])),
            ]
        )
    ],
    dependencies: [
        .package(name: "LayoutDemo", path: "../Demo"),
        .package(name: "Espalier", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            dependencies: [
                .product(name: "DemoScreens", package: "LayoutDemo"),
                .product(name: "NodesUIKit", package: "Espalier"),
            ],
            path: "."
        )
    ],
    swiftLanguageModes: [.v6]
)
