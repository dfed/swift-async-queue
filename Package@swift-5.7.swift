// swift-tools-version: 5.7
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
    ],
    products: [
        .library(
            name: "AsyncQueue",
            targets: ["AsyncQueue"]),
    ],
    targets: [
        .target(
            name: "AsyncQueue",
            dependencies: []
        ),
        .testTarget(
            name: "AsyncQueueTests",
            dependencies: ["AsyncQueue"]
        )
    ]
)
