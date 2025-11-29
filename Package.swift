// swift-tools-version: 6.2
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
			targets: ["AsyncQueue"],
		),
	],
	targets: [
		.target(
			name: "AsyncQueue",
			dependencies: [],
			swiftSettings: [
				.swiftLanguageMode(.v6),
				.treatAllWarnings(as: .error),
			],
		),
		.testTarget(
			name: "AsyncQueueTests",
			dependencies: ["AsyncQueue"],
			swiftSettings: [
				.swiftLanguageMode(.v6),
				.treatAllWarnings(as: .error),
			],
		),
	],
)
