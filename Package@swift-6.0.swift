// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-async-queue",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "AsyncQueue",
            targets: ["AsyncQueue"]),
    ],
    targets: [
        .target(
            name: "AsyncQueue",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageVersion(.v6),
            ]),
        .testTarget(
            name: "AsyncQueueTests",
            dependencies: ["AsyncQueue"],
            swiftSettings: [
                .swiftLanguageVersion(.v6),
            ]),
    ]
)
