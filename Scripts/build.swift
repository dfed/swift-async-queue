#!/usr/bin/env swift

import Foundation

// Usage: build.swift platforms

func execute(commandPath: String, arguments: [String]) throws {
    let task = Process()
    task.launchPath = commandPath
    task.arguments = arguments
    print("Launching command: \(commandPath) \(arguments.joined(separator: " "))")
    task.launch()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw TaskError.code(task.terminationStatus)
    }
}

enum TaskError: Error {
    case code(Int32)
}

enum Platform: String, CaseIterable, CustomStringConvertible {
    case iOS_18
    case tvOS_18
    case macOS_15
    case macCatalyst_15
    case watchOS_11
    case visionOS_2

    var destination: String {
        switch self {
        case .iOS_18:
            return "platform=iOS Simulator,OS=18.1,name=iPad Pro (12.9-inch) (6th generation)"

        case .tvOS_18:
            return "platform=tvOS Simulator,OS=18.1,name=Apple TV"

        case .macOS_15,
             .macCatalyst_15:
            return "platform=OS X"

        case .watchOS_11:
            return "OS=11.1,name=Apple Watch Series 7 (45mm)"

        case .visionOS_2:
            return "OS=2.1,name=Apple Vision Pro"
        }
    }

    var sdk: String {
        switch self {
        case .iOS_18:
            return "iphonesimulator"

        case .tvOS_18:
            return "appletvsimulator"

        case .macOS_15,
             .macCatalyst_15:
            return "macosx15.1"

        case .watchOS_11:
            return "watchsimulator"

        case .visionOS_2:
            return "xrsimulator"
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
