// swift-tools-version: 6.0

import PackageDescription

// What the app knows about the system's permissions. PermissionCore is kinds, status, errors
// and one order of asking, with a stand-in for tests; it depends on Foundation only.
// PermissionSystem asks the system's frameworks and checks the Info.plist keys before it
// does; PermissionUIKit and PermissionAppKit say whether the app is in front and open its
// Settings.
let package = Package(
    name: "Permissions",
    platforms: [.macOS(.v14), .iOS(.v16), .tvOS(.v16)],
    products: [
        .library(name: "PermissionCore", targets: ["PermissionCore"]),
        .library(name: "PermissionSystem", targets: ["PermissionSystem"]),
        .library(name: "PermissionUIKit", targets: ["PermissionUIKit"]),
        .library(name: "PermissionAppKit", targets: ["PermissionAppKit"]),
    ],
    targets: [
        .target(name: "PermissionCore"),
        // Some frameworks are in a platform's SDK with their calls marked unavailable, which
        // `canImport` cannot tell from a framework that works; these conditions name the
        // platforms where the calls exist.
        .target(
            name: "PermissionSystem",
            dependencies: ["PermissionCore"],
            swiftSettings: [
                .define("PERMISSION_LOCATION_ALWAYS", .when(platforms: [.iOS, .macOS, .macCatalyst])),
                .define("PERMISSION_SPEECH", .when(platforms: [.iOS, .macOS, .macCatalyst])),
                .define("PERMISSION_MOTION", .when(platforms: [.iOS, .macCatalyst])),
                .define("PERMISSION_MEDIA_LIBRARY", .when(platforms: [.iOS, .macCatalyst])),
            ]
        ),
        .target(name: "PermissionUIKit", dependencies: ["PermissionSystem", "PermissionCore"]),
        .target(name: "PermissionAppKit", dependencies: ["PermissionSystem", "PermissionCore"]),
        .testTarget(name: "PermissionCoreTests", dependencies: ["PermissionCore"]),
        .testTarget(
            name: "PermissionSystemTests",
            dependencies: ["PermissionSystem", "PermissionCore"]
        ),
    ]
)
