#!/usr/bin/env swift

import Foundation

// Usage: build.swift platforms

func execute(commandPath: String, arguments: [String]) throws {
	let task = Process()
	task.executableURL = .init(filePath: commandPath)
	task.arguments = arguments
	print("Launching command: \(commandPath) \(arguments.joined(separator: " "))")
	try task.run()
	task.waitUntilExit()
	guard task.terminationStatus == 0 else {
		throw TaskError.code(task.terminationStatus)
	}
}

enum TaskError: Error {
	case code(Int32)
}

enum Platform: String, CaseIterable, CustomStringConvertible {
	case iOS
	/// The minimum iOS version. Scripts/install-ios-18-simulator.sh
	/// installs its simulator runtime, which Xcode 27 can't download.
	case iOS18
	case tvOS
	case macOS
	case macCatalyst
	case watchOS
	case visionOS

	var destination: String {
		switch self {
		case .iOS:
			"platform=iOS Simulator,OS=27.2,name=iPad (A16)"

		case .iOS18:
			"platform=iOS Simulator,OS=18.5,name=iPad (10th generation)"

		case .tvOS:
			"platform=tvOS Simulator,OS=27.2,name=Apple TV 4K (4th generation)"

		case .macOS,
			 .macCatalyst:
			"platform=OS X"

		case .watchOS:
			"OS=27.2,name=Apple Watch Series 12 (46mm)"

		case .visionOS:
			"OS=27.2,name=Apple Vision Pro"
		}
	}

	var sdk: String {
		switch self {
		case .iOS,
			 .iOS18:
			"iphonesimulator"

		case .tvOS:
			"appletvsimulator"

		case .macOS,
			 .macCatalyst:
			"macosx27.2"

		case .watchOS:
			"watchsimulator"

		case .visionOS:
			"xrsimulator"
		}
	}

	var derivedDataPath: String {
		".build/derivedData/" + description
	}

	var description: String {
		rawValue
	}
}

guard CommandLine.arguments.count > 1 else {
	print("Usage: build.swift platforms")
	throw TaskError.code(1)
}

let rawPlatforms = CommandLine.arguments[1].components(separatedBy: ",")

for rawPlatform in rawPlatforms {
	guard let platform = Platform(rawValue: rawPlatform) else {
		print("Received unknown platform type \(rawPlatform)")
		print("Possible platform types are: \(Platform.allCases)")
		throw TaskError.code(1)
	}

	var xcodeBuildArguments = [
		"-scheme", "swift-async-queue",
		"-sdk", platform.sdk,
		"-derivedDataPath", platform.derivedDataPath,
		"-PBXBuildsContinueAfterErrors=0",
		"OTHER_SWIFT_FLAGS=-warnings-as-errors",
	]

	if !platform.destination.isEmpty {
		xcodeBuildArguments.append("-destination")
		xcodeBuildArguments.append(platform.destination)
	}
	xcodeBuildArguments.append("-enableCodeCoverage")
	xcodeBuildArguments.append("YES")
	xcodeBuildArguments.append("build")
	xcodeBuildArguments.append("test")
	xcodeBuildArguments.append("-test-iterations")
	xcodeBuildArguments.append("100")
	xcodeBuildArguments.append("-run-tests-until-failure")

	try execute(commandPath: "/usr/bin/xcodebuild", arguments: xcodeBuildArguments)
}
