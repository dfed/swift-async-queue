// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "CLI",
	platforms: [
		.macOS(.v14),
	],
	products: [],
	dependencies: [
		.package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.56.1"),
	],
	targets: []
)
