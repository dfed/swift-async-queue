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
    ],
    products: [
        .library(
            name: "AsyncQueue",
            targets: ["AsyncQueue"]),
    ],
    targets: [
        .target(
            name: "AsyncQueue",
            dependencies: []),
        .testTarget(
            name: "AsyncQueueTests",
            dependencies: ["AsyncQueue"],
            swiftSettings: [
                // TODO: Adopt `enableUpcomingFeature` once available.
                // https://github.com/apple/swift-evolution/blob/main/proposals/0362-piecemeal-future-features.md
                .unsafeFlags(["-Xfrontend", "-strict-concurrency=complete"])
            ]),
    ]
)
