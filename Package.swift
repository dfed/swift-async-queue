// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "swift-async-queue",
	platforms: [
		// The minimum versions that support `Mutex`.
		.macOS(.v15),
		.iOS(.v18),
		.tvOS(.v18),
		.watchOS(.v11),
		.macCatalyst(.v18),
		.visionOS(.v2),
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
			],
		),
		.testTarget(
			name: "AsyncQueueTests",
			dependencies: ["AsyncQueue"],
			swiftSettings: [
				.swiftLanguageMode(.v6),
			],
		),
	],
)
