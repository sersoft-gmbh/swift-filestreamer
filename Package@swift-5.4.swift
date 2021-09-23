// swift-tools-version:5.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-filestreamer",
    platforms: [
        .macOS(.v10_12),
        .iOS(.v10),
        .tvOS(.v10),
        .watchOS(.v3),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "FileStreamer",
            targets: ["FileStreamer"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-system.git", .upToNextMinor(from: "0.0.2")),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "FileStreamer",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
            ]),
        .testTarget(
            name: "FileStreamerTests",
            dependencies: ["FileStreamer"]),
    ]
)
