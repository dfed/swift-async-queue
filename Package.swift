// swift-tools-version: 5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-async-queue",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
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
                .enableUpcomingFeature("StrictConcurrency")
            ]),
        .testTarget(
            name: "AsyncQueueTests",
            dependencies: ["AsyncQueue"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]),
    ]
)
