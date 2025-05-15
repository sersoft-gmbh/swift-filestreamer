// swift-tools-version:5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let swiftSettings: Array<SwiftSetting> = [
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("IsolatedDefaultValues"),
    .enableUpcomingFeature("DeprecateApplicationMain"),
    .enableExperimentalFeature("StrictConcurrency"),
    .enableExperimentalFeature("GlobalConcurrency"),
    .enableExperimentalFeature("AccessLevelOnImport"),
//    .enableExperimentalFeature("VariadicGenerics"),
]


let package = Package(
    name: "swift-filestreamer",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "FileStreamer",
            targets: ["FileStreamer"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-system", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "FileStreamer",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            swiftSettings: swiftSettings),
        .testTarget(
            name: "FileStreamerTests",
            dependencies: ["FileStreamer"],
            swiftSettings: swiftSettings),
    ]
)
