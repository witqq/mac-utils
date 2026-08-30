// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacUtils",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "MacUtilsCore", targets: ["MacUtilsCore"]),
        .library(name: "MacUtilsSystem", targets: ["MacUtilsSystem"]),
        .executable(name: "MacUtilsApp", targets: ["MacUtilsApp"]),
    ],
    targets: [
        .target(name: "MacUtilsCore"),
        .target(
            name: "MacUtilsSystem",
            dependencies: ["MacUtilsCore"]
        ),
        .executableTarget(
            name: "MacUtilsApp",
            dependencies: ["MacUtilsCore", "MacUtilsSystem"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MacUtilsCoreTests",
            dependencies: ["MacUtilsCore"]
        ),
        .testTarget(
            name: "MacUtilsSystemTests",
            dependencies: ["MacUtilsSystem"]
        ),
        .testTarget(
            name: "MacUtilsAppTests",
            dependencies: ["MacUtilsApp", "MacUtilsCore", "MacUtilsSystem"]
        ),
    ]
)
